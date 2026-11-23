# Lyra Troubleshooting Guide

Problems you may meet with Lyra, what causes them, and how to fix them. For
the API see [API_REFERENCE.md](API_REFERENCE.md); for the migration path and
its pitfalls see [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md); for switching modes
see [MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes).

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Installation Issues](#installation-issues)
3. [Event Store Issues](#event-store-issues)
4. [State Consistency Issues](#state-consistency-issues)
5. [Mode Switching Issues](#mode-switching-issues)
6. [Event-Sourcing Configurations](#event-sourcing-configurations)
7. [Concurrency Issues](#concurrency-issues)
8. [Performance Issues](#performance-issues)
9. [Privacy and PII Issues](#privacy-and-pii-issues)
10. [Debugging Techniques](#debugging-techniques)
11. [Common Error Messages](#common-error-messages)
12. [Getting Help](#getting-help)

---

## Quick Diagnostics

Run these first to place the problem:

```bash
bin/rails lyra:mode:status          # configured mode, last applied mode, whether the gate is on
bin/rails lyra:repair DRY_RUN=1     # Monitor/Disabled only: records whose row and events disagree
```

```ruby
# bin/rails console
Lyra::ModeTransition.current        # => "monitor", "hijack", "event_sourcing/lazy", ...
Lyra.config.monitored_models        # the classes Lyra records events for
User.lyra_monitored?                # => true for a monitored model
Lyra.event_store                    # the RailsEventStore client Lyra writes to

Lyra.event_store.read.stream("User$123").to_a.map(&:event_type)
Lyra::DualView.find_discrepancies(User).size   # 0 when every row agrees with its events
```

Lyra writes to `Lyra.event_store` (the same object as `Lyra.config.event_store`).
The engine sets it to `RailsEventStore::Client.new` at boot unless your
initializer sets one; it does not read `Rails.configuration.event_store`.

---

## Installation Issues

### `NameError: uninitialized constant Lyra` (or `PamDsl`, `PetriFlow`)

**Cause**: The gems are named `orfeas_lyra`, `orfeas_pam_dsl` and
`orfeas_petri_flow`, but their entry files are `lyra`, `pam_dsl` and
`petri_flow`. Bundler's automatic require looks for a file named after the gem
and finds none.

**Fix**: Name the file to require in the Gemfile:

```ruby
gem "orfeas_lyra", "~> 1.0", require: "lyra"
gem "orfeas_pam_dsl", "~> 1.0", require: "pam_dsl"        # optional
gem "orfeas_petri_flow", "~> 1.0", require: "petri_flow"  # optional
```

See [GETTING_STARTED.md](GETTING_STARTED.md#1-install) for installing from
RubyGems or GitHub; use 0.9.0 or later, not the 0.6.0 releases.

### `NameError: uninitialized constant PetriFlow::Workflow` when eager loading

**Cause**: Lyra's `app/workflows/*.rb` subclass `PetriFlow::Workflow`. Earlier
versions eager-loaded them even without petri_flow, so production boot and the
`lyra` rake tasks that eager-load the application (`lyra:mode:*`,
`lyra:repair`, `lyra:schema:*`) failed.

**Fix**: Update Lyra. Without petri_flow, or with
`LYRA_DISABLE_PETRI_FLOW=true`, the engine neither autoloads nor eager-loads
`app/workflows`; formal verification is then unavailable. To verify, add
`orfeas_petri_flow` with `require: "petri_flow"`.

### Bundler cannot resolve `rails_event_store`

**Cause**: Lyra depends on `rails_event_store ~> 3.0`; an application pinned
to RailsEventStore 2 cannot resolve.

**Fix**: Move the application to RailsEventStore 3, or drop its own
`rails_event_store` line and let Lyra pull it in. The RailsEventStore 3 names
differ from 2: the repository is `RubyEventStore::ActiveRecord::EventRepository`,
and the migration generator is `ruby_event_store:active_record:migration`.

### `PG::UndefinedTable: relation "event_store_events" does not exist`

**Cause**: The event store tables were not created.

**Fix**:

```bash
bin/rails generate ruby_event_store:active_record:migration
bin/rails db:migrate
```

Lyra's own tables (`lyra_mode_transitions`, `lyra_projection_checkpoints`) are
created on first use and need no migration.

### A name in `config.models` fails the boot

**Cause**: `config.models = %w[...]` resolves each name once the application's
code has loaded; a name that does not resolve to a class raises
`ArgumentError`.

**Fix**: Correct the name (namespaced models need the full name,
`"Spree::Order"`), or remove it.

---

## Event Store Issues

### Events are not recorded

**Symptom**: Writes succeed but the record's stream stays empty.

**Diagnosis**:

```ruby
User.lyra_monitored?                               # false: the model is not monitored
Lyra::ModeTransition.current                       # "disabled": no mode records events
before = Lyra.event_store.read.stream("User$#{user.id}").count
user.update!(name: "Test")
Lyra.event_store.read.stream("User$#{user.id}").count - before   # 1 expected
```

**Causes and fixes**:

1. **The model is not monitored.** Add `monitor_with_lyra` to the model, or
   its name to `config.models`.
2. **Lyra is in Disabled mode.** Every other mode records events: Monitor
   appends one after each write, Hijack and the event-sourcing modes store
   the event as the write itself. See the modes table in
   [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#the-modes-at-a-glance).
3. **The write did not go through ActiveRecord.** Raw SQL
   (`connection.execute`), triggers and other applications are invisible to
   Lyra. Writes that skip callbacks (`update_all`, `delete_all`,
   `update_columns`, ...) are recorded as bypass events, not as `Updated` or
   `Destroyed`; see
   [API_REFERENCE.md](API_REFERENCE.md#callback-bypassing-writes).
4. **The append failed in Monitor.** Monitor logs the failure and keeps the
   write; see the next entry.
5. **You are reading the wrong stream.** Streams are named
   `"#{Model.name}$#{id}"` (`"User$123"`, `"Spree::Price$7"`).

### Error: `Lyra::EventStoreUnavailableError`, or log line "Lyra: Failed to publish event … run bin/rails lyra:repair"

**Symptom:** an event could not be stored. The error's message names the
stream, and its `cause` is the store's own error.

What happened to the write depends on the mode:

| Mode | Policy | The write |
|---|---|---|
| Hijack, event sourcing (any projection mode) | fail-closed | raises `EventStoreUnavailableError` and rolls back: nothing in the table, nothing in the log |
| Monitor | log-and-continue | stands; the error is logged ("Lyra: Failed to publish event … the write stands"), and the record's stream falls behind its row |
| Monitor, `monitor_append_failure = :fail_write` | fail-closed | as Hijack and event sourcing |

**Fix:** fix the cause (look at `error.cause`). In Monitor, then bring the
lagging streams back in line from the tables:

```bash
bin/rails lyra:repair DRY_RUN=1        # list the records out of line
bin/rails lyra:repair                  # append the events that bring them back
bin/rails lyra:repair MODELS=User,Order
```

Each repaired stream gets one event (`Imported`, `Updated` with the differing
columns, or `Destroyed`, metadata `source: "lyra_repair"`) that makes it replay
to its row; the detail of the lost changes is not recoverable. Repair refuses
to run in Hijack or event sourcing (`Lyra::Repair::Refused`), where the events
are authoritative: there, rebuild the tables from the log
(`bin/rails lyra:projections:rebuild`, see
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#recovery)). Sampled verification
(`config.dual_view_sample_rate`) reports such records as they happen.

### Times differ by fractions of a second between rows and events

**Cause**: The event store was configured with `serializer: JSON`. Ruby's JSON
writes times without fractional seconds, so an event can record a time that is
not the row's, or an update that changed nothing.

**Fix**: Use `Lyra::EventSerializer`, which writes times with microseconds:

```ruby
config.event_store = RailsEventStore::Client.new(
  repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
)
```

Events already stored keep the times they were stored with.

---

## State Consistency Issues

### A row disagrees with its events

**Symptom**: `Lyra::DualView.new(User, id).compare[:differences]` is not
`{}`, or `lyra:repair DRY_RUN=1` lists the record.

**Diagnosis**:

```ruby
comparison = Lyra::DualView.new(User, user.id).compare
comparison[:differences]   # {} when they agree; { exists: { crud: true, event_sourced: false } } or { "name" => { crud: ..., event_sourced: ... } }
```

`created_at` and `updated_at` are compared like any other column, and times compare at
microseconds. `bin/rails lyra:repair DRY_RUN=1` classifies each finding as
"row but no events", "events but no row", "row of a destroyed record" or "row
differs from its events".

**Causes and fixes**:

1. **Rows that predate Lyra** ("row but no events", or an `exists` difference).
   They have no stream until Genesis gives each one an `Imported` event. With
   the default `config.genesis = :auto` that happens on its own only in
   event-sourcing mode; otherwise run it:
   ```bash
   bin/rails lyra:genesis
   bin/rails lyra:genesis MODEL=User,Order
   ```
   Or set `config.genesis = true`. See
   [MIGRATION_GUIDE.md, Phase 2](MIGRATION_GUIDE.md#phase-2-genesis-rows-that-predate-lyra).
2. **Writes Lyra cannot see**: raw SQL, triggers, other applications. Find
   them (`execute`, `exec_update`, triggers in `db/structure.sql`) and route
   the writes through ActiveRecord. In Monitor, `bin/rails lyra:repair` then
   brings the streams back in line. Do not publish hand-made events to fix a
   stream.
3. **A lost append in Monitor**: see
   [`EventStoreUnavailableError`](#error-lyraeventstoreunavailableerror-or-log-line-lyra-failed-to-publish-event--run-binrails-lyrarepair).
4. **Expected lag**: in ES-Async, ES-Lazy and ES-NoProj the tables lag the log
   by design, so a comparison of rows with events there is not a consistency
   check. Sampled DualView skips these configurations.

### Replayed state is not what you expect

**Diagnosis**: look at the stream event by event.

```ruby
Lyra.event_store.read.stream("User$#{id}").each do |event|
  puts [event.event_type, Lyra::Event.operation_of(event).inspect, event.changes].join("  ")
end
Lyra::StateProjection.rebuild_state(User, id)   # the replayed attributes
```

Replay dispatches on each event's recorded operation (`Lyra::Event.operation_of`):
`:created` and `:imported` set the attributes, `:updated` applies the new value
of each change, `:destroyed` marks the record destroyed. Events for which
`operation_of` returns `nil` (an additional domain event with `also: true`, an
access-log event) are not replayed. A stream that starts with `Updated` has no
head: the record predates Lyra and was not imported (Genesis, above).

---

## Mode Switching Issues

Mode switches are gated: a switch that changes the authoritative store needs a
clean check of every row against its stream. The full procedure is in
[MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes).

### `Lyra::ModeTransition::Refused`: "Lyra will not start in hijack: the application last ran in monitor, and no clean check certifies that switch"

**Cause**: The initializer's mode was changed and deployed without a check.
At boot each process compares its configured mode with the last one applied
(`lyra_mode_transitions`); a switch that needs a check needs a fresh
certificate.

**Fix**: Run the check the message names, on the running application, then
deploy again:

```bash
bin/rails lyra:mode:check TO=hijack
bin/rails lyra:mode:check TO=event_sourcing PROJECTION=sync
bin/rails lyra:mode:check TO=monitor REBUILD=1   # leaving ES-NoProj
```

A certificate is valid for `config.mode_transition_certificate_ttl` seconds
(3600 by default). A check that reports "a write in flight at the check did
not end" met a transaction that stayed open longer than
`config.mode_transition_settle_timeout` (30 s): run the check again when it has
ended, or when writers are stopped. `LYRA_FORCE_MODE_TRANSITION=1` lets a process start without
one, when you accept that the stores may disagree. Rake tasks are not gated at
boot, so the check and migrations run in any configuration.

### `Lyra::ModeTransition::Refused`: "Lyra refuses monitor -> hijack: N discrepancies, e.g. …"

**Cause**: `lyra:mode:check`, `Lyra::ModeTransition.to!` or a `config.enable_*!`
helper after boot found rows that disagree with their events. `error.report`
holds the full `Report`.

**Fix**: Resolve the discrepancies as in
[State Consistency Issues](#state-consistency-issues) (in Monitor:
`bin/rails lyra:repair`), then check again. `ModeTransition.to!(mode,
force: true)` switches without the check.

### The mode changes back, or a process runs in another mode than its initializer says

**Cause**: `Lyra::ModeSync` keeps every process in the application's mode,
the last switch recorded in `lyra_mode_transitions`. A process whose mode was
set with the raw setter (`Lyra.config.mode = ...`) adopts a newer switch
recorded by another process.

**Fix**: Switch through a deploy or `Lyra::ModeTransition.to!`, which record
the switch. `bin/rails lyra:mode:status` shows the configured and the last
applied mode. In the test environment the gate and ModeSync are off by
default.

### Still in Hijack after `config.mode = :monitor`

**Cause**: `enable_hijack!` also sets `config.hijack_enabled`, and
`hijack_mode?` is true while that flag is set, whatever `mode` says.

**Fix**: Leave Hijack with `config.enable_monitor!` or
`Lyra::ModeTransition.to!(:monitor)`, which clear the flag.

### Rows are still written in Hijack

This is expected. In Hijack the event is stored first and then the row is
written, in the same transaction; reads still come from the tables. Only
ES-Async, ES-Lazy and ES-NoProj defer or skip the row write.

---

## Event-Sourcing Configurations

### `Lyra::Projections::UnsupportedQuery` (ES-NoProj)

**Cause**: In ES-NoProj (`projection_mode = :disabled`) reads are answered
from the event store and evaluated in Ruby. A query the reader cannot answer
exactly raises instead of returning a wrong answer: SQL fragments other than
simple `"column OP ?"` terms, string, nested, `:through`, polymorphic or
scoped joins, conditions on tables not joined, and scopes it cannot reduce to
conditions. Destroying a parent raises it, and the destroy is refused, when a
`has_many ... dependent: :delete_all` or `:nullify` association has such a
scope (an SQL string scope, say), or the child's default scope is one: the
children it would delete or nullify cannot be found exactly.

Reads go through the model's default scope, as Active Record's do. A message
naming "the default scope of *Model*" means that scope cannot be evaluated
(`default_scope { where("deleted_at IS NULL") }`, a join, an ordering by an
expression such as `order(arel_table[:name].lower)`): every read of that model,
and of associations to it, raises. A message naming `unscope(...) after other
query methods` means a scope that takes the default scope off
(`with_deleted`, `with_discarded`), or a `rewhere`, came after a `limit`,
`where.not`, an SQL fragment or the like (`Model.limit(5).with_discarded`):
call it first (`Model.with_discarded.limit(5)`), or after `where`, `order` and
named scopes only. A message naming a relation method ("`to_sql` on a
relation", "`invert_where` on a relation", "`merge` of a … relation") means the
relation cannot do it from the event store; it was refused before anything
ran. A message naming "a uniqueness check" comes from a `validates ...,
uniqueness:` whose `conditions:` (an SQL fragment such as
`-> { where("archived = ?", false) }`, a subquery, `LIKE`) or column (a
collation of its own) ES-NoProj cannot evaluate: the save is refused rather
than the value passed or refused on a guess. Write the conditions as hash
conditions (`-> { where(archived: false) }`).

**Fix**: Rewrite the query with hash conditions, or use ES-Lazy or a projected
configuration (ES-Sync, ES-Async) for that code. Write a default scope as hash
conditions and column orderings (`default_scope { where(deleted_at: nil) }`).
The supported subset is listed in
[API_REFERENCE.md](API_REFERENCE.md#es-noproj-projection_mode-disabled).

### `Lyra::ModeTransition::Refused`: "ES-NoProj cannot evaluate the default scope of …"

**Cause**: `Lyra::ModeTransition.to!(:event_sourcing, projection_mode:
:disabled)` checks each monitored model's default scope first. A scope
ES-NoProj cannot evaluate from the event store (see above) would make every
read of that model raise `UnsupportedQuery`, so the switch is refused and the
models are named. Setting `config.projection_mode = :disabled` directly is
not gated: the boot logs a warning per model, and the reads raise.

**Fix**: Write those default scopes as hash conditions and column orderings,
leave the models unmonitored, or use another projection mode.
`ModeTransition.to!(..., force: true)` switches anyway.

### `Lyra::ModeTransition::Refused`: "… a database foreign key into one of those tables from a table no monitored model writes …"

**Cause**: ES-NoProj keeps the records of monitored models in the event store
and writes no rows to their tables. A database foreign key from a table no
monitored model writes into one of those tables (an unmonitored `Match` with
`add_foreign_key :matches, :registrations`, `Registration` monitored) would
make every insert or update there that sets the column fail with
`ActiveRecord::InvalidForeignKey`, so the switch into ES-NoProj names each
such constraint (`matches.registration_id -> registrations (constraint
fk_rails_…)`) and is refused. Foreign keys between monitored tables, or from
a monitored table into an unmonitored one, never fire in ES-NoProj and are
not reported. Setting `config.projection_mode = :disabled` directly is not
gated: the boot logs a warning per constraint ("Lyra: in ES-NoProj every
write to matches that sets registration_id will fail"), and the writes fail.

**Fix**: Monitor the referencing model too (its records then live in the
event log beside the ones they reference), or drop the constraint
(`remove_foreign_key :matches, name: "fk_rails_…"`) and keep the reference in
the model: `belongs_to` validates that the record exists, and Lyra answers
that lookup from the event store. `ModeTransition.to!(..., force: true)`
switches anyway.

### A record just written is not found (ES-Async)

**Cause**: ES-Async projects each event to the table in a background job
(`Lyra::Projections::AsyncProjectionJob`, queue `lyra_projections`, enqueued
after commit). A read right after the write, such as the page a create
redirects to, can run before the job.

**Fix**: Use ES-Sync or ES-Lazy for flows that read their own writes, and make
sure a worker processes the `lyra_projections` queue. In the test environment
async projections run inline unless `config.async_projections_inline = false`.

### Projection failures are only logged (ES-Sync, ES-Async)

**Cause**: By default a failed sync projection, or a failed enqueue of an
async one, is logged and passed to `config.projection_error_handler`; the
event stays stored. A database error in a sync projection (a unique index, a
constraint) is not: it fails the write, whatever `strict_projections` says.
A projected create that meets another record's value in a unique index
brings that record's row up to date when its projection lags and nothing holds
the row; a held row makes its job retry for about a day
(`Lyra::Projections::ProjectionBehind`), then report it and give up (rebuild
the model then). It is logged once and discarded when two live records of the
log hold the value, or an index Lyra does not read refuses it
(`DuplicateInLog`; ES-Lazy's catch-up logs it once and goes on).

**Fix**: Set `config.strict_projections = true` to re-raise instead, or rebuild
the affected table from the log with `bin/rails lyra:projections:rebuild
MODEL=...`.

### Events skipped after a long transaction (ES-Lazy)

**Cause**: ES-Lazy applies pending events before each read and tracks gaps in
the event ids. A gap still empty after `LazyProjection::GAP_TTL` (300 seconds)
is taken to be a rolled-back transaction and forgotten, so a single
transaction open longer than that has its events skipped by the tables.

**Fix**: Keep transactions short. After one that ran longer, rebuild the
affected tables from the log (`bin/rails lyra:projections:rebuild MODEL=...`).

### Stale reads with raw SQL (ES-Lazy)

**Cause**: The catch-up runs before ActiveRecord reads; SQL sent directly
through the connection (`connection.select_all`) does not trigger it.

**Fix**: Read through ActiveRecord, or call
`Lyra::Projections::LazyProjection.catch_up!` first.

---

## Concurrency Issues

### `ActiveRecord::Deadlocked` in a transaction that writes several records

**Symptom**: A transaction that writes several records one after another
(`a.update!(...)`, then `b.update!(...)`, or a write followed by an
`update_all` over other records) sometimes fails with
`ActiveRecord::Deadlocked` ("deadlock detected") under concurrent load. The
message names an `advisory lock`, a `transaction`, or both.

**Cause**: Each write locks its record until the transaction ends. Monitor,
Hijack and ES-Sync lock the row; ES-Async, ES-Lazy and ES-NoProj take the record's
aggregate lock, a PostgreSQL advisory lock on its stream
(`lyra_aggregate/<stream>`); a write that takes both takes the aggregate lock
first, then the row (`Lyra::AdvisoryLock`). Lyra orders the locks of one write:
a bulk write (`update_all`, `delete_all`, `touch_all`) takes all its records'
aggregate locks together, in the order of their hashes. It does not order the writes of an application's transaction: a
transaction that holds record A and then asks for record B waits for whoever
holds B; if that one is waiting for A (another transaction that took B first,
or a bulk write that holds B and waits for A), neither can go on. PostgreSQL
detects the cycle after `deadlock_timeout` (1 s by default) and aborts one of
them. Plain Active Record does the same with row locks: two transactions that
update the same rows in opposite orders deadlock without Lyra too
(`test/aggregate_lock_deadlock_test.rb`).

A bulk write that holds no lock of its own yet keeps out of such cycles: while
it waits for records other sessions hold, it keeps the others for at most 100
ms, never as long as `deadlock_timeout`, then gives them back and tries again,
so a transaction that holds one of its records and asks for another goes on,
and PostgreSQL never aborts the bulk write (a `lock_timeout` of your own that
is shorter still applies, and raises `ActiveRecord::LockWaitTimeout`). A
transaction that already holds records (it wrote one, then bulk-writes others)
waits holding none of the new ones, but it still holds the first. Two
application transactions that take the same records in opposite orders cannot
be helped that way. The price of the bulk write's turns: under contention, the
transactions that share records with it wait while it holds them, and go through
less often than when it gave its locks back at once.

**ES-Lazy: a transaction that reads, then writes (fixed in 1.0.1).** In
1.0.0 a read inside a transaction caught up in that transaction: the rows it
wrote and the catch-up lock stayed held until the transaction ended, and a
transaction that held a row and then read could deadlock with another
reader's catch-up, or with a bulk write. From 1.0.1 such a catch-up runs on a
connection of its own and commits at once, and it waits at most 100 ms for a
row another transaction holds, then leaves that record for a later catch-up.
A read that only the transaction's own writes are behind replays those records
in the transaction. `lock!`, `with_lock` and `lock.find(ids)` take the records'
aggregate locks before their row locks, the order every writer takes them in.
A locking read whose keys are not known before it runs (`Model.lock.where(...)`,
a `lock` with a join) reads its keys first, takes their aggregate locks, then
runs. What can still deadlock: raw `FOR UPDATE` SQL and an eager-loading
locking read, which take rows before aggregate locks; a record that starts to
match such a read more than twice while it runs; and the fallback when no second connection
is free in the pool (or the connection is pinned, as in transactional tests),
where the catch-up runs in the transaction as in 1.0.0. That fallback holds the
catch-up lock until the transaction ends, so every other reader's catch-up
waits for that commit; the transaction's later reads catch up in it again, and
a catch-up on a connection of its own waits at most 1 s for the lock, then runs
in its reader's transaction, so a wait cycle through a fallback is a deadlock
PostgreSQL detects (`ActiveRecord::Deadlocked`), not a hang. In `REPEATABLE READ`
and `SERIALIZABLE` the catch-up also runs in the transaction, as in 1.0.0, so
that the transaction's snapshot sees the rows it applies.

**Fix**:

1. Take records in one order in every transaction, for example by primary key:
   ```ruby
   Order.transaction do
     orders.sort_by(&:id).each { |order| order.update!(status: "shipped") }
   end
   ```
2. Retry the whole transaction on `ActiveRecord::Deadlocked`, a few times; it
   was rolled back, nothing of it was written or recorded:
   ```ruby
   attempts = 0
   begin
     Order.transaction { ... }
   rescue ActiveRecord::Deadlocked
     attempts += 1
     retry if attempts < 3
     raise
   end
   ```
3. Keep transactions short. In ES-Lazy, read what you need before the
   transaction, or before its first write.
4. In ES-Lazy, give the pool a connection more for every thread that reads
   inside transactions (twice the threads), so the catch-up rarely falls back.

---

## Performance Issues

### Slow reads in ES-NoProj

**Cause**: Each record is rebuilt by replaying its stream, through a cache
keyed by the stream's last event id in `Rails.cache`. A collection query loads
every record of the model and filters in memory. With `:null_store` as the
cache nothing is kept, and every read replays.

**Fix**: Configure a persistent `Rails.cache` (Solid Cache, Redis, Memcached).
For queries over large tables use ES-Lazy, which runs real SQL.

### The first request after enabling a mode is slow

**Cause**: Genesis runs on a model's first use in a process and imports every
row that has no stream.

**Fix**: Run `bin/rails lyra:genesis` before enabling the mode.

### `Lyra::Genesis::Refused` or `Lyra::Repair::Unrepresentable`: rows hold values the model cannot represent

**Cause**: A row that predates Lyra holds a value its model reads as something
else (an enum value outside the mapping is read as `nil`), so its `Imported`
event would not match it. The message lists model, id, attribute, stored value
and value read (the first 20, with the count). Nothing of the model was
imported. `lyra:repair` checks what it would write the same way, and refuses
before repairing anything.

**Fix**: Correct the rows (or add the value to the model), then run
`bin/rails lyra:genesis MODEL=...` (or `lyra:repair`) again. To import or
repair the rest and leave those rows out, use `UNREPRESENTABLE=skip` or
`config.genesis_unrepresentable = :skip`. A write to a skipped row (also
`update_all` and other bulk writes) raises `Lyra::Genesis::Refused` naming
it: fix that row in the database (SQL), not through the model; its next use,
or `lyra:genesis`, imports it.

A legacy `'--- {}'` row under `serialize :col, type: Hash` is such a value
(read as `{}`, written back as `NULL`): set those rows to `NULL` by SQL, or
skip them. In Monitor with `config.genesis = true`, `:skip` and
`config.record_touches = false`, a timestamp-only `touch_all` that reaches a
skipped row is refused too, though it would record no event.

### Bulk writes are slow

**Cause**: Callback-bypassing bulk writes on monitored models (`update_all`,
`delete_all`, `insert_all`, ...) publish one bypass event per affected record.

**Fix**: This is by design: each changed record's stream records the change.
`Lyra.unrecorded_write(reason: "...") { ... }` runs a block without bypass events and
without strict-access checks, so its changes are missing from the log (in Monitor,
`lyra:repair DRY_RUN=1` then reports the records); the call itself is recorded in
the stream `Lyra::UnrecordedWrites`. Reserve it for data the log
need not hold; see [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#common-pitfalls).

---

## Privacy and PII Issues

### A field is not detected as PII

**Symptom**: `Lyra::Privacy::PIIDetector.detect(attributes)` leaves out a
field you consider personal.

**Cause**: `PIIDetector` delegates to the privacy provider's detector. With PAM
that is a name-based detector: a field is detected when its name matches one of
PAM's PII patterns (partial matching by default, so `billing_phone` matches),
and names that look like timestamps, counters, flags or amounts are excluded
first. Without PAM (`Lyra.pam_dsl_available?` false) nothing is detected.

**Fix**: Declare the field in the model's PAM policy:

```ruby
PamDsl.define_policy :my_policy do
  field :contact, type: :email, sensitivity: :confidential
end
```

Declarations are what Lyra's privacy features use: purpose-bound reads, the
access log, privacy stamps and erasure work on declared attributes.
`Lyra::Privacy::PolicyIntegration.new(:my_policy).detect_pii(attributes)`
reports declared fields first and falls back to the detector;
`PIIDetector.detect` alone does not read the policy.

### A field is not masked

**Cause**: `Lyra::Privacy::PIIMasker.mask(attributes, strategy: :partial)` masks
the fields the name-based detector finds, as above.

**Fix**: For a declared field, use the policy's transformations:
`Lyra::Privacy.policy_for(User).mask(:contact, value, :display)` or
`PolicyIntegration.new(:my_policy).mask_pii(:contact, value, :display)`.

### The privacy policy does not apply

**Diagnosis**:

```ruby
Lyra.pam_dsl_available?                     # false: PAM is not loaded (or LYRA_DISABLE_PAM_DSL=true)
PamDsl.policy(:my_policy)                   # raises PamDsl::PolicyNotFoundError if not defined
User.lyra_config.privacy_policy             # => :my_policy (nil falls back to config.privacy_policy)
Lyra::Privacy.policy_for(User).loaded?      # => true when Lyra sees the policy
```

**Fix**: Require PAM (`require: "pam_dsl"` in the Gemfile), define the policy
with `PamDsl.define_policy` in an initializer, and name it on the model
(`monitor_with_lyra privacy_policy: :my_policy`) or as the default
(`config.privacy_policy = :my_policy`).

### `Lyra::PurposeBoundReads::PurposeRequiredError`: "read of … with no declared purpose"

**Cause**: `config.reads_without_purpose = :deny`, and a model with a loaded
policy was read outside any declared purpose.

**Fix**: Declare the purpose where the read is made:

```ruby
Lyra.with_purpose(:invoicing) { Registration.find(id) }

class PaymentsController < ApplicationController
  lyra_purpose :payment_processing
end
```

Or use `:audit` while you add purposes; it logs such reads and lets them
through. See [API_REFERENCE.md](API_REFERENCE.md#purpose-bound-reads).

### A read inside a purpose raises a PAM error

**Cause**: Within a declared purpose, every declared attribute the query loads
must be allowed for that purpose. The policy's enforcement mode decides the
outcome: strict raises the first violation (`PamDsl::InvalidFieldError`,
`PurposeFieldMismatchError`, `ConsentRequiredError`, ...), audit logs it and
lets the read through.

**Fix**: Select only the attributes the purpose needs
(`Registration.select(:id, :vat_number).find(id)`), or allow the field for the
purpose in the policy (`allow_for`).

---

## Debugging Techniques

### Inspect a record's events

```ruby
events = Lyra.event_store.read.stream("User$123").to_a
events.each do |event|
  puts "#{event.event_type} #{event.event_id} at #{event.timestamp}"
  pp event.data
  pp event.metadata
end
```

Event readers (`operation`, `attributes`, `changes`, `model_class`,
`model_id`, `timestamp`) accept data with symbol or string keys; with a JSON
serializer `event.data` itself has string keys. The data envelope and the
metadata each write path records are listed in
[API_REFERENCE.md](API_REFERENCE.md#events-streams-and-metadata).

### Trace a record's history

```ruby
Lyra::AuditProjection.audit_trail(User, 123)   # one hash per event
Lyra.state_at(User, 123, 2.days.ago)           # the record as it was then
Lyra::StateAnalyzer.analyze(User, 123)         # comparison, audit trail and recommendations
```

### Follow a chain of writes

Writes in a `Lyra::Correlation.with_id { ... }` block share a correlation id,
so the events of one user action can be grouped:

```ruby
Lyra.event_store.read.to_a.select { |e| e.metadata[:correlation_id] == correlation_id }
```

### Log output

Lyra logs through `Rails.logger`; its messages begin with `Lyra`. There is no
separate Lyra logger to configure:

```bash
grep "Lyra" log/production.log
```

---

## Common Error Messages

The full list of errors Lyra raises is in
[API_REFERENCE.md](API_REFERENCE.md#errors). The ones most often met:

| Error | Cause | Fix |
|---|---|---|
| `Lyra::EventStoreUnavailableError` | An event could not be stored; the write rolled back (Hijack, event sourcing, and Monitor with `monitor_append_failure = :fail_write`). | [Above](#error-lyraeventstoreunavailableerror-or-log-line-lyra-failed-to-publish-event--run-binrails-lyrarepair) |
| `Lyra::ModeTransition::Refused` | A gated switch or a boot found discrepancies or no certificate, or a switch into ES-NoProj found a default scope it cannot evaluate or a database foreign key from an unmonitored table into a monitored one. | [Mode Switching Issues](#mode-switching-issues) |
| `Lyra::Repair::Refused` | `lyra:repair` outside Monitor/Disabled. | Rebuild the tables instead: `bin/rails lyra:projections:rebuild`. |
| `Lyra::Projections::UnsupportedQuery` | ES-NoProj cannot answer a query exactly. | [Above](#lyraprojectionsunsupportedquery-es-noproj) |
| `Lyra::PurposeBoundReads::PurposeRequiredError` | A read with no purpose under `reads_without_purpose = :deny`. | [Above](#lyrapurposeboundreadspurposerequirederror-read-of--with-no-declared-purpose) |
| `Lyra::StrictDataAccessViolation` | A callback-bypassing write with `config.strict_data_access` on. | Use `save`/`update`/`destroy`, or wrap deliberate bulk work in `Lyra.without_strict_access { ... }`. |
| `Lyra::Temporal::HistoryNotRecorded` | A point-in-time read before an imported record's history begins. | The record was imported by Genesis; its history before the import was not recorded. |
| `Lyra::MappingVerificationError` | `verify_mapping!` failed, or petri_flow is missing. | Read the failed checks in the message; add `orfeas_petri_flow` with `require: "petri_flow"`. |
| `ActiveRecord::Deadlocked` | A transaction writing several records met another taking them in another order (as with plain Active Record's row locks). | [Concurrency Issues](#activerecorddeadlocked-in-a-transaction-that-writes-several-records) |
| `ActiveRecord::RecordInvalid` | Model validations failed. | Validations run in every mode, before Lyra stores an event. |

A command that fails in Hijack or event sourcing does not raise: it adds its
error to the record's `errors[:base]`, and `save` returns false.

---

## Getting Help

### Gather information

1. The configuration: `bin/rails lyra:mode:status`, and in a console
   `Lyra::ModeTransition.current`, `Lyra.config.monitored_models`,
   `User.lyra_config`.
2. Versions: `Lyra::VERSION`, `bin/rails --version`, `ruby --version`,
   `bundle exec gem list rails_event_store`.
3. The events of an affected record:
   `Lyra.event_store.read.stream("User$123").to_a`.
4. The full error: `e.full_message`, and for `ModeTransition::Refused` its
   `report.summary`.
5. The `Lyra:` lines from the Rails log.

### Minimal reproduction

```ruby
# bin/rails runner repro.rb
class ReproUser < ApplicationRecord
  self.table_name = "users"
  monitor_with_lyra
end

user = ReproUser.create!(email: "test@example.com")
pp Lyra.event_store.read.stream("ReproUser$#{user.id}").to_a.map(&:event_type)
```

### Contact

- GitHub issues: https://github.com/mpantel/lyra-engine/issues
- Email: mpantel@aegean.gr

Include the Lyra, Rails and Ruby versions, the configuration, the error with
its stack trace, and the reproduction steps.

---

## Additional Resources

- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
- [Migration Guide](MIGRATION_GUIDE.md)
- [Switching Modes](MIGRATION_GUIDE.md#switching-modes)
- [Architecture](ARCHITECTURE.md)
- [Main Documentation](../README.md)
