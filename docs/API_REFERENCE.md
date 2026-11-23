# Lyra API Reference

The public API of the Lyra engine: configuration, the model hooks, modes and
mode switches, events, reads in each configuration, and the privacy layer.
Everything here is defined in `lib/lyra.rb`, `lib/lyra/**`, `lib/tasks/lyra_*.rake`
or, for PAM, `gems/pam_dsl/lib`. For how the parts fit together see
[ARCHITECTURE.md](ARCHITECTURE.md); for switching modes in production see
[MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes); for GDPR workflows see
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

`mode=` accepts one of `Lyra::Configuration::MODES` and `projection_mode=` one
of `Lyra::Configuration::PROJECTION_MODES`; a string (from ENV, say) is taken
as its symbol, and anything else raises `ArgumentError`. Predicates:
`Lyra.monitor_mode?`, `Lyra.hijack_mode?`, `Lyra.event_sourcing_mode?`,
`Lyra.disabled_mode?` (the same methods exist on `Lyra.config`).

### Options

Every option of `Lyra::Configuration` (`lib/lyra/configuration.rb`).

| Option | Default | Description |
|---|---|---|
| `mode` | `:monitor` | `:disabled`, `:monitor`, `:hijack` or `:event_sourcing`. The raw setter: no gate, no record (see [Modes and transitions](#modes-and-transitions)). |
| `projection_mode` | `:sync` | Event sourcing only: `:sync`, `:async`, `:disabled` (ES-NoProj) or `:lazy` (ES-Lazy). |
| `event_store` | `nil` | The RailsEventStore client. Set by the engine at boot if still `nil`. Also `Lyra.event_store` / `Lyra.event_store=`. |
| `hijack_enabled` | `false` | Set by the mode helpers. When true, `hijack_mode?` is true whatever `mode` says. |
| `metadata_proc` | `nil` | `->(record, operation) { Hash }`, merged into the metadata of every event a monitored record's write produces, in every mode. A proc that raises is logged and skipped. |
| `correlate_writes` | `true` | Group writes into causal chains: the writes of one HTTP request share the request id as their correlation (a generated id when the request has none), a job's writes the correlation in scope where it was enqueued (its own job id when there was none), and a write outside both opens one named after its own event; a write made inside another write's callbacks records that write's event as its cause. A correlation set with `Lyra::Correlation.with_id` is kept. `false` leaves both to the application. See [Correlation and causation](#correlation-and-causation). |
| `monitor_append_failure` | `:log` | What Monitor does when a write's event cannot be stored: `:log` lets the write stand and logs the failure; `:fail_write` raises `EventStoreUnavailableError` and rolls the write back, as Hijack and event sourcing always do (bulk writes included). Validated on assignment. |
| `lock_aggregate_before_append` | `true` | Hijack and ES-Sync lock the record's row before appending an update's or destroy's event (PostgreSQL: `FOR NO KEY UPDATE` for an update, `FOR UPDATE` for a destroy, the strength the write takes anyway), so two writers of one record append and write its row in the same order, and a write takes the locks plain ActiveRecord takes, in the same order (no deadlock against `with_lock`; `test/aggregate_lock_deadlock_test.rb`). A record with no row gets an advisory lock on its stream instead. ES-Async writers take the advisory lock on the stream (they do not write the row; the job does), so a record's events commit in the order they were appended, which lets the projection job apply only the events after its checkpoint. Costs three SQL statements per update and one per destroy (the lock, and on an update the savepoint pair the append then needs). `false` restores the earlier order, with a row/log divergence possible under same-record races in Hijack and ES-Sync that DualView detects, and makes ES-Async's job replay the whole stream every time. SQLite needs no lock (it serialises writers from the first write, which is the append; `test/sqlite_same_record_test.rb`); other adapters warn once and are safe in a single process only. |
| `bulk_write_lock_limit` | `5_000` | ES-NoProj, ES-Async and ES-Lazy: the most records one bulk write may lock. In ES-NoProj, `update_all`, `delete_all`, `touch_all` and `update_counters` on a relation or batch, and a `dependent: :delete_all` or `:nullify`, take the aggregate lock (advisory, on its stream) of each record the relation selects when the write is called, and in ES-Async and ES-Lazy `update_all`, `delete_all` and `touch_all` take those of the rows they reach, to leave out a record whose stream ends in a destroy, holding the locks until the write's transaction ends; `destroy_all` locks each record in its destroy's own transaction, so the limit applies to it only inside a transaction already open. PostgreSQL's lock table, shared by every session, holds about `max_locks_per_transaction` × (`max_connections` + `max_prepared_transactions` + background processes) locks (measured: about 12,800 with the default 64 and `max_connections` 100, about 23,200 with 200); past it every session's writes fail with "out of shared memory". A larger write raises `Lyra::BulkWriteLockLimitError` (its `count` and `limit`) before it locks or writes anything. Write such a set with `in_batches(of: n) { \|batch\| batch.update_all(...) }`: each batch commits and gives its locks back on its own, except inside a transaction already open, which holds them all until it ends. `nil` removes the limit. Not applied with `lock_aggregate_before_append` off, when nothing is locked. |
| `strict_projections` | `false` | Re-raise a failed sync projection, or a failed enqueue of an async one, instead of logging it. A database error in a sync projection fails the write either way (PostgreSQL has aborted the transaction). |
| `projection_error_handler` | `nil` | `->(error, record, operation)`, called when a projection fails and `strict_projections` is off. |
| `async_projections_inline` | `nil` | ES-Async: `nil` projects inline in the test environment only; `true` always; `false` never. |
| `strict_schema` | `false` | Enforce the stored event schema at boot: raises `Lyra::Schema::SchemaValidationError` when the drift includes a breaking change (model or column removed, column type or event name changed); warning- and info-level drift is logged. |
| `schema_path` | `nil` | Where schema versions are stored; `nil` means `db/lyra_schemas`. |
| `strict_data_access` | `false` | Raise `Lyra::StrictDataAccessViolation` on callback-bypassing writes to monitored models. |
| `record_touches` | `true` | Record a touch (instance `touch`, `touch_all`, `belongs_to ... touch: true`) whose only changes are the update timestamps. `false` leaves those out of the log, in Monitor only, and DualView then ignores differences confined to them; refused in Hijack and event sourcing, and no process escalates while any runs with it off (`Lyra::TouchRegistry`). A string `"true"`/`"false"` is taken as its value. See [Touches](#touches). From 1.0.0. |
| `unrecorded_writes` | `:allow` | Whether `Lyra.unrecorded_write(reason:) { ... }` may run: `:allow` (each use is recorded as an `UnrecordedWrite` event in the stream `Lyra::UnrecordedWrites`, with the reason, who ran it and where it was called from, never the rows) or `:deny` (it raises). See [Callback-bypassing writes](#callback-bypassing-writes). |
| `genesis` | `:auto` | Import rows that predate Lyra: `:auto` in Hijack and the event-sourcing modes (whose stream heads refuse an update of a record with no history; Hijack from 1.0.1), `true` in every event-producing mode (Monitor too), `false` never. See [Genesis](#genesis). |
| `genesis_unrepresentable` | `:refuse` | What Genesis does with a row holding a value its model cannot represent (an enum value outside the mapping, ...): `:refuse` raises `Lyra::Genesis::Refused`, listing the rows, and imports nothing of the model; `:skip` leaves those rows without a stream and imports the rest; a write to one is refused until it is fixed in the database. A gated mode switch refuses either way. `Lyra::Repair` follows the same setting. Validated on assignment. See [Genesis](#genesis). |
| `reference_links` | `:auto` | Link each event that sets a `belongs_to` key into a stream named after the key (`Model.foreign_key$value`), so ES-NoProj answers a lookup by foreign key from one stream instead of rebuilding every record of the model. `:auto` writes them in ES-NoProj only, `true` in every mode but Disabled, `false` (or `nil`) never; the switch into ES-NoProj first links the events the earlier modes stored. The same switch writes the value streams of the unique-index check (`Model!column$<digest>`), which `:auto` and `true` also write in ES-Async and ES-Lazy (their check reads them; the foreign-key links stay as above). See [ES-NoProj](#es-noproj-projection_mode-disabled). |
| `value_digest_key` | `nil` | The secret the value streams and the unique-value lock keys are keyed with (HMAC-SHA256, `Lyra::Projections::ValueDigest`); `nil` derives one from the application's `secret_key_base`. Changing it relinks the value streams on their next use; every process of an installation must use the same. |
| `unique_index_refresh` | `60` | Seconds after which a process reads a monitored model's unique indexes again, so an index a migration adds is enforced (and its column linked) in a running process; `nil` reads them only once (and after `reset_column_information`). |
| `retention_policy` | `nil` | Default retention used by `Lyra::Privacy::GDPRCompliance` reports and recorded in the event schema. Does not delete anything. |
| `privacy_policy` | `nil` | Default privacy policy name for monitored models that name none. |
| `mode_transition_gate` | `nil` | Gate mode switches: `nil` everywhere but the test environment; `true` always; `false` never. |
| `mode_transition_certificate_ttl` | `3600` | Seconds a clean `lyra:mode:check` certifies a switch. |
| `mode_transition_settle_timeout` | `30` | Seconds the check, and the switch, wait for the writes in flight when they read the event store's position (PostgreSQL); a write still open then leaves the check unclean. |
| `stream_heads` | `true` | Keep each record's stream head and check its history where its events are appended (Hypothesis H's first clause, `Lyra::StreamHeads`): a create on a live key, an update or destroy of a record with no live history, and a change of a primary key are refused in Hijack and the event-sourcing modes; Monitor records the write (a key change as a destroy and a create) and reports a head that disagreed. PostgreSQL only. `false` gives 1.0.0's behaviour, for comparison. |
| `check_effects` | `false` (`LYRA_CHECK_EFFECTS=1`: `true`) | Hijack and ES-Sync: after each write through callbacks, compare the record's row with the replay of its stream in the write's transaction, and raise `Lyra::EffectMismatchError` (rolling the write back) when they differ (Hypothesis H's effect clause, H2). Costs a read of the row and the stream and a replay per write. Writes that skip callbacks are not checked. |
| `dual_view_sample_rate` | `0.0` | Share of committed writes checked by DualView (opt-in; `0.0` is off). |
| `dual_view_discrepancy_handler` | `nil` | Called with each `ModeTransition::Discrepancy` the sampler finds. |
| `mode_sync` | `nil` | Keep every process in the application-wide mode: `nil` follows the gate setting; `true`; `false`. |
| `mode_sync_interval` | `5` | Seconds between ModeSync checks. |
| `annotate_privacy` | `false` | Stamp each event's metadata with its privacy annotation (opt-in). |
| `record_access_events` | `false` | Record each policy-validated access as an event (opt-in; needs pam_dsl). |
| `access_metadata_proc` | `nil` | `->(access) { Hash }`, extra metadata for each recorded access. |
| `record_subject_access_exports` | `true` | Record each explicit Art. 15 copy (`GDPRCompliance#data_export`; not `record: false`, `full_report` or the dashboard) as a `SubjectAccessExported` event in `Lyra::SubjectAccessExports$<Type>$<id>`, which access-log erasure leaves: when, which sections, who; never values. From 1.0.0. |
| `erase_access_log` | `false` | `Lyra::Erasure.erase!` also deletes the subject's access log once the record is fully erased (every personal field, now or earlier), unless the call says otherwise (`access_log:`). |
| `rights_refresh_interval` | `1` | Seconds a process answers the checks of restrictions, objections (Condition 6) and consent from what it last read (`Lyra::Rights`), and never from what it read before the current checking scope began (a purpose block, a request, a job, a batch). What this process records is seen at once; what another records, from the next scope or within the interval. From 1.0.0. |
| `rights_refresh` | `:scope` | When a process reads the rights and consent afresh: `:scope` at the first check of each checking scope (a `Lyra.with_purpose` block, a web request, a job, a batch of `in_batches`/`find_each`/`find_in_batches`), so another process's right applies from the next scope, at the cost of one indexed query per scope that checks something; `:interval` only after `rights_refresh_interval`, so it may apply up to that long later, in the middle of a request, and a scope costs no query of its own. Scopes open either way. A string is taken as its symbol; other values raise `ArgumentError`. From 1.0.0. |
| `erasure_max_copies` | `10` | With `Lyra::Erasure.erase!(…, everywhere: true)`, a value held by more other records than this is left as shared and reported in `Result#shared`; the person's linked records (`belongs_to` the erased record) do not count. A positive integer; `max_copies:` and `lyra:erase MAX_COPIES=` override it per call. From 1.0.0. |
| `reads_without_purpose` | `:allow` | Reads of a policy-covered model with no declared purpose: `:allow`, `:audit` or `:deny`. Validated on assignment. |
| `retention_executor` | `false` | Allow `Lyra::Retention.apply!` to change data (opt-in). |
| `retention_anchors` | `{}` | Column each model's retention period runs from, keyed by model name (a String); `created_at` when absent. |
| `dashboard_max_events` | `10_000` | The most events a dashboard page or JSON route reads from the log in one request; `?limit=` may only lower it. The routes that look across the log (the CRUD summary, a correlation, a user's actions, PII detection) read the most recent events up to it, leaving out the access log's own entries, and report `window: { limit:, returned:, truncated:, skipped: }` (`truncated`: older events were not read; `skipped`: access-log entries and `SaveWithoutEffect` markers passed over; at most ten times the limit is scanned). A subject's timeline (`flow/timeline`, `privacy/pii_inventory`) reads the newest events of that record's stream, at most the limit. Before 1.0.0 they read the whole log. |
| `dashboard_authorization` | `nil` | Who may use the engine's dashboard: a proc run on the controller before each action; truthy allows, falsy answers 403. `nil` allows development and test only. See [Dashboard](#dashboard). |
| `dashboard_purpose` | `nil` | The purpose the dashboard reads under when a request names none (`?purpose=`), one the policy declares for oversight. With neither, it reads without a purpose, as `reads_without_purpose` decides; a read the policy refuses answers 403 and says how to name one. |

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
| `declared_models` | What `models=` asked for (`Lyra::ModelSelection::Spec`: `all`, `entries` `{ "Name or pattern" => options }`, `except`). |

```ruby
config.models = %w[Order Payment]                          # by name
config.models = { "Order" => { event_prefix: "Shop" }, "Payment" => {} }
config.models = %w[Spree::* Order]                         # a namespace pattern
config.models = :all                                       # every eligible model
config.models = :all, except: %w[Session Spree::LogEntry]  # with a denylist
config.verify_mapping!
```

A name that does not resolve fails the boot. Patterns and `:all` enrol only
eligible models: concrete (not abstract), named, with a table and a
single-column primary key, and the base class of a single-table-inheritance
hierarchy (its subclasses follow it). The primary key may have any name and
type (`self.primary_key = "code"`); a model with a composite primary key is
not supported, and naming one (or calling `monitor_with_lyra` on it) raises
`ArgumentError`. The application's code is eager-loaded
first, so every model is found. Some models are never enrolled, and naming
one fails the boot: the event store's own tables (an event about an event
would recurse), Lyra's, and those of Solid Cache, Solid Queue, Solid Cable,
Active Storage, Action Text, Action Mailbox and PaperTrail. A pattern that
matches nothing logs a warning; the enrolled models are logged at boot.
`:all` outside Monitor mode warns: Hijack and the event-sourcing modes then
route every write of every model through events, including models no one has
reviewed, so an allowlist suits them better. A single-table-inheritance
hierarchy shares one stream per row, named after its base class
(`Lyra.stream_name`), so enrolling the base class covers every subclass and
any of them reads the same history.

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

Rails' own association writes are always allowed and recorded: a `has_many`'s nullify
(`dependent: :nullify`, and removing children from the collection, whatever the key's columns),
a `has_one`'s `dependent: :nullify`, a `has_many :through`'s `dependent: :nullify` of its through
records and the delete of its through records when records are removed from it, and the deletes
of `has_and_belongs_to_many` join rows (recorded as `AssociationUnlinked`). A `has_many`'s
`dependent: :delete_all` is refused. Lyra tells them by a mark Rails' association code puts on the
one relation or record it writes, just before the write
(`Lyra::Associations::Maintenance`).
The same writes made by the application (`Article.where(...).update_all(author_id: nil)`, a
`delete_all` on the join table's model) are refused like any other. So are the application's
`insert_all`, `insert_all!` and `upsert_all` (and `insert`, `insert!`, `upsert`) of join rows,
through Rails' join model (`Item::HABTM_Tags`) or a model of its own on the join table; where
they run they are recorded as `AssociationLinked` (see below).

`insert_all`, `insert_all!` and `upsert_all` conflict as Monitor's table would, in every mode.
In ES-Async the rows of the primary keys the rows give are first brought up to date with their
streams, under the records' aggregate locks (a record whose destroy is still waiting for its
projection job is inserted again, a `Created` after the `Destroyed`, with the column defaults;
one whose create is waiting conflicts), and the waiting jobs then find nothing to apply. In
ES-NoProj the primary key and every other unique index (not partial, not an expression, on no
column with a nondeterministic collation; NULLS NOT DISTINCT honoured) are checked against the
event store under their locks: `insert_all` leaves a row out (or, with `unique_by:`, raises
`ActiveRecord::RecordNotUnique` for a conflict on another index), `insert_all!` raises. A row
Genesis left without a stream conflicts as in Monitor. In ES-Sync, ES-Async and ES-Lazy the
same unique indexes' values are locked, and in ES-Async and ES-Lazy looked up in the event store
too (a record whose create is not projected yet holds its value), with the same outcomes;
`upsert_all` there raises for a conflict on an index other than its conflict columns. Those locks (one per row and index, plus
one per key) count together against `config.bulk_write_lock_limit`, so a model with several
unique indexes reaches it at fewer rows. A model whose primary key has several columns is
refused these writes in the event-sourcing modes (`ArgumentError`), before anything is written.
A `create` or `update` through callbacks, `update_columns`, `update_column` and `update_all` are
checked against the same indexes (see "Unique indexes" under ES-NoProj below). The result of
`returning:` is Active Record's own (its column types included), whatever key Lyra adds to read
the rows back.

### Touches

An instance `touch` and a `belongs_to ... touch: true` cascade (Rails's
`touch_later`, run at commit) are recorded with `bypass_source: "touch"`; a
`touch_all` is Rails's `update_all` of the timestamps and is recorded as
`update_all`. Each changes `updated_at` (and any column it names), and the event
carries the change, so the log replays to the row and DualView compares the
timestamps like any other column.

An application that touches a lot (cache-busting `touch: true` chains) can
leave those out:

```ruby
config.record_touches = false   # default true
```

What it does, per mode:

| | `record_touches = true` (default) | `record_touches = false` |
|---|---|---|
| Monitor | Every touch is an event. | A touch whose only changes are the model's update timestamps (`updated_at`, `updated_on`) appends nothing, once the process's entry in the registry below is written (when it cannot be, the touch is recorded); the row's `updated_at` moves, its stream's does not. A touch that changes another column too (`touch(:completed_at)`, a `lock_version` increment, `touch_all(:published_at)`) is recorded in full. `update_all(updated_at: ...)` and `update_columns(updated_at: ...)` are not touches and are recorded. |
| Hijack, event sourcing | Every touch is an event. | Refused. These modes take the log as the record of every change and rebuild rows from it (a switch into event sourcing, which Hijack passes unchecked, a Rebuild, ES-NoProj's reads); a missing touch would rebuild a stale `updated_at`. `record_touches = false` raises `ArgumentError` there. While it is false, `mode=`, `hijack_enabled = true`, `ModeTransition.apply_label` and, before boot or with the gate off, `enable_hijack!` and `enable_event_sourcing!` raise `ArgumentError`; after boot with the gate on, those two go through `ModeTransition.to!` and raise `ModeTransition::Refused`. |
| Disabled | Nothing is recorded. | Nothing is recorded. |

With the option off:

- **DualView** (`calculate_differences`, the sampler, the gate's check, `lyra:repair`)
  takes a difference confined to the update timestamps as agreement. A
  difference in any other column is reported with the timestamps beside it,
  and `lyra:repair` then records both.
- **The registry.** A process with the option off registers in
  `lyra_mode_transitions` (a row of kind `touch_skipping`: host, pid, when it
  began, Lyra's version, last seen), at boot or when the option is set false,
  and before its first touch is left out in any case; a touch is left out only
  once the entry is committed. It refreshes the entry at most every
  `Lyra::TouchRegistry::HEARTBEAT` seconds (60), from the touch path and from
  ModeSync's check before requests, jobs and writes (outside transactions),
  and ends it when the option is set back to `true` and at exit, best effort.
  An entry not refreshed for `EXPIRY` seconds (180) is no longer live. Times
  are the database's clock (`clock_timestamp()` on PostgreSQL). With the option
  `true` no write path reads or writes the registry; each `to!` or `check` into
  Hijack or event sourcing, each ModeSync adoption of such a mode and each
  `Rebuild.rebuild` runs one registry `SELECT`, and `to!` and `check` also take
  the registry's advisory lock in a short transaction.
- **Registry writes never join the caller's transaction.** Each commits on its
  own: on the thread's connection when it has no transaction open, else on a
  second connection checked out for at most one second
  (`Lyra::TouchRegistry::CHECKOUT_TIMEOUT`), with a two-second `lock_timeout`.
  When no such connection can be had (every one is in use, or the connection
  is pinned, as in Rails' transactional tests), the touch is recorded and the
  heartbeat waits for the next chance. No thread waits on a lock its own
  transaction holds. What a touching thread may wait for: up to about one
  second for a second connection, when a heartbeat falls due inside a
  transaction while the pool is full, and up to two seconds (`lock_timeout`)
  when the registry's lock is held, for example by a `to!` or `check` running
  inside an outer transaction; in both cases the touch is then recorded. With
  pinned connections (Rails' transactional tests) every touch is recorded, with
  a warning, so the option off cannot be exercised there.
- **The mode gate** refuses every way into Hijack or event sourcing while
  touches are left out: by this process (the option off here), or by any
  process with a live entry. `Lyra::ModeTransition.to!` (`force: true`
  included), `check` (at its start and again before it certifies), ModeSync's
  adoption of a switch made elsewhere, and a boot into such a mode raise or
  log `ModeTransition::Refused`, naming each live process (host, pid, since,
  last seen) and the way up. `rake lyra:mode:check` prints it and exits
  non-zero; `rake lyra:mode:status` lists the live processes. The raw
  setters (`config.mode =`, and `enable_*!` with the gate off), which skip
  the gate by design, check only this process's option.
- **Registration and a switch are serialized.** Every registry write takes
  the registry's PostgreSQL advisory lock and, under it, reads the
  application's latest applied mode; a switch into Hijack or event sourcing
  takes the same lock for its last look at the registry and its record
  (`to!`), as a check does for its last look and its certificate. So either
  the switch sees the new entry and is refused, or the registering process
  sees the switch: it ends its entry at once, records the touch, and is
  fenced (below). No touch is left out in a mode whose log rebuilds rows. On
  adapters other than PostgreSQL, `Lyra::AdvisoryLock` takes no lock (it warns
  once, except on SQLite), so this race is closed only on PostgreSQL.
- **ModeSync**: a process with the option on that finds a switch into Hijack
  or event sourcing while another process has a live entry does not adopt
  it yet (logged once); the switch stays unseen, and the process adopts it at
  a later check, once that entry has ended or expired.
- **Certificates**: a certificate counts only if it was issued after every
  entry's latest refresh or end, so nothing certified before or during a
  period in which a process left touches out is taken afterwards; the switch
  runs a full check instead. With no live entry the check compares
  timestamps strictly, finds each touch that was left out, and refuses until
  `lyra:repair` has recorded them.
- **An application already in Hijack or event sourcing**: a process with the
  option off does not boot into it (`Lyra::TouchRegistry.boot!` raises
  `ModeTransition::Refused`), cannot set the option false in it at runtime
  (the setter raises and leaves the option `true`), and one that finds it in
  such a mode later (ModeSync, after its entry expired; or its own next
  registry write) is fenced: each ModeSync check raises, and so does every
  touch it would have left out, and with it every save that cascades such a
  touch (a child's `save` under `belongs_to ... touch: true` fails and rolls
  back), until it runs with the option on. Failing closed is deliberate: such a
  process must be restarted with the option on, not left writing.
- **A warning**, once per process, when it registers: "Lyra: record_touches is
  off — touches that change only update timestamps are not recorded;
  escalation to Hijack or event sourcing is refused while any process runs
  this way. To escalate: restart every process with record_touches on, run
  `rake lyra:repair` in Monitor, then switch."
- **Rebuild** (`Lyra::Projections::Rebuild.rebuild`, `rake lyra:projections:rebuild`)
  is refused while the option is off here or a process has a live entry
  (`Rebuild::Refused`; the task prints it and exits non-zero): it would set
  every touched row's `updated_at` back to what the log says.
- **To escalate**, restart every process with `record_touches = true` (their
  entries end), and run `bin/rails lyra:repair` in Monitor: the check now sees
  each stale `updated_at`, the repair appends one
  `Updated` event per record with the row's value (metadata `source:
  "lyra_repair"`), and the switch then passes.
- **Genesis**: a row without a stream that is touched with the option off gets
  no event; Genesis imports it later as it then is, timestamps included.
- **Strict mode** is unchanged: a `touch` is allowed (Rails calls it for
  `touch: true`), `touch_all` is refused as `update_all`.
- **Causation**: a touch runs no write scope, so it is never a cause; an
  unrecorded one has no event id, and nothing names it.
- **History**: `Lyra.state_at`, `as_of` and the audit trail show the
  `updated_at` of the last recorded write, not of the last touch.

### Optimistic locking

A model with a `lock_version` column (or another `locking_column`) raises
`ActiveRecord::StaleObjectError` on a stale `save`, `update`, `destroy` or
`touch` in every mode, as plain Active Record does, and leaves the stale
record's version as it was. Each write's event records the increment as a
change of the column, `[old, old + 1]`, so the log replays to the row's
version and DualView compares it like any other column.

Monitor and Hijack leave the check to Active Record's own UPDATE or DELETE. The
event-sourcing modes check before appending, under the lock on the aggregate
(taken for such a model even with `lock_aggregate_before_append = false`):
the newest event of the stream that records the column gives the version, and
a record that expects an older one is stale. The check is against the log
because in ES-Async and ES-Lazy the row can trail it, and in ES-NoProj there
is no row. A version submitted with the change (`update(lock_version:
params[:lock_version], ...)`) is checked instead of the loaded one, as in Active
Record. A record that expects a newer version than the log's passes: events
written before Lyra recorded the column (a Hijack table switched to event
sourcing) did not carry increments their rows made.

### `has_and_belongs_to_many` links

A HABTM join table has no model of its own, so Lyra records its rows as links
of the owner: `tags << tag`, `tag_ids=`, `tags.create`, saving a new owner with
tags, `tags.delete`, `tags.clear` and destroying the owner each append a
`Lyra::Events::AssociationLinked` or `AssociationUnlinked` event to the owner's
stream, in every mode but `:disabled`. The event names the association, the join
table, the associated ids (`target_ids`) and the join rows written or deleted
(`rows: [{ "item_id" => 1, "tag_id" => 5 }]`), and is linked into each associated
record's stream when that model is monitored, so either side's stream tells its
links. A failed append follows the bypass-event policy (`BypassEvents.required?`).

The events change no record's state on replay. DualView compares each HABTM
association's links (`{ "tags" => { crud: [...], event_sourced: [...] } }`),
`Rebuild` restores the model's join tables from them, and Genesis records the
links a row already had. The join table is read as a set: a pair linked twice
is one link.

The application's own writes of join rows are recorded the same way: a
`delete_all`, `insert_all`, `insert_all!` or `upsert_all` through the join model
or a model it declared on the join table records, for each row written (read
back with `RETURNING`; a row `ON CONFLICT` skipped records nothing), the link or
unlink Rails' own from each side records, on every monitored owner's stream the
row names (an upsert that moves a row to another pair unlinks the old pair). A
table is a join table when a `has_and_belongs_to_many` whose links Lyra records
names it, whether its owner's model is monitored or only the associated
records'. A `has_many :through` over a model Lyra does not monitor is not one:
its rows are that model's, and no link is recorded for them from either side.

### Who wrote it

Events take `user_id` from `Current.user` and `request_id` from
`Current.request_id` when the application defines them, in every mode, including
writes that skip callbacks (`update_columns`, `touch`, `update_all`, ...). A model
may override the private hooks `lyra_current_user_id` and
`lyra_current_request_id` for writes through callbacks; writes that skip them read
`Current` directly. `record.lyra_event_metadata(operation)` returns the
attribution metadata a write by that record would carry.

---

## Modes and transitions

See [MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes) for the procedure. This section
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
| `to!(mode, projection_mode: nil, force: false, rebuild: false)` | Switch, gated. Runs a check when the switch changes the authoritative store (escalation from Disabled/Monitor, or leaving ES-NoProj/ES-Lazy/ES-Async for a table-reading mode), unless a fresh certificate covers it. Raises `ModeTransition::Refused` (with `#report`) on discrepancies, and, entering ES-NoProj, when a monitored model has a default scope ES-NoProj cannot evaluate or an unmonitored table has a database foreign key into a monitored one. Records the switch so other processes adopt it. Returns the check's `Report`, or `nil`. |
| `check(to:, from: current, models: Lyra.config.monitored_models, rebuild: false, batch_size: 1_000)` | Compare every row with its stream; imports pre-Lyra rows first on escalation (a row holding a value its model cannot represent is a discrepancy and its model is not imported); stores a certificate when clean. Returns a `Report`. With `rebuild: true`, leaving ES-NoProj, ES-Lazy or ES-Async, it rebuilds the tables (`Rebuild.rebuild`) and compares them in one transaction (a savepoint in a transaction already open), rolled back unless the check is clean (from 1.0.1): a check that fails leaves the tables as they were (`report.rebuilt` is then 0). When a rebuild refuses to clear a table (see [Rebuild](#rebuild)), it raises `ModeTransition::Refused` and changes no table; rebuild the tables yourself first (`TRUNCATE=false`, or `FORCE=1` after a backup), then check without `rebuild`. |
| `current` | This process's configuration as a label: `"monitor"`, `"event_sourcing/lazy"`. |
| `label(mode, projection_mode = nil)` | Build such a label. |
| `gate_enabled?` | Whether switches are gated (`config.mode_transition_gate`). |
| `gate_required?(from, to)` | Whether a switch between two labels needs a check. |
| `last_applied` | Label of the last applied switch recorded in `lyra_mode_transitions`, or `nil`. |

`Report` fields: `from`, `to`, `checked`, `rechecked`, `imported`, `rebuilt`,
`discrepancies` (`Discrepancy` with `model`, `id`, `problem`, `details`),
`position`, `started_at`, `finished_at`, `unrepresentable` (rows Genesis would not import,
holding values their model cannot represent; each listed one is also a discrepancy, see
[Genesis](#genesis)); methods `clean?` and `summary`.

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
  stream falls behind its row until `Lyra::Repair` brings it back. With
  `config.monitor_append_failure = :fail_write`, Monitor is fail-closed too.

### `Lyra::Repair`

Only in Monitor or Disabled (raises `Lyra::Repair::Refused` otherwise).

```ruby
result = Lyra::Repair.run(dry_run: true)
result.summary   # "checked 1200 records: 3 out of line, 0 repaired, 3 still out of line"
```

| Method | Description |
|---|---|
| `run(models: Lyra.config.monitored_models, dry_run: false, operator: nil, unrepresentable: config.genesis_unrepresentable)` | Find out-of-line records and, unless `dry_run`, repair them. Returns a `Result` (`checked`, `found`, `repaired`, `remaining`, `skipped`, `unrepresentable`, `summary`). |
| `repair(model, id, operator: nil, unrepresentable: config.genesis_unrepresentable)` | Repair one record: an `Imported` event for a row without events, an `Updated` event for a row that differs, a `Destroyed` event for events without a row. Returns the `Discrepancy` repaired, or `nil`. |

Repair events carry `source: "lyra_repair"` in their metadata.

A repair writes the row as its model reads it, so it applies Genesis's check
([Genesis](#genesis), `Genesis.unrepresentable(record, columns:)`): on the
whole row for an `Imported` event, on the changed columns for an `Updated` one.
A record whose event would hold a value its model cannot represent (an enum
value outside the mapping, read as `nil`) follows the same setting as Genesis
(from 1.0.0): with `:refuse` (default) `run` raises `Lyra::Repair::Unrepresentable`
(a `Repair::Refused`; `rows`, `values`, `found`, the same listing, personal
values not shown) before anything is written; with `:skip` those records stay
out of line (in `remaining`), the rest is repaired, and `Result#skipped` and
`#unrepresentable` list them. A dry run lists them and never raises.

### Genesis

`Lyra::Genesis` gives each row that predates Lyra one `Imported` event holding
the row as it is. It runs on a model's first use in a process (its first write;
in ES-NoProj also its first read) when `Genesis.enabled?` (`config.genesis`).

| Method | Description |
|---|---|
| `import(model_class, unrepresentable: config.genesis_unrepresentable)` | Import every row without a stream now, whatever the mode, in one transaction. Returns a `Result` (`model`, `imported`, `skipped`, `unrepresentable`: the first `LISTED` values of the skipped rows, `summary`). Raises `Refused` for rows the model cannot represent unless `unrepresentable: :skip` (see below). From 1.0.0. |
| `import_all(model_class, unrepresentable: config.genesis_unrepresentable)` | The same; returns the count imported. |
| `import_one(model_class, id)` | Import that one row now, whatever the mode, if it still has no stream, under the model's Genesis lock; returns whether it did. `Lyra::Erasure` uses it for a row it erased that had no stream (from 1.0.0). Genesis's lock is per table, named after its stream owner (the STI base class) since 1.0.0. |
| `first_use(model_class, id = nil)` | Import once per process, if enabled; with `id`, `admit!` that row. |
| `enabled?`, `imported?(model_class)`, `reset!` | |

For a large table run `bin/rails lyra:genesis` before enabling a mode.

**Values the model cannot represent** (from 1.0.0). The `Imported` event holds
the row as the model reads it, so a stored value the model cannot read would
give an event that disagrees with its row: `status = '2'` under
`enum :status, { requested: "requested", approved: "approved" }` is read as
`nil`, and the disagreement surfaced later (ES-Lazy's catch-up writing `NULL`
into a `NOT NULL` column). Genesis checks every attribute of every row first:
the value read, written back by the model's type, must be the value stored,
compared as the column's own type reads both (or as the database would be
sent them). `'1'` and `1`, time zones and timestamp precision, a time of day,
a decimal's trailing zeros, jsonb key order, arrays, booleans, money,
intervals, ranges and a `normalizes` attribute's legacy value are no
difference. Found: an enum value outside the mapping; a type that reads a
value lossily (`attribute :amount, :integer` over `10.50`, `:date` over a
timestamp); an inet value's host bits, which Rails drops (`192.168.1.5/24` is
read as `192.168.1.0/24`; in `inet[]` arrays element by element); a value out
of the model's integer range ("out of range for the model's type").

Whatever the type, a stored value the model writes back as `NULL` is lost,
in a nullable column too ("which would be written back as NULL"): a JSON
`null` in a json/jsonb column, an empty range, a blank or `'null'` JSON text
or an empty YAML hash in a serialized column (read as `nil` or `{}`). In a
`NOT NULL` column a rebuild would fail on it; in a nullable one
`where(col: nil)` would find the row afterwards. A serialized, encrypted or
JSON attribute's stored text is otherwise one of many encodings of its value
(JSON whitespace, a fresh ciphertext), so its text is not compared; a value
of another class is. Columns the model ignores (`ignored_columns`) are
imported as stored and not checked.

- `:refuse` (default): every row is checked before anything is written, then
  `Lyra::Genesis::Refused` (`model`, `rows`, `values`: the first
  `Genesis::LISTED`, 20, `Unrepresentable` values with `model`, `id`,
  `attribute`, `stored`, `read_as`, `reason`; `found`: all of them). Nothing of
  the model is imported; inside a caller's transaction the import is a
  savepoint, so a caller that rescues the refusal commits nothing of it. On
  first use the write or read that triggered it fails with it. A refused first
  use is remembered for `Genesis::REFUSAL_RECHECK` (30) seconds from the scan
  that found it: the uses meanwhile raise it again without scanning the table;
  `import`, `import_all` and `lyra:genesis` always scan.
- `:skip`: those rows keep no stream; the rest is imported; the log warns. A
  write to a skipped row, through callbacks (`update!`, `destroy!`) or
  bypassing them (`update_columns`, `touch`, `update_all`, `touch_all`,
  `delete_all`, `upsert_all`, ...), or an ES-NoProj `find`/`exists?` of it,
  imports it if the model can now represent it, and raises `Refused` (`id`:
  the row, or the rows of a bulk write) while it cannot, so its stream never
  begins with the write's event (`Genesis.admit!`, `Genesis.admit_all!`,
  `Genesis.skipped?`). A query over many records (`where`, `count`) does not
  see it. **To fix a skipped row** in event sourcing, correct it in the
  database (SQL), since writes through the model are refused; the next use
  of it imports it, or run `bin/rails lyra:genesis MODEL=...`.

Cases to know:

- A legacy empty YAML hash, `'--- {}\n'`, under `serialize :col, type: Hash`
  is read as `{}` and written back as `NULL`, so by default it refuses the
  model (`UNREPRESENTABLE=skip`, or set those rows to `NULL` by SQL).
- In Monitor with `config.genesis = true`, `:skip` and
  `config.record_touches = false`, a timestamp-only `touch_all` reaching a
  skipped row is refused, though no event would have been recorded for it.
- `dependent: :nullify` over children one of which was skipped: where events
  are required the parent's destroy is refused; in Monitor that child's
  event is left out (logged) and every other child gets its event.

A process imports on its own first use of a model, and knows the rows it
skipped itself. A row written outside Lyra (SQL) after that first use, or
skipped by another process, is unknown to it until `lyra:genesis` imports
it. A write that bypasses callbacks runs the model's first use too.

The value of an attribute the model's privacy policy declares, or of an
encrypted one, is not shown (`code (a personal value, not shown)`). At a gated
switch into Hijack or event sourcing (`ModeTransition.to!`, `lyra:mode:check`)
the rows refuse the switch whatever the setting, as discrepancies
(`a value the model cannot represent`), counted in `Report#unrepresentable`;
the refused model's rows are not compared. `import_one` (erasure) logs such a
value and imports the row. `Genesis.unrepresentable(record, columns: nil)`
runs the check on a record loaded from its row (`Lyra::Repair` uses it).

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

`Lyra::Events` defines an event class on first reference when the name is one
a monitored model or the stored schema writes, loading the model from the
name's stem first if needed (`PostCreated` → `Post`, `SpreeOrderCreated` →
`Spree::Order`). A process that only reads therefore gets `Lyra::Event`s with
the readers above, not plain `RubyEventStore::Event`s. Any other name raises
`NameError`. A model with a custom `event_prefix` or `event_mapping` that is
not loaded yet resolves only through the schema store.

### Metadata

| Written by | Metadata keys |
|---|---|
| Monitor (interceptor) | `user_id`, `request_id`, `correlation_id`, `causation_id`, `action_id`, `user_action`, plus `metadata_proc`'s hash |
| Hijack and event sourcing (command handler) | the same keys as Monitor, plus `source: "lyra_command_handler"`; a command without a record (direct `CommandHandler` use) carries `correlation_id`, `causation_id`, `action_id` and `user_action` |
| Genesis | `genesis: true` |
| Repair | `source: "lyra_repair"`, `repaired`, `repaired_by` (a label), `os_user`, `host`, `pid`, `correlation_id` |
| Erasure | `source: "lyra_erasure"`, `erased_by` (a label), `os_user`, `host`, `pid`, `correlation_id` (on `ErasureApplied`, whose data adds `any_fields`, `requested_fields`, `beyond_policy`) |
| any, with `annotate_privacy` | `privacy` (see [Privacy stamps](#privacy-stamps-opt-in)) |

`metadata_proc` applies to every mode's events.

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

For an update or destroy, a model's own `aggregate_class` is loaded with its
stream's history first (`load(id, store, model_class)`), so domain checks can
use it; the default `GenericAggregate` starts empty, since nothing in it
depends on history, and its writes read no stream. The command handler
instantiates the aggregate as `new(id, model_class)` and uses its stream, so a
custom aggregate should subclass `Lyra::GenericAggregate`, whose stream is the
model's
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
`:lyra_projections`, enqueued after commit, up to 5 attempts), which applies,
under a lock held per stream, the record's events after the stream's
checkpoint (the last event a job applied, table `lyra_async_checkpoints`,
created on first use), so out-of-order jobs converge and a record's jobs cost
what its history is long. That relies on a record's events committing in the
order they were appended, which the lock on the aggregate gives
(`lock_aggregate_before_append`, taken by ES-Async writers as an advisory lock
on the stream); with the lock off, or without a usable checkpoint, the job
replays the whole stream. With `async_projections_inline` (the test
environment's default) the writer runs the same job itself, after its
transaction commits.

Read-your-writes under ES-Async: the block's writes are projected before it
returns (the job is still enqueued and converges on the same row). Blocks
nest: an inner block projects its own writes when it ends and restores the
outer block's list; if the inner block raises, its unprojected writes pass to
the outer block. Every write is projected by the time the outermost block
returns. By default writes are projected when the block ends, not as they are
made: a read inside the block, before it ends, can still come before the
projection. Code that writes and then reads in one unit of work, as Solidus's
checkout does, opens the block with `each_write: true`: each write is then
projected as it is made, in its own transaction, as ES-Sync projects it (the
job is still enqueued and finds nothing new to apply). The option holds for
the block that sets it; a nested block has its own.

```ruby
Lyra::Consistency::ReadYourWrites.with_guaranteed_read do
  @registration = Registration.create!(params)
end
Registration.find(@registration.id)   # projected

Lyra::Consistency::ReadYourWrites.with_guaranteed_read(each_write: true) do
  order.payments.create!(amount: order.total)
  order.complete!                     # reads the payment: already projected
end

class RegistrationsController < ApplicationController
  include Lyra::Consistency::ControllerConcern   # wraps actions in ES-Async
end

# An application whose actions read back what they have just written, adapted
# from an initializer without changing its code (applies to subclasses too):
Spree::BaseController.include Lyra::Consistency::ControllerConcern
Spree::BaseController.lyra_read_your_writes each_write: true
```

`Lyra::Consistency::ControllerConcern` wraps each action in a block under
ES-Async only. `lyra_read_your_writes each_write: true` makes that block
project each write as it is made; the default, `false`, projects when the
action ends. (Earlier versions of this page named the concern
`ReadYourWrites::ControllerConcern`, which does not exist.)

### ES-NoProj (`projection_mode :disabled`)

Writes store events only; nothing is written to the tables. On a monitored
model, `find`, `find_by`, `find_by!`, `exists?` (with an id), `where`, `all`,
`first` and `last` read from `Lyra::Projections::EventStoreReader`, which
rebuilds records from their streams through a cache keyed by each stream's last
event id (`Rails.cache`). Associations to monitored models are read the same
way.

Every such read goes through the model's default scopes, as Active Record's
do: a soft-deleted record (`default_scope { where(deleted_at: nil) }`, as
paranoia, discard and Solidus use) is not found, counted or returned by an
association, and a default `order` orders the results (a later `order` adds
to it; `reorder` replaces it; `first` and `last` follow it). An association
reads through the target's default scopes less what its own scope unscopes
(`belongs_to :variant, -> { with_discarded }`). `Model.unscoped` returns every
record of the model from the event store, and inside `Model.unscoped { ... }`
reads leave the default scope out (`reload` uses this). Scopes that unscope
the default (`with_deleted`, `with_discarded`, `unscope(where: :deleted_at)`),
`unscope(:where)`, `unscope(:order)` and `rewhere` work after `where`, `order`
and named scopes, on the model and on an association: the relation keeps how
it was selected and replays it without what is taken off. After a `limit`,
`offset`, `where.not`, `or`, a join or an SQL fragment an unscope or `rewhere`
that would change the answer raises `UnsupportedQuery`, since the records it
would bring back are no longer there. A default scope that cannot be evaluated
(an SQL string, a join, an ordering by an expression) makes every read of
the model raise `UnsupportedQuery`, and `ModeTransition.to!` refuses the switch
into ES-NoProj for it (`force: true` overrides). Active Record's internals
and Lyra's own code that call `Model.unscoped` (association scopes,
uniqueness validation, counter caches) keep Active Record's relation; which
caller is which is told by the calling file (Active Record's, Lyra's, or any
other), passing over a model's own `unscoped` override.

The tables of monitored models get no rows, so a database foreign key from a
table no monitored model writes into one of them would refuse every write
there that sets the column. `ModeTransition.to!` refuses the switch into
ES-NoProj while one exists, naming the referencing table and column, the
referenced table and the constraint (`force: true` overrides); drop the
constraint (`remove_foreign_key :table, name: "..."`) and keep the reference
in the model (`belongs_to` validates it), or monitor the referencing model.
Foreign keys between monitored tables, or from a monitored table into an
unmonitored one, never fire and pass.
`Lyra::Projections::ForeignKeys.blocking(models)` lists them (structs with
`from_table`, `column`, `to_table`, `name` and `referencing_models`). ES-NoProj
set by configuration (`config.projection_mode = :disabled` in an initializer)
passes no switch; at boot `Lyra::ModeTransition.check_es_noproj!` warns
(`Rails.logger.warn`) of each such constraint and each default scope ES-NoProj
cannot evaluate, for the models enrolled by then, and returns the warnings.
The boot goes on.

Collections are `Lyra::Projections::CachedRelation` objects, evaluated in
Ruby:

- `where` with hash conditions (values, arrays, ranges, `nil`, records),
  `where.not`, `where.missing`, `where.associated`, `or`, and SQL fragments made
  only of `"column OP ?"` terms joined all by `AND` or all by `OR` (`OP` one of
  `= != <> < <= > >= LIKE ILIKE`);
- `excluding`/`without` (`where.not` of the records' primary keys; a record or
  relation of another model is Active Record's `ArgumentError`) and
  `in_order_of(column, values, filter: true)` on a column of the model (a
  `where` of the values, which `rewhere` and `unscope` take off, the values
  cast as Active Record casts them, `nil` a position, ordered after any order
  the relation already has); an SQL expression as the column raises
  `UnsupportedQuery`;
- `order`, `reorder`, `reverse_order`, `limit`, `offset`, `page`/`per`,
  `distinct` (removes repeated records). Without an `order`, a `limit` or
  `offset` takes the records in primary-key order. SQL leaves that order to the
  plan, so Monitor's may differ; both are valid answers, and an application
  that pages needs an `order` in either mode;
- `load` (with a block: each record), `loaded?`, `records`, `reset` and
  `reload` (read again from the event store, as a relation built at that
  moment; a relation that cannot be built again, one of given records,
  raises `UnsupportedQuery`). A loaded relation's `destroy_all` and `update`
  work on its loaded records (`destroy_all` then resets it), its
  `update_all`, `delete_all` and `touch_all` select at write time, and a bang
  query method raises `ActiveRecord::UnmodifiableRelation`, as in Active
  Record. A relation that is not loaded is read when it is first used (from
  1.0.1): one built before a write sees it, as Active Record's query run at
  that point does. A right placed after `load` (an erasure, a restriction)
  applies to the loaded records when they are next read: ES-NoProj raises where
  Monitor serves the records it already holds, which is the stricter of the two;
- `joins`, `left_joins`, `left_outer_joins` on direct associations, evaluated
  in memory: an inner join drops records without a partner, a has_many join
  repeats the record per partner as SQL does;
- `count`, `sum`, `average`, `minimum`, `maximum`, `group` with grouped
  calculations, `pluck`, `pick`, `ids`, `find_each`, `find_in_batches`,
  `in_batches` (each batch read from the event store when the loop reaches
  it, a limit and an offset included: the batches stop after the limit's
  records, and the offset skips records in every batch's query, as Active
  Record applies it; `in_batches` of a relation with an offset and no order
  raises `UnsupportedQuery` (Active Record's batch query has the `OFFSET` and
  no `ORDER BY`, so the records it skips are the database plan's), as do the
  queries of its `load: true` batches and `use_ranges: true` with an offset;
  `find_each` and `find_in_batches` answer; a batch that holds its records
  (`load: true`, or a batch of a loaded relation) runs its query methods,
  aggregates, finders and `update_all`/`delete_all`/`touch_all` as its
  query's, as in Active Record; a loaded relation's batches are its loaded
  records, as Active Record's);
- scopes whose relation reduces to hash conditions, order and limit; a
  model's other class methods run with the relation as the current scope;
- `merge`/`merge!` with a relation of the same model, `where!` with hash
  conditions, `rewhere`, `unscope`, `create_with`;
- `update_all`, `delete_all`, `destroy_all`, `touch_all`, `delete_by`, `destroy_by` (recorded as events);
- `update`, `update!` and `update_counters` on the selected records,
  `first_or_initialize`, `first_or_create(!)`, `find_or_create_by(!)`,
  `sole`, `find_sole_by`,
  `create_or_find_by(!)` with the relation's conditions (`create_or_find_by`
  finds the record a unique index of the table would conflict with, as
  Active Record finds it on the violation);
- `lock`, `annotate`, `optimizer_hints`, `strict_loading`: accepted, no
  effect.

Anything it cannot answer exactly raises
`Lyra::Projections::UnsupportedQuery`: other SQL fragments, string, nested,
`:through`, polymorphic or scoped joins, a condition on a table not joined,
conditions nested more than one level, and scopes it cannot reduce. Use ES-Lazy
or a projected mode for such queries.

A `has_many` association's `dependent: :delete_all` or `:nullify` (on the
parent's destroy, `delete_all`, `delete(record)` or assigning a new set) writes
an event for each child the association selects: the owner's records, narrowed
by the child's default scopes (less what the association's scope unscopes) and
the association's scope. If one of those scopes cannot be evaluated against the
event store (an SQL string scope such as `-> { where("status = 'x'") }`), the
write raises `UnsupportedQuery` and the parent's destroy is refused, rather
than delete or nullify children the association might not select. Counter
caches are not maintained in ES-NoProj; such a write leaves the owner's
counter as the log holds it.

Rails' uniqueness validation (`validates :x, uniqueness: ...`) keeps the
relation Rails builds for it (`Model.unscoped`, the value compared as the
connection compares it, `scope:`, `conditions:`, and on update the record
itself left out by its primary key), and its `exists?` is answered from the
event-sourced records (`Lyra::Projections::Uniqueness`): a soft-delete default
scope is not applied, as in Rails, and under STI the type condition is that of
the class that declared the validation. Its where clause is evaluated as the
database evaluates it: equality, `IS NULL`, `IN`, `NOT IN`, ranges, `where.not`,
`or` and named scopes made of those, each value bound through the attribute's
type (a hash condition's list leaves out the values the type binds as NULL, as
Active Record's `IN` does; a `character(n)` value compares without its trailing
spaces; a serialized attribute compares as the text it is stored as);
`case_sensitive: false` (`LOWER(column) = LOWER(value)`) and a `citext`
column's equality by the database's own `LOWER`, applied to the values the
records hold (texts lowered once are remembered per database in the process,
so a check sends only new ones, in one query). An SQL fragment or a subquery in
`conditions:`, a join, `LIKE`, a comparison with another column, a string
column with a collation of its own, or a string comparison on an adapter other
than PostgreSQL or SQLite raises `UnsupportedQuery`.

Cost: each check reads the last event of every stream of the model (one query,
which grows with the model's events) and tests every record in Ruby; the
records are kept, stamped as the projection cache's entries are, in a
per-process copy, so only the streams written since the last check are read
from the cache or rebuilt. On the development VM a check of the testbed's
`BankPayment#remittance_info` took 1.6 ms at 331 records and 4.7 ms at 1,531
(24 ms when every record was read from the cache); in the test suite's
environment, at 3,000 records, 24 ms (41 ms under `case_sensitive: false`)
against 94 ms. A model's bulk creates in ES-NoProj therefore cost time that
grows with the records already there (quadratic in total). Each check answers
from the copy's entries as it read them, so another thread's uncommitted
record is never used. The copies of all models are kept under 32 MB (beside
the projection cache's own 32 MB), the least recently used dropped first; a
model with more than 20,000 streams is read through the projection cache
instead; a copy expires after an hour, as the cache's memory entries do, and
is rebuilt when its model's columns change (`reset_column_information`).

Race: on PostgreSQL, inside a transaction (`save`, `create`, `update`), a
check that claims a value (a new record, a changed attribute or scope column,
or any check with `conditions:`) first takes a transaction-level advisory lock
on the model, attribute and value as the column holds it (under
`case_sensitive: false` or on a `citext` column, on `LOWER(value)` as the
database computes it), so that a second writer of the value waits for the
first's commit and then finds its record: the table modes have the unique index
for that race, ES-NoProj has no row for an index to refuse. A save that keeps
its value takes no lock, though the check still runs. The key leaves `scope:`
and `conditions:` out and is hashed to 32 bits, so it is coarser than a unique
index on the scoped columns: two writers of one value in two scopes wait for
each other. Not covered: `valid?` and then `save(validate: false)`; a
REPEATABLE READ or SERIALIZABLE transaction whose snapshot predates the other
writer's commit; adapters other than PostgreSQL. Two transactions that each
claim the same two values in opposite orders deadlock, as inserting them into a
unique index does, and PostgreSQL fails one of them (`ActiveRecord::Deadlocked`).

Unique indexes (`Lyra::Projections::UniqueIndexes`). The table's unique
indexes are enforced on the writes that record one record's change: `create`,
`save` and `update` through callbacks, `update_columns`, `update_column` and
`update_all` (which `update_counters` reaches); `insert_all` and `insert_all!`
check the same indexes (above). A value a live record holds raises
`ActiveRecord::RecordNotUnique`, with PostgreSQL's message (`duplicate key value
violates unique constraint "<index>"`, `Key (<columns>)=(<values>) already
exists`), where the table modes' `INSERT` or `UPDATE` raises it: after the
`before_*` callbacks, before the event is built, so no `after_*` callback runs
and nothing is appended; `update_columns` after the destroyed-record check, as
its `UPDATE` would reach no row of a destroyed record; `update_all` before any
of its events, two of its records given one value conflicting with each other.

The same check runs in ES-Sync, ES-Async and ES-Lazy, which append the event
before their projection writes the row: a duplicate there appended its event
and the projection's `INSERT` or `UPDATE` then failed, logged (with
`strict_projections` off), and ES-Lazy's next catch-up failed on it for every
model's reads. Now it raises `ActiveRecord::RecordNotUnique` (the message names
the mode) with no event, no projection job, no row. ES-Sync looks the value up
in its table under the value's lock (its projection writes the row in the
writer's transaction); ES-Async and ES-Lazy, whose tables lag, in the value
streams, which are linked in these two modes as well (the foreign-key links
are not). `update_columns`, `update_column`, `update_all`, `insert_all`,
`insert_all!` and `upsert_all` take the values' locks in all three, and in
ES-Async and ES-Lazy are checked against the value streams before their table
write (a holder not yet projected; `upsert_all` raises for a conflict on an
index other than its conflict columns, and updates the holder on them). A
holder destroyed or moved away whose row is still in the table holds no value;
ES-Async brings such a row up to date in the write's transaction where that
waits for no lock. A write that sets no column of a checked index costs
nothing more. In ES-Sync a write inside `ReadYourWrites.with_guaranteed_read`
writes its row at once, as outside the block (it was deferred to the block's
end, which hid its value from the check). A projected create that meets
another record's value raises instead of inserting nothing (both errors are
`ActiveRecord::RecordNotUnique`s): `Lyra::Projections::ProjectionBehind` when
that record's stream gave the value up and only its row lags, and the row is
held by another transaction (an ES-Async job first brings such rows up to date
itself, where nothing holds them, so a holder whose own job was lost does not
block it, and inserts again): the job retries it at most every five minutes,
for about a day (`AsyncProjectionJob::BEHIND_ATTEMPTS`, 300), then reports it
(log, `projection_error_handler`) and gives up, leaving the record to a
rebuild; `Lyra::Projections::DuplicateInLog` when a live record holds the
value in the log too (a duplicate the log already has), a row with no stream
holds it, or no holder is found (an expression index, which Lyra does not
read): logged once per record and process (up to 10,000 remembered) and passed
to `projection_error_handler`, and the job discarded. A tuple with a NULL
holds nothing unless its index is `NULLS NOT DISTINCT`.
ES-Sync's write fails with either; ES-Lazy's catch-up logs it (once) and goes on. In ES-Sync a database error in the
projection fails the write whatever `strict_projections` says (PostgreSQL has
aborted the transaction). Not covered, in any event-sourcing mode:
transactions at `REPEATABLE READ` or `SERIALIZABLE`, whose snapshot misses a
value committed after they began (as for a uniqueness validation). ES-Sync's
write then fails at its projection, as Monitor's would; ES-Async and ES-Lazy
save both records, and the second's projection fails with `DuplicateInLog`
(logged once; the job discarded, the catch-up going on).

Which: the indexes that are unique, on columns, not partial, other than the
primary key, and on no column with a nondeterministic collation (an ICU
collation with `deterministic = false`: its equality is the database's alone,
and a uniqueness validation refuses such a column too). A partial, expression
or nondeterministic index is not enforced in ES-NoProj. They are read from the
database once per model and process, again after `reset_column_information`,
and every `config.unique_index_refresh` seconds (60; `nil`: never), so an index
a migration adds is enforced in a process that started before it. An index is
checked when the write sets one of its columns (an update, a column it
changes); the columns it does not write are taken from the record's stream,
read under its aggregate lock, so a copy read before another writer changed
them claims the tuple the row would hold. NULL conflicts with nothing unless
the index is `NULLS NOT DISTINCT`; a value is compared as the column holds it
(`"250"` and `250.00` on a decimal are one value), a `citext` column's by
`LOWER` as the database computes it (as `citext` compares); a destroyed record
holds no value, and a record keeps its own. A uniqueness validation still runs
first, and answers as before.

Locks: each claimed value takes the advisory lock a uniqueness validation of
the index's first column takes (`insert_all` takes it too), so a second writer
of the value waits for the first's commit and then raises. An update,
`update_columns` and `update_all` take it after the records' aggregate locks,
as Monitor's `UPDATE` takes the row and then the index entry: writers of one
record, or of two records and one value, wait for each other where Monitor's
do and do not deadlock where Monitor's do not. An update of a model with a
uniqueness validation takes the record's aggregate lock before its
validations (the same lock, taken once, earlier), so the validation's value
lock comes after it as well; a create has no record to lock. The key holds a
keyed digest of the value, never the value: lock statements reach the
database's log, and the `LOWER` a `citext` value is compared by is asked for
with the value bound (named after its column, so the statement log filters it
where the application filters that column).

The links are caught up without waiting: a write that finds another thread or
process linking the model, or no connection free in the pool and the links'
lock taken, checks against every record of the model instead (as a uniqueness
validation does), once; a thread that caught up in its own transaction takes
the model for linked until that transaction ends. So a model's first use with
every connection of the pool taken by its writers (Puma's default: five
threads, a pool of five) finishes. The digest key: `config.value_digest_key`,
else one derived from `secret_key_base` (the same in every process of an
application); without either, every environment but development and test (staging and
preview included) raises `Lyra::Projections::ValueDigest::KeyMissing` at first
use, and development and test use a fixed key with a warning. Applications that share an event
store set `config.value_digest_key` to one value. The unique indexes ES-NoProj
does not enforce (partial, expression, nondeterministic collation) are named
in the log once per model.

Lookup: each event that sets an indexed column is linked into
`"Model!column$<digest>"` (`ReferenceLinks`), and a check rebuilds only the
records whose events are in its value's stream, so its cost is that of the
value's history, not the model's size. The digest is an HMAC-SHA256 under
`config.value_digest_key` (by default a key derived from the application's
`secret_key_base`; `Lyra::Projections::ValueDigest`), so neither the stream
table nor the lock keys hold a value, nor a hash a dictionary reverses.
Changing the key relinks a column's value streams on its next use (the old
links deleted); every process of an installation must use one key, or their
locks miss each other. An erasure (`Lyra::Erasure`) moves the links of the
events it rewrites with them: the link of an erased value is deleted, its
replacement's added. A create of a fresh value costs three round trips (the
lock, the stream read, the link's `INSERT`); a write that sets no indexed
column, and a model without such an index, cost nothing. With
`config.reference_links = false`, or for a `NULLS NOT DISTINCT` tuple that is
all NULL, every record of the model is read instead (as a uniqueness
validation reads them).

Coverage: each column's links have a checkpoint of their own. Before the first
check of a model in a process (and before its value locks), the events after
each column's checkpoint are linked, in one read; a column new to the process
(an index added) is linked from the first event, and the foreign keys are not
read again. A process of this release that reads a new index (on a refresh)
links its own earlier writes itself, before its next write of the model;
until then, and while processes of an earlier Lyra still write, their writes
lack the column's links and a check elsewhere may miss them. After such a
rolling deploy, once they are gone, run `bin/rails lyra:link_values`
(`ReferenceLinks.relink_values!`: every value linked again from the first
event). ES-Sync, ES-Async and ES-Lazy check the same indexes before their
event (see "The same check runs in ES-Sync, ES-Async and ES-Lazy" above).

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
| `LazyProjection.catch_up!(force: false)` | Apply every pending event now. Returns the number applied. Outside ES-Lazy it returns 0 unless `force: true` (as `ModeTransition.to!` passes when leaving ES-Lazy). |
| `LazyProjection.checkpoint` | `[position, { gap_id => first_seen_epoch }]`. |
| `LazyProjection.reset!` | Forget the checkpoint (after truncating or rebuilding tables). |
| `LazyProjection.active?` | Whether ES-Lazy is the current configuration. |

A transaction open longer than `LazyProjection::GAP_TTL` (300 s) can have its
events skipped.

### Rebuild

```ruby
Lyra::Projections::Rebuild.rebuild(Registration)               # => { model:, streams:, events:, records:, destroyed: }
Lyra::Projections::Rebuild.rebuild(Order, truncate: false)     # in place
Lyra::Projections::Rebuild.rebuild(Order, force: true)         # clear even where rows would be lost
Lyra::Projections::Rebuild.rebuild_all                         # all monitored models
Lyra::Projections::Rebuild.replay_record(Order, 42)            # one record; returns events replayed
Lyra::Projections::Rebuild.clear_hazards(Order)                # => { references:, streamless:, streamless_ids: }
```

`rebuild` clears the table (unless `truncate: false`) and replays every stream
through the same projection code as live projection, in one transaction.
Clearing deletes every row, and the database applies each foreign key's
`ON DELETE` action to the rows that reference them. From 1.0.1 `rebuild`
refuses to clear a table (`Rebuild::Refused`, before anything is written)
while that would lose what the log cannot restore, and names it
(`clear_hazards`):

- rows of another table that reference it through a foreign key that is
  `ON DELETE CASCADE`, `SET NULL` or `SET DEFAULT` (from PostgreSQL's catalog),
  whether that table is monitored or not: a rebuild restores one model's table
  only. A key whose table has no row referencing a row does not count, nor one
  from the table into itself, nor the model's own HABTM join tables (restored
  from their link events);
- rows of the table itself with no event stream (not yet imported: run
  `Lyra::Genesis.import_all(Model)` or `rake lyra:genesis` first). A row whose
  stream ends in a destroy is deleted, as the log says.

Back up the database first. Then either rebuild in place (`truncate: false`),
which deletes only the rows whose records the log destroys but leaves a column
changed outside Lyra that no later event sets (`ModeTransition.discrepancy`
finds it), or clear the table anyway (`force: true`). `rebuild_all` passes
`truncate:` and `force:` to each model's rebuild, one transaction per model.

### Custom projections

`Lyra::Projection` subclasses handle events with `apply_<event_name>` methods.
`handle(event)` takes the name from `event.event_type`, demodulized and
underscored (`Lyra::Events::PostCreated` → `apply_post_created`), so an event
read back as a plain `RubyEventStore::Event` still reaches its handler.
`subscribe_to(*event_types)` subscribes the class to the event store and
returns RubyEventStore's unsubscribe procs; the class is the subscriber, and
its `call(event)` passes each event to a new instance's `handle`.
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
# => { crud_view: {...}, event_sourced_view: {...}, differences: {}, metadata: {...} }
```

| Method | Description |
|---|---|
| `compare` | Both views and the differences (`{}` when they agree, `{ exists: { crud:, event_sourced: } }` when only one has the record, or `{ "attr" => { crud:, event_sourced: } }`, keyed by column name as a string). A destroyed record whose row is gone compares clean; one whose row remains is an `exists` difference. `created_at`/`updated_at` are compared like any other column, except that with `config.record_touches = false` a difference confined to the update timestamps counts as agreement ([Touches](#touches)); times compare at microseconds. |
| `crud_state` | `{ exists:, attributes:, timestamps: }`. The row is read as the caller reads it: under `reads_without_purpose :deny` it needs a purpose that allows the declared fields (from 1.0.0; before, it read as Lyra). `compare` and `compare_all` read it the same way; Lyra's mode gate, sampler and repair read as Lyra; the dashboard reads under its request's purpose (`dashboard_purpose`). |
| `event_sourced_state` | `{ exists:, destroyed:, state:, events_count:, first_event_at:, last_event_at:, events_summary: }`; `destroyed: true` (and `exists: false`) when the last replayed event is a destroy, `state` keeping the last known attributes. A stream of only `replay: false` events has `exists: false`. |
| `audit_trail` | `AuditProjection.audit_trail` for the record. |
| `DualView.compare_all(model)` | `compare` for every existing row. |
| `DualView.find_discrepancies(model)` | Those with differences. |

`Lyra::StateAnalyzer.analyze(model, id)` adds the audit trail and plain-text
recommendations.

**Normalisation.** Attribute names match whether they are strings or symbols. Before two values
are compared, times (and strings that look like timestamps) become UTC at microsecond resolution,
that of a PostgreSQL timestamp; numbers become floats rounded to six decimal places, so an integer
equals the same float and a numeric string the number. Nothing else is equated: `nil` and the empty
string differ, and so do values of other types whose string forms differ. A difference is never
graded by severity: every one counts as a discrepancy. The mode-transition gate and the sampler
report the names of the first five differing fields, never their values.

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
gem is loaded. Set `LYRA_DISABLE_PETRI_FLOW=true` to run as without it.
Without petri_flow the engine neither autoloads nor eager-loads its
`app/workflows`, so production boot and the `lyra` rake tasks that eager-load
the application work without the gem.

---

## Privacy

Lyra's privacy layer talks to a provider through `Lyra::Privacy`. PAM
(`gems/pam_dsl`) is the provider when the gem is loaded; without it a null
provider declares nothing and allows everything. `Lyra.pam_dsl_available?` and
`Lyra.privacy_features_available?` report which is in use. Set
`LYRA_DISABLE_PAM_DSL=true` to run without PAM.

### Encrypted attributes (Active Record Encryption)

An attribute declared with `encrypts` reaches the event log as ciphertext, as
it reaches the row: every event passes through `Lyra.append_events`, which
replaces the attribute's values (in `attributes` and in `changes`) with what
Active Record writes to the column (`Lyra::EncryptedAttributes`). Projections,
rebuilds and DualView decrypt them; records instantiated from events (ES-NoProj
reads, `as_of`) are decrypted by Active Record itself. Events written before
0.9.0 hold such values in clear; they are still read, and the rows written from
them are encrypted. The log is then protected by the application's encryption
keys, as the table is; erasure treats the ciphertext as opaque.

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
`payment_token`, and from 1.0.0 the other Art. 9(1) special categories
(`genetic`, `racial_ethnic_origin`, `political_opinion`, `religious_belief`,
`trade_union_membership`, `sex_life_orientation`) and Art. 10 data
(`criminal_offence`), from names that say what the column holds. Sensitive:
`ssn`, `credit_card`, `financial`, `health`, `biometric`, `identifier`,
`credential`, `token`, `payment_token`, the special categories and
`criminal_offence`. Set
`PamDsl::PIIDetector.partial_match = false` for exact name matching
(`PamDsl::PIIDetector.reset!` restores the default).

With PAM, `Lyra::Privacy::PIIMasker.mask(attributes, strategy: :partial)`
(`:partial`, `:full`, `:redact_sensitive`) and `mask_field(value, field_name)`
mask attribute hashes; `mask_events(events, strategy: :partial)` returns masked
copies of events (same class, id and metadata; attributes and the old and new
values in `changes` masked).

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

- A query uses every declared attribute it names (from 1.0.0): `select`,
  `pluck` and `pick` columns, the aggregated column, `group`, `where`,
  `having`, `order`, the conditions of `find_by`/`find_by!` (class-level too)
  and `exists?`, the filter of `update_all`, `delete_all`, `touch_all`,
  `delete_by` and `destroy_by`, and subqueries. `count`, `count(:all)` and
  `size` name nothing; `count(:f)` uses `f`.
- Record loads are checked before the query with PAM's `validate_fields!`
  (no consent step), then per record returned with `validate_access!`
  (consent included), for the attributes the record holds and those the
  query named.
- Aggregates (`count`, `sum`, `average`, `minimum`, `maximum`, their
  `async_` forms, grouped calculations), `exists?` (and `any?`, `empty?`,
  `none?`), `ids`, `pluck`, `pick` and the bulk writes are checked with
  `validate_access!` and subject `"Model$*"`: refused under a purpose whose
  basis is consent.
- A joined monitored model's declared attributes are checked against its own
  policy, subject `"Other$*"`.
- `find_each`, `find_in_batches` and `in_batches` check and record a query
  once, not once per batch.
- A violation follows the policy's enforcement mode: strict raises the PAM
  error before the query runs, audit logs it and lets the query run.
- `config.reads_without_purpose`: `:allow` (default; the hooks return before
  looking at the query), `:audit` (logged, and recorded when the access log
  is on), `:deny` (raises `Lyra::PurposeBoundReads::PurposeRequiredError`).
- Not checked: Lyra's own reads, Rails' uniqueness validation and an
  association's `dependent:` handling on destroy (part of the write; for
  `:destroy`, the lookup of the dependents; `find_or_create_by` and the
  application's own deletes by the same key are checked), Disabled mode, and SQL sent through
  the connection. An SQL fragment is matched by the queried model's declared
  names only; string joins, views, functions, triggers, custom Arel nodes and
  CTEs are not seen ([PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#purpose-bound-reads)).

Subqueries and CTEs are checked whole (`"Model$*"`), a `table.column` in a
fragment is that table's model's, a column a joined model has is that model's,
`update_all`'s SET expressions and `insert_all`/`upsert_all`'s `returning:`
columns are reads, and `cache_version` is an aggregate. The purpose is kept in
fiber storage tied to its thread (Enumerator fibers have it; new threads do
not).

`Lyra::PurposeBoundReads.current` returns the purpose in scope;
`Lyra::PurposeBoundReads.internal?` whether Lyra's own reads are in progress;
`Lyra::PurposeBoundReads.named_fields_of(relation)` returns the attribute
names a relation's query names, by model (`{ Registration => ["email"] }`).

### Access log (opt-in, needs pam_dsl)

With `config.record_access_events = true`, `Lyra::AccessLog` records every
`validate_access!` call as `Lyra::Events::DataAccessed` (outcome `granted` or
`audited`) or `Lyra::Events::DataAccessDenied`, in the subject's stream
`"Lyra::DataAccess$<subject>"`. The data holds the policy, purpose, legal
basis, field names, subject, outcome, time and violations; the metadata holds
`user_id` (`Current.user`), `ip_address`, `request_id`, correlation and
causation ids, and `config.access_metadata_proc`'s hash. An access that cannot
be recorded does not go ahead. Nothing is recorded in Disabled mode. From 1.0.0
an access inside a transaction is recorded on a second connection, so it
survives a rollback; size the pool at about twice the threads, or a read waits
`checkout_timeout` for a connection and is then recorded inline (see
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#the-access-log)).

**Reads made by another gem inside a write.** A gem's callback that loads a
record runs under the purpose the application declared, like any other read, so
it is checked and recorded. With PaperTrail's version limit in Monitor, for
example, a destroy runs `enforce_version_limit!`, which loads the whole record
(`version.item`). Under a purpose that does not cover every field of that model,
the load is refused and recorded as `DataAccessDenied`, once per destroy, while
the destroy itself goes ahead: the gem's own step continues without that data,
and the application's write is unaffected. Such an entry is a truthful record of
a refused read, not of a refused operation; its `request_id` and correlation tie
it to the write that caused it. An application that does not want it can avoid
the read (for PaperTrail, run without a version limit) or declare a purpose
that covers the model for the code path that destroys. Hijack and event
sourcing retire PaperTrail for monitored models, so there is no such read.

```ruby
config.record_access_events = true
config.access_metadata_proc = ->(access) { { api_token: Current.api_token&.id } }

Lyra::AccessLog.for(registration)   # its recorded accesses, oldest first
```

### Data subject rights and consent (needs pam_dsl)

From 1.0.0, when PAM DSL is loaded, Lyra installs `Lyra::Rights` into it: a
durable `PamDsl.rights_store` for restrictions and objections (Arts. 18 and
21, recorded through `PamDsl.rights`), a durable `PamDsl.consent_store` that
every policy's `consent_policy` uses, and `PamDsl.subject_key_resolver`.

| Part | What it does |
|---|---|
| `Lyra::Rights::Store` | The rights store protocol (`append(events, expected_version:)`, `events_for(key)`, `subject_key_for(id)`, `active`, `active_for(keys)`, `any_active?`, `durable?` true). Events in `"Lyra::Rights$<subject key>"`, linked to `"Lyra::Rights"`; the table `lyra_rights` (one row per restriction or objection) written in the same transaction. An append is folded with the subject's events first, so one that does not replay stores nothing; a stale `expected_version` raises `PamDsl::RightsConcurrencyError`. Checks answer from a per-process snapshot of committed requests in force; a transaction that recorded a right reads its own keys afresh. |
| `Lyra::Rights::ConsentStore` | `request`, `grant`, `withdraw`, `record_for`, `granted?`, `consents_for(key)`, `durable?` true. Events `ConsentRequested`, `ConsentGranted`, `ConsentWithdrawn` in `"Lyra::Consent$<subject key>"`, linked to `"Lyra::Consent"`; the table `lyra_consents` (one row per subject key and purpose). A record naming one person uses that person's consent; one naming several raises `Lyra::Rights::ConsentStore::SharedRecordConsentError` (a `PamDsl::ConsentRequiredError`) in 1.0.0. A grant repeating the granted record's times records nothing. |
| `Lyra::Rights::SubjectKeys` | A record's keys: its own (`"Invoice$12"`) and those of the people it names, by the selection rule of `Lyra::Privacy::SubjectLinks` (a `belongs_to`'s class, a polymorphic one's type column, or a `<type>_id` column no association owns, for the monitored model of that name). Link columns a record was loaded without are read from its row; when they cannot be, `Lyra::Rights::UnresolvedSubjectError`. Other subjects: PAM DSL's default. |
| `Lyra::Rights.install!(only_unset: false)` | Install the stores and the resolver; the engine calls it at boot with `only_unset: true`, keeping any the application installed in an initializer. |
| `Lyra::Rights.refresh!` | Forget the snapshot of requests in force and the remembered consent lookups; the next check reads the tables. |
| `Lyra::Rights.scope { ... }` | A checking scope: the first check inside reads the rights and consent afresh, whatever `rights_refresh_interval` says. `Lyra.with_purpose`, `Lyra::Rights::Middleware` (each web request; the engine installs it), `Lyra::Rights::Job` (each Active Job) and each batch of `in_batches`/`find_each`/`find_in_batches` open one. Costs a clock read; nothing is read unless a check is made. |
| `Model.lyra_processable(fields: nil)` | A scope without the records the purpose in scope may not process (a restriction or objection covering them): for batch jobs, which would otherwise stop at the first restricted record. `fields:` the declared fields the job reads (default: every declared field). Every record with no purpose in scope. Active Record and ES-NoProj. |
| `Lyra::Rights::Queries` | Model-wide queries under a purpose (aggregates, `pluck`, `pick`, `ids`, `exists?`, `cache_version`) leave out the subjects a right in force covers (own key column `NOT IN`, link columns `IS NULL OR NOT IN`); a join, subquery or CTE reaching such a subject raises `PamDsl::RestrictedProcessingError`. Nothing is left out in audit mode (logged). |
| `Lyra::Rights::ErasureGuard` | Asked by `Lyra::Erasure.erase!` at its entry: a restricted record is refused (`PamDsl::RestrictedProcessingError`) unless `lifting:` names its restrictions, each with the Art. 18(3) notice recorded (else `PamDsl::RightsTransitionError`); they are lifted and the record erased in one transaction. |
| `Lyra::Rights.rebuild!` | Rebuild both tables from the index streams (`bin/rails lyra:rights:rebuild`). Returns `[requests, consents]`. |

```ruby
r = PamDsl.rights.restrict!(subject: "Payer$7", ground: :accuracy_contested)   # durable, every process
Lyra.with_purpose(:invoicing) { Invoice.find(12) }   # payer_id 7: PamDsl::RestrictedProcessingError
PamDsl.policy(:shop).consent_policy.grant_consent(purpose: :newsletter, subject: payer)  # seen by every policy
```

The streams are never erased: not by `Lyra::Erasure.erase!`, nor by
`Lyra::AccessLog.erase!`. Lyra's read checks apply Condition 6 to each record
they check under a purpose (also to a record loaded by undeclared columns,
for a restriction of all of the subject's data or an objection), leave
restricted subjects out of model-wide queries, and refuse a join or subquery
that reaches one; `Lyra::Erasure.erase!` refuses a restricted record unless
it lifts a notified restriction (`lifting:`), and `Lyra::Retention` skips
restricted records (outcome `:restricted`). Writes are not checked under a
restriction in 1.0.0. See
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#restriction-of-processing-article-18-and-the-right-to-object-article-21).

```ruby
Lyra.with_purpose(:invoicing) { Invoice.count }                           # payer 7's invoices left out
Lyra.with_purpose(:invoicing) { Invoice.lyra_processable.find_each { … } } # skips them
PamDsl.rights.notify_lift!(r.id)
Lyra::Erasure.erase!(Payer, 7, reason: "Art. 17", lifting: r.id)          # lifts and erases, one transaction
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
| `everywhere:` | Also search for the erased values of direct identifiers (email, phone, identifier, ssn, credit_card, financial, payment_token, ip_address, credential, token) in other records: the whole log, and from 1.0.0 the tables of monitored models with a policy (not in ES-NoProj), so a row whose events lack the value is found too. Only the person's own values are searched for (from 1.0.0: not a third party's value nested under a personal key in the person's data). Other records' events are scrubbed and their rows updated; a row with no stream is erased and then imported (Genesis). Lyra's own record streams (rights, consent, access logs, exports) are not rewritten. Only the values of the record's own fields (its row, its own CRUD events) are searched for. Uses PostgreSQL-specific SQL. |
| `max_copies:` | With `everywhere`, a value held by more than this many other records, counted by record through events and rows, is treated as shared, left and reported in `shared`. The person's linked records (by the subject-access copy's rule, `Lyra::Privacy::SubjectLinks`: a `belongs_to` to the erased record's model naming it, by id or by its `primary_key:` column, a polymorphic one, a `<model>_id` column) are not counted, for the threshold only. Default `config.erasure_max_copies` (10); else a positive Integer, or `ArgumentError` before anything is written. |
| `dry_run:` | `true` runs the erasure in a transaction (a savepoint inside a caller's) and rolls it back: the `Result` says what it would do, `dry_run: true`, and nothing is written. Use it to choose `max_copies` before an erasure with `everywhere`: once the person's values are erased, a later run cannot find the copies left as shared. From 1.0.0. |
| `access_log:` | `true` deletes the record's access log (`Lyra::DataAccess$<Model>$<id>`), its events too; `false` keeps it; default `config.erase_access_log` (false), applied only when the erasure completes the record. From 1.0.0. |
| `access_log_subjects:` | Ids the application used as this person's subject (`validate_access!(…, subject: "user-7")`): their logs are erased, or kept and counted, with the record's. A model-wide key (`Model$*`) raises `Lyra::AccessLog::ModelWideSubject`. From 1.0.0. |
| `lifting:` | With PAM DSL's rights (from 1.0.0): the id (or ids) of the restrictions of processing (Art. 18) that cover the record, each with its Art. 18(3) notice recorded; they are lifted (reason `:erased`) and the record erased in one transaction. Without it, a record that a restriction in force covers (its own, a person's it names, one under `access_log_subjects:`; of all the data or of a field being erased) is refused with `PamDsl::RestrictedProcessingError`. An objection's 18(1)(d) restriction does not refuse an erasure. A dry run is refused the same way, and with `lifting:` lifts nothing: `Result#lifting` lists the restrictions it would lift (after a real erasure, those it lifted). Only a restriction of the record being erased is lifted this way: a restriction of a person it names is refused here (lift it with `PamDsl.rights.lift!`, or erase that person's own record with `lifting:`). |

`Result` fields: `model`, `id`, `fields`, `events_rewritten`, `row_erased`,
`copies` (records whose copies were erased and whose row no longer holds the
value), `shared_values` (an Integer: the
count of values left as shared, 0 when none), `shared` (from 1.0.0, with
`everywhere`: each value left as shared as `{ field:, type:, holders: }`, the
personal field it was found under, its PAM type and how many other records hold
it, never the value; `[]` otherwise), `rows_without_events` (from 1.0.0, with
`everywhere`: records whose row held an erased value that their events did not
hold whole, erased in the row only, `"Model id"`; run `lyra:repair` for them in
Monitor or Disabled, or rebuild their tables in the other modes; a row with no
stream is imported instead and not listed; `[]` otherwise), `dry_run` (from
1.0.0: whether nothing was written), `left_behind` (from 1.0.0:
records whose row still holds an erased value as a JSON key, inside a longer
string or in a primary or foreign key, as `{ record: "Model id", columns: [...] }`,
never the value: the erased record itself, its replayed state in ES-NoProj, and
with `everywhere` the other records reached; `[]` when none; a record whose key
holds an erased value is `"Model <key withheld>"`), `not_searched` (from 1.0.0,
with `everywhere`: the encrypted columns of monitored models, `"Model.column"`,
which the search of the log cannot read; `[]` otherwise), `key_withheld` (from
1.0.0: the erased record's own key holds an erased value), `access_log` (`"erased"` or
`"kept"`) and `access_log_entries` (how many entries it held), both also
recorded in `ErasureApplied` (with `access_log_subjects`, the number of extra subjects, when any). From 1.0.0, with PAM DSL's rights: `lifting` (the restriction ids lifted, or in a dry run to be lifted) and `restricted_copies` (with `everywhere`: other records holding a copy that a restriction covers, left unmodified, as `{ record:, columns: }`, never the value).
An `ErasureApplied` of another record reached by `everywhere` has `row_only: true` when only its
row held the value, and `imported: true` when the row had no stream and was imported after it
was erased (from 1.0.0).

`Lyra::AccessLog.erase!(subject, reason:, erased_by: nil)` deletes one subject's
access log on its own (a record or a bare id) and returns how many entries it
deleted; it records `Lyra::Events::AccessLogErased` (subject, entries, reason,
`erased_by`, and beside that label the OS user, host and pid) in the stream `Lyra::AccessLogErasures`. Rake: `lyra:erase_access_log
SUBJECT=… REASON=… [OPERATOR=…]`. The replacement is `nil` where the column allows it,
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
`Lyra::Retention::Disabled`. From 1.0.0, a record that a restriction of
processing (Art. 18) covers is skipped, with outcome `:restricted` and the
restrictions in `detail`; `Result#restricted` lists them, and
`lyra:retention:apply` prints them. It is acted on at the first run after the
restriction is lifted.

Only a model with a rule of its own (`for_model`) is acted on; the policy's
`default` period is not executed. `:soft_delete` is also the strategy of a rule
that names none, and on a table with neither `deleted_at` nor `discarded_at` it
can never act. From 1.0.0 Lyra warns about such a rule (`Rails.logger.warn`,
else `Kernel#warn`), naming the model, its policy and rule, and the fix (add the
column, or `on_expiry :anonymize` or `:hard_delete`): at boot for the models
enrolled by then, and in each run that skips records for it, once per model.
`Lyra::Retention.check_rules!(models: Lyra.config.monitored_models)` makes the
boot check on demand and returns the names of the models it warned about.

### GDPR reports (needs pam_dsl)

`Lyra::Privacy::GDPRCompliance.new(subject_id:, subject_type: "User", actor_label: nil, access_log_subjects: nil)` wraps
PAM's report builder over the event store: `data_export`,
`right_to_be_forgotten_report`, `portable_export(format: :json)`,
`rectification_history`, `processing_activities`, `retention_compliance_check`,
`consent_audit`, `full_report`. See [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).
Each model's policy (its `privacy_policy`, else `config.privacy_policy`) reaches
the reports: `processing_activities` takes purpose, legal basis, categories,
recipients and retention from it, and `rectification_history` lists an update
that changed a declared field as well as one the detector flags (from 1.0.0).

`data_export(history: true, accesses: true, disclose_actors: false, verified_by: nil, record: true)`
is the Art. 15 copy. From 1.0.0 it adds five keys to the ones it always returned:

| Key | Content |
|---|---|
| `records` | Each of the subject's records whole: `model`, `id`, `state` (`:current`, `:replayed`, `:destroyed`, `:reassigned`), `as_of`, `attributes` (every column; encrypted ones in plaintext), `withheld` (`[{ field:, basis: }]`, the policy's `withheld_from_access:`, and values set while a moved record was another person's), `review` (fields declared `about:` another person, with value and history), `history_from`, `periods` (when the record moved between people; a moving event gives the subject's side only), `history` (`[{ at:, operation:, field:, from:, to:, by: }]`). |
| `accesses` | The access log's entries for those records and the subject (`at`, `record`, `purpose`, `legal_basis`, `fields`, `outcome`, `by`), within a moved record's periods, plus those under `access_log_subjects:` (default: the bare id) and earlier exports; with `record_access_events` off, the exports only, and a gap. |
| `processing_context` | Per policy and purpose admitting the records' declared fields: `legal_basis`, `legal_basis_label`, `fields`, `data_categories`, `recipients`, `transfers`, `retention` (model and field periods as the policy declares them; `nil` and a gap where it declares none), `sources`. Undeclared recipients or transfers are `nil`, not `[]`. |
| `notice` | The policy's `access_notice`: `controller`, `rights`, `complaint`, `automated_decisions`. |
| `gaps` | `[purpose or nil, item]` for each item the policy does not declare, and for the access log when it is off. |
| `restrictions`, `objections` | With PAM DSL's rights (from 1.0.0): the subject's own requests of Arts. 18 and 21, under the subject's key and the keys of records of theirs that name no one else. A restriction: `id`, `subject`, `ground`, `article`, `fields`, `state`, `requested_at`, `lift_notified_at`, `lifted_at`, `lift_reason`. An objection: `id`, `subject`, `policy`, `purpose`, `article`, `state`, `grounds` (the subject's), `requested_at`, `decided_at`, `decision_grounds`, `reason`, `notified_at`, `withdrawn_at`. Who on the staff recorded them is left out. |

`by` is a role label (`"you"` when the event records the subject's id and
class, `"staff or you"` for the subject's id with no class, `"staff"`,
`"system"`); from 1.0.0 events record the acting user's class as `user_type`
beside `user_id`. The older keys of `data_export` follow the copy's rules
(withheld and other people's fields left out, encrypted values opened).
The per-event `processing_activities` key, whose purposes were guessed from
keywords, is gone from 1.0.0: the copy's purposes are `processing_context`.
`disclose_actors: true`
adds `actor: { user_id:, ip_address: }`. `history: false` and `accesses: false`
are for a request the subject narrowed. Each explicit export is recorded as
`Lyra::Events::SubjectAccessExported` in its own stream
`Lyra::SubjectAccessExports$<Type>$<id>` (sections, record count, `verified_by`,
never values; `Lyra::AccessLog.record_export`, read with `AccessLog.exports_for`),
which erasing the access log leaves, unless `config.record_subject_access_exports`
is false. `data_export(record: false)` records nothing: `full_report` and the
dashboard's subject and GDPR routes use it, as views rather than answered requests.

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
  `identifier`, `online_identifier`, `credential`, `token`, `payment_token`,
  `custom`, the other Art. 9(1) special categories `genetic`,
  `racial_ethnic_origin`, `political_opinion`, `religious_belief` (religious or
  philosophical beliefs), `trade_union_membership`, `sex_life_orientation`, and
  the Art. 10 type `criminal_offence` (the detector reports login-name
  columns as `identifier`; declare `online_identifier` yourself where it
  fits). Sensitivity:
  `public`, `internal` (default), `confidential`, `restricted`.
- `basis`: `contract`, `legal_obligation`, `consent`, `vital_interests`,
  `public_task`, `legitimate_interests`; with none declared (or `undetermined`)
  access is refused and the register lists the purpose as a gap. Special-category
  fields (`health`, `biometric`, `genetic`, `racial_ethnic_origin`,
  `political_opinion`, `religious_belief`, `trade_union_membership`,
  `sex_life_orientation`) also need `art9_basis`; `criminal_offence` fields need
  `art10_authorisation "<the official authority or the law that authorises it>"`
  instead (`CriminalDataViolationError` without it; an Art. 9(2) basis does not
  satisfy Art. 10, nor an Art. 10 authorisation Art. 9).
- Arts. 18 and 21 (from 1.0.0): `allowed_when_restricted :legal_claims` (also
  `:consent`, `:protection_of_rights`, `:important_public_interest, reference:
  "<the law>"`) lets a purpose continue while a subject's processing is
  restricted; `direct_marketing!` and `research_or_statistics!
  public_interest_task: true|false` mark purposes for Art. 21(2) and 21(6);
  `purpose.objectable` gives the article that lets a subject object, or nil
  (Art. 21(1) for `public_task` and `legitimate_interests`, research or not).
- `on_expiry`: `hard_delete`, `soft_delete` (default), `anonymize`, `archive`.
- For the Art. 15 copy (from 1.0.0), a field may declare
  `withheld_from_access: "<the controller's basis>"` (named with that basis
  instead of its value), `about: :payer` (another person's data, for review)
  and `collected_from "the tax registry"` or `collected_from: :data_subject`
  (Art. 15(1)(g)); the policy declares the controller's notice once:
  `access_notice controller: "...", rights: "...", complaint: "...",
  automated_decisions: "..."`. What is not declared is listed in the copy's `gaps`.

| Call | Description |
|---|---|
| `PamDsl.define_policy(name) { ... }` | Define and register a policy. |
| `PamDsl.policy(name)` | Look one up; raises `PamDsl::PolicyNotFoundError`. |
| `policy.get_field(name)` / `get_purpose(name)` | Raise `InvalidFieldError` / `UndeclaredPurposeError` if undeclared. |
| `policy.allowed?(field, purpose)` | True when the field's `allow_for` names the purpose or the purpose's `requires`/`optionally` names the field: `allow_for` widens, it does not restrict. |
| `policy.validate_access!(field_names, purpose, subject:)` | Def. 1 check: `true`, or raises the first violation (strict) / returns `false` (audit). |
| `policy.retention_for(model_class, field_name: nil)` | Duration, falling back to the default. |
| `policy.consent_policy.grant_consent(purpose:, subject:)` | Record consent at run time (also `withdraw_consent`, `request_consent`). |
| `PamDsl.enforcement_mode = :audit` | Global mode (`:strict` default); `enforcement :audit` inside a policy overrides it. |
| `PamDsl.on_violation { \|v\| ... }` | Called with each audit-mode violation. |
| `PamDsl.rights.restrict!(subject:, ground:, fields: nil)` | Record an Art. 18(1)(a)-(c) restriction (from 1.0.0); then `notify_lift!(id)` (Art. 18(3)) and `lift!(id, reason:)`, which raises `RightsTransitionError` without the notice. |
| `PamDsl.rights.object!(subject:, policy:, purpose:)` | Record an objection: upheld at once for direct marketing, pending (the purpose restricted for that subject, Art. 18(1)(d)) for Art. 21(1) and 21(6), rejected with `ObjectionNotApplicableError` otherwise; returns the objection in force instead of recording a second; then `decide!(id, outcome: :upheld)` or, for Art. 21(1) only, `decide!(id, outcome: :overridden, grounds:, reason:, notified_at:)`, and `withdraw_objection!(id)`. An upheld direct-marketing objection stops every direct-marketing purpose. Times are `Time` (or `DateTime`) and run forwards, else `ArgumentError`. |
| `PamDsl.rights.state(subject)` / `open_requests` | A subject's restrictions and objections with their history; the requests still open, oldest first. |
| `PamDsl.rights_store` | Where rights are kept (`append(events, expected_version:)`, checked with `Rights.project` first; `events_for`, with `Time` values; `subject_key_for`; `active`). PAM DSL ships an in-memory store that refuses to record outside development and test (`RightsStoreNotDurableError`); the durable store is the host's. |
| `PamDsl.on_rights_event { \|e\| ... }` | Called with each recorded rights event (to notify recipients, Art. 19). |

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
| `Lyra::Causation.outside_write_scopes` | The cause in scope outside every write scope: what the access log records. |
| `Lyra::Causation.track(cause_id, effect_id)`, `chain_for(event_id)`, `cause_of(event_id)` | An in-process, in-memory causation map. |
| `Lyra::Causation.integrity(store = Lyra.config.event_store)` | Reads the whole store: `{ events:, caused:, dangling: }`, `dangling` listing each event (`event_id`, `event_type`, `causation_id`) whose cause is not in the store. |
| `Lyra::UserActionContext.with_context(action_type:, user_id: nil, **options) { \|ctx\| ... }` | Set the user action for the block (and its id as the correlation id); events record it as `action_id` and `user_action` in every mode. Options: `controller:`, `action_name:`, `params:`. |

All are thread-local. With `correlate_writes` on (the default) Lyra sets them itself: one correlation per HTTP request (the request id, or a generated id when there is none) or per job (the correlation in scope where it was enqueued, or the job id when there was none), a new one named after its own event for a write outside a request and a job, and the event of the enclosing write as the cause of a write made in its callbacks, such as the destroy of a dependent record. An id set with `with_id` is kept.

With `config.correlate_writes` (the default), a monitored write is the cause of
the writes made while it runs, in all its callbacks (`after_save` and
`after_destroy` included): Lyra opens the write's scope around the whole save or
destroy callback chain, inside its transaction (around `create_or_update` and
`destroy`, and around a destroy chain the application runs itself with
`run_callbacks(:destroy)`, as a soft delete does), and adds no callback.

- Writes made once the write's own event is in the log (its `after_*`
  callbacks, has_many autosave among them) name that event. When the write
  records none (a save that changes nothing, an update or destroy that reaches
  no row), they take the cause that was in scope when the write began.
- Writes made before (its `before_*` callbacks: a `belongs_to` autosave, a
  `dependent: :destroy`) name the write. If the write then ends without its
  event in the log (it records none, is aborted or refused, raises, or its
  Monitor append fails), Lyra appends a `Lyra::Events::SaveWithoutEffect`
  marker with that id, in the write's transaction (in a savepoint, best effort,
  when the write raised), to the stream `Lyra::SavesWithoutEffect`
  (`Lyra::SavesWithoutEffect::STREAM`), never to the record's stream. Its data:
  `model` (the stream owner's name), `record_id`, `operation` (`create`,
  `update`, `destroy`), `reason` (`no change`, `no row`, `not saved`,
  `append failed`) and `replay: false`, no attribute value; its metadata is
  that of the write's own event (correlation, the cause in scope, who). Replay,
  the projections, ES-Lazy's catch-up, DualView, `Lyra::EventWindow` (the
  dashboard, `EventFlow`) and the GDPR reports pass it over;
  `event_store.read.event(id)` finds it. Nothing is recorded in Disabled mode.
- An access-log entry commits on a connection of its own and stays when the
  write in scope rolls back, so it names no write in scope: its
  `causation_id` is the cause from outside every write scope (one the
  application set, or a job's), and its `correlation_id` ties it to the writes
  around it.

So once its transaction commits, every `causation_id` Lyra gives names an
event in the store (`Lyra::Causation.integrity` checks a store). The
exceptions are a cause the application sets itself
(`Lyra::Causation.with_id`), and Monitor's log-and-continue policy, under which
an append that fails (a marker's too) is logged and the stream falls behind
until `lyra:repair`.

---

## Event flow analysis

`Lyra::EventFlow.new(subject_id: nil, subject_type: nil, time_range: nil)`
reads events from the whole store, filtered to the subject (by `user_id` or by
model and id) and the time range (default the last 30 days).

| Method | Description |
|---|---|
| `flow_data` | `{ timeline:, flows:, statistics:, privacy_impact: }` |
| `crud_to_event_mapping(model, operation, model_id = nil)` | Events for one operation; `model` is a class or its name, `operation` such as `:created` (a String works too). |
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

Every engine action is authorized by `config.dashboard_authorization`, a proc
run on the controller before the action (`instance_exec`, and given the
controller when it takes an argument): truthy allows, falsy answers 403. Unset,
the dashboard is open in the development and test environments only and
refused (403, with a log line) everywhere else, since its privacy pages show a
data subject's personal data. The engine controller inherits
`ActionController::Base`, not the host's `ApplicationController`, so helpers
defined only there are not reachable (Devise's `current_user` is).

```ruby
config.dashboard_authorization = ->(controller) { controller.current_user&.admin? }
config.dashboard_authorization = -> { session[:lyra_admin] == true }
```

The engine's root redirects to `dashboard` relative to the mount point.
Routes (relative to the mount): `dashboard`, `dashboard/model/:model_class`,
`dashboard/compare/:model_class/:id`, `dashboard/discrepancies/:model_class`,
`dashboard/audit_trail[/:model_class/:id]`, `dashboard/schema[/history|/:version]`,
`config/projections`, `privacy/...` (subject data, GDPR report, portable
export, PII inventory, data lineage, PII detection, policy, and from 1.0.0
`privacy/rights`: the open restrictions and objections with their age against
the month of Art. 12(3)), `flow/...`
(timeline, event chain, CRUD mapping, correlation, user actions),
`visualizations/...` (event graph, heatmap, JSON feeds) and `verification`.
`config/routes.rb` has the full list. From 1.0.0, under the dashboard's purpose, a route about
one record answers 403 when a restriction or upheld objection (Arts. 18, 21) covers it, and a route
over many records leaves out the events of the records they cover (`X-Lyra-Rights-Withheld` gives
how many).

---

## Rake tasks

Host applications get the tasks in `lib/tasks/lyra_*.rake`; run them with
`bin/rails` or `bundle exec rake`. The `privacy:` and `pam_dsl:` tasks are
loaded by PAM's Railtie when the pam_dsl gem is in the application's bundle.

| Task | Description |
|---|---|
| `lyra:mode:check TO=... [PROJECTION=sync\|async\|disabled\|lazy] [FROM=...] [REBUILD=1]` | Check a switch and certify it when clean; exits 1 otherwise. |
| `lyra:mode:status` | Configured mode, last applied mode, whether the gate is on. |
| `lyra:repair [DRY_RUN=1] [MODELS=User,Order] [UNREPRESENTABLE=refuse\|skip]` | Bring the event log back in line with the tables (Monitor/Disabled only). Records with values their model cannot represent: refused with the listing (nothing repaired), or with `UNREPRESENTABLE=skip` listed and left out of line. |
| `lyra:erase MODEL=... ID=... REASON=... [FIELDS=a,b] [EVERYWHERE=1] [MAX_COPIES=n] [DRY_RUN=1]` | `Lyra::Erasure.erase!` for one record; `MAX_COPIES` is passed as `max_copies:` (a positive integer; default `config.erasure_max_copies`), `DRY_RUN=1` as `dry_run: true`. Prints the copies erased, the records left behind, the rows erased without events with the remedy for the mode (`lyra:repair`, or a rebuild), and each value left as shared by field, type and holders; after a dry run, with the `MAX_COPIES` that would erase them. `LIFTING=id[,id]` passes `lifting:`; the restrictions lifted and the copies kept under a restriction are printed. |
| `lyra:retention:apply [DRY_RUN=1] [MODELS=...]` | `Lyra::Retention.apply!`. |
| `lyra:genesis [MODEL=A,B] [UNREPRESENTABLE=refuse\|skip]` | Import pre-Lyra rows now. Lists the rows whose values a model cannot represent: a refused model (nothing of it imported; exits 1 after the other models), or with `UNREPRESENTABLE=skip` the rows left out. |
| `lyra:projections:rebuild [MODEL=A,B] [TRUNCATE=false] [FORCE=1]` | Rebuild tables from the event log, one model at a time. Refuses (prints it, exits non-zero) to clear a table where that would lose rows the log cannot restore ([Rebuild](#rebuild)); the models rebuilt before it stay rebuilt. `TRUNCATE=false` rebuilds in place; `FORCE=1` clears anyway. |
| `lyra:schema:create`, `update`, `verify`, `report`, `history`, `diff[v1,v2]` | Event schema versions in `schema_path`. |
| `lyra:workflows:generate [MODE=...] [OUTPUT_DIR=...] [REPORTS_DIR=...]`, `lyra:workflows:verify`, `lyra:generate_workflows` | Generate and verify PetriFlow workflows (needs petri_flow). See [WORKFLOW_GENERATOR.md](WORKFLOW_GENERATOR.md). |
| `pam_dsl:report:full`, `policy`, `pii`, `retention`, `access_patterns`, `article_30`, `export[path]`, `compare[p1,p2,path]` | PAM reports. |
| `pam_dsl:generate:policy[name]`, `pam_dsl:generate:from_models[name]` | Generate a policy file; an existing `config/initializers/pam_dsl_policy.rb` is kept unless `FORCE=1`. |
| `privacy:report`, `privacy:policy`, `privacy:retention`, `privacy:article_30`, `privacy:export[path]` | Aliases of the `pam_dsl:report:*` tasks. |

Without `MODEL`/`MODELS`, tasks eager-load the application and use every
monitored model.

---

## Errors

| Error | Raised when |
|---|---|
| `Lyra::EventStoreUnavailableError` | An event could not be stored (fails the write in Hijack and event sourcing, and in Monitor with `monitor_append_failure = :fail_write`). |
| `Lyra::ModeTransition::Refused` | A gated switch or a boot found discrepancies or no certificate; `#report`. Also a switch, check, adoption or boot into Hijack or event sourcing while `record_touches` is false here or any process has a live `touch_skipping` entry (`force: true` included), and then the gated `enable_hijack!`/`enable_event_sourcing!`; a process with the option off booting into, or finding, an application in such a mode, and `record_touches = false` set at runtime in one. |
| `Lyra::Repair::Refused` | `Repair.run` outside Monitor/Disabled. |
| `Lyra::Projections::Rebuild::Refused` | `Rebuild.rebuild` while `record_touches` is false, or a process has a live `touch_skipping` entry; from 1.0.1 also a clearing rebuild (`truncate: true`, without `force: true`) where clearing the table would lose rows the log cannot restore (`Rebuild.clear_hazards`). |
| `Lyra::Projections::UnsupportedQuery` | ES-NoProj cannot answer a query exactly. |
| `Lyra::Temporal::HistoryNotRecorded` | A point-in-time read before an imported record's history begins. |
| `Lyra::StrictDataAccessViolation` | A callback-bypassing write with `strict_data_access` on. |
| `Lyra::PurposeBoundReads::PurposeRequiredError` | A read with no purpose under `reads_without_purpose = :deny`. |
| `Lyra::Erasure::Unsupported` | No personal fields to erase, or a NOT NULL column with no replacement. |
| `Lyra::Retention::Disabled` | `Retention.apply!` without `retention_executor` (and not a dry run). |
| `Lyra::MappingVerificationError` | `verify_mapping!` failed, or petri_flow is missing. |
| `Lyra::Schema::SchemaValidationError` | `strict_schema` found a breaking schema change at boot. |
| `ArgumentError` | Unknown `mode`, `projection_mode`, `monitor_append_failure`, `record_touches` or `reads_without_purpose` value, `record_touches = false` outside Monitor and Disabled (or, while it is false, `mode=`, `hijack_enabled = true`, `apply_label` or an ungated `enable_hijack!`/`enable_event_sourcing!` into Hijack or event sourcing; a gated one raises `ModeTransition::Refused`), bad `domain_events` rule, or an unresolvable name in `config.models`. |
| `PamDsl::PolicyNotFoundError`, `InvalidFieldError`, `UndeclaredPurposeError`, `PurposeFieldMismatchError`, `ConsentRequiredError`, `SpecialCategoryViolationError`, `CriminalDataViolationError` | PAM validation (all subclasses of `PamDsl::Error`). `SensitivityViolationError` is a deprecated alias of `SpecialCategoryViolationError`, removed in 2.0. `CriminalDataViolationError` (from 1.0.0): Art. 10 data read without an `art10_authorisation`. |
| `PamDsl::RestrictedProcessingError`, `ObjectedProcessingError` | Condition 6 (from 1.0.0): `validate_access!` for a subject whose restriction covers the access (and the purpose declares no Art. 18(2) exception that applies), or who objected to the purpose and the objection was upheld. Checked after every other condition. |
| `PamDsl::ObjectionNotApplicableError`, `RightsTransitionError`, `RightsStoreNotDurableError`, `RightsConcurrencyError` | The rights API (from 1.0.0): an objection to a purpose with no right to object (recorded as rejected first); a transition the state does not allow (a lift without notice); a store that is not durable where one is required; a concurrent change to the same subject's rights. |

`Lyra::Error` is defined but not raised by the engine.
