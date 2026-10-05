# Getting Started with Lyra

This is the short path: install Lyra in a Rails application, record events for
one model in Monitor mode, and check that the events agree with the table. In
Monitor the tables stay authoritative and every write behaves as before; Lyra
only appends an event after it. Moving on to Hijack or event sourcing is
covered by [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md), and every option by
[API_REFERENCE.md](API_REFERENCE.md).

## Requirements

- Ruby 4.0 or later and Rails 8.0 or later (from `lyra.gemspec`).
- RailsEventStore 3 (`rails_event_store ~> 3.0`), pulled in by Lyra.
- PostgreSQL. Lyra depends on the `pg` gem. Genesis and ES-Lazy take
  PostgreSQL advisory locks to stay correct under concurrency, and Hijack
  reserves record ids from PostgreSQL sequences.
- Writes go through ActiveRecord. Lyra does not see raw SQL, triggers, or
  other applications writing the same tables.

## 1. Install

The gems are named `orfeas_*`, and their entry files are not, so name the
file to require. From a checkout of the repository:

```ruby
# Gemfile
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"          # optional, privacy
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"  # optional, verification
```

or the engine straight from GitHub:

```ruby
gem "orfeas_lyra", git: "https://github.com/mpantel/lyra-engine", branch: "main", require: "lyra"
```

The `orfeas_*` 0.6.0 releases on rubygems.org date from January 2026 and
predate this guide (no RailsEventStore 3, Genesis or repair); use the
repository.

Then install, and create the event store tables with the RailsEventStore 3
generator:

```bash
bundle install
bin/rails generate ruby_event_store:active_record:migration
bin/rails db:migrate
```

Lyra's own tables (`lyra_mode_transitions`, `lyra_projection_checkpoints`) are
created on first use.

## 2. Add an initializer in Monitor

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor
end
```

`:monitor` is also the default. Without `config.event_store`, the engine uses
`RailsEventStore::Client.new`. Other options (a JSON serializer, who made each
change through `config.metadata_proc`) are in
[MIGRATION_GUIDE.md, Phase 0](MIGRATION_GUIDE.md#phase-0-install).

## 3. Monitor one model

In the model:

```ruby
class Order < ApplicationRecord
  monitor_with_lyra
end
```

or by name in the initializer, without editing the model file:

```ruby
config.models = %w[Order]
```

A name in `config.models` that does not resolve to a class fails the boot.

## 4. Make a write and read its stream

Each record has one stream, `"#{Model.name}$#{id}"`. In `bin/rails console`:

```ruby
order = Order.create!(total: 10)
order.update!(total: 12)

events = Lyra.config.event_store.read.stream("Order$#{order.id}").to_a
events.map(&:event_type)  # => ["Lyra::Events::OrderCreated", "Lyra::Events::OrderUpdated"]
events.last.operation     # => :updated
events.last.changes       # the update's previous_changes
events.last.attributes    # the row after the write, without created_at/updated_at
```

`destroy` appends `OrderDestroyed`. Writes that skip callbacks (`update_all`,
`delete_all`, `insert_all`, ...) are recorded as bypass events; see
[API_REFERENCE.md](API_REFERENCE.md#callback-bypassing-writes).

If an append fails in Monitor, the write stands and the error is logged
(`Lyra: Failed to publish event ... run bin/rails lyra:repair ...`). Step 7
finds and repairs such records. `config.monitor_append_failure = :fail_write`
fails the write instead.

## 5. Compare the row with its events

```ruby
Lyra::DualView.new(Order, order.id).compare
# => { crud_view: {...}, event_sourced_view: {...},
#      differences: { no_differences: true }, metadata: {...} }
```

`differences` is `{ no_differences: true }` when the row and the state replayed
from the stream agree (a destroyed record whose row is gone agrees too),
`{ exists_mismatch: true }` when only one of them has the record, and
otherwise one entry per differing column,
`{ total: { crud: ..., event_sourced: ... } }`. `created_at` and `updated_at`
are not compared. `Lyra::DualView.find_discrepancies(Order)` runs the
comparison for every row.

## 6. Rows that existed before Lyra

A row written before Lyra was enabled has no stream, so DualView reports
`exists_mismatch` for it. Genesis gives each such row one `Imported` event
(`OrderImported`) holding the row as it is. With the default
`config.genesis = :auto` it runs by itself only in event-sourcing mode, so in
Monitor run it yourself:

```bash
bin/rails lyra:genesis                # every monitored model
bin/rails lyra:genesis MODEL=Order
```

or set `config.genesis = true` to import on the first write to each model in
a process. Run the task before the first write when the table already has
rows. Details: [MIGRATION_GUIDE.md, Phase 2](MIGRATION_GUIDE.md#phase-2-genesis-rows-that-predate-lyra).

## 7. Check every record

```bash
bin/rails lyra:repair DRY_RUN=1               # lists out-of-line records, writes nothing
bin/rails lyra:repair DRY_RUN=1 MODELS=Order
```

It prints `checked N records: X out of line, 0 repaired, X still out of line`
and up to 20 findings, each one of "row but no events", "events but no row",
"row of a destroyed record" or "row differs from its events". Without
`DRY_RUN=1` it appends events that bring each stream back in line with its row.
It runs only in Monitor or Disabled, where the tables are authoritative. See
[MIGRATION_GUIDE.md, Phase 3](MIGRATION_GUIDE.md#phase-3-verify-and-repair-in-monitor).

## 8. Optional: mount the dashboard

```ruby
# config/routes.rb
mount Lyra::Engine => "/lyra"
```

The dashboard is at `/lyra/dashboard` (the engine's root redirects to
`dashboard` under wherever you mount it), with record comparisons, audit
trails, event flow views and privacy pages. It is open in development and
test; elsewhere it answers 403 until you say who may use it, because its
privacy pages show personal data:

```ruby
# config/initializers/lyra.rb
config.dashboard_authorization = ->(controller) { controller.current_user&.admin? }
```

## Do not just change the mode in the initializer

Changing `config.mode` to `:hijack` or `:event_sourcing` makes the events
authoritative. Outside the test environment, Lyra then refuses to boot unless
a clean check certifies the switch from the mode the application last ran in:

```bash
bin/rails lyra:mode:status
bin/rails lyra:mode:check TO=hijack
```

Run the check, fix what it reports, and deploy the new mode within the
certificate's lifetime (an hour by default). The whole procedure, and how to
step back, is in [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#phase-4-hijack) and
[MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes).

## Where next

- [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md): from Monitor to Hijack and event
  sourcing, through the mode check, with recovery steps.
- [API_REFERENCE.md](API_REFERENCE.md): every configuration option, method and
  rake task.
- [MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes): how mode switches are checked
  and certified.
- [MIGRATION_GUIDE.md, Adopting Lyra](MIGRATION_GUIDE.md#adopting-lyra-in-an-existing-application): what adoption costs, and when it is not worth it.
- [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md): privacy policies with PAM
  DSL, erasure, retention and access logging.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the engine is built.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): common errors.
