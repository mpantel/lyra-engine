# Lyra API Reference

The public API of the Lyra engine: configuration, the model hooks, modes and
mode switches, events, reads in each configuration, and the privacy layer.
Everything here is defined in `lib/lyra.rb`, `lib/lyra/**`, `lib/tasks/lyra_*.rake`
or, for PAM, `gems/pam_dsl/lib`. For how the parts fit together see
[ARCHITECTURE.md](ARCHITECTURE.md); for switching modes in production see
[MODE_TRANSITIONS.md](MODE_TRANSITIONS.md); for GDPR workflows see
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

## Contents

1. [Configuration](#configuration)
2. [Model integration](#model-integration)
3. [Modes and transitions](#modes-and-transitions)
4. [Events, streams and metadata](#events-streams-and-metadata)
5. [Commands and aggregates](#commands-and-aggregates)
6. [Projections and reads](#projections-and-reads)
7. [Point-in-time state](#point-in-time-state)
8. [DualView and verification](#dualview-and-verification)
9. [Privacy](#privacy)
10. [PAM DSL essentials](#pam-dsl-essentials)
11. [Correlation and causation](#correlation-and-causation)
12. [Event flow analysis](#event-flow-analysis)
13. [Dashboard](#dashboard)
14. [Rake tasks](#rake-tasks)
15. [Errors](#errors)

---

## Configuration

### `Lyra.configure` and `Lyra.config`

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :sync
  config.models = %w[Order Payment]
  config.metadata_proc = ->(record, operation) { { tenant_id: Current.tenant&.id } }
end

Lyra.config.mode             # => :event_sourcing
Lyra.config.projection_mode  # => :sync
```

`Lyra.config` returns the process's `Lyra::Configuration`; `Lyra.reset_config!`
replaces it with a fresh one (tests). The engine sets `config.event_store` to a
`RailsEventStore::Client.new` at boot unless the application has set one.

### The seven configurations

The mode is application-wide. Per model you choose only whether it is
monitored (`monitor_with_lyra`, or `config.models=`).

| Configuration | `mode` | `projection_mode` |
|---|---|---|
| Disabled | `:disabled` | – |
| Monitor | `:monitor` (default) | – |
| Hijack | `:hijack` | – |
| ES-Sync | `:event_sourcing` | `:sync` (default) |
| ES-Async | `:event_sourcing` | `:async` |
| ES-NoProj | `:event_sourcing` | `:disabled` |
| ES-Lazy | `:event_sourcing` | `:lazy` |

Neither `mode=` nor `projection_mode=` validates its value. Predicates:
`Lyra.monitor_mode?`, `Lyra.hijack_mode?`, `Lyra.event_sourcing_mode?`,
`Lyra.disabled_mode?` (the same methods exist on `Lyra.config`).

### Options

Every option of `Lyra::Configuration` (`lib/lyra/configuration.rb`).

| Option | Default | Description |
|---|---|---|
| `mode` | `:monitor` | `:disabled`, `:monitor`, `:hijack` or `:event_sourcing`. The raw setter: no gate, no record (see [Modes and transitions](#modes-and-transitions)). |
| `projection_mode` | `:sync` | Event sourcing only: `:sync`, `:async`, `:disabled` (ES-NoProj) or `:lazy` (ES-Lazy). |
| `event_store` | `nil` | The RailsEventStore client. Set by the engine at boot if still `nil`. Also `Lyra.event_store` / `Lyra.event_store=`. |
| `event_backend` | `:rails_event_store` | Read only by `Lyra::EventStoreAdapter.build`; the engine does not use it. |
| `hijack_enabled` | `false` | Set by the mode helpers. When true, `hijack_mode?` is true whatever `mode` says. |
| `metadata_proc` | `nil` | `->(record, operation) { Hash }`, merged into the metadata of Monitor-mode events. A proc that raises is logged and skipped. |
| `strict_projections` | `false` | Re-raise a failed sync projection, or a failed enqueue of an async one, instead of logging it. |
| `projection_error_handler` | `nil` | `->(error, record, operation)`, called when a projection fails and `strict_projections` is off. |
| `async_projections_inline` | `nil` | ES-Async: `nil` projects inline in the test environment only; `true` always; `false` never. |
| `strict_schema` | `false` | Enforce the stored event schema at boot (raises `Lyra::Schema::SchemaValidationError` on drift). |
| `schema_path` | `nil` | Where schema versions are stored; `nil` means `db/lyra_schemas`. |
| `strict_data_access` | `false` | Raise `Lyra::StrictDataAccessViolation` on callback-bypassing writes to monitored models. |
| `genesis` | `:auto` | Import rows that predate Lyra: `:auto` in event-sourcing mode only, `true` in every event-producing mode, `false` never. See [Genesis](#genesis). |
| `retention_policy` | `nil` | Default retention used by `Lyra::Privacy::GDPRCompliance` reports and recorded in the event schema. Does not delete anything. |
| `privacy_policy` | `nil` | Default privacy policy name for monitored models that name none. |
| `mode_transition_gate` | `nil` | Gate mode switches: `nil` everywhere but the test environment; `true` always; `false` never. |
| `mode_transition_certificate_ttl` | `3600` | Seconds a clean `lyra:mode:check` certifies a switch. |
| `dual_view_sample_rate` | `0.0` | Share of committed writes checked by DualView (opt-in; `0.0` is off). |
| `dual_view_discrepancy_handler` | `nil` | Called with each `ModeTransition::Discrepancy` the sampler finds. |
| `mode_sync` | `nil` | Keep every process in the application-wide mode: `nil` follows the gate setting; `true`; `false`. |
| `mode_sync_interval` | `5` | Seconds between ModeSync checks. |
| `annotate_privacy` | `false` | Stamp each event's metadata with its privacy annotation (opt-in). |
| `record_access_events` | `false` | Record each policy-validated access as an event (opt-in; needs pam_dsl). |
| `access_metadata_proc` | `nil` | `->(access) { Hash }`, extra metadata for each recorded access. |
| `reads_without_purpose` | `:allow` | Reads of a policy-covered model with no declared purpose: `:allow`, `:audit` or `:deny`. Validated on assignment. |
| `retention_executor` | `false` | Allow `Lyra::Retention.apply!` to change data (opt-in). |
| `retention_anchors` | `{}` | Column each model's retention period runs from, keyed by model name (a String); `created_at` when absent. |

Configuration methods:

| Method | Description |
|---|---|
| `models=(names_or_hash)` | Declare monitored models by name; each gets `monitor_with_lyra(options)` once the application's code has loaded (and after each reload). A name that does not resolve fails the boot. |
| `apply_declared_models!` | Instrument the declared models now (the engine calls it; call it yourself outside Rails). Returns the classes. |
| `verify_mapping!` | In the initializer: verify the CRUD-to-event mapping at boot, after the declared models are instrumented. After boot: verify now. Needs petri_flow. |
| `enable_monitor!`, `enable_hijack!`, `enable_event_sourcing!` | Switch mode. After boot, with the gate on, they go through `Lyra::ModeTransition.to!`. |
| `disable!` | Switch to `:disabled` (never gated). |
| `monitored_models` | The monitored model classes. |
| `model_config(model_class)` | The model's `Lyra::ModelConfiguration`. |
| `declared_models` | `{ "Name" => options }` from `models=`. |

```ruby
config.models = %w[Order Payment]
config.models = { "Order" => { event_prefix: "Shop" }, "Payment" => {} }
config.verify_mapping!
```

---

## Model integration

### `monitor_with_lyra(options = {})`

Added to every ActiveRecord model by the engine. Marks the model monitored and
registers it with `Lyra.config`.

```ruby
class Payment < ApplicationRecord
  monitor_with_lyra privacy_policy: :shop_data,
                    event_mapping: { created: "PaymentInitiated" }
end
```

| Option | Default | Description |
|---|---|---|
| `event_prefix` | model name | Prefix of generated event names: `"#{prefix}Created"`, `Updated`, `Destroyed`, `Imported`. |
| `event_mapping` | `{}` | Event name per operation, overriding the prefix: keys `:created`, `:updated`, `:destroyed`, `:imported`. |
| `aggregate_class` | `nil` (uses `Lyra::GenericAggregate`) | Aggregate used by the command handler in Hijack and event-sourcing modes. See [Commands and aggregates](#commands-and-aggregates). |
| `command_handler` | `nil` | Stored in the model configuration and shown on the dashboard. The write path always uses `Lyra::CommandHandler`. |
| `privacy_policy` | `nil` (falls back to `config.privacy_policy`) | Name of the privacy policy that covers the model. |
| `domain_events` | `[]` | Domain event rules; see below. |

Unknown options are ignored. Generated event classes live in `Lyra::Events`;
a namespaced model's names drop the `::` (`Spree::Price` gives
`Lyra::Events::SpreePriceCreated`).

Class methods added to every model: `lyra_monitored` (boolean),
`lyra_config` (the `ModelConfiguration`), and `as_of(time)` (see
[Point-in-time state](#point-in-time-state)).

### Domain events (`domain_events:`)

Name a write after what it means instead of the CRUD operation. Rules are
checked in order against each write that runs the model's callbacks.

```ruby
monitor_with_lyra domain_events: [
  { name: "PaymentCompleted", on: %i[create update],
    if: ->(payment, changes) { payment.status == "success" && changes.key?("status") },
    payload: ->(payment, _changes) { { amount: payment.amount } } },
  { class: ReceiptDue, on: :update, if: ->(p, c) { c.key?("status") }, also: true }
]
```

| Key | Description |
|---|---|
| `name:` | Event name; the class is generated in `Lyra::Events`. |
| `class:` | Your own event class (a `RubyEventStore::Event` subclass). Give `name:`, `class:` or both. |
| `on:` | `:create`, `:update`, `:destroy` (or a list). Default: all three. |
| `if:` | `->(record, changes)` or `->(record)`; `changes` maps attribute to `[old, new]`. |
| `payload:` | Same arguments; must return a Hash, stored under `data[:payload]`. |
| `also: true` | Emit an additional event next to the write's own, in the same stream and transaction. It carries `replay: false` and the own event's id as `causation_id`. |

The first matching rule without `also:` names the write's own event; it keeps
the standard envelope, so replay, projections, DualView and `Lyra.state_at` are
unaffected. Unknown keys raise `ArgumentError`. Writes that skip callbacks
(`update_all`, `insert_all`, ...) are recorded as CRUD bypass events, not
domain events.

### Callback-bypassing writes

`update_columns`, `update_column`, `touch`, `delete`, `update_all`,
`delete_all`, `insert_all`, `insert_all!` and `upsert_all` on a monitored model
publish a bypass event per affected record. With `config.strict_data_access =
true`, all but `touch` raise `Lyra::StrictDataAccessViolation` (with
`#method_name`, `#model_class`, `#alternative`) unless run inside
`Lyra.without_strict_access`:

```ruby
Lyra.without_strict_access do
  Registration.where(status: "stale").delete_all   # still publishes bypass events
end
```

`dependent: :nullify` updates are always allowed and recorded.

### Who wrote it

Monitor-mode events take `user_id` from `Current.user` and `request_id` from
`Current.request_id` when the application defines them. A model may override
the private hooks `lyra_current_user_id` and `lyra_current_request_id`.

---

## Modes and transitions

See [MODE_TRANSITIONS.md](MODE_TRANSITIONS.md) for the procedure. This section
lists the API.

### `Lyra::ModeTransition`

```ruby
Lyra::ModeTransition.to!(:hijack)
Lyra::ModeTransition.to!(:event_sourcing, projection_mode: :lazy)
Lyra::ModeTransition.to!(:monitor, rebuild: true)   # leaving ES-NoProj
Lyra::ModeTransition.to!(:hijack, force: true)      # no check
```

| Method | Description |
|---|---|
| `to!(mode, projection_mode: nil, force: false, rebuild: false)` | Switch, gated. Runs a check when the switch changes the authoritative store (escalation from Disabled/Monitor, or leaving ES-NoProj/ES-Lazy/ES-Async for a table-reading mode), unless a fresh certificate covers it. Raises `ModeTransition::Refused` (with `#report`) on discrepancies. Records the switch so other processes adopt it. Returns the check's `Report`, or `nil`. |
| `check(to:, from: current, models: Lyra.config.monitored_models, rebuild: false, batch_size: 1_000)` | Compare every row with its stream; imports pre-Lyra rows first on escalation; stores a certificate when clean. Returns a `Report`. |
| `current` | This process's configuration as a label: `"monitor"`, `"event_sourcing/lazy"`. |
| `label(mode, projection_mode = nil)` | Build such a label. |
| `gate_enabled?` | Whether switches are gated (`config.mode_transition_gate`). |
| `gate_required?(from, to)` | Whether a switch between two labels needs a check. |
| `last_applied` | Label of the last applied switch recorded in `lyra_mode_transitions`, or `nil`. |

`Report` fields: `from`, `to`, `checked`, `rechecked`, `imported`, `rebuilt`,
`discrepancies` (`Discrepancy` with `model`, `id`, `problem`, `details`),
`position`, `started_at`, `finished_at`; methods `clean?` and `summary`.

At boot the engine refuses to start a process in a mode that the last applied
one cannot switch to without a certificate (`LYRA_FORCE_MODE_TRANSITION=1`
overrides). Rake tasks are not gated at boot.

### `Lyra::ModeSync`

Keeps every process in the application-wide mode. At most every
`config.mode_sync_interval` seconds it adopts a newer switch recorded by
another process: before each request (`Lyra::ModeSync::Middleware`, installed
by the engine), each ActiveJob, and each `save`/`update`/`destroy` on a
monitored model, never inside an open transaction.

| Method | Description |
|---|---|
| `enabled?` | `config.mode_sync`, or the gate setting when `nil`. |
| `maybe_sync!` | Sync if due and outside a transaction. Returns the adopted label or `nil`. |
| `sync!` | Sync now. |

### Failure policies

Every event Lyra writes goes through `Lyra.append_events(events, stream_name:,
store: config.event_store)`, which wraps any store error in
`Lyra::EventStoreUnavailableError`.

- Hijack and the event-sourcing modes are fail-closed: the write raises and its
  transaction rolls back.
- Monitor is log-and-continue: the write stands, the error is logged, and the
  stream falls behind its row until `Lyra::Repair` brings it back.

### `Lyra::Repair`

Only in Monitor or Disabled (raises `Lyra::Repair::Refused` otherwise).

```ruby
result = Lyra::Repair.run(dry_run: true)
result.summary   # "checked 1200 records: 3 out of line, 0 repaired, 3 still out of line"
```

| Method | Description |
|---|---|
| `run(models: Lyra.config.monitored_models, dry_run: false)` | Find out-of-line records and, unless `dry_run`, repair them. Returns a `Result` (`checked`, `found`, `repaired`, `remaining`, `summary`). |
| `repair(model, id)` | Repair one record: an `Imported` event for a row without events, an `Updated` event for a row that differs, a `Destroyed` event for events without a row. Returns the `Discrepancy` repaired, or `nil`. |

Repair events carry `source: "lyra_repair"` in their metadata.

### Genesis

`Lyra::Genesis` gives each row that predates Lyra one `Imported` event holding
the row as it is. It runs on a model's first use in a process (its first write;
in ES-NoProj also its first read) when `Genesis.enabled?` (`config.genesis`).

| Method | Description |
|---|---|
| `import_all(model_class)` | Import every row without a stream now, whatever the mode. Returns the count. |
| `first_use(model_class)` | Import once per process, if enabled. |
| `enabled?`, `imported?(model_class)`, `reset!` | |

For a large table run `bin/rails lyra:genesis` before enabling a mode.

---

## Events, streams and metadata

### Streams

Each record has one stream, `"#{Model.name}$#{id}"`: `"User$123"`,
`"Spree::Price$7"`. Access-log events go to `"Lyra::DataAccess$User$123"`.

```ruby
events = Lyra.event_store.read.stream("Order$42").to_a
```

### `Lyra::Event`

Subclass of `RubyEventStore::Event`; every generated event class inherits from
it. Data envelope:

| Key | Description |
|---|---|
| `model_class` | Model name (String) |
| `model_id` | Record id |
| `operation` | `:created`, `:updated`, `:destroyed` or `:imported` |
| `attributes` | Record attributes (Monitor omits `created_at` and `updated_at`) |
| `changes` | `{ "attr" => [old, new] }` |
| `timestamp` | When the event was built |
| `payload` | Domain event payload, if any |

Readers (symbol or string keys): `model_class`, `model_id`, `operation`,
`attributes`, `changes`, `timestamp`, `user_id`, `request_id`, plus
`event_id`, `data`, `metadata`, `event_type` from RubyEventStore.

`Lyra::Event.operation_of(event)` returns what a stored event does on replay
(`:created`, `:imported`, `:updated`, `:destroyed`) or `nil` (not replayed,
e.g. an `also:` domain event). It reads the operation from the data and falls
back to the name's suffix only for events that carry none.

`Lyra::EventRegistry.all` lists the registered `Lyra::Event` subclasses;
`find_by_name(name)` finds one.

### Metadata

| Written by | Metadata keys |
|---|---|
| Monitor (interceptor) | `user_id`, `request_id`, `correlation_id`, `causation_id`, `action_id`, `user_action`, plus `metadata_proc`'s hash |
| Hijack and event sourcing (command handler) | `source: "lyra_command_handler"`, `correlation_id`, `causation_id` |
| Genesis | `genesis: true` |
| Repair | `source: "lyra_repair"`, `repaired`, `correlation_id` |
| Erasure | `source: "lyra_erasure"`, `erased_by`, `correlation_id` (on `ErasureApplied`) |
| any, with `annotate_privacy` | `privacy` (see [Privacy stamps](#privacy-stamps)) |

`metadata_proc` applies only to the Monitor path.

---

## Commands and aggregates

In Hijack and the event-sourcing modes the interceptor turns each write into a
command and runs it through `Lyra::CommandHandler.handle(command)` before the
row write. Applications rarely call this directly.

| Class | Constructor |
|---|---|
| `Lyra::Commands::CreateCommand` | `new(model_class, attributes)` |
| `Lyra::Commands::UpdateCommand` | `new(model_class, id, changes)` |
| `Lyra::Commands::DestroyCommand` | `new(model_class, id)` |

Commands expose `model_class`, `data`, `aggregate_id`, and `record`
(read/write; the record whose callbacks produced the command).

### `Lyra::CommandResult`

```ruby
Lyra::CommandResult.success(attributes: { id: 5 }, events: [event])
Lyra::CommandResult.failure(error: "message")
```

Readers: `success`, `attributes`, `error`, `events`; predicates `success?`,
`failure?`. A failure adds the error to the record's `errors[:base]` and stops
the write. `EventStoreUnavailableError` is re-raised, not turned into a failure.

### `Lyra::Aggregate` and `Lyra::GenericAggregate`

`Lyra::Aggregate` is a minimal base: `new(id = nil)`, `id`, `version`,
`changes`, `apply(event, persisted: false)` (dispatches to
`apply_<event_class_underscored>`), `store(event_store = nil)` (appends pending
changes), `stream_name` (`"#{class.name.demodulize}$#{id}"`), and
`Aggregate.load(id, event_store = nil)`. State helpers `set_state`,
`get_state` and `state` are protected.

The command handler instantiates the model's `aggregate_class` as
`new(id, model_class)` and uses its stream, so a custom aggregate should
subclass `Lyra::GenericAggregate`, whose stream is the model's
(`"#{model_class.name}$#{id}"`) and which dispatches by operation to private
`apply_created`, `apply_updated` and `apply_destroyed`:

```ruby
class OrderAggregate < Lyra::GenericAggregate
  private

  def apply_updated(event)
    super
    # domain checks; raise to fail the write
  end
end

class Order < ApplicationRecord
  monitor_with_lyra aggregate_class: OrderAggregate
end
```

---

## Projections and reads

### ES-Sync and ES-Async

ES-Sync projects each event to the model's table in the write's transaction.
ES-Async enqueues `Lyra::Projections::AsyncProjectionJob` (queue
`:lyra_projections`, enqueued after commit, up to 5 attempts), which
replays the record's whole stream so out-of-order jobs converge.

Read-your-writes: `Lyra::Consistency::ReadYourWrites.with_guaranteed_read`
(and its `ControllerConcern`, which wraps actions in ES-Async) is meant to
project a block's writes before the block returns. Only the ES-Sync path
records writes for it, so under ES-Async it currently has no effect: a record
created in the block is still projected by the job. Until that is fixed, use
ES-Sync or ES-Lazy for flows that read their own writes.

### ES-NoProj (`projection_mode :disabled`)

Writes store events only; nothing is written to the tables. On a monitored
model, `find`, `find_by`, `find_by!`, `exists?` (with an id), `where`, `all`,
`first` and `last` read from `Lyra::Projections::EventStoreReader`, which
rebuilds records from their streams through a cache keyed by each stream's last
event id (`Rails.cache`). Associations to monitored models are read the same
way.

Collections are `Lyra::Projections::CachedRelation` objects, evaluated in
Ruby:

- `where` with hash conditions (values, arrays, ranges, `nil`, records),
  `where.not`, `where.missing`, `where.associated`, `or`, and SQL fragments made
  only of `"column OP ?"` terms joined all by `AND` or all by `OR` (`OP` one of
  `= != <> < <= > >= LIKE ILIKE`);
- `order`, `reorder`, `reverse_order`, `limit`, `offset`, `page`/`per`,
  `distinct` (removes repeated records);
- `joins`, `left_joins`, `left_outer_joins` on direct associations, evaluated
  in memory: an inner join drops records without a partner, a has_many join
  repeats the record per partner as SQL does;
- `count`, `sum`, `average`, `minimum`, `maximum`, `group` with grouped
  calculations, `pluck`, `pick`, `ids`, `find_each`, `find_in_batches`,
  `in_batches`;
- scopes whose relation reduces to hash conditions, order and limit;
- `update_all`, `delete_all`, `destroy_all` (recorded as events).

Anything it cannot answer exactly raises
`Lyra::Projections::UnsupportedQuery`: other SQL fragments, string, nested,
`:through`, polymorphic or scoped joins, a condition on a table not joined,
conditions nested more than one level, and scopes it cannot reduce. Use ES-Lazy
or a projected mode for such queries.

`EventStoreReader` class methods: `find(model, id)`, `find_by(model, attrs)`,
`exists?(model, id)`, `relation(model)`, `all(model)`, `where(model,
conditions)`, `count(model, conditions = {})`, `invalidate(model, id)`,
`warm(model, id)`.

### ES-Lazy (`projection_mode :lazy`)

Writes store events only. Before any ActiveRecord read (record loads,
associations, `count` and other calculations, `pluck`, `exists?`) on any model,
`Lyra::Projections::LazyProjection` applies the events not yet in the tables,
in the log's global order, under a PostgreSQL advisory lock; the read then runs
as real SQL. SQL sent directly through the connection is not covered. The
checkpoint lives in `lyra_projection_checkpoints`, created on first use.

| Method | Description |
|---|---|
| `LazyProjection.catch_up!` | Apply every pending event now. Returns the number applied. |
| `LazyProjection.checkpoint` | `[position, { gap_id => first_seen_epoch }]`. |
| `LazyProjection.reset!` | Forget the checkpoint (after truncating or rebuilding tables). |
| `LazyProjection.active?` | Whether ES-Lazy is the current configuration. |

A transaction open longer than `LazyProjection::GAP_TTL` (300 s) can have its
events skipped.

### Rebuild

```ruby
Lyra::Projections::Rebuild.rebuild(Registration)               # => { model:, streams:, events:, records:, destroyed: }
Lyra::Projections::Rebuild.rebuild(Order, truncate: false)     # in place
Lyra::Projections::Rebuild.rebuild_all                         # all monitored models
Lyra::Projections::Rebuild.replay_record(Order, 42)            # one record; returns events replayed
```

`rebuild` clears the table (unless `truncate: false`) and replays every stream
through the same projection code as live projection.

### Custom projections

`Lyra::Projection` subclasses handle events with `apply_<event_name>` methods;
`subscribe_to(*event_types)` subscribes the class to the event store.
`Lyra::StateProjection.rebuild_state(model, id)` returns the replayed
attributes of one record; `Lyra::AuditProjection.audit_trail(model, id)`
returns one hash per event (`operation`, `timestamp`, `user_id`, `changes`,
`attributes`).

---

## Point-in-time state

Works in every mode that records events, Monitor included.

```ruby
Lyra.state_at(Order, 42, 3.days.ago)     # => { "id" => 42, "state" => "cart", ... } or nil
Order.as_of(3.days.ago).find(42)         # read-only Order as it was
Order.as_of(3.days.ago).find_by_id(42)   # nil instead of RecordNotFound
Order.as_of(3.days.ago).all              # every Order that existed then, by primary key
```

An event's time is when the store stored it. `state_at` returns `nil` if the
record had no event yet or its last event by then destroyed it. For a record
imported by Genesis, a time before its import raises
`Lyra::Temporal::HistoryNotRecorded`, unless the imported row's `created_at`
shows it did not exist yet. `as_of(time)` returns a `Lyra::Temporal::AsOf`.

---

## DualView and verification

### `Lyra::DualView`

Compares a record's row with the state replayed from its stream.

```ruby
view = Lyra::DualView.new(Order, 42)
view.compare
# => { crud_view: {...}, event_sourced_view: {...}, differences: { no_differences: true }, metadata: {...} }
```

| Method | Description |
|---|---|
| `compare` | Both views and the differences (`{ no_differences: true }`, `{ exists_mismatch: true }`, or `{ attr: { crud:, event_sourced: } }`). `created_at`/`updated_at` are ignored; times compare at microseconds. |
| `crud_state` | `{ exists:, attributes:, timestamps: }` |
| `event_sourced_state` | `{ exists:, state:, events_count:, first_event_at:, last_event_at:, events_summary: }` |
| `audit_trail` | `AuditProjection.audit_trail` for the record. |
| `DualView.compare_all(model)` | `compare` for every existing row. |
| `DualView.find_discrepancies(model)` | Those with differences. |

`Lyra::StateAnalyzer.analyze(model, id)` adds the audit trail and plain-text
recommendations.

### Sampled DualView (opt-in)

With `config.dual_view_sample_rate` above `0.0`, that share of committed writes
to monitored models is compared after commit. A discrepancy is logged and
passed to `config.dual_view_discrepancy_handler`; the write is never failed or
delayed. Skipped in ES-NoProj, ES-Lazy and ES-Async, whose tables lag by
design.

```ruby
config.dual_view_sample_rate = 0.02
config.dual_view_discrepancy_handler = ->(d) { Rails.error.report(RuntimeError.new(d.to_s)) }
```

### Formal verification (needs petri_flow)

`Lyra.verify_mapping!` runs the PetriFlow nets for the CRUD-to-event mapping
and checks that each monitored model has a table and a primary key; it raises
`Lyra::MappingVerificationError` naming every failed check, or returns the
report. `Lyra.verify_crud_mapping` returns the raw report.
`Lyra.verification_available?` / `Lyra.petri_flow_available?` say whether the
gem is loaded.

---

## Privacy

Lyra's privacy layer talks to a provider through `Lyra::Privacy`. PAM
(`gems/pam_dsl`) is the provider when the gem is loaded; without it a null
provider declares nothing and allows everything. `Lyra.pam_dsl_available?` and
`Lyra.privacy_features_available?` report which is in use. Set
`LYRA_DISABLE_PAM_DSL=true` to run without PAM.

### Provider interface

| Method | Description |
|---|---|
| `Lyra::Privacy.provider` / `provider=` | The provider (`Lyra::Privacy::Adapters::Pam` or `Lyra::Privacy::Provider`). |
| `Lyra::Privacy.policy(name)` | The provider's `Policy` for a name (a null policy for `nil` or an unknown name). |
| `Lyra::Privacy.policy_for(model_class)` | The model's `privacy_policy`, else `config.privacy_policy`. |
| `Lyra::Privacy.detector` | The provider's PII detector. |
| `Lyra::Privacy.annotations_for(event)` | `{ "field" => Annotation }` for the declared attributes an event touches. |

A provider subclasses `Lyra::Privacy::Provider` and implements `name`,
`available?`, `policy(name)` and `detector`. A `Lyra::Privacy::Policy`
implements `name`, `loaded?`, `declared_fields`, `annotation(field)`,
`declared?(field)`, `allowed?(field, purpose)`, `validate_access!(fields,
purpose, subject:)`, `allowed_purposes(field)`, `consent_required?(purpose)`,
`retention_for(model_class, field_name: nil)`, `retention_rule(model_class)`,
`mask(field, value, context = :display)`, `sensitive_fields`,
`restricted_fields`, `purposes_count` and `metadata`. `Annotation` has `field`,
`type`, `sensitivity`, `sensitive`, `purposes`, `source`, `transformations`;
`RetentionRule` has `duration`, `field_durations`, `strategy`, `applies`.

### PII detection and masking

`Lyra::Privacy::PIIDetector` delegates to the provider's detector (PAM's
name-based detector; the null detector finds nothing).

```ruby
Lyra::Privacy::PIIDetector.detect(email: "a@example.com", count: 3)
# => { email: { type: :email, value: "a@example.com", sensitive: false, sensitivity: ... } }
Lyra::Privacy::PIIDetector.contains_pii?(:billing_phone)   # => true (partial matching)
Lyra::Privacy::PIIDetector.mask("a@example.com", :email)
Lyra::Privacy::PIIDetector.sensitive?(:ssn)                # => true
Lyra::Privacy::PIIDetector.extract_from_event_stream(events)
```

PAM detects these types: `email`, `name`, `phone`, `ip_address`, `address`,
`online_identifier`, `identifier`, `ssn`, `date_of_birth`, `credit_card`,
`financial`, `health`, `biometric`, `location`, `credential`, `token`,
`payment_token`. Sensitive: `ssn`, `credit_card`, `financial`, `health`,
`biometric`, `identifier`, `credential`, `token`, `payment_token`. Set
`PamDsl::PIIDetector.partial_match = false` for exact name matching
(`PamDsl::PIIDetector.reset!` restores the default).

With PAM, `Lyra::Privacy::PIIMasker.mask(attributes, strategy: :partial)`
(`:partial`, `:full`, `:redact_sensitive`) and `mask_field(value, field_name)`
mask attribute hashes.

### Privacy stamps (opt-in)

With `config.annotate_privacy = true`, each event of a model with a loaded
policy gets `metadata[:privacy]`, the annotation of every declared attribute it
carries, as the policy stood when the data was written. Never a value.

```ruby
Lyra::Privacy.stamp_of(event)
# => { "policy" => "shop_data",
#      "fields" => { "email" => { "type" => "email", "sensitivity" => "confidential",
#                                 "purposes" => ["invoicing"], "retention" => "P2Y",
#                                 "transformations" => ["display"] } } }
```

`stamp_of` returns `nil` for an unstamped event. `Lyra::Privacy.stamp(model,
data, metadata)` is what the write paths call.

### Purpose-bound reads

A read of a monitored model whose policy is loaded, made within a declared
purpose, is checked with the policy's `validate_access!`: every declared
attribute the query loaded must be allowed for the purpose, with the record as
subject. No setting turns it on; declaring a purpose does.

```ruby
Lyra.with_purpose(:invoicing) { Registration.select(:id, :vat_number, :address).find(id) }

class PaymentsController < ApplicationController
  lyra_purpose :payment_processing                # around every action
  lyra_purpose :invoicing, only: :invoice         # around_action options
end

class ExportJob < ApplicationJob
  lyra_purpose :audit_trail
end
```

- `pluck` and `pick` are checked by the declared attributes they name, with
  `"Model$*"` as subject.
- A violation follows the policy's enforcement mode: strict raises the PAM
  error, audit logs it and lets the read through.
- `config.reads_without_purpose`: `:allow` (default), `:audit` (logged, and
  recorded when the access log is on), `:deny` (raises
  `Lyra::PurposeBoundReads::PurposeRequiredError`).
- Not checked: Lyra's own reads, Disabled mode, and SQL sent through the
  connection.

`Lyra::PurposeBoundReads.current` returns the purpose in scope.

### Access log (opt-in, needs pam_dsl)

With `config.record_access_events = true`, `Lyra::AccessLog` records every
`validate_access!` call as `Lyra::Events::DataAccessed` (outcome `granted` or
`audited`) or `Lyra::Events::DataAccessDenied`, in the subject's stream
`"Lyra::DataAccess$<subject>"`. The data holds the policy, purpose, legal
basis, field names, subject, outcome, time and violations; the metadata holds
`user_id` (`Current.user`), `ip_address`, `request_id`, correlation and
causation ids, and `config.access_metadata_proc`'s hash. An access that cannot
be recorded does not go ahead. Nothing is recorded in Disabled mode.

```ruby
config.record_access_events = true
config.access_metadata_proc = ->(access) { { api_token: Current.api_token&.id } }

Lyra::AccessLog.for(registration)   # its recorded accesses, oldest first
```

### Erasure

`Lyra::Erasure.erase!` erases one record's personal data from its row and
from every event in its stream, on request (Art. 17). Events are overwritten in
place (same id, position and time); an `Lyra::Events::ErasureApplied` event
records the fields, reason and who erased them. The stream still replays to the
row.

```ruby
result = Lyra::Erasure.erase!(Registration, 5, reason: "Art. 17 request #12")
result = Lyra::Erasure.erase!(Registration, 5, reason: "...", fields: %w[email phone],
                              erased_by: admin.id, everywhere: true, max_copies: 10)
```

| Argument | Description |
|---|---|
| `model`, `id` | The record. |
| `reason:` | Required; stored on `ErasureApplied`. |
| `fields:` | Erase exactly these; default: the policy's declared fields plus those the events' stamps list. |
| `erased_by:` | Default `Current.user&.id`. |
| `everywhere:` | Also search the whole log for the erased values of direct identifiers (email, phone, identifier, ssn, credit_card, financial, payment_token, ip_address, credential, token): other records' events are scrubbed and their rows updated. Uses PostgreSQL-specific SQL. |
| `max_copies:` | With `everywhere`, a value held by more than this many other records (default 10) is treated as shared and left. |

`Result` fields: `model`, `id`, `fields`, `events_rewritten`, `row_erased`,
`copies` (records whose copies were erased), `shared_values` (count of values
left as shared). The replacement is `nil` where the column allows it,
`"erased:<id>"` for a NOT NULL string column, else the column default; a NOT
NULL column with neither raises `Lyra::Erasure::Unsupported`, as does a record
with no personal fields.

### Retention (opt-in)

`Lyra::Retention.apply!` applies the policy's retention rules to monitored
models. It changes data only with `config.retention_executor = true`; a dry run
works either way.

```ruby
config.retention_executor = true
config.retention_anchors = { "Registration" => :registered_at }

result = Lyra::Retention.apply!(dry_run: true)
result.summary
Lyra::RetentionJob.perform_later   # ActiveJob wrapper, for a scheduler
```

`apply!(models: Lyra.config.monitored_models, dry_run: false, now:
Time.current)` returns a `Result` (`actions`, `dry_run`, `summary`); each
`Action` has `model`, `id`, `strategy`, `fields`, `outcome`, `detail`. Per
record past its period (from `created_at` or the anchor column), by the rule's
`on_expiry`:

| Strategy | Effect |
|---|---|
| `:anonymize` | Erase its personal attributes (`Lyra::Erasure`). |
| `:hard_delete` | Erase, then `destroy!` through the write path. |
| `:soft_delete` | Set `deleted_at` or `discarded_at` through the write path; skipped without one. |
| `:archive` | Skipped. |

A field with its own shorter duration is erased when that passes. Already
erased attributes are skipped. Without the executor, `apply!` raises
`Lyra::Retention::Disabled`.

### GDPR reports (needs pam_dsl)

`Lyra::Privacy::GDPRCompliance.new(subject_id:, subject_type: "User")` wraps
PAM's report builder over the event store: `data_export`,
`right_to_be_forgotten_report`, `portable_export(format: :json)`,
`rectification_history`, `processing_activities`, `retention_compliance_check`,
`consent_audit`, `full_report`. See [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

---

## PAM DSL essentials

The full DSL is in [gems/pam_dsl/README.md](../gems/pam_dsl/README.md).

```ruby
PamDsl.define_policy :shop_data do
  field :email, type: :email, sensitivity: :confidential do
    allow_for :invoicing
    transform(:display) { |v| "#{v[0]}***@#{v.split('@').last}" }
  end
  field :vat_number, type: :identifier, sensitivity: :restricted

  purpose :invoicing do
    describe "Issue invoices"
    basis :legal_obligation
    requires :vat_number
    optionally :email
  end

  purpose :marketing do
    basis :consent
    requires :email
  end

  retention do
    default 7.years
    for_model "Registration" do
      keep_for 5.years
      field :email, duration: 2.years
      on_expiry :anonymize
    end
  end

  consent do
    for_purpose :marketing do
      required!
      expires_in 1.year
    end
  end
end

class Registration < ApplicationRecord
  monitor_with_lyra privacy_policy: :shop_data
end
```

- Field types: `email`, `name`, `phone`, `address`, `ssn`, `date_of_birth`,
  `ip_address`, `credit_card`, `financial`, `health`, `biometric`, `location`,
  `identifier`, `credential`, `token`, `payment_token`, `custom`. Sensitivity:
  `public`, `internal` (default), `confidential`, `restricted`.
- `basis`: `consent` (default), `contract`, `legal_obligation`,
  `vital_interests`, `public_task`, `legitimate_interests`. Special-category
  fields (`health`, `biometric`) also need `art9_basis`.
- `on_expiry`: `hard_delete`, `soft_delete` (default), `anonymize`, `archive`.

| Call | Description |
|---|---|
| `PamDsl.define_policy(name) { ... }` | Define and register a policy. |
| `PamDsl.policy(name)` | Look one up; raises `PamDsl::PolicyNotFoundError`. |
| `policy.get_field(name)` / `get_purpose(name)` | Raise `InvalidFieldError` / `UndeclaredPurposeError` if undeclared. |
| `policy.allowed?(field, purpose)` | |
| `policy.validate_access!(field_names, purpose, subject:)` | Def. 1 check: `true`, or raises the first violation (strict) / returns `false` (audit). |
| `policy.retention_for(model_class, field_name: nil)` | Duration, falling back to the default. |
| `policy.consent_policy.grant_consent(purpose:, subject:)` | Record consent at run time (also `withdraw_consent`, `request_consent`). |
| `PamDsl.enforcement_mode = :audit` | Global mode (`:strict` default); `enforcement :audit` inside a policy overrides it. |
| `PamDsl.on_violation { \|v\| ... }` | Called with each audit-mode violation. |

---

## Correlation and causation

```ruby
Lyra::Correlation.with_id do |correlation_id|   # generates "corr_<time>_<hex>" when no id is given
  order.update!(status: "paid")
  payment.save!
end

Lyra::Causation.with_id(event.event_id) { Shipment.create!(order: order) }
```

| Method | Description |
|---|---|
| `Lyra::Correlation.with_id(id = nil) { \|id\| ... }` | Set the correlation id for the block, restoring the previous one after. |
| `Lyra::Correlation.current_id` | |
| `Lyra::Correlation.generate_id` | |
| `Lyra::Causation.with_id(id) { \|id\| ... }` | Set the causation id for the block. |
| `Lyra::Causation.current_id`, `Lyra::Causation.clear` | |
| `Lyra::Causation.track(cause_id, effect_id)`, `chain_for(event_id)`, `cause_of(event_id)` | An in-process, in-memory causation map. |
| `Lyra::UserActionContext.with_context(action_type:, user_id: nil, **options) { \|ctx\| ... }` | Set the user action for the block (and its id as the correlation id); Monitor events record it as `action_id` and `user_action`. Options: `controller:`, `action_name:`, `params:`. |

All are thread-local.

---

## Event flow analysis

`Lyra::EventFlow.new(subject_id: nil, subject_type: nil, time_range: nil)`
reads events from the whole store, filtered to the subject (by `user_id` or by
model and id) and the time range (default the last 30 days).

| Method | Description |
|---|---|
| `flow_data` | `{ timeline:, flows:, statistics:, privacy_impact: }` |
| `crud_to_event_mapping(model_name, operation, model_id = nil)` | Events for one operation; `model_name` is a String, `operation` a Symbol such as `:created`. |
| `reconstruct_state_chain(model, id)` | State after each event of the record's stream. |
| `data_lineage(field_name, model_name = nil)` | Every event that set or changed a field. |
| `privacy_impact_analysis` | PII inventory and risk assessment over the selected events. |

`Lyra::EventAnalyzer.new(events).analyze` returns timeline, operation, metric
and privacy summaries for a list of events.

---

## Dashboard

```ruby
# config/routes.rb
mount Lyra::Engine, at: "/lyra"
```

The engine adds no authentication; wrap the mount in your own constraint.
Routes (relative to the mount): `dashboard`, `dashboard/model/:model_class`,
`dashboard/compare/:model_class/:id`, `dashboard/discrepancies/:model_class`,
`dashboard/audit_trail[/:model_class/:id]`, `dashboard/schema[/history|/:version]`,
`config/projections`, `privacy/...` (subject data, GDPR report, portable
export, PII inventory, data lineage, PII detection, policy), `flow/...`
(timeline, event chain, CRUD mapping, correlation, user actions),
`visualizations/...` (event graph, heatmap, JSON feeds) and `verification`.
`config/routes.rb` has the full list.

---

## Rake tasks

Host applications get the tasks in `lib/tasks/lyra_*.rake`; run them with
`bin/rails` or `bundle exec rake`. The `privacy:` and `pam_dsl:` tasks are
loaded by PAM's Railtie when the pam_dsl gem is in the application's bundle.

| Task | Description |
|---|---|
| `lyra:mode:check TO=... [PROJECTION=sync\|async\|disabled\|lazy] [FROM=...] [REBUILD=1]` | Check a switch and certify it when clean; exits 1 otherwise. |
| `lyra:mode:status` | Configured mode, last applied mode, whether the gate is on. |
| `lyra:repair [DRY_RUN=1] [MODELS=User,Order]` | Bring the event log back in line with the tables (Monitor/Disabled only). |
| `lyra:erase MODEL=... ID=... REASON=... [FIELDS=a,b] [EVERYWHERE=1]` | `Lyra::Erasure.erase!` for one record. |
| `lyra:retention:apply [DRY_RUN=1] [MODELS=...]` | `Lyra::Retention.apply!`. |
| `lyra:genesis [MODEL=A,B]` | Import pre-Lyra rows now. |
| `lyra:projections:rebuild [MODEL=A,B] [TRUNCATE=false]` | Rebuild tables from the event log. |
| `lyra:schema:create`, `update`, `verify`, `report`, `history`, `diff[v1,v2]` | Event schema versions in `schema_path`. |
| `lyra:workflows:generate [MODE=...]`, `lyra:workflows:verify`, `lyra:generate_workflows` | Generate and verify PetriFlow workflows (needs petri_flow). See [WORKFLOW_GENERATOR.md](WORKFLOW_GENERATOR.md). |
| `pam_dsl:report:full`, `policy`, `pii`, `retention`, `access_patterns`, `article_30`, `export[path]`, `compare[p1,p2,path]` | PAM reports. |
| `pam_dsl:generate:policy[name]`, `pam_dsl:generate:from_models[name]` | Generate a policy file. |
| `privacy:report`, `privacy:policy`, `privacy:retention`, `privacy:article_30`, `privacy:export[path]` | Aliases of the `pam_dsl:report:*` tasks. |

Without `MODEL`/`MODELS`, tasks eager-load the application and use every
monitored model.

---

## Errors

| Error | Raised when |
|---|---|
| `Lyra::EventStoreUnavailableError` | An event could not be stored (fails the write in Hijack and event sourcing). |
| `Lyra::ModeTransition::Refused` | A gated switch or a boot found discrepancies or no certificate; `#report`. |
| `Lyra::Repair::Refused` | `Repair.run` outside Monitor/Disabled. |
| `Lyra::Projections::UnsupportedQuery` | ES-NoProj cannot answer a query exactly. |
| `Lyra::Temporal::HistoryNotRecorded` | A point-in-time read before an imported record's history begins. |
| `Lyra::StrictDataAccessViolation` | A callback-bypassing write with `strict_data_access` on. |
| `Lyra::PurposeBoundReads::PurposeRequiredError` | A read with no purpose under `reads_without_purpose = :deny`. |
| `Lyra::Erasure::Unsupported` | No personal fields to erase, or a NOT NULL column with no replacement. |
| `Lyra::Retention::Disabled` | `Retention.apply!` without `retention_executor` (and not a dry run). |
| `Lyra::MappingVerificationError` | `verify_mapping!` failed, or petri_flow is missing. |
| `Lyra::Schema::SchemaValidationError` | `strict_schema` found schema drift at boot. |
| `ArgumentError` | Unknown `reads_without_purpose` value, bad `domain_events` rule, or an unresolvable name in `config.models`. |
| `PamDsl::PolicyNotFoundError`, `InvalidFieldError`, `UndeclaredPurposeError`, `PurposeFieldMismatchError`, `ConsentRequiredError`, `SensitivityViolationError` | PAM validation (all subclasses of `PamDsl::Error`). |

`Lyra::Error` is defined but not raised by the engine.
