# Migrating a Rails Application from CRUD to Event Sourcing

This guide takes an existing Rails application from plain ActiveRecord to event
sourcing with Lyra, one checked step at a time. Each step can be undone by
switching back to the previous mode.

It is written for developers who maintain a Rails 8 application on PostgreSQL
and want an event history of it, and possibly event sourcing, without
rewriting its models or controllers. Read
[Adopting Lyra in an existing application](#adopting-lyra-in-an-existing-application)
first: it says what adoption costs and when it is not worth it. How a mode
switch works is in [Switching modes](#switching-modes). Method signatures and
every configuration option are in [API_REFERENCE.md](API_REFERENCE.md).

## Adopting Lyra in an existing application

What "non-intrusive" means for Lyra, what adopting it costs, and what to check
in your own codebase before relying on it. Written from the real-data replays
(BPI Challenge 2017, and Olist orders through an unmodified Solidus 4.7) and the
Aegean ePay testbed, all part of the research evaluation behind Lyra.

### What "non-intrusive" means here

**It holds in two senses:**

- **No application code changes.** Solidus needed only the gem, an
  initializer, and `monitor_with_lyra` added to its models from outside
  (`class_eval`). No Solidus source was edited.
- **The same results as plain ActiveRecord**, in Monitor, Hijack, ES-Sync and
  ES-Lazy. On both replays these modes ended in the state an independent
  oracle expects (computed from the source data alone) and matched Disabled
  mode, with DualView finding every row consistent with its events.

**It does not mean:**

- **Zero cost.** Every mode costs throughput (below).
- **Unchanged behaviour in every mode.** ES-NoProj answers reads differently.
- **That Lyra sees every write.** Writes that bypass ActiveRecord never reach
  it.

### Is it worth it?

**Yes, when you want what only it gives you:**

- a complete event history of an application you cannot or will not rewrite;
- a migration path toward event sourcing in which every step is checked
  (DualView, and an oracle where you can build one) and can be undone by
  switching mode.

Its costs are the price of those two things, and each one can be measured
before you commit: start in Monitor against real traffic, which changes no
results.

**Probably not, if:**

- you need neither a history nor a migration, and your hot path is
  write-heavy and latency-critical;
- a large share of your writes are raw SQL or database triggers (Lyra cannot
  see them);
- you want to replay on every read (ES-NoProj) in code that reads through
  joins and merged relations. Use ES-Lazy, or stay with a projected mode.

### Costs, and what to do about each

| Caveat | Effect | What to do |
|---|---|---|
| **Throughput** | Every mode costs throughput against plain ActiveRecord; how much is being re-measured. The mechanism is countable: every event adds two inserts, Monitor also opens a savepoint on every write, and Hijack avoids it on updates ([PERFORMANCE.md](PERFORMANCE.md)). | Measure on your workload in Monitor first. The cost is per write, so it scales with your write share. |
| **ES-NoProj changes read semantics** | Reads come from event streams. Joins on plain associations are evaluated in memory, as SQL would. Queries it cannot answer exactly (merged relations, SQL fragments, nested, `:through` or scoped joins) raise `UnsupportedQuery` rather than guess. It cannot run Solidus. | Use **ES-Lazy** (`projection_mode :lazy`): it brings tables up to date from the log before each read and runs real SQL. |
| **ES-NoProj read cost** | Every answer is rebuilt from streams, from cached entries that are each checked against their stream's last event. Collection reads touch every stream of the model. A delete that nullifies children must find them by attribute: 0.1–0.4 s in the Aegean smoke runs. A filter on a `belongs_to` association compares foreign keys, as ActiveRecord does, but every collection read still assembles the whole model from the cache: about 1.3 s per query over 10,000 rows in the mode-comparison benchmark, against 1–6 ms with real SQL. | Keep ES-NoProj for code that reads through simple finders, or use ES-Lazy. |
| **Monitor and failed appends** | By default (`config.monitor_append_failure = :log`), if the event append fails in Monitor, the write still succeeds and the failure is only logged. | Alert on the log and run `lyra:repair` ([Phase 3](#phase-3-verify-and-repair-in-monitor)). If losing events is unacceptable, set `config.monitor_append_failure = :fail_write`, or use Hijack or an event-sourcing mode, where the append is the write. |
| **Global hooks** | Hijack and the event-sourcing modes take over writes through modules prepended to `ActiveRecord::Persistence` and `ActiveRecord::Relation`. They act only on monitored models, and they switch PaperTrail off for those models. | Expect them in stack traces. If you rely on PaperTrail versions for monitored models, rely on Lyra's events instead. |
| **Bulk writes record events** | `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify` on a monitored model publish one event per affected row. | Wrap seeding, fixtures and table wipes in `Lyra.projection_write { … }`, which publishes nothing. |
| **Rows that predate Lyra** | In event-sourcing modes, a model's first use imports every row that has no stream yet (Genesis), so it can be slow once. | Run `bin/rails lyra:genesis MODEL=…` before switching modes on large tables ([Phase 2](#phase-2-genesis-rows-that-predate-lyra)). |
| **Writes Lyra cannot see** | Raw SQL (`connection.execute`), database triggers, other applications writing the same tables. | Find them before you rely on the history. DualView reports the rows they changed as discrepancies. |
| **Unverified codebases** | Each real-data replay found Lyra defects that broke these guarantees until fixed: namespaced models could not use Hijack or event sourcing at all, events were built before the model's own callbacks ran, and `update_columns`/`touch` writes went unrecorded. | Treat "the hook sees every write" as something to verify for your codebase, not to assume. See the checklist. |

### Checklist for a new codebase

1. **Start in Monitor** against real traffic. Nothing changes but cost and
   the event log.
2. **Run DualView** over the monitored models (`Lyra::DualView`,
   `bin/rails lyra:repair DRY_RUN=1`). A discrepancy means a write Lyra did not
   see, or a defect.
3. **Search for writes outside ActiveRecord**: `execute`, `exec_update`,
   triggers in the schema, other writers to the database.
4. **Wrap housekeeping bulk writes** in `Lyra.projection_write`.
5. **Import existing rows** with `bin/rails lyra:genesis` before an
   event-sourcing mode.
6. **Pick the event-sourcing variant by how the code reads.** ES-Sync for
   table-shaped reads. ES-Lazy if reads use joins or merged relations.
   ES-NoProj only for simple finders.
7. **Where you can, replay a real workload with an oracle**
   ([Testing during the migration](#testing-during-the-migration)). An oracle
   catches writes that never reached the database, which DualView cannot,
   because both of its views come from the same system.

### Evidence

- [PERFORMANCE.md](PERFORMANCE.md): per-mode cost, why, and how to measure it.
- [CHANGELOG.md](../CHANGELOG.md): what changed and why, entry by entry,
  including the defects the real-data replays found and their fixes.

## Prerequisites

- Ruby 4.0 or later, Rails 8.0 or later.
- PostgreSQL. Lyra depends on the `pg` gem, and several features rely on
  PostgreSQL: the advisory locks that keep Genesis and ES-Lazy correct under
  concurrency (SQLite needs none; on other databases the step runs unlocked and
  Lyra logs a warning that it is safe in a single process only), and safe id
  reservation in Hijack mode (integer keys backed by a PostgreSQL sequence;
  elsewhere Hijack falls back to a placeholder id with a warning).
- RailsEventStore 3 (`rails_event_store ~> 3.0`, pulled in by Lyra).
- All writes you want recorded go through ActiveRecord. Lyra does not see raw
  SQL (`connection.execute`), database triggers, or other applications
  writing the same tables.
- Optional: the `orfeas_pam_dsl` gem for privacy features, the
  `orfeas_petri_flow` gem for mapping verification.

## The modes at a glance

The mode is application-wide. Event sourcing takes one of four projection
modes, which gives seven configurations:

| Configuration | Settings | Authoritative store | What a write does | Reads |
|---|---|---|---|---|
| Disabled | `mode = :disabled` | tables | plain ActiveRecord, no events | tables |
| Monitor | `mode = :monitor` | tables | row written, then the event appended in the same transaction | tables |
| Hijack | `mode = :hijack` | events | event appended, then the row written | tables |
| ES-Sync | `mode = :event_sourcing`, `projection_mode = :sync` | events | event appended; the row projected in the same transaction | tables |
| ES-Async | `mode = :event_sourcing`, `projection_mode = :async` | events | event appended; the row projected later by a background job | tables, which lag the log |
| ES-NoProj | `mode = :event_sourcing`, `projection_mode = :disabled` | events | event appended; no row | records rebuilt from events, queries evaluated in Ruby |
| ES-Lazy | `mode = :event_sourcing`, `projection_mode = :lazy` | events | event appended; no row yet | tables brought up to date from the log before each read, then real SQL |

The path this guide follows is Disabled → Monitor → Hijack → one of the
event-sourcing configurations. Every switch that makes the events
authoritative is checked first (Mode Transition Safety); see
[Switching modes](#switching-modes).

## Phase 0: Install

**1. Add the gems.** The gem names and their entry files differ, so name the
file to require:

```ruby
# Gemfile
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"          # optional
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"  # optional
```

**2. Create the event store tables** with the RailsEventStore 3 generator:

```bash
bin/rails generate ruby_event_store:active_record:migration
bin/rails db:migrate
```

Lyra's own tables (`lyra_mode_transitions`, `lyra_projection_checkpoints`) are
created on first use and need no migration.

**3. Add an initializer.** Start in Monitor:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor

  # Optional. Without it the engine uses RailsEventStore::Client.new (YAML
  # serializer). If you configure a JSON serializer, use Lyra::EventSerializer,
  # not JSON: JSON drops fractional seconds from times.
  config.event_store = RailsEventStore::Client.new(
    repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
  )

  # Optional: who made each change, merged into every event's metadata.
  config.metadata_proc = ->(record, operation) { { user_id: Current.user&.id } }
end
```

Real initializers: `examples/aegean_epay_testbed/config/initializers/lyra.rb`
and `examples/solidus_case_study/config/initializers/lyra.rb`.

**4. Choose the models.** Either in each model:

```ruby
class Order < ApplicationRecord
  monitor_with_lyra
end
```

or by name in the initializer, without editing model files (the way to
instrument a gem's models, such as Solidus's):

```ruby
config.models = %w[Order Payment]
config.models = { "Spree::Order" => { event_prefix: "Shop" }, "Spree::Payment" => {} }
```

Declared models are instrumented once the application's code has loaded, and
again after each reload; a name that does not resolve fails the boot. A model
records events from the moment it is declared, in whatever mode the
application runs. There is no per-model mode: `monitor_with_lyra` ignores a
`mode:` option.

Events go to one stream per record, named `"#{Model.name}$#{id}"`
(`"Order$42"`), with event types such as `OrderCreated`, `OrderUpdated` and
`OrderDestroyed` (`event_prefix:` changes the prefix).

**5. Optional: verify the mapping at boot** (needs PetriFlow):

```ruby
config.verify_mapping!
```

It runs the PetriFlow nets for the CRUD-to-event mapping and checks that each
monitored model has a table and a primary key; a failure stops the boot.

**6. Optional: mount the dashboard.** `mount Lyra::Engine => "/lyra"` serves a
dashboard and privacy pages (subject data, exports). Outside development and
test it answers 403 until you say who may use it:

```ruby
config.dashboard_authorization = ->(controller) { controller.current_user&.admin? }
```

The proc runs on the engine's controller before every action; see
[API_REFERENCE.md](API_REFERENCE.md#dashboard).

## Phase 1: Monitor

**What changes.** After each create, update or destroy of a monitored model,
an event is appended inside the write's transaction (in a savepoint, opened by
the event store's repository). The table stays authoritative. If the append
fails, the error is logged (`Lyra: Failed to publish event ... run bin/rails
lyra:repair`) and the write stands; its stream then falls behind its row until
repaired. Alert on that log line. To fail the write instead, as Hijack and
event sourcing do, set `config.monitor_append_failure = :fail_write`; an
event-store failure then becomes a failed write.

Writes that skip callbacks are recorded as bypass events, one per affected
row: `update_column(s)`, `touch`, `delete`, `update_all`, `delete_all`,
`insert_all`, `upsert_all` and `dependent: :nullify`. A bulk write on a large
table therefore writes many events. Two settings govern them:

- `config.strict_data_access = true` (opt-in) makes the callback-bypassing
  methods raise `Lyra::StrictDataAccessViolation` on monitored models
  (`touch` and `dependent: :nullify` are allowed). Use it to find them.
  `Lyra.without_strict_access { ... }` allows them in a block; they still
  publish events.
- `Lyra.projection_write { ... }` runs a block that publishes nothing and
  skips the strict check. Use it for seeding, fixtures and table wipes whose
  history you do not want.

Rows that already exist have no stream yet. Read Phase 2 before the first
deploy: setting `config.genesis = true` now avoids a stream starting without
its record's state.

**How to switch.** Monitor is the default mode and leaving Disabled for Monitor
is not checked; deploy the initializer.

**How to verify.** Create, update and destroy a record in a console and read
its stream:

```ruby
Lyra.config.event_store.read.stream("Order$#{order.id}").to_a
Lyra::DualView.new(Order, order.id).compare   # the row against the replayed events
```

Phase 3 covers checking every record.

**How to step back.** Switch to `:disabled` (not checked). Writes made while
disabled are not recorded; `lyra:repair` (Phase 3) brings their streams back
in line when you return to Monitor.

## Phase 2: Genesis (rows that predate Lyra)

**What changes.** Genesis gives each row that has no stream one `Imported`
event (for example `OrderImported`) holding the row as it is, timestamps
included. Replay treats it like `Created`; its metadata says `genesis: true`.
Without it, a pre-existing record's first `Updated` event starts a stream
with no head, and DualView, rebuilds, the mode check and ES-NoProj see the
record wrongly or not at all.

`config.genesis` decides when it runs on its own:

| Value | Runs on first use in |
|---|---|
| `:auto` (default) | event-sourcing mode only |
| `true` | every mode that records events (Monitor, Hijack, event sourcing) |
| `false` | never |

"First use" is the first write to the model in a process (and, in ES-NoProj,
the first read): it imports every row of the model without a stream, once.
The import runs under a per-model PostgreSQL advisory lock, on a connection of
its own when the caller is inside a transaction.

**How to run it.** On large tables, import ahead of time so no request pays
for it:

```bash
bin/rails lyra:genesis                      # every monitored model
bin/rails lyra:genesis MODEL=Order,Payment
```

This works in any mode. The mode check of Phase 4 also imports rows without a
stream before it compares.

**How to verify.** `bin/rails lyra:repair DRY_RUN=1` (Phase 3) should no longer
list "row but no events".

**How to step back.** Imported events stay in the log; there is nothing to undo.

## Phase 3: Verify and repair in Monitor

Run Monitor against real traffic long enough to exercise your write paths, and
check that every row agrees with its events. A discrepancy means a write Lyra
did not see (raw SQL, a trigger, another application), a lost append, or a
defect.

**Full check, read-only:**

```bash
bin/rails lyra:repair DRY_RUN=1                 # lists out-of-line records, writes nothing
bin/rails lyra:repair DRY_RUN=1 MODELS=Order
```

Each finding is one of: "row but no events", "events but no row", "row of a
destroyed record", "row differs from its events (columns...)".

**Sampled check, continuous (opt-in):**

```ruby
config.dual_view_sample_rate = 0.01   # share of committed writes compared; 0.0 (default) is off
config.dual_view_discrepancy_handler = ->(discrepancy) { ErrorTracker.notify(discrepancy.to_s) }
```

Sampling runs after commit, never fails or delays the write, logs each
discrepancy (`Lyra DualView sample: ...`) and costs a stream read and a replay
per sampled write. It is skipped in ES-NoProj, ES-Lazy and ES-Async, whose
tables lag the log by design.

**Repair.** In Monitor (or Disabled), where the table is authoritative:

```bash
bin/rails lyra:repair                  # all monitored models
bin/rails lyra:repair MODELS=Order
```

It appends, under a lock on each row: an `Imported` event for a row with no
events or for a row its stream says was destroyed; an `Updated` event with the
differing columns; a `Destroyed` event where events exist but the row does
not. Each carries metadata `source: "lyra_repair"`. The stream then replays to
the row; the detail of the missed changes is not recovered. The task exits
non-zero if anything is still out of line, and refuses to run in Hijack or an
event-sourcing mode, where the events are authoritative.

Then find the cause: search for `execute`, `exec_update`, triggers in
`db/structure.sql`, and other writers to the database.

## Phase 4: Hijack

**What changes.** Lyra takes over the write itself. Its hooks are prepended to
`ActiveRecord::Persistence`, so they run after every `before_*` callback of the
model and just before the INSERT, UPDATE or DELETE. The write goes through a
command; the event is appended first, then the row is written, in the same
transaction. The events are now authoritative: if the event cannot be stored,
the write fails with `Lyra::EventStoreUnavailableError` and rolls back. A
command that fails returns false, so `save` returns false with the error on
`errors[:base]`. PaperTrail, if present, is switched off for monitored models
in this mode and the event-sourcing modes. Reads are unchanged.

**How to switch (gated).** Moving from Monitor (or Disabled) to Hijack or any
event-sourcing mode is checked: every row must agree with its events.

1. Check ahead, on the running application:
   ```bash
   bin/rails lyra:mode:check TO=hijack
   ```
2. Deploy `config.mode = :hijack`.
3. The boot gate lets each process start in Hijack only with a fresh
   certificate from that check; ModeSync brings processes still on the old
   configuration into the new mode.

At run time, `Lyra::ModeTransition.to!(:hijack)` or
`Lyra.config.enable_hijack!` runs the same gate in the current process. What
each step does, and the overrides, are in
[The rule: switch modes with a deploy](#the-rule-switch-modes-with-a-deploy),
[Switching at run time](#switching-at-run-time) and [Overrides](#overrides).

**How to verify.** `bin/rails lyra:mode:status` shows the configured mode, the
last applied one and whether the gate is on. Sampled DualView (Phase 3) keeps
working in Hijack.

**How to step back.** Hijack → Monitor is not checked: the tables were written
on every write. Deploy `config.mode = :monitor`.

## Phase 5: Event sourcing

**What changes.** A write appends its events and does not issue its own
INSERT, UPDATE or DELETE; what happens to the table depends on
`config.projection_mode`. As in Hijack, a write whose event cannot be stored
fails and rolls back. `config.genesis = :auto` imports pre-existing rows on
first use. Choose the projection mode by how your code reads:

**ES-Sync (`:sync`, the default).** The row is projected from the event in the
same transaction. Reads are unchanged. If a projection fails, the error is
logged and `config.projection_error_handler` is called, and the write stands
with its table behind; set `config.strict_projections = true` to make the
write fail instead.

**ES-Async (`:async`).** The row is projected by
`Lyra::Projections::AsyncProjectionJob` (queue `lyra_projections`), enqueued
after commit and retried on failure. Writes are cheaper than ES-Sync, but
reads are eventually consistent: a record just created is not in its table
until the job runs, so `find` right after `create!` can raise
`RecordNotFound`. Needs a running ActiveJob backend.

**ES-NoProj (`:disabled`).** Nothing is projected. Reads of monitored models
(`find`, `find_by`, `where`, `all`, `first`, `last`, associations,
aggregates) rebuild records from their streams, cached in `Rails.cache`, and
evaluate the query in Ruby. Queries it cannot answer exactly (SQL fragments,
merged relations, some joins) raise `Lyra::Projections::UnsupportedQuery`
rather than return a wrong answer, `upsert_all` among them. It is
the slowest way to read, and its cost grows with the log. Use it for audit and
replay, or code that reads through simple finders, rather than to serve an
application's reads.

**ES-Lazy (`:lazy`).** Nothing is projected at write time. Before any
ActiveRecord read (record loads, associations, `count`/`sum`/`pluck`/`exists?`,
on any model) the tables are brought up to date from the log under an
advisory lock, and the read runs as real SQL, so joins and merged relations
work. Each read first checks whether the log has moved (two small queries).
The tables are a cache that can be rebuilt. Raw SQL through the connection is
not covered.

Cost, from cheapest read to dearest: ES-Sync and ES-Async read plain tables;
ES-Lazy pays for the events since the last read; ES-NoProj rebuilds from
streams. See [PERFORMANCE.md](PERFORMANCE.md) and
[Costs, and what to do about each](#costs-and-what-to-do-about-each).

**How to switch (gated).**

- From Monitor: the same check as Phase 4, naming the projection mode:
  ```bash
  bin/rails lyra:mode:check TO=event_sourcing PROJECTION=lazy
  ```
  then deploy `config.mode = :event_sourcing` and `config.projection_mode = :lazy`.
- From Hijack to any event-sourcing configuration, from ES-Sync to any other,
  and between ES-NoProj and ES-Lazy: not checked; the events stay
  authoritative. Deploy the new settings.
- Leaving ES-NoProj, ES-Lazy or ES-Async for any configuration other than
  ES-NoProj or ES-Lazy (Disabled, Monitor, Hijack, ES-Sync, ES-Async): checked,
  because those tables lag the log. Run the check before deploying, while the
  application still runs the mode you are leaving.
  - ES-Async: let the projection queue drain, then check.
  - ES-Lazy: the check catches the tables up first (only in a process that
    runs ES-Lazy).
  - ES-NoProj: the tables are empty or stale; rebuild them as part of the check:
    ```bash
    bin/rails lyra:mode:check TO=monitor REBUILD=1
    ```

At run time, `Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :sync)`
runs the gate in-process (`rebuild: true` when leaving ES-NoProj).

**How to verify.** `bin/rails lyra:mode:status`. For ES-Sync, sampled DualView
still runs; for the lagging modes it is skipped, and a check before leaving
them is the verification.

**How to step back.** ES-Sync → Hijack or Monitor is not checked; if
`strict_projections` was off, look for `Lyra: Sync projection failed` in the
log first, or compare every record in a console with
`Lyra::ModeTransition.check(to: "monitor").discrepancies`, and rebuild if any
(Recovery). From the lagging modes, follow the gated route above.

## Switching modes

How Lyra keeps an application in one mode, and how to move it to another
safely. The safety rule comes from the thesis (Mode Transition Safety): a
switch that changes which store is authoritative is allowed only when the
rows and the events agree, for every monitored record.

### Who holds the mode

- **Each process holds the mode it runs in**, in its own memory
  (`Lyra.config.mode`, `Lyra.config.projection_mode`), set by the
  application's initializer (`config/initializers/lyra.rb`).
- **The database holds the application's mode**: the latest `applied` row in
  `lyra_mode_transitions`. A process writes one when it boots into a new mode,
  or when none is recorded yet (after the boot gate, and only while the gate
  is on), and on every gated switch (`ModeTransition.to!`). The table also
  keeps the certificates of clean checks. Lyra creates it on first use; it
  needs no migration.
- **`Lyra::ModeSync` keeps the two in step.** At most every
  `config.mode_sync_interval` seconds (default 5) each process looks for a
  newer `applied` row and adopts its mode, without running the gate again
  (the process that recorded it already passed it). It looks before each web
  request, each background job and each `save`, `update` or `destroy` of a
  monitored model (which covers consoles and scripts), and never inside an
  open transaction, so a mode cannot change half-way through a write.

### Which switches are checked

| From | To | Checked? | Why |
|---|---|---|---|
| Disabled or Monitor | Hijack or any event-sourcing mode | yes | the events become authoritative, so they must reproduce every row |
| ES-NoProj, ES-Lazy or ES-Async | Disabled, Monitor, Hijack, ES-Sync, or ES-Async | yes | those tables lag the log by design; they must catch up first |
| anything else (Monitor → Disabled, ES-Sync → ES-NoProj, ES-NoProj ↔ ES-Lazy, …) | | no | the authoritative store does not change |

A check imports rows that predate Lyra first (Genesis, on a switch out of
Disabled or Monitor), compares every row and every stream, re-checks what
changed while it ran, and stores a clean result as a certificate for that
switch (valid for `config.mode_transition_certificate_ttl`, 1 hour by
default). Leaving ES-Lazy, it catches the tables up first; leaving ES-NoProj,
it rebuilds them when asked (`REBUILD=1`, or `rebuild: true`).

### The rule: switch modes with a deploy

Switching is a deploy, not a console command:

1. **Check ahead**, on the running application:
   ```bash
   bin/rails lyra:mode:check TO=hijack
   bin/rails lyra:mode:check TO=event_sourcing PROJECTION=sync
   bin/rails lyra:mode:check TO=monitor REBUILD=1   # leaving ES-NoProj
   ```
   It checks the switch from the mode the application last ran in (`FROM=`
   names another), and says so when the switch needs no check. It prints up
   to 20 discrepancies and exits non-zero, or certifies the switch when there
   are none. On a large table this is the slow part; it runs while the
   application keeps serving.
2. **Deploy the new configuration** (`config.mode = :hijack`, or the
   environment variable your initializer reads).
3. **The boot gate** compares each process's configured mode with the one the
   application last ran in, and lets it start in the new mode only with a
   fresh certificate for that switch, after re-checking just what changed
   since the check. It then records the new mode. Without a certificate, the
   process refuses to start (`Lyra::ModeTransition::Refused`) and says which
   check to run.
4. **ModeSync** brings any process still running the old configuration (during
   a rolling deploy) into the new mode within seconds of the first new process
   recording it.

`bin/rails lyra:mode:status` shows the configured mode, the last applied one,
and whether the gate is on.

### Switching at run time

`Lyra::ModeTransition.to!(:hijack)` (and the `config.enable_*!` helpers after
boot) runs the same gate in the current process: a fresh certificate is
re-checked for what changed since, otherwise a full check runs, and
discrepancies refuse the switch (`Refused`, with the report). A clean switch
is recorded as the application's mode, so the other processes adopt it through
ModeSync; the log line says so. With ModeSync off, it says the switch reached
this process only. Use it for single-process work (a console during an
incident, a maintenance script, tests); for a planned change, prefer the deploy
above.

### Overrides

- `ModeTransition.to!(mode, force: true)` switches without the check.
- `LYRA_FORCE_MODE_TRANSITION=1` lets a process boot into an uncertified mode.
- Rake tasks are not gated at boot, so migrations and the check itself can run
  in any configuration.
- `config.mode = ...` is the raw setter: no gate, no record, and ModeSync does
  not override it unless another process records a new switch. Tests and the
  benchmark harnesses use it. `config.disable!` is not gated either.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `mode_transition_gate` | `nil` | `nil` gates everywhere but the test environment; `true`; `false` |
| `mode_transition_certificate_ttl` | `3600` | seconds a clean check certifies a switch |
| `mode_sync` | `nil` | `nil` follows the gate; `true`; `false` |
| `mode_sync_interval` | `5` | seconds between a process's checks for a switch made elsewhere |

The sampled DualView settings (`dual_view_sample_rate`,
`dual_view_discrepancy_handler`) are in
[Phase 3](#phase-3-verify-and-repair-in-monitor).

## Privacy (optional, PAM)

With the `orfeas_pam_dsl` gem installed, a PAM policy can govern monitored
models. Everything here is opt-in except what the policy itself declares.

- **Draft a policy** from your models:
  `bin/rails "pam_dsl:generate:from_models[shop]"`. It writes
  `config/initializers/pam_dsl_policy.rb` from column names, and refuses to
  replace an existing file unless you add `FORCE=1`. Treat it as a draft: review every field, purpose
  (`basis`, `requires`) and retention rule before relying on it.
- **Attach it**: `config.privacy_policy = :shop` for every monitored model, or
  `monitor_with_lyra privacy_policy: :shop` (also as a `config.models` option)
  per model.
- **Purpose-bound reads**: `Lyra.with_purpose(:invoicing) { ... }`, or
  `lyra_purpose :invoicing` in a controller or job. Reads without a purpose
  follow `config.reads_without_purpose` (`:allow` by default, `:audit`, `:deny`).
- **Access log** (`config.record_access_events = true`) and **privacy stamps**
  on events (`config.annotate_privacy = true`): both off by default, as they
  add work to every read or write.
- **Erasure** (Art. 17), which rewrites the record's events in place and
  records an `ErasureApplied` event:
  `bin/rails lyra:erase MODEL=Customer ID=5 REASON="request #12"`.
- **Retention**: `config.retention_executor = true`, then
  `bin/rails lyra:retention:apply` on a schedule (`DRY_RUN=1` lists what would
  happen, with the executor on or off).

Details: [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

## Point-in-time reads

In every mode that records events:

```ruby
Lyra.state_at(Order, 42, 3.days.ago)   # attributes then, or nil
Order.as_of(3.days.ago).find(42)       # a read-only Order as it was then
Order.as_of(3.days.ago).all
```

For a record imported by Genesis, history before the import was not recorded:
asking for an earlier time raises `Lyra::Temporal::HistoryNotRecorded`, unless
the row's `created_at` shows it did not exist yet (then the answer is nil).

## Recovery

**Events authoritative (Hijack, event sourcing): rebuild the tables from the
log.**

```bash
bin/rails lyra:projections:rebuild                    # every monitored model
bin/rails lyra:projections:rebuild MODEL=Order
bin/rails lyra:projections:rebuild MODEL=Order TRUNCATE=false
```

```ruby
Lyra::Projections::Rebuild.rebuild(Order)
Lyra::Projections::Rebuild.rebuild(Order, truncate: false)
```

By default the table is cleared (`delete_all`, publishing nothing) and every
stream replayed through the same projection code live writes use, in one
transaction. Rows without a stream are lost, so run Genesis first. Clearing a
table that other tables reference by foreign key fails, or with
`ON DELETE CASCADE` removes their rows; use `TRUNCATE=false` there, which
replays each stream onto the table in place.

**Tables authoritative (Monitor, Disabled): repair the log** with
`bin/rails lyra:repair` (Phase 3).

**Undoing data changes.** Do not fix data with `update_columns` or
`update_all` loops: on monitored models they publish bypass events (or raise
under `strict_data_access`), so they become part of the history. Make
corrections as ordinary writes, which are recorded as such.

**Undoing a mode switch.** Switch back by the routes in Phases 4 and 5 and
[Switching modes](#switching-modes). Use
`ModeTransition.to!(mode, force: true)` or `LYRA_FORCE_MODE_TRANSITION=1` only
when you accept that the stores may disagree.

## Testing during the migration

- In the test environment the gate is off (`config.mode_transition_gate` nil),
  so is ModeSync, and `:async` projections run inline
  (`config.async_projections_inline` nil). Set
  `config.async_projections_inline = false` with a queuing job adapter to test
  the real background path.
- Switch modes in tests with the raw setter: `Lyra.config.mode = :hijack`,
  `Lyra.config.projection_mode = :lazy`. It is ungated and records nothing.
  `Lyra.reset_config!` restores the defaults; `Lyra::Genesis.reset!` forgets
  which models were imported.
- Run your suite in each configuration you plan to pass through. Lyra's own
  suite does this; see [TESTING.md](TESTING.md).
- `LYRA_DISABLE_PAM_DSL=true` loads Lyra without PAM, to test without the
  privacy features.
- Where you can, replay a real workload and compare the end state with an
  oracle computed from the source data, as `examples/bpi2017_loan_app` and
  `examples/solidus_case_study/lib/olist` do. DualView compares two views from
  the same system; an oracle also catches writes that never reached the
  database.

## Common pitfalls

- **Writes Lyra cannot see.** Raw SQL, triggers and other writers change rows
  without events. In Monitor, `lyra:repair DRY_RUN=1` shows them as
  discrepancies; in Hijack and the event-sourcing modes the log does not hold
  their changes, so a rebuild discards them.
- **Bulk writes record events.** `update_all` over a large table writes one
  event per row. Wrap housekeeping in `Lyra.projection_write`.
- **Pre-existing rows without Genesis.** In Monitor with `genesis: :auto`
  (the default), pre-existing records get no `Imported` event; their streams
  start at their first change. Set `config.genesis = true` or run
  `bin/rails lyra:genesis` early.
- **A failed append in Monitor is only logged.** Alert on it and run
  `lyra:repair`. If losing events is unacceptable, move on to Hijack.
- **ES-NoProj raises `UnsupportedQuery`** on SQL fragments, merged relations
  and joins it cannot evaluate exactly. Use ES-Lazy for that code.
- **ES-Async read-after-write.** A redirect to a record just created can find
  nothing. Use ES-Sync or ES-Lazy for flows that read their own writes.
- **ES-Lazy and long transactions.** Event ids are assigned before commit, so
  ES-Lazy tracks gaps in the log. A gap still empty after 300 seconds
  (`LazyProjection::GAP_TTL`) is taken to be a rollback and forgotten: a
  single transaction open for longer than that has its events skipped by the
  tables. Keep transactions short, or rebuild after one.
- **ES-Lazy and raw SQL reads.** `connection.select_all` does not trigger a
  catch-up and can read stale tables.
- **`lyra:mode:check` writes.** On an escalation it imports rows without a
  stream before comparing, whether or not the check passes.
- **Per-model modes.** There are none; a `mode:` option to
  `monitor_with_lyra` is ignored.
- **Regenerating a reviewed policy.** `FORCE=1` on
  `pam_dsl:generate:from_models` replaces `config/initializers/pam_dsl_policy.rb`,
  review and all; generate to a scratch app or compare by hand instead.
- **The dashboard answers 403 in production.** That is the default until
  `config.dashboard_authorization` says who may use it.
