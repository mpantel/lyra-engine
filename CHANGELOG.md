# Changelog

All notable changes to the Lyra project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - unreleased

A patch release of `orfeas_lyra`; `orfeas_pam_dsl` and `orfeas_petri_flow` stay at 1.0.0. It adds
one table of Lyra's own, `lyra_stream_heads`, and one column, `lyra_projection_checkpoints.event_id`,
each created on first use like the others or by the new install migration, and three settings:
`stream_heads` (on), `check_effects` (off) and `mode_transition_settle_timeout`. A record's history is
checked where its events are appended; in ES-Lazy a catch-up no longer holds its lock to the
application's commit; a read under a row lock sees every committed write of its records and keeps
out the others until it ends, in ES-Async, ES-Lazy and ES-NoProj; and the mode gate waits for the
writes in flight (see Fixed). What remains is listed under Known issues.

### Added
- **`config.check_effects`, opt-in (off by default; `LYRA_CHECK_EFFECTS=1`): the effect clause of
  Hypothesis H checked at the write.** In Hijack and ES-Sync the row is written in the same
  transaction as the event. With the setting on, after each create, update or destroy through
  callbacks, Lyra compares the record's row with the replay of its stream, as the mode gate and
  DualView compare them, and raises `Lyra::EffectMismatchError` when they differ (a trigger, a
  default the database computes, a type that does not round-trip), so the write and its event roll
  back together. Off, such a write goes through as in 1.0.0 and DualView finds the difference
  later. Monitor takes its event from what its table did, and ES-Async, ES-Lazy and ES-NoProj
  write the row later or never, so the check does not apply there; writes that skip callbacks
  (`update_columns`, `update_all`, `insert_all`) are not checked, nor are a soft-deleted record (its
  stream ends in a destroy while its row stays, by design) and a model on another database than
  the event store; an STI record is compared by its base class, as its stream names it. Cost: a read of the row and of
  the stream and a replay per write. The benchmark campaign runs with it off.
- **`bin/rails generate lyra:install`** writes one migration with Lyra's own tables
  (`lyra_mode_transitions`, `lyra_projection_checkpoints`, `lyra_async_checkpoints`, `lyra_rights`,
  `lyra_consents`, `lyra_stream_heads`), with the definitions Lyra uses when it creates them at run
  time, and an index on Rails Event Store's `event_store_events_in_streams (stream, id)`, which
  serves Lyra's backward reads by id (Rails Event Store 3 creates it for a new event store; event
  stores created by earlier versions lack it), and one on its `event_id`, which serves ES-NoProj's
  reference links (Rails Event Store 3 creates it too; below); each only where it is missing, and on
  PostgreSQL concurrently. It also
  writes `config/initializers/lyra.rb` unless the application has one (`--skip-initializer`), and
  takes `--database` for another database's migrations path. With the migration the tables are in
  `db/schema.rb` or `db/structure.sql`, so `db:schema:load` and test databases have them, and the
  application's database role needs no right to create tables. Creation on first use stays: without
  the migration Lyra creates each table the first time it needs it, as in 1.0.0, and with it finds
  the table there and does nothing. Every statement is "if not exists", so the migration runs where
  Lyra already created the tables, leaves them as they are, and gives a `lyra_mode_transitions`
  created by an earlier version the columns later versions added; rolling it back changes nothing.
  **Upgrading:** run the generator and `bin/rails db:migrate`; the stream heads need no backfill, as
  each record's head is built from its events the first time its stream is met. A test creates
  every table both ways and compares them in PostgreSQL's catalog (columns, types, nulls, defaults,
  indexes, constraints), and loads them from a dumped `db/schema.rb`.

### Fixed
- **Hijack imports the rows that predate Lyra before a model's first use, as the event-sourcing
  modes do** (`config.genesis` `:auto`, the default). Its stream heads refuse an update of a record
  with no history, and `:auto` imported only in the event-sourcing modes: where the mode gate did
  not run (the test environment's default, a forced switch), every update of such a row in Hijack
  was refused (`MissingRecordError`). The benchmark campaign's smoke step met it in its Hijack cells.
- **Partial unique indexes are enforced in the event-sourcing modes** where their condition is one
  PostgreSQL writes back in a common form: a column `IS [NOT] NULL`, a column `=` or `<>` a literal
  (casts on either side), a boolean column alone or under `NOT`, joined by `AND`. A record outside the
  index claims nothing, and a holder outside it holds nothing, as the table's index decides; ES-Sync
  adds the index's own `WHERE` to its lookup. Before, every partial index was skipped: ES-NoProj saved
  the duplicate, and in ES-Async and ES-Lazy it reached the log and its projection met the index. A
  condition with `OR`, `IN`, a function or another column is still left to the table (named in the
  log).
- **ES-NoProj: a relation built before a write and read after it sees the write,** as Active Record's
  does (it runs its query at the first read). ES-NoProj evaluated a relation when it was built, so a
  record created or changed in between was missing from its reads and its count. A relation that has
  not been loaded is now evaluated again at its first use if a record event was appended in this
  process since it was built; a loaded one keeps its records until `reset` or `reload`, as in Active
  Record. A write of another process is seen by a relation built after it.
- **ES-Async: a record-level `touch` or `update_columns` is no longer written over by a projection
  job.** Such a write took the record's aggregate lock but not its stream's, so a job in its last
  pass (the stream's lock, the events after its checkpoint, then the row) could read the stream
  before the write, wait for its row, and then write the older value over it, with its checkpoint
  below the write's event, which no job then applied: the row stayed behind its log until the
  record's next write (the Olist replay at 4 threads, `Spree::Shipment`'s `updated_at`; an
  `update_columns` lost its value). The write now applies the events its job has not, under the
  stream's lock, before its row, as a bulk write does.
- **ES-NoProj: inserts inside `where(...).scoping { }` and on a relation take the scope's
  attributes,** as Active Record's `InsertAll` writes them in Monitor: `insert_all`, `insert_all!`
  and `insert` wrote their records without them.
- **ES-Async: a bulk write starts from the row as its stream has it.** `update_all` (an SQL
  expression such as `n = n + 1`), `update_counters`, `increment!` and `touch_all` on a record whose
  projection job had not run read the row the job had not written yet: the update pending in the job
  was lost (a log of `n` 0 → 7, then 0 → 1, where Monitor gives 8), with no error. Under the records'
  aggregate locks, the events their jobs have not applied are now applied first, under the streams'
  locks (`AsyncProjectionJob.project_pending`), as `insert_all` and `upsert_all` already did; a
  pending destroy deletes its row there, and the write leaves it out as before. Found by trace
  conformance: the ES-Async lock-order net models bulk writes that way, and the recorded
  `update_all` took the row without the stream lock.
- **ES-Lazy: a catch-up that fell back to its reader's transaction no longer hangs the readers.**
  Where no second connection is free, a read inside a transaction catches up in it, and holds the
  catch-up lock to its commit. Two ways of waiting for that lock hung, with no error, before this
  release: the same transaction's next read, once a connection was free, caught up there and waited
  for the lock its own transaction held; and a reader holding a record that the fallback's
  transaction then wrote caught up on its own connection and waited for the lock while its
  transaction waited for it in Ruby, a cycle PostgreSQL's detector cannot see. The Olist replay
  hung within a minute in ES-Lazy at 16 threads with a pool of 20 (the concurrency nets found the
  second way first: `LazyLockOrderNet`'s hang). Now a transaction that holds the lock catches up in
  place, and a catch-up on its own connection waits at most 1 s for the lock
  (`LazyProjection::OWN_LOCK_WAIT`), then runs in its reader's transaction, where a cycle is a
  deadlock PostgreSQL detects (`ActiveRecord::Deadlocked`, which the application can retry).
- **ES-NoProj's deletes no longer slow down as the event store grows.** A destroy checks its
  dependent associations through the reference links, and the lookup joined Rails Event Store's
  links table to itself by `event_id`. Rails Event Store 3's own migration indexes that column, but an
  event store set up otherwise can lack the index (the testbed's did), and the lookup then read every
  link row: on the testbed a delete took about 120 ms at 10⁵ events and about 1 s at 10⁶. The install
  migration now adds the index where it is missing, with which the same delete takes about 15 ms at
  10⁵, as at 10⁴. An application that ran the migration of an earlier 1.0.1 build adds it with
  `add_index :event_store_events_in_streams, :event_id, algorithm: :concurrently, if_not_exists: true`.
  Where it is new, the index adds one entry per link row to every append.
- **DualView reads the row without the model's default scope, and so do ES-Sync's projection
  writes.** DualView, and with it the mode gate, the sampler and `lyra:repair`, looked the row up
  through the model's default scope, so a row it hides (a soft-deleted one) was reported missing
  while its events described it; ES-Sync's projection updated and deleted through the same scope,
  so an update or a destroy of such a record left its row as it was. Both read and write the row
  unscoped now.
- **A read-modify-write under a row lock no longer loses an update in ES-Async, ES-Lazy and
  ES-NoProj.** Two transactions that each read a record with `lock!`, `with_lock` or
  `Model.lock.find(id)` and increment it could give 1 instead of 2, with no error: in ES-Async the
  row lock read a row waiting for its projection job, in ES-NoProj the lock locked nothing (there
  is no row), and in ES-Lazy the catch-up ran before the lock was granted. Now such a read first
  takes the records' aggregate locks, which every writer of them takes before its append; in
  ES-Async also the records' stream locks, under which their rows are brought up to date with
  the events no job has applied yet; then it reads (in ES-Lazy, under the row lock and the
  records' stream heads, the records behind their streams are replayed and read again). A writer
  of those records waits until the reader's transaction ends. The order (the aggregate lock, the
  stream's, then the row) is the one writes that skip callbacks take, and it removes ES-Async's
  deadlocks between `with_lock` followed by a write and a write that skips callbacks or a
  read-your-writes projection (checked on `Lyra::Verification::AsyncLockOrderNet`). A locking read
  whose keys are not known before it runs (`Model.lock.where(...)`, a `lock` with a join) reads the
  keys it selects first, without the lock, takes their locks, then runs; a record that started to
  match in between is locked and the read runs again (up to twice). In ES-NoProj a locked relation
  (`lock`, carried to what is built from it, as Active Record's is) locks its records before its
  first read and reads them again under the locks. Hijack, ES-Sync and Monitor, whose row lock is
  the lock, are unchanged. In ES-NoProj a locking read through `find_by`, which is how Rails reads `lock!`, `with_lock` and
  `reload(lock: true)` (`all.lock.find_by!(id: ...)`), locks only the records it reads, as
  `lock.find(ids)` does.

- **ES-Lazy: a checkpoint whose event is gone is no longer trusted.** An event store emptied or
  restored without `lyra_projection_checkpoints`, whose new events reached the old checkpoint's
  position, was not caught up: the guard compared positions only, so the new events below the
  position looked applied. The checkpoint now keeps the id of the event at its position (a new
  column, `event_id`, added at run time to a table an earlier version created, and by the install
  migration), and a checkpoint whose event is no longer there is started over, with a warning, as
  one past the newest event was. A checkpoint written by 1.0.0 names no event and is taken as
  before until the next catch-up moves it.
- **A record's history is now checked where its events are appended (stream heads).** Lyra 1.0.0 did
  not check that a record's operations are valid for the ORM, an assumption its correctness
  arguments make. A `create` with a live record's primary key, given or generated by a sequence
  behind the table, appended a second `Created` in ES-Sync, ES-Async, ES-Lazy and ES-NoProj, with no
  error: the table kept the old row while the log said the new one, and ES-NoProj served the new
  values. An `upsert_all` whose generated key met a live row recorded a second `Created` in every
  mode that records events but ES-NoProj. Now every replayed CRUD event Lyra appends first moves
  its record's head, a row in the new table `lyra_stream_heads`, in the same transaction:
  - a create or an import needs no live record; an update or a destroy needs a live one; a destroy
    makes it gone, and a destroyed record's key can be created again;
  - two concurrent creators of one key meet on the head's primary key: the second waits for the
    first's transaction, as on the table's own key, and is refused if that committed;
  - in Hijack and the event-sourcing modes a refused write raises before its event is stored:
    `Lyra::StreamHeads::LiveKeyError` (an `ActiveRecord::RecordNotUnique`, as plain Active Record
    raises for the table's key, so `create_or_find_by` works), `Lyra::RecordDestroyedError` or
    `Lyra::StreamHeads::MissingRecordError` (both `ActiveRecord::RecordNotFound`);
  - Monitor never refuses a write its table took: it records it, and reports a head that disagreed
    (the log, and the `lyra.stream_head_mismatch` notification) for DualView and `lyra:repair`.

  The head is a row lock, not an advisory lock, so a transaction may create any number of
  records. It is taken last before the append, after the aggregate lock and the unique-index
  locks. The log stays the authority: a head whose last event is no longer in the store (events
  deleted by hand, a test database cleaned of them) is not trusted, and a stream with events but no
  head (written before 1.0.1) gets its head from its events when first met. The table is created
  on first use; `config.stream_heads = false` restores 1.0.0's behaviour.
- **A change of a record's primary key** is refused in Hijack and the event-sourcing modes
  (`Lyra::StreamHeads::KeyChangeError`), where 1.0.0 recorded the update on the new key's stream:
  onto a live key it overwrote that other record with no error, onto a free key it began a stream
  with no create. Monitor, which records what its table did, records it as the destroy of the old
  key and the create of the new one.
- **An `upsert_all` that met a live record is recorded as that record's update**, as the database
  executed it, with its changes from the record's replayed state, where 1.0.0 recorded a create.
- **ES-Sync refuses a create whose row's key is already taken** (`LiveKeyError`), as Monitor's
  `INSERT` is refused; 1.0.0 skipped the insert and kept the event.
- **ES-Lazy: the check before a read skipped committed events below the checkpoint, the thread's
  own included.** Event ids are assigned before commit, so a write can commit below the checkpoint
  (a gap) when a later id was applied first. The check took the tables for up to date whenever the
  process had re-checked the gaps less than a second before, whether or not a gap's event had
  committed since. Such a write was invisible to reads until a later catch-up, with no error where
  it was read: a thread got `RecordNotFound` for a record it had just created, two increments from
  0 by one thread, one after the other, gave 1, `update_all` matched no row, and
  `catch_up!(force: true)` left the write out of the tables. The defect is not new in 1.0.0: 0.9.0
  has it too. Now, while gaps are open, the check asks in one more query whether the event of one
  of them is visible to the read, and catches up if so.
- **ES-Lazy: a late event under a foreign key no longer stops every read.** A catch-up applied the
  events above the checkpoint first and filled the gaps after them, by replaying each gap's whole
  record. A child above the checkpoint whose parent's create was a gap failed on its foreign key,
  and so did a replay that passed through a parent destroyed since; the catch-up rolled back, and
  every later read raised `ActiveRecord::InvalidForeignKey`, also after the gap expired. Now a
  gap's event, once visible, is applied in its place in the log's order, before the events above
  it, followed only by those later events of its record that were applied before it. A store
  already in that state recovers at the next read.
- **ES-Lazy: the check and the catch-up are no longer answered from the query cache** (in a
  request or a job). The check came from the cache, so a read could miss another connection's
  committed write until the cache was next cleared. So did the attempt to take the catch-up lock,
  so a catch-up could run on an earlier answer without holding the lock.

- **A mode set in a process after boot is no longer overridden by a switch recorded before that
  boot.** A process whose boot check does not run (every rake task, and any process with
  `mode_transition_gate = false` and `mode_sync = true`) took the latest `applied` row of
  `lyra_mode_transitions` for a new switch at its first ModeSync check. It adopted that row over a
  mode it had set itself with `config.mode =`, `projection_mode =`, `hijack_enabled =`, `disable!`
  or an `enable_*!` helper, so a benchmark that replayed Disabled in a rake task ran in Monitor and
  stored events. Now such a process notes, when it finishes booting, the latest applied switch,
  and a switch recorded up to then does not override any mode it sets after boot, including the
  one it booted in. A process that sets no mode after boot still adopts the application's mode at
  its first check, so a task or console booted with an older configuration does not write in the
  wrong mode. The configuration a code reload applies again is not a set. A switch recorded after
  the boot is adopted as before. With ModeSync on, booting costs one read-only query, which creates
  nothing and gives back the connection it opened.
- **Leaving Hijack with `config.mode =` clears `config.hijack_enabled`.** `enable_hijack!`, a switch
  into Hijack and ModeSync's adoption of one set the flag, and `mode =` never cleared it.
  `hijack_mode?` stayed true, so a process set to Disabled or Monitor still routed writes through
  events as in Hijack. Now `mode =` clears the flag when it leaves Hijack, as a switch does, and
  `enable_hijack!` followed by `mode =` follows the last call. Code that relied on the flag
  outliving `mode =` now really leaves Hijack. `hijack_enabled = true` set on its own, outside
  Hijack, still makes Lyra act as Hijack whatever `mode` says.

- **A rebuild no longer destroys rows the event log cannot restore without being asked to.**
  `Lyra::Projections::Rebuild.rebuild` (and `rebuild_all`, and `rake lyra:projections:rebuild`)
  clears the table by default before it replays the streams, and the database then applies each
  foreign key's `ON DELETE` action: the rows of another table on an `ON DELETE CASCADE` key into
  it were deleted, and `SET NULL` or `SET DEFAULT` references rewritten, with no error; rows of the
  table itself that had no stream (not yet imported) were deleted and not restored. A clearing
  rebuild now looks for both first, foreign keys from PostgreSQL's catalog, and raises
  `Rebuild::Refused` before writing anything, naming each key with its table, column, action,
  constraint and the rows it reaches, and the rows without a stream. A key counts only where rows
  reference the table; the table's references to itself and its model's own
  `has_and_belongs_to_many` join tables (restored from their link events) do not count, and the
  rows of a monitored table do, as a rebuild restores one model's table. The message says how to
  proceed: back up, import the rows without a stream (Genesis), then rebuild in place
  (`truncate: false`, `TRUNCATE=false`, unchanged) or clear anyway with the new `force: true`
  (`FORCE=1`). `Rebuild.clear_hazards(Model)` returns what a clearing rebuild would lose.
- **A mode check that rebuilds no longer changes the tables when it fails.**
  `Lyra::ModeTransition.check(rebuild: true)` (and so `to!(..., rebuild: true)` and
  `rake lyra:mode:check REBUILD=1`) rebuilt the tables, committed, then compared, so a check that
  found discrepancies, or a switch it refused, had already rewritten them. The rebuild and the
  comparison now run in one transaction (a savepoint inside a transaction already open), rolled
  back unless the check is clean; a clean check keeps the rebuilt tables and its certificate. A
  rebuild the check cannot do safely (above) raises `ModeTransition::Refused` and changes no
  table.
- **The mode gate no longer certifies a switch with a write in flight.** The check noted the event
  store's position (its highest event id) and later re-checked only the records with events above
  it. A write whose event took an id below that position and committed after it was never
  re-checked: after a gated switch from ES-Lazy to ES-Sync its record was in the log and missing
  from the table, with no error. On PostgreSQL the gate now settles each position it uses, at
  the check's start and end and at the switch: it waits until every writing transaction of the
  database running when the position was read has ended, at most `mode_transition_settle_timeout`
  seconds (new, default 30), so the catch-up, the comparison and the re-check that follow see what
  those writes committed. A write that does not end in time leaves the check unclean, with the
  discrepancy "a write in flight at the check did not end", and no certificate is stored. This
  relies on a Lyra write holding a transaction id before its event takes an id, which writing the
  record's stream head first ensures. Elsewhere the position is read as before.

### Changed
- **ES-NoProj: a uniqueness validation a unique index covers takes no lock.** Where a unique index on
  every row has exactly the validated attribute and its `scope:` columns (and the validation no
  `conditions:`, and `case_sensitive: false` only on a citext column), the validation takes neither its
  value lock nor the record's aggregate lock before it: two writers of one value may both pass it, as
  in Monitor, and the second is refused at its append by the index check, under the value's lock
  (`ActiveRecord::RecordNotUnique`, the table index's error in Monitor, where it was
  `ActiveRecord::RecordInvalid`). A failed validation there no longer holds the aggregate lock to the
  end of its transaction. A validation no index covers keeps both locks, which Monitor does not take
  (Rails' validation alone is a read, then a write).
- **ES-Lazy warns once per process when a catch-up finds no free connection** and runs in its
  reader's transaction (the fallback), naming the pool's size: that transaction then holds the
  catch-up lock to its commit, and every other reader's catch-up waits for it. A pool of twice the
  threads that read inside transactions keeps it rare. Not for a pinned connection (Rails'
  transactional tests).
- **ES-NoProj: a uniqueness validation on a column with a unique index reads its value's holders,
  not every record of the model.** Every record that ever held the value has an event in that value's
  stream (the one the unique-index check reads), so those are read and the validation's conditions
  tested on them as before: at 3,000 records a `valid?` took 0.9 ms instead of 29 ms, and a
  `create!` 24 ms instead of 70 (dev VM). Without a unique index, under `case_sensitive: false` on a
  column that is not citext, or with value links off, every record is read as before.
- **Writes cost more statements.** A create adds the head's insert and a check of its stream; an
  update or a destroy one statement on its head. The cost is measured in the 1.0.1 benchmark
  campaign.
- **An update or destroy of a record with no event history is refused** in Hijack and the
  event-sourcing modes (`MissingRecordError`), where 1.0.0 appended an event that began its
  stream. Genesis imports the rows that predate Lyra before a model's first write, so this meets
  only rows written around Lyra; import them with Genesis or `lyra:repair` first.
- **The head is a lock in every mode that records events**, also with
  `lock_aggregate_before_append` off: two writers of one record are ordered at the append. A
  comparison without any lock needs `stream_heads = false` too.
- **A soft delete is recorded as the update it is, not as a destroy.** A soft delete (paranoia's
  `paranoia_destroy`, which runs the destroy callbacks itself and keeps the row; discard's
  `discard`; a retention rule's `:soft_delete`) writes `deleted_at` (or `discarded_at`), and that
  write is recorded, as `Updated`, in every mode. The destroy callbacks it runs record nothing
  themselves, as no row was deleted. 1.0.0 recorded a `Destroyed`: the record's stream ended while
  its row stayed, so DualView, the mode gate and `lyra:repair` reported every soft-deleted record
  as a mismatch, ES-NoProj lost the record from its view where Monitor keeps it behind its default
  scope, and an update or a `restore` after it was an update after a destroy. Now the stream
  follows the row: a soft-deleted record can be updated, touched and restored, each recorded as an
  update, and a real destroy of it (paranoia's `really_destroy!`) is its destroy. The writes in a
  soft delete's destroy callbacks name its write scope as their cause, which, recording no event
  of its own, is a `SaveWithoutEffect` marker. A stream written by 1.0.0, which ends in a destroy
  while its row stays, keeps that history: a touch of it writes the row and records nothing.
- **The stream heads are kept on PostgreSQL only.** They rely on its row locks (`FOR UPDATE`) and
  `INSERT ... ON CONFLICT`. On SQLite they are not kept, and the history clauses are not enforced,
  as in 1.0.0. A head is taken on the record's own database, where Lyra keeps its event store.
- **Tests that delete the event store's rows** should delete `lyra_stream_heads`' rows too. A head
  left behind is corrected from the events before it refuses anything, but until then it orders
  writers by itself.
- **ES-Lazy: a read inside a transaction catches up on a connection of its own** (see Fixed), so
  while it does, it uses a second connection of the pool. Where none is free, or the connection
  is pinned (transactional tests), the catch-up runs in the reader's transaction as in 1.0.0, with
  1.0.0's deadlock, and holds the catch-up lock to that commit, so other readers' catch-ups wait
  for it (see Fixed for the hangs this could cause). A pool of twice the threads that read inside
  transactions keeps the fallback rare. A read that only its own transaction's events are behind replays those
  records itself and runs no catch-up.
- **ES-Lazy costs one query more per read while gaps are open,** including for the up to 300
  seconds that a rolled-back transaction's ids stay gaps. The query grows with their number: on
  a development VM, a read by id took about 0.5 ms longer with one gap and 3.3 ms longer with
  1,000, and the query alone about 22 ms with 10,000 in a store of 2 million events. With no gap
  open a read sends the same two statements as before (the check and the read), except that in a
  request or a job its check is sent every time instead of coming from the cache.
- A catch-up that cannot be applied now fails the reads that need it at once, where between
  re-checks they went on from stale tables.

### Security
- The example applications' lockfiles take the fixed releases of gems with published advisories
  (puma, rack and crass; in the Solidus case study also addressable, msgpack, net-ssh, ransack,
  rubyzip and view_component 3.27), with Ruby, Rails, Rails Event Store and Solidus unchanged, and
  the Solidus case study's canonical tag no longer builds the request's format parameter into a
  regular expression, which a `?format=` query could make fail or backtrack.

### Known issues
This release does not change these:
- ES-Lazy, ES-Async and ES-NoProj: a locking read Lyra cannot order runs as in 1.0.0: raw SQL
  (`find_by_sql` with `FOR UPDATE`), an eager-loading locking read (`lock.includes(...).references`),
  one that selects no primary key, and, in ES-NoProj, a locked relation with a window (`limit`,
  `offset`). A record that starts to match a locking read after its keys were read, more than
  twice, is left out of it (ES-NoProj) or takes its row lock before its aggregate lock (ES-Lazy,
  ES-Async), which can deadlock with a writer of it (`ActiveRecord::Deadlocked`);
- ES-Lazy: a catch-up that cannot be applied fails every read: events that no order of the log
  makes valid under the table's constraints, or one that needs an event skipped for good;
- ES-Lazy: a write whose transaction stays open more than 300 seconds after its id became a gap,
  one in flight more than 100 ids below the first event of a fresh checkpoint, and one in flight
  when the application leaves ES-Lazy without the gate (`mode_transition_gate` off, or a forced
  switch) can be missing from the tables for good;
- ES-Lazy: `eager_load` (and `includes` with `references`) loading records, `ids`, `count_by_sql`,
  a relation's `cache_version` and raw SQL do not catch up before they read;
- ES-Lazy: in `REPEATABLE READ` and `SERIALIZABLE` a transaction does not see rows a catch-up
  applied after its snapshot was taken, so it can read stale rows;
- ES-Lazy: a query repeated in a query-cache scope can be answered from that cache, as in Active
  Record.


## [1.0.0] - 2026-11-22

### Breaking
- **Lyra requires Rails 8.1: `rails >= 8.1, < 8.2`** (`lyra.gemspec`), where it declared
  `rails >= 8.0`. Rails 8.0 was never tested: Lyra is developed and tested on Rails 8.1.4.1 (with
  Ruby 4.0.10 and RailsEventStore 3.2.0), and CI tests only the lockfile. The upper bound is new
  because Lyra patches Active Record internals (relations, associations, persistence), which a
  Rails minor release may change, so a future Rails minor needs a Lyra release that is tested on
  it. The `rails_event_store ~> 3.0` and Ruby `>= 4.0` requirements are unchanged. The blog app
  asks for Ruby `>= 4.0`, Lyra's floor; no locked gem version changed.

- **A query uses every declared field it names, whatever it returns.** Purpose-bound reads checked
  record loads and `pluck`; aggregates, filters and `exists?` were not checked, so under a purpose
  that does not allow `name`, `Registration.group(:name).count`, `maximum(:name)` and
  `where(name: "Ann").exists?` answered, and `find_by(name: "Ann")` raised for Ann and returned
  `nil` for anyone else: a membership test. Now the declared fields a query names (its select or
  pluck list, the aggregated column, `group`, `where`, `having`, `order`, the conditions of
  `find_by`, class-level too, and `exists?`, a subquery, and the filter of `update_all`,
  `delete_all`, `touch_all`, `delete_by` and `destroy_by`) are checked before it runs, so such code
  under a purpose now raises `PamDsl::PurposeFieldMismatchError` (or, with no purpose under
  `reads_without_purpose :deny`, `PurposeRequiredError`). `count`, `count(:all)` and `size` name
  nothing and are not checked; `count(:name)` uses `name`. The check is split by what can be known:
  a record load has its query's fields checked without the consent step (PAM's new
  `validate_fields!`), then each record returned as before, consent included, for what it holds
  and what the query named; aggregates, `exists?`, `ids`, `pluck` and bulk writes read everyone at
  once (subject `Model$*`) and are refused under a purpose whose basis is consent. A joined
  model's declared fields are checked against its own policy (subject `Other$*`). `find_each` and
  `in_batches` check and record a query once, not per batch. ES-NoProj gives the same answers:
  its relations keep what their query named, and it no longer disagrees with Monitor on
  `exists?(hash)`. Rails' uniqueness validation and an association's `dependent:` handling when a record
  is destroyed (`:delete_all`, `:nullify`, `:delete`, the restrict options, and the lookup of the
  dependents `:destroy` destroys) run as part of the write and are not checked; `find_or_create_by`
  and an application's own `where(author_id: id).delete_all` are. In ES-NoProj a block given to
  `select` (now returning an Array, as in Active Record), `find` or `many?` sees only checked
  records; it saw the cached records unchecked. So do its association readers (`belongs_to`,
  `has_one`), `records`, `each` and `find_each` without a block, and `inspect`, which handed
  records out unchecked. A subquery or CTE reads other people, so what it names is checked whole
  (subject `Model$*`), even on the queried model; a `table.column` inside an SQL fragment belongs
  to that table's model; a column named without its table that the queried model lacks belongs
  to the joined model that has it; a condition on a `belongs_to` association names its foreign
  key; `update_all`'s SET expressions read the columns they name (`"email = name"`); the
  `returning:` columns of `insert_all` and `upsert_all` are read; and `cache_version` and
  `cache_key_with_version` are aggregates. A refused check is never remembered, and the
  application's block inside `find_each` or `in_batches` is checked each time it queries; only the
  loop's own cursor queries are checked once. The purpose and Lyra's internal-read flag are kept
  in Ruby's fiber storage, tied to their thread, so the fiber an Enumerator runs in
  (`relation.to_enum.next`) has them and another thread does not; code that read
  `Thread.current[:lyra_purpose]` uses `Lyra::PurposeBoundReads.current`. With no purpose and `reads_without_purpose :allow` the hooks return before
  looking at the query. Limits: hand-written SQL, string joins, views, functions, triggers, custom
  Arel nodes and CTEs are not seen, and an SQL fragment is matched by the queried model's declared
  names only.
- **Lyra's escape hatches are Lyra's.** `Lyra.projection_write`, `Lyra::PurposeBoundReads.internal`,
  `Lyra::Projections::ModelProjection.project` and `Lyra::Projections::Rebuild.project_events`
  switch off the checks that keep every write in the log and every read under its purpose. They now
  take a token only Lyra's own code can name, and raise `Lyra::InternalApiError` without it;
  `ModelProjection.project_create`, `project_update` and `project_destroy` are private. Application
  code that wrote without events (seeding, fixtures, a wipe whose history is not wanted) uses
  `Lyra.unrecorded_write(reason:) { ... }`. It runs the block the same way and records that it ran
  (reason, who, the caller) in the stream `Lyra::UnrecordedWrites`; `config.unrecorded_writes =
  :deny` refuses it. The token keeps code from calling them by accident; it is no barrier against
  code out to defeat it. A refused call leaves the flags of the block it ran in as they were.
- **`DualView#crud_state` reads the row as its caller does,** so under `reads_without_purpose :deny`
  it needs a purpose that allows the declared fields, as any read does; before, it read as Lyra.
  `compare`, `compare_all` and `find_discrepancies` follow it. Lyra's mode gate, the sampler,
  repair still read as Lyra. The dashboard reads under a purpose, as the application does: the
  request's `?purpose=`, else the new `config.dashboard_purpose`; a read the policy refuses answers
  403 and says how to name one.
- **PAM DSL: a purpose that declares no `basis` is `:undetermined`,** where it was `:consent`.
  The register printed such a purpose as Art. 6(1)(a), and nothing checked it, because no consent
  block asked for one. Access under it now raises `PamDsl::UndeterminedBasisError`, and the
  Article 30 register lists it as a gap, as for a purpose the policy generator writes. A policy
  that relied on the default must declare the basis it means (`basis :consent` included).

- **The Art. 15 export no longer has `processing_activities`.** `data_export`'s
  `processing_activities` listed, per event, a purpose guessed from keywords in its
  `metadata[:source]` (Lyra's events carry `lyra_interceptor` or `lyra_command_handler`, so unless
  a `metadata_proc` set another source every event read "Application functionality"), whatever
  the policy declared. The key is gone: the
  copy's purposes are `processing_context`, taken from each record's model's policy (basis,
  recipients, transfers, retention and sources per purpose). Code that read
  `data_export[:processing_activities]` reads `processing_context`. The per-subject Art. 30 method
  `GDPRCompliance#processing_activities`, and the GDPR report's key of that name, are unchanged.

- **PAM DSL: the consent grammar refuses what the Regulation does not allow, and a `:consent`
  purpose always needs consent.** On a purpose whose basis is `:consent`, `required! false` (Art.
  6(1)(a)) and `withdrawable! false` (Art. 7(3)) raise `PamDsl::ConsentGrammarError` when the
  purpose or its consent block is declared, in either order, through `define_policy` or the
  methods of `Policy`. `granular!`, recorded and never enforced, is removed: it raises
  `ConsentGrammarError`, and the consent report has no `granular` key. Access under a `:consent`
  purpose now needs an active consent whether or not a consent block is declared for it; with no
  block it passed the legal-basis check unchecked.

- **`created_at` and `updated_at` are ordinary columns, and event logs written before 1.0.0 are
  not supported.** Every event Lyra writes now carries the two timestamps like any other column
  (a create's `attributes`, an update's `changes` when they moved), DualView compares them, and
  nothing treats them specially any more. The compatibility code for older logs is gone:
  `Lyra::Event.created_attributes` no longer recovers a create's timestamps from its `changes`
  (Monitor creates written by 0.9.x left them out of `attributes`), and `ModelProjection` no longer
  stamps `created_at`/`updated_at` with the projection time when an event lacks them. An update
  that left `updated_at` alone (`update_columns`, an `update_all` that does not set it) now leaves
  it alone in the projected row too, where before a rebuild stamped the rebuild time and the row
  differed from its events. An application with a log from Lyra 0.9.x should start a new event
  store at 1.0.0 (Genesis imports the existing rows) rather than replay the old one; the per-mode
  event shapes of 0.9.x are not supported.

- **`DualView#compare` and `#calculate_differences` return `{}` when the row and its replayed
  state agree,** where they returned `{ no_differences: true }`. An agreement is now an empty hash,
  and every entry of a non-empty one has the same shape, `{ crud:, event_sourced: }`: an attribute
  that differs, or `exists: { crud:, event_sourced: }` (`true`/`false` each) when only one view has
  the record, where it was `{ exists_mismatch: true }`. That entry keeps the result non-empty, so a
  check for `{}` cannot take a missing record for agreement. Code that tested
  `differences[:no_differences]` or compared with `{ no_differences: true }` must test
  `differences.empty?`; code that tested `differences[:exists_mismatch]` must test
  `differences.key?(:exists)`. Attribute differences are keyed by column name as a **string**
  (`differences["email"]`, as Active Record keys `attributes`, and as HABTM link differences already
  were), where they were symbols; the existence entry is the symbol `:exists`, so no column, a
  column named `exists` included, can collide with it. Lyra's own callers
  (`ModeTransition`, `Repair`, `DualView.find_discrepancies`, the recommendations) and the replay
  verifiers of the BPI and Olist examples are updated.

### Added
- **The switch into ES-NoProj refuses a database foreign key it cannot honour.** ES-NoProj leaves
  the tables of monitored models empty: their records live in the event log. A database foreign
  key from a table no monitored model writes into such a table (an unmonitored `Match` whose
  `registration_id` references `registrations`) therefore made every write there that sets the
  column fail with `ActiveRecord::InvalidForeignKey`. `Lyra::ModeTransition.to!` into ES-NoProj now
  refuses such a constraint up front (`ModeTransition::Refused`, as for a default scope ES-NoProj
  cannot evaluate), naming the referencing table and column, the referenced table, the constraint
  and the loaded models that write the table, and the fix: drop the constraint
  (`remove_foreign_key :table, name: "..."`) and keep the reference in the model (`belongs_to`
  validates it), or monitor the referencing model. `force: true` switches anyway. Foreign keys
  between monitored tables, and from a monitored table into an unmonitored one, sit on a table
  that gets no rows in ES-NoProj and pass. The check reads `connection.foreign_keys` for each
  table of each database the monitored models use, at the switch only
  (`Lyra::Projections::ForeignKeys.blocking(models)`). ES-NoProj set by configuration at boot
  (`config.projection_mode = :disabled`, which no switch gates) now gets a warning
  (`Rails.logger.warn`, else `Kernel#warn`) for each such constraint and each default scope
  ES-NoProj cannot evaluate, for the models enrolled by then (with eager loading, all of them);
  the boot goes on, as for a retention rule that cannot act. `Lyra::ModeTransition.check_es_noproj!`
  runs that check on demand and returns the warnings.
- **A warning for a retention rule that can never act.** `:soft_delete`, PAM's strategy for a
  rule that names none, sets `deleted_at` or `discarded_at`; on a table with neither,
  `Lyra::Retention` skipped every record past its period and kept it, and said so only in each
  action's `detail`. Lyra now warns (`Rails.logger.warn`, else `Kernel#warn`), naming the model,
  its policy and rule, and the fix (add the column, or `on_expiry :anonymize` or `:hard_delete`):
  at boot for the models enrolled by then, and in each run that skips records for it, once per
  model, not once per record. `Lyra::Retention.check_rules!(models:)` makes the boot check on
  demand and returns the names of the models it warned about. Nothing else changes: the records
  are still skipped, and only models with a rule of their own are acted on (the policy's
  `default` period is not executed; now documented).
- **`config.record_touches`: keep timestamp-only touches out of the log, in Monitor.** An instance
  `touch`, a `touch_all` and a `belongs_to ... touch: true` cascade each append an event, and an
  application that touches a lot fills the log with writes that change only `updated_at` (on the
  Olist replay through Solidus, cascades touching orders and shipments). `true`, the default,
  records every touch as before. `false` leaves out a touch whose only changes are the model's
  update timestamps (`updated_at`, `updated_on`); a touch that also changes another column
  (`touch(:completed_at)`, a `lock_version` increment) is recorded in full, and so is an explicit
  `update_all(updated_at: ...)` or `update_columns(updated_at: ...)`, which are not touches.
  DualView, and with it the sampler, the gate's check and `lyra:repair`, then takes a difference
  confined to those columns as agreement; a difference in any other column is reported with the
  timestamps beside it. Monitor (and Disabled) only: Hijack and event sourcing take the log as the
  record of every change and rebuild rows from it, where a missing touch would rebuild a stale
  `updated_at`, and Hijack passes into event sourcing without a check. So `record_touches =
  false` raises `ArgumentError` in those modes, and while it is false `mode=`, `hijack_enabled =
  true`, `ModeTransition.apply_label` and an ungated `enable_hijack!` or `enable_event_sourcing!`
  raise `ArgumentError`. A process with the option off registers in `lyra_mode_transitions` (kind
  `touch_skipping`: host, pid, since, Lyra's version, last seen; `Lyra::TouchRegistry`) before it
  leaves a touch out, refreshes the entry at most every 60 seconds from the touch path and
  ModeSync's check, ends it when the option is set back to `true` and at exit, and logs a warning
  once. An entry not refreshed for 180 seconds (the database's `clock_timestamp()`) is no longer
  live. Registry writes never join the caller's transaction: each commits on its own, on a second
  connection when the caller's is in a transaction (checked out for at most one second, with a
  two-second `lock_timeout`); when none can be had, the touch is recorded. Each takes the
  registry's advisory lock and re-reads the application's mode under it, and a switch takes the
  same lock for its last look at the registry and its record (a check for its last look and its
  certificate), so a registration and a switch are serialized: either the switch is refused, or the
  registering process ends its entry, records the touch and is fenced. While this process has the
  option off or any process has a live entry, every way into Hijack or event sourcing is refused
  with `ModeTransition::Refused`, naming the processes and the way up: `ModeTransition.to!` (`force: true` included, and so the gated
  `enable_*!` helpers), `check` (at its start and before it certifies; `rake lyra:mode:check`
  prints it and exits non-zero), ModeSync's adoption (the switch stays unseen, and is adopted once
  the entry has ended or expired) and a boot into such a mode; `rake lyra:mode:status` lists the
  live processes. No certificate issued before an entry's latest refresh or end is taken. A process
  with the option off does not boot into an application whose mode is Hijack or event sourcing,
  cannot set the option false at runtime in one, and one that finds itself in such a mode later is
  fenced: each ModeSync check raises, and so does every touch it would have left out, with the save
  that cascades it. `Lyra::Projections::Rebuild.rebuild` is refused (`Rebuild::Refused`) with the
  option off or a live entry, since it would set every touched row
  back. To escalate: restart every process with the option on, run `lyra:repair` in Monitor (the
  check then sees the stale timestamps; the repair records them, one `Updated` event per record),
  then switch. A row with no stream that is touched with the option off is imported by Genesis as
  it then is. Strict mode is unchanged (a `touch` is allowed, `touch_all` refused as
  `update_all`). An unrecorded touch has no event, so no event names it as its cause.
  `LYRA_RECORD_TOUCHES=false` sets it in the Solidus example. Accepts `"true"`/`"false"` strings.
  On 200 Olist orders replayed through Solidus in Monitor, the log falls from 8,691 events (2,547
  of them touches) to 6,331; the 187 touches left are order completions (`touch(:completed_at)`),
  and the oracle (197/200 orders, as in Disabled), the mails and DualView (1,575 records, no
  discrepancy) are unchanged.

### Fixed
- **Every `causation_id` Lyra gives names an event in the log.** A write's scope fixed its event
  id before its callbacks ran, and the writes they made recorded it as their cause. A save that
  changes nothing records no event (see Changed), so its callbacks' writes named an event that
  never existed: replaying 200 Olist orders through Solidus, 203 of 793 causation ids in Monitor,
  ES-Sync and ES-NoProj alike, each a `LineItemUpdated` inside an `Order#save` with nothing to
  change, which still saves its line items (has_many autosave). A write is now the cause of the
  writes made after its own event is in the log; when it records none, they take the cause that
  was in scope when the write began. The writes its `before_*` callbacks make (a `belongs_to`
  autosave, a `dependent: :destroy`) come before anyone knows and name the write, as before. A
  save that changes nothing still records nothing in its stream; when a write made in its
  `before_*` callbacks names it as cause, Lyra records a `SaveWithoutEffect` marker with its id in
  an internal stream, `Lyra::SavesWithoutEffect`, in the write's transaction. So it does for every
  write that ends without its event in the log after naming it: an update or destroy that reaches
  no row (Monitor's stale copy), an aborted save, a command refused after the id was taken
  (Hijack, event sourcing), a write whose Monitor append failed, and a write that raised, which a
  caller may rescue inside an enclosing transaction and commit (then in a savepoint, best effort).
  The marker holds the model, the record's key, the operation and the reason (`no change`,
  `no row`, `not saved`, `append failed`), no attribute value, and `replay: false`; replay, the
  projections, ES-Lazy's catch-up, DualView, the dashboard's event window and the subject reports
  pass it over. A write's scope now wraps its whole save or destroy callback chain, a model's own
  `after_save` and `after_destroy` included: it opens around `create_or_update` and `destroy`, and
  around a destroy chain an application runs itself with `run_callbacks(:destroy)` (a soft delete,
  such as paranoia's). As an `around_save`/`around_destroy` callback it had closed before them
  (Active Model prepends `after_*` callbacks), so their writes (Solidus's `Payment#update_order`)
  had no cause and opened a correlation of their own. Bypass writes (`touch`, `update_columns`)
  and jobs created during a write take their cause the same way. An access-log entry, which
  commits on its own connection and outlives a write that rolls back, names no write in scope: its
  cause is the one from outside every write scope (`Lyra::Causation.outside_write_scopes`), and
  its correlation ties it to the writes. `Lyra::Causation.integrity` reports the causation ids
  that name no event in a store; none do once the transactions commit, except a cause the
  application sets itself and an append lost under Monitor's log-and-continue policy. The
  correlation id the outermost write opens is still its event id when it records nothing: a
  correlation id is a group's label, not a reference.
- **Hijack no longer keeps the event of a row write that failed.** Hijack appends a write's event
  before its row write. On a model with optimistic locking the row write can raise
  `StaleObjectError` after the append, and a caller that rescued it inside an enclosing
  transaction committed an `Updated` (or `Destroyed`) for a write that never happened: the log and
  the row parted, and DualView reported the record. The append and the row write now share a
  savepoint, which takes the event with it when the row write raises. The row lock taken before
  the append is still held to the end of the transaction when the write succeeds. Models without
  optimistic locking take no savepoint: their row write does not raise for a row that moved.
- **DualView on a model without `created_at` or `updated_at`.** `DualView#crud_state` read both
  whatever the model had, so a model with only `updated_on`, or no timestamps, raised
  `NoMethodError` in DualView, the mode gate's check and `lyra:repair`. Its `timestamps` now hold
  the model's own timestamp columns (`timestamp_attributes_for_create_in_model` and
  `..._for_update_in_model`), none for a model without.
- **ES-NoProj refuses an Active Record relation's condition it cannot read, instead of skipping
  it.** A named scope called on a relation, a relation passed to `merge`, and a default scope are
  read as hash conditions on the model's own columns. An equality or `IN` whose left side was not
  a column was skipped: `scope :p, -> { where(Arel.sql("lower(name)").eq("pear")) }` called as
  `Item.where(...).p` returned every record the other conditions selected, and a default scope
  made only of such a condition was taken as evaluable and not applied. A column of another
  table was read as the model's column of the same name, a right side that is not a value
  (another column, an SQL literal) was compared as if it were one, and a column named twice
  (`where(qty: 2).where(qty: 5)`) kept only the last condition. Each now raises
  `UnsupportedQuery`, except the column named twice, whose conditions are both applied, as SQL
  does. Orders likewise: an order on another table's column (`"posts.title"`, an Arel attribute
  of another table) sorted by the model's column of that name, and a direction other than `asc`
  or `desc` (`order(qty: "desc nulls last")`) sorted ascending; both are refused.
- **ES-NoProj's `exists?(false)` and `exists?(nil)` are `false`, as in Active Record.** They
  answered whether the relation had any record.
- **ES-NoProj's `limit!` limits the relation it is called on**, as Active Record's; it returned a
  limited copy and left the relation whole. The bang query methods it does not implement
  (`offset!`, `reorder!`, `distinct!`, `group!`, `none!`, ...) are refused, as before.
- **ES-NoProj's `only` keeps the parts named and drops the rest, as Active Record's**
  (`only(:where)` keeps the conditions and drops the order, limit, select and group; `only(:order)`
  orders every record). It returned the relation unchanged, its order and limit kept. The
  conditions and order are taken off as `unscope` takes them off; `only` of a joined relation
  without its joins is refused (`UnsupportedQuery`).
- **ES-NoProj's pagination is Kaminari 1.2.2's.** `page(n)` is `limit(size).offset((n - 1) *
  size)`, the size the model's `paginates_per` (else Kaminari's `default_per_page`, else 25), or its
  `max_paginates_per` when that is smaller; a page number below 1, `nil` or not a number is page 1.
  `page(n)` without `per` answered with every record, and the maximum was not applied. `per(m)` is
  the page of that size with the same number, at most `max_per_page:`, the relation's
  `max_paginates_per(n)` (kept on the relation; it set the model's) or the model's; `per(nil)`, a
  negative or a non-numeric size keep the page as it is (they gave an empty page). `padding`,
  `next_page`, `prev_page`, `first_page?`, `last_page?`, `out_of_range?`, `total_pages` and
  `current_page` are Kaminari's (the first five were missing), as are, on a page only,
  `entry_name` (`page_entries_info`'s), `without_count` (its `last_page?` and `out_of_range?`
  look at the page; `total_count` raises Kaminari's error) and the deprecated `current_per_page`.
  `total_count` and `total_pages`
  count the records the relation selects before the window, through the same purpose check and
  rights as any count; they counted the page's records, so a paginated list showed one page of
  one. `Model.page(n)`, Kaminari's own, gives the same page: the relation answers what Kaminari's
  relation modules define (extending it with them was refused when read). `page` no longer
  changes the relation it is called on.
- **ES-NoProj takes a limit or offset after the relation's conditions and order, as SQL does.**
  A `where`, `where.not`, `order`, scope, `merge`, `select` or `unscope` called after `limit` or
  `offset` acted on the window's records (`Model.order(:code).limit(2).where(status: "draft")`
  filtered the first two records); it now applies before the window. A second `limit` or `offset`
  replaces the first (`limit(1).limit(3)` is three records, `limit(2).offset(1)` records 2 and 3);
  they applied to the window. `limit_value` and `offset_value` are the values given, as in Active
  Record (`limit_value` was the page size, `nil` after `limit`; `offset_value` was 0 without an
  offset). `find`, `find_by` and `exists?` with a condition on a window apply the condition first
  and keep the window's offset, as Active Record's `where(...).take` does. `sum`, `average`,
  `minimum` and `maximum` of a window are Active Record's: its one aggregate row, which the window
  keeps (the aggregate over every record the relation selects) or leaves out (an offset, a limit of
  0: `0` for `sum`, `nil` otherwise); they were computed over the window's records. `or` of two
  windows needs the same window, as in Active Record (an `ArgumentError` otherwise). A grouped
  aggregate of a window, which Active Record limits to some of the groups, is refused. Under a
  right in force, a window's count, pluck, ids, exists? and batch sizes are taken from the records
  the right does not leave out, as SQL takes LIMIT and OFFSET after its WHERE (the window was
  taken first, and then shortened by a record left out of it). `find` with
  several ids (`find(a, b)`, `find([a, b])`) is Active Record's, window included; it raised
  `ArgumentError`.
- **ES-NoProj's `or` returns the records in the relation's order** (else by primary key), each once;
  it returned this relation's records, then the other's.
- **ES-NoProj's `reselect` replaces the selected columns, a second `select` adds to the first, and
  `unscope(:select)` and `unscope(:group)` take them off, as in Active Record.** `reselect` did
  nothing and a second `select` replaced the first, so the records came back without the columns
  asked for (`MissingAttributeError`); `unscope(:select)` and `unscope(:group)` were ignored.
  `select` and `reselect` with no column raise Active Record's `ArgumentError`. The relation's
  plan (what `unscope`, `rewhere` and `only` replay) now survives `select`, `group` and
  `create_with`, and a replay keeps them.
- **ES-NoProj's `unscope(:where)` of a relation filtered by an SQL fragment is refused** (`Model
  .where("qty > ?", 2).unscope(:where)`); it kept the fragment's condition. `where.not` now
  continues the relation's plan, so `unscope`, `rewhere` and `merge` can take it off, as Active
  Record does (they were refused after it). `unscope(where: :owner_id)` takes off a condition
  named by its `belongs_to` association (`where(owner: ann)`); it was kept.
- **ES-NoProj's `distinct` of selected columns (`select(:status).distinct`, `SELECT DISTINCT`) is
  refused**, in either order and through `merge`: its rows are distinct values, not records, and
  it answered with the records.
- **ES-NoProj batches as Active Record does.** `find_in_batches`, `find_each` and `in_batches` go
  by primary key (or the `cursor:` columns, in `order: :asc` or `:desc`, from `start:` to `finish:`),
  whatever the relation's order (logged, or `ArgumentError` with `error_on_ignore: true`), keeping its
  limit; they followed the relation's order and took no options. Each `in_batches` batch is the
  relation narrowed to the batch's records, in the relation's order (`load: true`: the batch's
  records). `in_batches` without a block returns Active Record's `BatchEnumerator` (`each`,
  `each_record`, `update_all`, `delete_all`, ...); it raised `LocalJumpError`. The enumerators of
  `find_each` and `find_in_batches` have Active Record's sizes. Counted (those sizes, and
  `in_batches`' batches of keys), the records leave out those a right in force leaves out, before
  the relation's limit, as a count does; a restricted record was counted. Loaded (`find_each`,
  `find_in_batches`, `in_batches(load: true)`, `each_record`, or a batch's records), each is
  checked as a load is, and a restricted record raises, as in Active Record. The batches of a
  relation with no conditions are ranges of keys, as Active Record's are (`use_ranges:`), so a
  record the keys left out is in one, and loading that batch raises as Active Record's does.
  Batches of a relation with an offset are taken as Active Record takes them: it applies the
  offset to each batch's query (see below).
- **An ES-NoProj bulk write writes what its relation selects when it is called, as Active Record's
  does, and no longer brings back a record destroyed since.** A relation, and each batch
  `in_batches` yields, held the records it selected when it was built, loaded or not, and
  `update_all`, `delete_all`, `touch_all`, `destroy_all`, `update_counters` and `update` wrote
  those. A record deleted in the meantime (by another relation's `delete_all`, a `destroy`, an
  erasure, or during an `in_batches` loop) got an `Updated` event after its `Destroyed` and read
  as live again, so a stale relation could undo a delete or an erasure; `delete_all` appended a
  second `Destroyed`; `destroy_all`, `update` and `update!` raised `Lyra::RecordDestroyedError`
  part-way. A record changed or created since was written or left out by the old selection, and a
  window was not taken again: `order(:code).offset(1).limit(3)`, after one of its records was
  deleted, wrote the two it still held where Active Record writes the next three. A relation now
  keeps how it was built (`Lyra::Projections::Rebuildable`): where it started (every record of
  the model, a foreign-key lookup, an association, a `:through` association with no association
  scope on the way, its default scopes kept as they were built) and the query methods called on it since, with their arguments
  copied when they were called, so that a caller changing an array, hash or string afterwards
  does not change what the write selects, as it does not change Active Record's query. A scope or
  class method called on the relation is the application's code and is not run again: what it
  built is recorded as the query methods it called, with the values it used then (`Time.current`,
  the ids it plucked), as Active Record binds them. A step that changes no selection (`extending`,
  `includes`, `readonly`, ...) is not recorded; one with another block, or an argument that cannot
  be copied, leaves the relation without a recipe. `unscope`, `rewhere`, `except` and `only`,
  which rebuild the relation from its plan, keep the recipe that rebuild records (where the plan
  started, read again), so they too select at write time; they wrote the records the plan held
  when the relation was built, with their old values. A write builds the relation again from the
  event store: the aggregate locks of the records it holds are taken, the lock a single record's
  update or destroy takes, all or none (`Lyra::AdvisoryLock.xact_lock_all`: tried without waiting
  in one statement; when one is held, the others are given back and the next try first waits for
  that one, so two writers over overlapping records wait for each other instead of deadlocking),
  then the selection is read; a record that came to match since is locked in turn and the
  selection read again (up to four times, after which a record not yet locked is left out, as if
  it had matched after the write). A destroyed record is not in the selection. The count returned
  is Active Record's. A relation keyed by primary key (`where(id: ...)`) is read again by those
  keys only. `destroy_all`, `update` and `update!` load the selection as Active Record's do, or,
  once the application has loaded the relation (`to_a`, `each`, ...), work on the records loaded,
  as Active Record's do: there a record destroyed since is left out of `destroy_all` (Active
  Record also runs `destroy` on it, reaching no row, and returns it) and takes `update`'s
  attributes in memory without being written. `destroy_all` delivers its records as a load does,
  so a record under a restriction raises `RestrictedProcessingError` before any is destroyed, as
  in Monitor; it was destroyed. It checks each record under its lock before its destroy, which
  checks again after its `before_destroy` callbacks (one that deletes the record is refused with
  `Lyra::RecordDestroyedError`, and rolled back). Each batch of `in_batches` is the relation
  narrowed to the batch's keys, as in Active Record, so a record of a later batch that no longer
  matches is not written by the batch's bulk write (and the batches are read as the loop reaches
  them: see below). A relation without a recipe (made from given records, such as a
  `dependent: :delete_all` or `:nullify`'s children, or from a scope or argument that could not
  be recorded) writes the records it holds, less those whose streams end in a destroy, read under
  the same locks (`Lyra::StreamTail.destroyed_streams`: one query for all of them where each last
  event is a create or an update). The cost is on writes only: one locking statement (in a
  savepoint) and one read of the selection per bulk write, the read of the records with the given
  keys for a keyed relation; one read of the streams for a relation without a recipe;
  `destroy_all` adds two locks and two stream reads per record. On 2,047 records, a
  `where(id: x).update_all` takes about what it took (165 ms against 156), a `where(code: ...)`
  one about three times (one more read of the model's records at the write). Reads are unchanged
  but for recording each query method's call. With `lock_aggregate_before_append` off nothing is
  locked or checked, as for a single record. ES-Sync, Hijack and Monitor write through SQL and
  were not affected; for ES-Async and ES-Lazy, see below.
- **ES-Async bulk writes leave out a row whose destroy is waiting for its projection job.** The
  row stays in the table until the job runs, and `update_all`, `delete_all` and `touch_all` wrote
  it and appended an `Updated` after the `Destroyed` (or a second `Destroyed`), bringing the record
  back. The write now reads the keys it matches, takes their aggregate locks (all or none), then
  locks the rows (and Genesis admits rows that predate Lyra), reads the rows' streams in one query
  and leaves out a destroyed record's row from the write, the events and the count, as Active
  Record's reaches no row of it. A row that came to match while the locks were taken gives the row
  locks back and the keys are read again (up to three times). `dependent: :nullify` leaves out a
  destroyed child the same way: no event, and its row is not written. The same
  `bulk_write_lock_limit` applies. On 1,000 rows the write costs what it did (4,013 queries against
  4,005, 3.05 s). For ES-Lazy, see below.
- **A record's locks are taken in one order: its aggregate lock, then its row.** ES-Async's and
  ES-Lazy's writes through callbacks take the aggregate (advisory) lock only, Hijack's and
  ES-Sync's the row's only; the writes that skip callbacks (`update_columns`, `touch`, `delete`,
  ES-Async's `update_all` and `delete_all`) and an erasure now take the aggregate lock first, then
  write or lock the row. An erasure took the row first, and with the checks above a bulk write
  took the rows first too, which deadlocked against a write holding the aggregate lock (an ES-Async
  `update_all` against concurrent `update_columns`: 232 deadlocks in 300 writes; none now). The
  order is written down at `Lyra::AdvisoryLock`.
- **A stale copy's `update_columns`, `touch` and `delete` no longer bring back a destroyed record
  or log a second destroy.** A copy read before another copy, a relation's `delete_all` or an
  erasure destroyed the record recorded an `Updated` after the `Destroyed` (`update_columns`,
  `touch`) or a second `Destroyed` (`delete`), in ES-NoProj, ES-Async and ES-Lazy, and `delete`
  did in Monitor, Hijack and ES-Sync as well. In the first three they now read the record's stream
  under its aggregate lock first; elsewhere `delete` locks the row first. When the record is gone
  they record nothing and return what Active Record returns for a row already gone: `false` from
  `update_columns` and `touch` (the attributes are set in memory), the frozen record from
  `delete`. A row still in the table (in ES-Async, before the destroy's job deletes it) is not
  written either: Active Record's own write runs in a savepoint that is rolled back.
- **ES-NoProj's class-level counters write the record.** `Model.increment_counter`,
  `decrement_counter`, `update_counters(id, ...)` (with `touch:`) and a record's `increment!` and
  `decrement!` went to Active Record's SQL on the empty table: they returned 0 and recorded no
  event. They now write as a relation's `update_counters` does (locks, the counters' current
  values, an event per record), reading only the records with those keys, and return the number of
  records written. With optimistic locking the lock version moves too, as Active Record's
  `Locking::Optimistic.update_counters` moves it, so a copy read before raises `StaleObjectError`
  on save. A counter cache, which Active Record's associations keep through these, is still left
  as it is: ES-NoProj does not keep counter caches.
- **ES-NoProj's `update_counters` on a relation adds to the counters' current values, and two of
  them no longer deadlock.** It added to the values the relation had read, so an update made since
  (`update!(qty: 100)`, then `+1` gave the old value plus one, not 101) or a concurrent increment
  was lost (two threads, 25 increments each over seven records, ended 175 short); Active Record's
  SQL (`qty = COALESCE(qty, 0) + 1`) adds to the row as it is. It also wrote one `update_all` per
  set of current values, each taking its records' locks, so two writers whose relations ordered
  the records differently took them in opposite orders and deadlocked (30 of 50 calls). It now
  takes every selected record's lock (all or none), reads the counters from the event store under
  those locks, and writes the groups without locking or reading again.
- **`config.bulk_write_lock_limit` (default 5,000) caps the records one bulk write locks.** An
  ES-NoProj bulk write (`update_all`, `delete_all`, `touch_all`, `update_counters`, a `dependent:
  :delete_all` or `:nullify`, and a `destroy_all` inside a transaction already open), and an
  ES-Async or ES-Lazy `update_all`, `delete_all` or `touch_all`, holds one advisory lock per record until its
  transaction ends, and PostgreSQL's lock table is shared by every session: past about 12,800
  locks with the default `max_locks_per_transaction` and `max_connections` 100 (about 23,200 with
  200), every session's writes failed with "out of shared memory". A larger write now raises
  `Lyra::BulkWriteLockLimitError` (its `count` and `limit`) before it locks or writes anything,
  and a parent's destroy whose dependent write is refused rolls back. Write in batches
  (`in_batches(of: n) { |batch| batch.update_all(...) }`), each of which commits and gives its
  locks back on its own, but not inside a transaction already open, which holds them all until it
  ends; `nil` removes the limit.
- **ES-Lazy writes that skip callbacks see a destroy committed after their catch-up.** A bulk
  write (`update_all`, `delete_all`, `touch_all`), `update_columns`, `touch`, `delete` and a
  `dependent: :nullify` bring the tables up to date and then write; a destroy committed in
  between left its row in the table, and the write wrote it and appended an `Updated` after the
  `Destroyed` (or a second `Destroyed`). They now take the records' aggregate locks after the
  catch-up and read their streams (as in ES-NoProj and ES-Async), leaving such a record out, and
  replay onto its row each record whose stream has an event the tables have not had yet, so an
  update committed in between is the row the write starts from (it was lost under the write, or
  `update_all("tag = tag || ...")` read the old value). The
  write's own reads no longer catch up again: a catch-up there waited for the catch-up lock while
  the write held rows that a catch-up running elsewhere waited for, a deadlock that bulk writes
  and writes that skip callbacks met against catch-ups under load before 1.0.0 too (9 in a run of
  a bulk write, writes through and past callbacks and a catch-up in a loop, against none to 1
  now: a catch-up writing rows in the log's order and a bulk write locking them in the table's can
  still meet on rows alone). A catch-up that a catch-up under way refused no longer clears the
  under-way flag of the outer one.
- **ES-NoProj's batches are read when the loop reaches them, as Active Record queries each.**
  `in_batches`, `find_in_batches` and `find_each` on a relation that can be built again (see
  above) read each batch then: the records after the last batch's last cursor values, in cursor
  order, from `start:` to `finish:`, `of` of them, so a record inserted, changed or deleted during
  the loop is seen as Active Record sees it (a later batch no longer yields a record deleted or no
  longer matching, and yields one inserted). `use_ranges`, `order: :desc`, `load: true`,
  `each_record`, a custom cursor and the rights (loads raise, counts leave out) are as before. A
  relation with no recipe takes its batches from the records it holds, as before.
  Each batch costs one read: where the relation starts from every record of the model and the
  cursor is the integer primary key, of the model's keys and then of the next records by key (about
  the batch's own cost); otherwise of the whole relation. Locally, `in_batches(of: 1000)` over
  10,000 records takes 2.8 s against 1.3 s (one read of every record up front), `find_each` 2.3 s
  against 0.9 s.
- **ES-NoProj's batches of a relation with a limit or an offset are read as the loop reaches
  them, and take the limit and offset as Active Record does.** They read every record up front,
  and an offset was refused. Each batch is read when the loop reaches it, as above; a limit stops
  the loop after its records (a batch reads `of` records, or what is left of the limit when that
  is less), and the offset skips that many records after the last batch's cursor in every batch's
  query, as Active Record applies `OFFSET` to each (`offset(1).find_each(batch_size: 2)` skips a
  record before each batch). An `in_batches` batch is the relation narrowed to the batch's keys
  with its limit and offset, as Active Record's `rewhere(cursor => values)` is, so the offset
  skips records of the batch again, and its writes select so at write time (a batch's keys were
  those of its window); a batch of a relation that starts from every record of the model is
  built again from its own keys (`Rebuildable::Keyed`), not from every record. An
  `in_batches(load: true)` batch holds the records read for it; its query methods, aggregates,
  finders (`find_by`, `find`, `find_or_create_by`, `find_sole_by`, ...) and `update_all`,
  `delete_all` and `touch_all` are that narrowed relation's, read again from the event store each
  time, as Active Record's batch keeps its query and runs it (`CachedRelation#query_relation`).
  Active Record's batch query of a relation with an offset has no `ORDER BY`, so which records
  it skips is the database's plan (an index scan, or the table's physical order after an
  update): `in_batches` of such a relation without an order raises `UnsupportedQuery`, and so do
  the queries of its `load: true` batches (their records are read in cursor order, and given);
  `find_each` and `find_in_batches`, ordered by the cursor, answer. `in_batches(use_ranges:
  true)` with an offset raises it too (each range is read with the `OFFSET` and no `ORDER BY`),
  and with `limit(0)` (Active Record's query has `OFFSET -1`, which the database rejects). The
  enumerators' sizes take the offset too. The batches of a loaded relation (after `load`, `to_a`,
  `each`, ...) are its loaded records, from `start:` to `finish:`, in cursor order, as Active
  Record's are; they were read again. Each `in_batches` batch of it is loaded with its records,
  and its query methods, aggregates, finders and `update_all`, `delete_all` and `touch_all` are
  the relation's, as Active Record's batch is the relation loaded with them (each batch's
  `update_all` writes every record the relation selects); `destroy_all` and `update` work on the
  batch's records. The batches read by key took every record a step brought in: an `or` (whose
  other relation is read whole) gave records of other chunks and from before the cursor, so a
  batch repeated records and, without a limit, `find_each` and `find_in_batches` never ended
  (since the batches were read as the loop reaches them, above). Each chunk now keeps only its
  own records, which a step keeps or leaves out as it would among every record; `distinct` and
  `group` are read whole. Cost, locally, 10,000 records: `limit(5000).find_each(batch_size:
  1000)` takes 1.36 s against 0.84 s (11 queries against one read of every record up front),
  `in_batches(of: 1000)` 1.34 s against 0.85 s, as the batches without a limit cost (one read
  of the keys and one of the batch's records per batch); `find`, `where`, `to_a`, `count` and
  `first` are unchanged (same queries, time and allocations).
- **ES-NoProj's `load`, `reload`, `reset` and `loaded?` answer as Active Record's.** They raised
  `UnsupportedQuery`. `load` loads the records as any read delivers them (the purpose check, each
  record checked, a restricted one raising `RestrictedProcessingError`), passes each to its block,
  and returns the relation, `loaded?` true after (before: false on `Model.all`, nil on a relation
  derived from another, as in Active Record); a relation loaded already is not loaded again.
  `reset` reads the relation again from the event store (Rebuildable), as a relation built at that
  moment, and leaves it not loaded; `reload` is `reset` and `load`. A relation that cannot be
  built again (one of given records) raises `UnsupportedQuery` there. A loaded relation's reads
  do not read again, its `destroy_all` and `update` work on its loaded records and its
  `update_all`, `delete_all` and `touch_all` select at write time, as before and as in Active
  Record. `destroy_all` then resets the relation, as Active Record's does: it no longer holds the
  records it destroyed (it held them, still loaded). A bang query method (`where!`, `order!`,
  `limit!`, ...) on a loaded relation raises `ActiveRecord::UnmodifiableRelation`, as in Active
  Record; it changed the loaded records. `DeferredRelation#loaded?`, which said whether an
  association's records had been read, is `records_read?`.
- **ES-NoProj's `find_or_create_by` and `find_or_create_by!` create as `create_or_find_by` does,
  as Active Record 8.1's.** A record a unique index of the table would conflict with is found
  (or, outside the relation, `RecordNotFound`) instead of created again.
- **ES-NoProj's `excluding`, `without` and `in_order_of` are query methods, as Active Record's.**
  They were Enumerable's, which returned an Array, so a write on them raised `NoMethodError`.
  `excluding(*records)` (and `without`) is `where.not(primary key: ids)` of the records and of the
  relations given; a record or relation of another model raises Active Record's `ArgumentError`.
  `in_order_of(column, values, filter: true)` is a `where` of the column (`IS NULL` for `nil`; no
  `where` with `filter: false`), which `rewhere`, `unscope(where: ...)`, `unscope(:where)` and
  `except(:where)` take off as in Active Record, and an order by the column's position among the
  values after any order the relation has, as Active Record's `CASE` added by `order!`, which
  `unscope(:order)` and `reorder` take off; the values are cast as Active Record casts them (an
  enum's label to its value, one the column cannot hold left out, `nil` a position of its own),
  and none left is `none`. The column may name the model's table (`"items.code"`); an SQL
  expression raises `UnsupportedQuery`. Both keep the relation's recipe, so `update_all`,
  `delete_all`, `touch_all` and `destroy_all` on them select at write time, with a limit, offset,
  `where` or order chained before or after.
- **ES-NoProj's `merge` takes the other relation's conditions where both name a column, and its
  further arguments as options, as Active Record (7 and later) does.** `where(status: "active")
  .merge(where(status: "draft"))` is the draft records; it was the records with both, none. A
  condition named by a `belongs_to` association (`where(owner: ann)`) is one on its key. This
  relation's conditions on such a column are taken off as `unscope` takes them off, a `where.not`
  and an earlier merge included; where they cannot be (after an SQL fragment or a join, an
  association's key, a condition on several columns at once, `where([:a, :b] => ...)`, or an `or`
  of conditions on that one column) the merge is refused. An `or` over different columns is kept,
  as Active Record keeps it. `merge(r1, r2)` intersected with `r2` too, and `merge(r, rewhere:
  true)` was refused; both are now `merge(r1)`. `merge(nil)` and `merge(false)` raise
  `ArgumentError` (they returned the relation), as does a value that is not a relation; `merge`
  of an Array is the loaded records both have, and of a Proc the Proc run on the relation. The
  other relation's limit and offset (an event-store relation's window, or an Active Record
  relation's) replace this one's, its group and select columns are added, its distinct taken and,
  if it reorders, its order replaces this one's; they were dropped (an Active Record relation's
  limit was taken inside this one's). A relation joined on one side, or both to the same
  associations, merges as the join's rows (it was refused); a condition on a joined table that the
  other relation names too, and relations joined to different associations, are refused.
- **ES-NoProj's `relation.update(id, attributes)` and `update!(id, ...)` are Active Record's
  `Model.update(id, ...)`:** the model's record with that id is found and written through the
  model's own read and write paths (its default scope, the purpose check, an event), whether or
  not the relation selects it, as Active Record does. They raised `RecordNotFound` for a record
  outside the relation.
- **ES-NoProj's `update_counters({})` raises Active Record's `ArgumentError`** ("Empty list of
  attributes to change"); it returned 0. `update_counters(touch: true)` with no counter touches the
  records, as in Active Record; it did nothing.
- **A scope answers the same under ES-NoProj on the model and on a relation.** A scope called on
  a relation now runs its body on that relation, as Active Record runs it (it was built as an Active
  Record relation and the relation narrowed by it). A scope with an Arel condition
  (`where(arel_table[:qty].eq(2))`) called on the model was refused while the same scope on a
  relation was answered; both are answered, by building that scope as Active Record builds it. A
  scope whose body returns a value (a count, a record) returns it, as in Active Record; on the model
  it returned the relation, on a relation it was refused. One that returns an Active Record
  relation of the model answers with that relation's records (it returned the relation the scope was
  called on). A scope's `where.not` of a list is now answered on a relation as `where.not` is (it
  was refused). As in Active Record, the body runs with no current scope (a body reading
  `Model.where(...)` read the relation the scope was called on), and a bang method in it changes a
  copy of that relation (`limit!(1)` limited the caller's). A `scoping` block's relation is seen
  inside a fiber or an enumerator in it, as Active Record's current scope is (they read every
  record).
- **`update_all(foreign_key: nil)` on an Active Record relation of a monitored model under
  ES-NoProj** (counted as a dependent nullify) published events for the records the event store
  holds with that foreign key, every other condition of the relation skipped: `where(author_id: 1,
  status: "published")` nullified the author's drafts too in the log. The records are now those the
  relation's where clause selects, all of it, read from the event store (not the table first); a
  condition that cannot be read refuses the write (`UnsupportedQuery`). The events and the write
  are one transaction where events are required, so a write that fails after its events were
  published takes them back (a refused write used to leave its records nullified in the log).
  `author.articles.update_all(author_id: nil)` now nullifies under ES-NoProj what Monitor does.
- **A bulk write with an offset in Monitor and the other table modes** (`order(:code).offset(5)
  .delete_all`, a page's `update_all`) wrote no row: the write by the snapshot's keys applied the
  offset again. It now writes the rows the relation selects, as Active Record does.
- **A polymorphic `has_one ... as:` under ES-NoProj matches the owner's type**, as the `has_many`
  path does; it returned a record of another type of owner with the same id.
- **A `has_one` with a scope of its own is narrowed by it under ES-NoProj.** `has_one
  :selected_rate, -> { where(selected: true) }` and `has_one :latest, -> { order(id: :desc) }`
  answered with whichever record of the owner's the event store found first; the scope is now
  applied to the owner's records and the first in its order is the answer, as Active Record's
  `LIMIT 1`. A scope ES-NoProj cannot evaluate raises `UnsupportedQuery`. The record is checked
  as a loaded row, as a `has_one` without a scope's is; it was returned unchecked.
- **A `has_one :through` a plain `has_one` reaches its target as Active Record's join does under
  ES-NoProj.** It followed only the intermediate record the `has_one` reads, where the join reaches
  the targets of every intermediate record the owner has (those the `has_one`'s scope selects),
  narrowed by the association's own scope. When either scope orders, the first target in that
  order is the answer; in no order, the one target there is (it could be `nil` before, when the
  intermediate record read had none), and with more than one ES-NoProj now refuses
  (`UnsupportedQuery`) rather than answer with one of them. The intermediate records are read as
  Lyra's own read, without a purpose check, as the join reads them in SQL; the `has_one` reader
  used before was checked, and under a purpose that does not allow the intermediate model's fields
  raised `PamDsl::PurposeFieldMismatchError`.
- **ES-NoProj reads a `:through` association's intermediate records afresh, as Active Record's
  join reads the tables.** A `has_one :through` a `belongs_to`, and a `has_many :through`, took
  them from the owner's association when it was loaded: after the intermediate record changed
  through another instance (moved to another owner), the answer came from the stale copy. Reading
  the target also left the intermediate association loaded on the owner, which the join does not.
  Every record on the way is now read on an association object of its own (from the event store,
  or with SQL for a model not read from events), and the owner's associations are left as they
  were. As the join, such a read reads the intermediate records each time: a loaded intermediate
  association no longer saves the reads.
- **ES-NoProj checks only the records a `:through` association returns, as Active Record's join
  does.** The intermediate records reached through a `belongs_to` or a `has_many` were checked as
  loaded rows (a purpose that does not allow the intermediate model's fields raised
  `PamDsl::PurposeFieldMismatchError`), and every target was checked before the association's
  own scope, order and limit: a restricted target the scope leaves out (`scoped_tags`,
  `tags.where(...)`, a limit, the other candidates of a `has_one :through`) raised where Monitor
  answers. The records on the way are now read as Lyra's own read; the records returned are
  checked, and a query on the association (`count`, `exists?`, `pluck`) is checked as a query
  through the intermediate models, as the join's SQL is (a restriction in force for one of them
  refuses it, as in Monitor).
- **An association scope that unscopes brings back a `:through` association's target that the
  target's default scope leaves out, under ES-NoProj.** `has_one :x, -> { with_discarded },
  through: ...` answered `nil` for a soft-deleted target, and a `has_many :through` left it out,
  because the source association had already applied the target's default scope; and a `has_many
  :through` whose source unscopes (`belongs_to :variant, -> { with_discarded }`) applied the whole
  default scope again afterwards. The targets are now read without the default scope and narrowed
  by it as the join applies it: less what the source's scope or the association's own unscopes.
  The intermediate models' default scopes apply as before, as in the join, except on a step on
  the target's own table (`cat.grandchildren` through a soft-deleted child), which the join
  aliases and applies none to. `unscope(where: :col)` called on such an association drops the
  column from the intermediate models' default scopes too in Active Record (a soft-deleted
  intermediate record's targets come back); ES-NoProj read those records through their default
  scopes, and refuses an unscope of a column one of them conditions (`UnsupportedQuery`).
- **A `:through` association reaches every candidate of each `has_one` on the way under
  ES-NoProj, in the join's order.** Through another `has_one :through`, a `has_one :through`
  followed only the target that association read (and was refused when that one was ambiguous);
  through a `has_one` source with several records, or a `has_one` step on a model not read from
  events (read with its `LIMIT 1`), it answered with the one record read. The candidates are now
  all read, as the join reaches them. The targets were in the intermediate records' order, so an
  order of the source's scope or the association's own came second (`has_one :latest_tag, through:
  :first_item` answered the first item's latest tag, where the join orders by the tag's label
  first and the item's position after). They are now ordered as the join orders them: the
  target's default scope, the next intermediate model's default scope, the association's own
  scope and the source's (an order on the intermediate model's columns included, as Solidus's
  `Product#prices` has), then the intermediate step's scope; an `unscope(:order)` in a scope on
  the target takes the default scopes' and the steps' orders off, as in the join. In no order at
  all, the targets are in primary key order, as Active Record's `first` takes them. Where the
  join's order cannot be reproduced (an order on another table, or a default scope ordering a
  step past the first while an association scope orders too), a read that depends on the order
  (loading, `first`, `last`, `take`, a `limit` or `offset`, `pluck` and `ids`, a `has_one
  :through`'s answer) is refused (`UnsupportedQuery`) when there is more than one record;
  `count`, `size`, `length`, `exists?` and sums answer, and so does a read after `reorder`. A
  `has_one :through` answers with the first target in that order; in no order, with the one
  target there is, and more than one is refused. `first`, `last` and `take` on a `has_many
  :through` follow the same order; they took the first record by primary key.
- **A `has_many :through` that reaches a target through two intermediate records has it twice
  under ES-NoProj**, as Active Record's join has (`author.article_authors` through two articles);
  ES-NoProj kept one, and counted one. `-> { distinct }` keeps one, as before.
- **`update_all` on a `has_many` under ES-NoProj** (`author.articles.update_all(author_id: nil)`,
  a `has_many :through` too) writes the records the association selects, as Active Record's runs
  through the association's scope, recording an event for each, and returns how many; it ran
  against the table and was refused. A record a `has_many :through` reaches twice is written once,
  as SQL updates its row once (also for `delete_all`, `touch_all` and `destroy_all` on such a
  relation).
- **Inside a transaction that recorded rights, a restriction committed before it began is in
  force.** A write of rights drops its subject from the store's shared snapshot until the next
  read, and a connection with rights of its own in its open transaction never read the snapshot
  again, so a subject restricted just before such a transaction was not restricted inside it
  (`active_for`, `active`, `keys_in_force`). Such a connection now reads the rights of every other
  subject into a snapshot of its own, at most once per refresh interval and checking scope, and its
  own subjects as its transaction left them; the shared snapshot is never written from it (under
  `REPEATABLE READ` it reads the database as its transaction began). Outside such a transaction
  nothing changes, and no query is added. `keys_in_force` inside a transaction that lifted a
  restriction no longer lists its subject, as `active` does not.
- **ES-NoProj answers a `has_one :through` by following the through association.** The lookup
  used the source's foreign key on the target: Solidus's `InventoryUnit has_one :order, through:
  :shipment` was asked as `Spree::Order.find_by(order_id: <the unit's id>)`, a column only
  `spree_shipments` has. 0.9.x returned `nil` for such an association under ES-NoProj, so
  `carton.orders` was empty and Solidus sent no shipped email. 1.0.0 reads the intermediate record
  and then the source association, each as that association reads under ES-NoProj, and narrows
  the result by the association's own scope (a scope it cannot evaluate raises
  `UnsupportedQuery`). A `has_many :through` whose source is a `has_one :through`
  (`carton.orders`) follows it too. With `source_type:` (a polymorphic source), a `has_one` or
  `has_many :through` follows only the intermediate records whose type column names that class,
  as Active Record's join does; a `has_many :through` returned records of whatever class the
  column named.
- **ES-NoProj let Rails' uniqueness validation pass every duplicate.** `validates :x, uniqueness:
  true` asks the table whether another row holds the value; in ES-NoProj a monitored model's table
  is empty, so every value passed, and the table's unique index could not catch the duplicate
  either, since no row is written. The testbed saved a second bank-transfer payment with an RF code
  already issued (`BankPayment#remittance_info`) and a second web invoice with a series and number
  already used (`Finance::WebInvoice`). The relation Rails builds for the check is now answered
  from the records rebuilt from events (`Lyra::Projections::Uniqueness`), as Active Record and the
  database answer it from the table: Rails still builds it, so `scope:` (columns and
  associations), `conditions:` (hash conditions, `where.not`, ranges, `or`, named scopes, a lambda
  taking the record), `case_sensitive:`, `allow_nil`/`allow_blank`, the record itself left out on
  update by its primary key (a custom one too), `Model.unscoped` (a soft-delete default scope is
  not applied, as in Rails) and, under STI, the type condition of the class that declared the
  validation all follow Rails' own construction. Values compare through the attribute's type (a
  decimal `"250.00"` is `250`, an enum's label, a datetime in another zone), with SQL's NULL
  semantics; `LOWER(column) = LOWER(value)` and a `citext` column's equality are worked out by the
  database's own `LOWER` (texts it lowered once are remembered). A form that cannot be evaluated exactly (an SQL fragment
  or a subquery in `conditions:`, a join, `LIKE`, a string column with a collation of its own)
  raises `UnsupportedQuery` instead of passing or refusing the value on a guess. The check is
  still exempt from the purpose check. Other modes keep Active Record's relation and the table's
  answer. A uniqueness check is a read and then a write in every mode; where the table modes
  have the unique index to refuse the second of two concurrent writers, ES-NoProj now takes a
  transaction-level advisory lock on the model, attribute and value before the check reads
  (PostgreSQL; under `case_sensitive: false` or on `citext`, on `LOWER(value)` as the database
  computes it), so the second writer's check waits for the first's commit and then finds its
  record. It is taken only inside a transaction (`save`, `create`, `update`) and only by a save
  that claims a value (a new record, a changed attribute or scope column, or a check with
  `conditions:`): a save that keeps its value does not wait for, or deadlock with, other writers.
  It closes the race under READ COMMITTED, not for a REPEATABLE READ transaction whose snapshot
  predates the other's commit. Each check reads every record of the model; a per-process copy
  stamped as the projection cache's entries are reads only the streams written since the last
  check (24 ms instead of 94 ms at 3,000 records in the test environment). A check answers from
  the entries it read itself, so another thread replacing one meanwhile cannot show it that
  thread's uncommitted state; the copies are kept under 32 MB (models with more than 20,000
  streams are read through the projection cache), expire after an hour as the cache's memory
  entries do, and are rebuilt when a model's columns change.
- **An erasure in another process did not reach warm ES-NoProj reads.** `Lyra::Erasure` rewrites
  the record's events in place and appends an `ErasureApplied`. The eraser drops its own cache
  entries; another process brought its entry up to date by replaying only the events after the
  entry's stamp, the `ErasureApplied`, which changes no attribute, and kept the erased values:
  `find_by`, `where` and the uniqueness check answered with the erased e-mail until the entry
  expired. An entry with an `ErasureApplied` after its stamp is now rebuilt from the rewritten
  stream.
- **ES-NoProj's lists, `character(n)` columns and serialized attributes compared as the table does
  not.** A hash condition's list of two or more values is an `IN` of the values the type binds:
  Active Record leaves out one it binds as NULL (`"abc"` on an integer, an enum's unknown label,
  `""` on a boolean), and ES-NoProj kept it as NULL, so `where.not(qty: [9, "abc"])` returned no
  row instead of every row but 9. An enum's unknown label alone is bound as `IS NULL`, as Active
  Record binds it; an integer the enum has no label for (`where(status: 5)`) is bound as `= 5`,
  which no row equals, NULL or not, and stays a member of a list (`where.not(status: [5, 7])`
  returned no row). A `character(n)` value compares without its trailing spaces (`'ab'` is `'ab '`
  in PostgreSQL). A serialized attribute compares as the text it is stored as
  (`{"a"=>1,"b"=>2}` is not `{"b"=>2,"a"=>1}` there), and a Hash given for one is its value, not a
  condition on a table named after it (`where(prefs: {...})` was refused). Hash conditions in
  `where`, `where.not`, `find_by`, `exists?` and `count`, and the uniqueness check, all follow.
- **ES-NoProj compared a condition's value as given, not cast through the column's type.**
  Active Record binds a condition's value through the attribute's type before the database
  compares it; ES-NoProj compared the Ruby values. `find_by(amount: 250.0)` on a decimal column
  compared the event's `"250.0"` with the Float and found nothing, with a BigDecimal too (the
  testbed created a second bank-transfer payment code instead of reusing the first), and
  `where(transaction_type: :card)` matched no row, as did a Symbol on any string column or enum.
  Conditions in `where`, `where.not`, `find_by`, `exists?`, `count` and the joined conditions now
  bind the value as Active Record binds it (the attribute's type serializes it) and read it back as
  a record holds it, in equality, `IN` lists and ranges (each end): a decimal, float or integer
  given as a String, Float or BigDecimal (`3.5` on an integer is 3, `250.004` on a decimal(10, 2)
  is 250.00); a date given as a String or Time; a `datetime`, `timestamptz` or `time` given as a
  String or Date, read in the database's clock (UTC) as Active Record binds it, not in
  `Time.zone`, and a `time` compared as its time of day in UTC; a boolean given as `"t"`, `1`,
  `"0"`; an enum, integer- or string-backed, given as its label, a Symbol or its column's value
  (`where(status: "0")`); a deterministically encrypted attribute as its ciphertext compares
  (`downcase: true` included); an alias for its attribute. A value the type binds as NULL (`"abc"`
  or `""` on an integer column, `""` on a boolean) matches nothing, a value out of an integer
  column's range matches nothing (and leaves a range end open), and NULL is unknown as in SQL:
  `where.not(tag: "x")` and `where.not(amount: 250)` no longer return the rows whose column is
  NULL. An equality on a non-deterministically encrypted attribute matches no row, as on the
  table, and a range, a pattern or an SQL fragment on one is refused (`UnsupportedQuery`). SQL
  fragments (`where("at >= ?", date)`) bind as Active Record quotes: a date or a string on a
  datetime in the database's clock (the testbed's refund list filtered `requested_at` by a date
  in `Time.zone` "Athens"), a number not rounded to the column's scale, and a value the database
  rejects (`"qty >= ?", 2.5` on an integer column) refused. A condition on a name that is not an
  attribute (`where(id: …)` where the primary key is `code`) is refused, as the table rejects
  it; it matched nothing. An order puts `false` before `true` (they compared as equal) and orders
  an enum by the value its column holds, not by its label. A record rebuilt from events also read
  an integer-backed enum wrong: the event holds the label, which was read as the column's
  integer, so every record had the first label (`0`); and a serialized attribute (`serialize
  :prefs, coder: JSON`) failed to load. Both are now turned into the column's value, as a
  projection writing the row does, once when the record's cache entry is built (the entries'
  format is new: `CachedProjection::CACHE_VERSION` 3), with an STI subclass's own enums and
  serialized attributes, and also in `Lyra::Temporal` reads and the rights' subject lookup. A
  record that cannot be built from its events raises; it was left out of the answer. Strings are
  still ordered by code point, not by the database's collation.
- **Retention did nothing in ES-NoProj.** `Lyra::Retention` (and `lyra:retention:apply`) listed
  the model's ids from its streams but loaded each record from its table, which ES-NoProj leaves
  empty or stale: no record was found, a dry run listed nothing and no rule was applied, and
  `:hard_delete` and `:soft_delete` would have failed reloading the record from its table. In
  ES-NoProj retention now finds the records, their anchor column (`created_at` or
  `config.retention_anchors`) included, in the event store, with no default scope applied (a
  soft-deleted record is still due), and acts on them there: `:hard_delete` destroys the record
  rebuilt from its events (a destroy event) and `:soft_delete` updates it (an update event). The
  other modes are unchanged.
- **The Art. 15 copy read a column an association owns as a link to another model too.** The
  `<type>_id` convention of `Lyra::Privacy::SubjectLinks` also read `owner_id` of
  `belongs_to :owner, class_name: "Person"` as a link to a model named `Owner`, and a polymorphic
  `owner_id` as one whatever `owner_type` said, so the export for `Owner` 13 included the note
  of `Person` 13. A column an association owns now links only to that association's class (a
  polymorphic one's, only with its type column naming the subject's class), and the convention
  reads only columns no association owns, for a subject type that is a monitored model or names
  no model at all.
- **ES-NoProj reads apply the model's default scope.** Active Record builds every read of a
  table from the model's `default_scope`; ES-NoProj reads, rebuilt from the event log, left it
  out, so soft-deleted records (`default_scope { where(deleted_at: nil) }`, as paranoia, discard
  and Solidus's `Spree::SoftDeletable` use) were found, counted and returned by associations.
  `find`, `find_by`, `find_by!`, `exists?`, `where`, `all` (and so `count`, `pluck` and the other
  calculations), `first`, `last` and named scopes now read through the default scope, as do
  `belongs_to` and `has_one` readers and `has_many` readers, counts, sizes and collection queries
  (through the target's default scope less what the association's scope unscopes, as Active
  Record's association scope). A default `order` orders the results; on a `CachedRelation` an
  `order` now adds to the existing order and `reorder` replaces it, as in Active Record, and
  `first`/`last` follow the relation's order (`last(n)` returns the last n in that order, no
  longer reversed). `Model.unscoped` read the table, which ES-NoProj leaves empty or stale; in
  application code it now returns every record from the event store, and reads inside
  `Model.unscoped { ... }` (and `reload`) leave the default scope out. Active Record's internals
  and Lyra's own code keep Active Record's relation from `Model.unscoped`, also through a
  model's own `def self.unscoped = super`. Scopes that take the default scope off
  (`with_deleted`, `with_discarded`, `unscope(where: :deleted_at)`) and `rewhere` work after
  `where`, `order` and named scopes, on the model and on an association, as on Active Record
  (the relation replays its conditions without what is taken off); **after a `limit`,
  `where.not` or an SQL fragment they raise `UnsupportedQuery`**, since the records they would
  bring back are no longer in the relation. **A default scope ES-NoProj cannot evaluate (an SQL
  string, a join, an ordering by an expression) now raises `UnsupportedQuery` on every read of
  the model**, rather than answer with the records it leaves out, and
  `Lyra::ModeTransition.to!` refuses the switch into ES-NoProj while a monitored model has one
  (`force: true` overrides). An association's scope is evaluated on each read, so one that
  decides at run time (`-> { Current.admin? ? with_deleted : all }`) is honoured. A find by
  primary key reads one record even under an ordered default scope. Models without a default
  scope read as before.
- **ES-NoProj relations no longer act on records their query did not select.** A
  `CachedRelation` answers exactly or raises `UnsupportedQuery` before anything is written.
  `merge` and `merge!` returned the relation unchanged, so `Model.unscoped.merge(Model.where(...))
  .delete_all` deleted every record; they now evaluate the other relation (its conditions,
  order and limit, or the records of an event-store relation) and refuse another model's.
  `where!` with anything but hash conditions kept every record and now
  raises; `exists?(["title = ?", x])` ignored its condition and now evaluates it as `where`
  does (or refuses it). Relation methods Lyra did not implement ran on a bare relation of the model, past the
  relation's conditions: `update` and `update_counters` changed every record, `first_or_create!`
  and `create_or_find_by!` created records without the conditions, `create_with` was dropped and
  `to_sql` raised `NoMethodError`. `update`, `update!`, `update_counters` (with `touch:`),
  `first_or_initialize`, `first_or_create(!)`, `create_or_find_by(!)` (a record is found instead
  when a unique index of the table would refuse it, as Active Record finds it on the violation)
  and `create_with` now work on the relation's records and conditions, and `sole` and
  `find_sole_by` raise `RecordNotFound` or `SoleRecordExceeded` as Active Record does; `lock`, `annotate`,
  `optimizer_hints` and `strict_loading` are accepted and do nothing (writes take Lyra's
  aggregate lock); `to_sql` and every other Active Record relation method raise
  `UnsupportedQuery` before running. A model's own class methods called on a relation run with
  it as the current scope, as Active Record runs them: their reads and writes act on its
  records.
- **PAM DSL prints a retention period given in plain seconds correctly.** With ActiveSupport
  loaded, as in a Lyra application, an Integer number of seconds (`keep_for 86400`,
  `default 7 * 365 * 86400`, or an Integer from configuration) was read as years: 86400 printed
  "0 years" in the Article 30 register, the policy summary and the retention check, and the
  policy comparator printed 365 days of seconds as "365 days" and seven years of seconds as
  "6 years". Plain seconds are now worded the same with and without ActiveSupport, with the
  polyfill's fixed-length units (1 month = 30 days, 1 year = 365 days), rounded down to the
  largest whole unit: 3600 is "1 hour", 86400 "1 day", 30 days "1 month", 365 days "1 year".
  `ActiveSupport::Duration` values (`1.day`, `7.years`) print as before. Retention enforcement
  was not affected: it already read plain seconds as seconds in both modes.
- **Lyra's GDPR retention check dropped a policy's retention given in plain seconds** and
  applied the configured or default period (7 years) instead; it now keeps a plain number of
  seconds as it keeps an `ActiveSupport::Duration`.
- **An erased record's row kept personal values inside `json`, `jsonb` and array columns that
  its events had lost,** so it no longer replayed to its events. This happened with or without
  `everywhere`. The erasure rewrote the events recursively but replaced only top-level string
  columns in the row. `Lyra::Erasure` now scrubs every column of the row with the rule its events
  get: the record's own row with the key and value rule, another record's row reached by
  `everywhere` with the value rule only, so a third party's email under an `email` key there is
  kept. `json`, `jsonb` and array columns and serialized attributes are recursed into and written
  back whole in the same `UPDATE`. A `text` column holding JSON is still compared as a string, as
  in its events. A column declared personal that holds a hash or an array is replaced whole, in
  the row and in the events alike (each side of a change too): `nil`, or, when it is NOT NULL,
  its own default as the database stores it (`[]`, `{}`); before, the events kept it, or got its
  elements replaced one by one. Inside a hash, the strings that are identifying for the field's type (an
  email for `:email`, a phone number for `:phone`) count as the person's values, and those under a
  nested personal field; their copies elsewhere in the record, and with `everywhere` in other
  records, are erased too. Labels such as `"home"` are not. An earlier erasure's `"erased:<id>"`
  is no one's value, so a second erasure neither reports nor searches for it. The row is scrubbed by
  the attribute's type, as its events are, so `hstore` columns and attributes cast as json are
  recursed into too. An
  encrypted attribute is compared in clear in its events, as in its row, and a replacement is
  encrypted again; before, its ciphertext stayed in the events and replayed back to the value.
  The erasure moves the row's optimistic-lock column, as any write does, so a copy loaded before
  it fails with `StaleObjectError` instead of saving the erased values back; the move is recorded
  as an ordinary update of that column alone (metadata `source: "lyra_erasure"`), so the row still
  equals its replay. Before, the lock moved in the row only, and the row no longer replayed to its
  events. Virtual attributes are no longer written, which made the erasure fail. An
  event that is not a CRUD event (an application's own, in the record's stream) gets the key rule
  at its top level, so a personal field's hash there is replaced whole. With `everywhere`, a
  record is listed in `result.copies` only if its row no longer holds the value anywhere. A value
  held as a JSON key, or inside a longer string, is not erased, and the record is listed in the
  new `result.left_behind` as `{ record:, columns: }`, never with the value; `lyra:erase` prints
  it. Before, such a record was listed as erased. The erased record's own row is checked the same
  way, with or without `everywhere`, and listed first. A primary or foreign key is never rewritten;
  one that holds an erased value is reported in `left_behind` as `"Model <key withheld>"` (and
  `result.key_withheld`), and no result, reason or task output prints it. With `everywhere`, each
  record found is locked and its stream read again before it is erased, so a copy written during
  the search is not missed; candidates are found without case, and a `citext` copy differing in
  case is reported. The new `result.not_searched` names the encrypted columns of monitored
  models, which a text search of the log cannot read. In ES-Async the lock moves from the version
  the log last recorded.
- **`everywhere` erased a third party's own record when the person's data named them.** In the
  person's own record a value under a personal field's name is the person's (the key rule), so a
  manager's email nested inside the person's JSON (`{"manager" => {"email" => …}}`), or a friend's
  email at the top of another event in the person's stream (an invitation), was erased there and
  then searched for in other records, the third party's own included. Now only the person's own
  values drive the search: those of the row's personal fields and at the top of a personal field in
  the record's own CRUD events (an attribute, either side of a change, a payload entry), with the
  strings inside a structure declared personal taken by its type as before. The others are still
  erased in the person's record, as its events are, and no longer anywhere else.
- **`everywhere` missed rows that held a value their events did not.** The search reached rows
  only through events, so a row given the value by raw SQL, written before monitoring, or changed
  by a write Lyra could not intercept kept it, and nothing reported it; and a record reached
  through an event that mentioned the value only inside a longer string kept a whole copy in its
  row. With `everywhere`, the tables of monitored models with a policy are now searched directly,
  one query per table that returns keys only (string and text columns by equality, `json`/`jsonb`
  as text by a `LIKE` on the value as a JSON string, string arrays with `= ANY`, `hstore` values);
  not in ES-NoProj, where the tables are absent or stale. Every record reached has its row scrubbed
  by the value rule, whether or not its events held the value whole. When only the row held it,
  its `ErasureApplied` says `row_only: true` and it is listed in the new
  `result.rows_without_events` (its row already differed from its replay: `lyra:repair` in Monitor
  or Disabled, a rebuild of its table in the other modes; the task says which). A row with no
  stream is erased first and then imported the Genesis way, so its `Imported` event holds the
  replacement, never the value (an `ErasureApplied` alone would have started a stream Genesis never
  imports); if a Genesis run imported it first, that stream is rewritten instead. A key column is
  still never rewritten, and a row holding a value only as a JSON key or in another case in a
  `citext` column is reported in `left_behind`. The log is searched once for all the values (it
  was searched again per value to count holders), and candidate events are read in batches.
- **`everywhere`'s threshold counted streams, not people's records.** A value was taken as shared
  when more than `max_copies` other streams held it, so one person's many records (and a record's
  reference links) counted against it. Holders are now counted by record, through events (each
  confirmed by an exact match) and rows alike, and the person's linked records, found by the rule
  of the subject-access copy (`Lyra::Privacy::SubjectLinks`: any `belongs_to` to the erased
  record's model naming it, by id or by its `primary_key:` column, a polymorphic one, a
  `<model>_id` column), do not count. `max_copies:` must be a positive Integer (`ArgumentError`
  before anything is written; a String failed half-way before).
- **`everywhere` rewrote Lyra's own record streams.** An event in a stream that was not a monitored
  record's was rewritten when it held an erased value, so a consent recorded under an email as its
  subject key (`Lyra::Consent$<email>`) lost it, and the consent store, rebuilt from those events,
  lost the consent. Restrictions and objections (`Lyra::Rights`), consent (`Lyra::Consent`), the
  access log and its erasures and the subject-access exports, with their per-subject streams, are
  now never rewritten by `everywhere`, nor counted as holders.
- **Genesis's lock was per class, not per table.** An import through an STI subclass did not wait
  for one through its base class. The lock is now named after the table's stream owner (the STI
  base class), which the erasure of a row with no stream also takes.
- **Genesis imported a value the model cannot represent as the model read it.** A row holding a
  value outside a string or integer enum's mapping (`refund_requests.status = '2'`) was imported
  with `status: nil`: the `Imported` event disagreed with its row, and the disagreement surfaced
  later and elsewhere (ES-Lazy's catch-up failed with `PG::NotNullViolation`). Genesis now checks
  every attribute of every row it imports: the value the model reads, written back by the model's
  type, must be the value stored, compared as the column's own type reads both or as the database
  would be sent them. `'1'` and `1`, time zones and timestamp precision, a time of day, a decimal's
  trailing zeros, jsonb key order or a normalized attribute's untrimmed legacy value are no
  difference; an enum value outside the mapping, a lossy attribute type (`attribute :n, :integer`
  over `10.50`), an inet value's host bits (which Rails drops; in `inet[]` arrays too) and a value
  out of the model's integer range are. Whatever the type, a stored value the model writes back
  as NULL is lost, in a nullable column too: a JSON `null` in a json/jsonb column, an empty range,
  a blank or `'null'` JSON text or an empty YAML hash in a serialized column. A serialized,
  encrypted or JSON attribute's text is otherwise one of many encodings of its value and is not
  compared (a value of another class is). Columns the model ignores are imported as stored.
  - By default a model holding such rows is refused: every row is checked before anything is
    written, and `Lyra::Genesis::Refused` lists model, id, attribute, stored value and value read
    (at most `Genesis::LISTED`, 20, with the count; a value the privacy policy declares, or an
    encrypted one, is not shown). Nothing of the model is imported; inside a caller's transaction
    the import is a savepoint, so a caller that rescues the refusal commits nothing of it. A
    refused first use is remembered for `Genesis::REFUSAL_RECHECK` (30) seconds from the scan
    that found it, so repeated uses do not scan the table again; `lyra:genesis` always scans.
  - With `config.genesis_unrepresentable = :skip` (or `unrepresentable: :skip`, or
    `UNREPRESENTABLE=skip` for `lyra:genesis`) those rows are left without a stream, the rest is
    imported, and the rows are listed in the result (`Lyra::Genesis.import`, new, returns a
    `Result`; `import_all` still returns the count) and in the log. A write to a skipped row,
    through callbacks or bypassing them (`update_columns`, `touch`, `update_all`, `touch_all`,
    `delete_all`, `upsert_all`, ...), and an ES-NoProj `find` of it, import it once the model can
    represent it and raise `Refused` (naming the rows) until then, so its stream never begins with
    the write's event. A skipped row is therefore fixed in the database; the next use of it, or
    `lyra:genesis`, imports it. A process knows only the rows it skipped itself. `dependent:
    :nullify` over a skipped child refuses the parent's destroy where events are required; in
    Monitor that child's event is left out (logged) and the other children still get theirs.
  - A write that bypasses callbacks now also runs the model's first use, as a write through
    callbacks does: on a model not yet imported in the process, `update_all` and the like import
    the rows that predate Lyra before recording their events.
  - A gated switch into Hijack or event sourcing is refused with such rows as discrepancies,
    whatever the setting (`Report#unrepresentable` counts them); `lyra:genesis` lists a refused
    model's rows and exits 1. `Genesis.import_one` (an erasure of a row with no stream) logs such
    a value and imports the row: the erasure does not fail on it.
  - `Lyra::Repair` wrote what the model read too (an `Imported` event for a row without events,
    an `Updated` event for the changed columns). It now applies the same check
    (`Genesis.unrepresentable`) under the same setting: by default `Lyra::Repair::Unrepresentable`
    (a `Repair::Refused`, with the listing) is raised before anything is written; with `:skip`
    (`Repair.run(unrepresentable: :skip)`, `UNREPRESENTABLE=skip` for `lyra:repair`) those
    records stay out of line, the rest is repaired, and `Repair::Result` (`skipped`,
    `unrepresentable`) and `lyra:repair` list them; a dry run lists them.
  - The error of work run on a connection of its own (`Lyra::OwnConnection`) is raised in the
    caller only, no longer also printed by its thread.
- **An erasure could miss an update that committed while it ran.** It read the record's stream
  before its transaction and took the row lock only when it wrote the row, after rewriting the
  events, so a Monitor update that committed in between appended an event the erasure never saw,
  and that event kept the value. `Lyra::Erasure.erase!` now takes the row lock, then the record's
  advisory lock (the locks a writer holds, in the order writers take them), and only then reads
  the stream, all in one transaction; everything derived from the stream is computed under the
  locks, so a refusal there rolls back with nothing changed. A write already in flight finishes
  first; one that starts later waits and is new data. In ES-NoProj, with no row, only the advisory
  lock is taken.
- **An access-log entry was lost when the reader's transaction rolled back,** though the read had
  already returned its value. `Lyra::AccessLog` now appends on a connection of its own
  (`Lyra::OwnConnection`), so the entry survives the rollback; an access that cannot be recorded
  still does not go ahead. Inside a transaction this costs a second connection per access, so size
  the pool for it (twice the threads avoids any wait): when no connection comes free within the
  pool's checkout timeout, or the connection is pinned (Rails' transactional tests), the entry is
  written inline, in the reader's transaction, and lost if that rolls back.
- **PAM DSL works without ActiveSupport again.** Loaded on its own, with its standard-library
  polyfill, the Article 30 register raised `NoMethodError` (`String#presence` is ActiveSupport),
  and JSON export (`Reporter#export_json`, `GDPRCompliance#portable_export`) relied on
  ActiveSupport having loaded `json`. The polyfill now provides `presence` and treats a
  whitespace-only string as blank, as ActiveSupport does, and both files require `json`. Behaviour
  under ActiveSupport is unchanged. `rake test:all` now runs the PAM DSL suite twice, with
  ActiveSupport and with the polyfill (`rake test:both`), so CI covers both.
- **A model whose single primary key is not `id`** (`self.primary_key = "code"`, a string or
  uuid column, no `id` column) is supported in every mode. `Lyra::DualView` looked the row up
  with `find_by(id:)`, so `DualView#compare`, `compare_all`, `find_discrepancies`,
  `Lyra::ModeTransition.discrepancy`, the mode gate's check and `lyra:repair` raised on such a
  model; sync projection and rebuild updated and deleted rows `where(id:)`. Hijack and event
  sourcing ignored the key the application gave, reserved another (a uuid), and put an `id`
  attribute the table does not have into the `Created` event. ES-NoProj's and `as_of`'s
  reconstructed records and the dashboard's record pages also used `id`. All now use the
  model's primary key. A composite primary key is still not supported, and
  is now refused clearly: `monitor_with_lyra` and `config.models` raise `ArgumentError` naming
  the key, and `verify_mapping!` reports it.
- **ES-NoProj: `has_many ... dependent: :delete_all` left the children alive.** Rails deletes
  them through the association's table scope, which matches no row in the events-only store, so
  no `Destroyed` event was written and the children were still read back after their parent was
  destroyed. A `dependent: :nullify` found its children by foreign key alone, so it also cleared
  those outside a scoped association (`has_many :x, -> { where(...) }`), and a polymorphic one
  (`as:`) wrote no events at all. Both now find the children the association selects in the event
  store, as Active Record's association scope does: the owner's records, narrowed by the child's
  default scopes (less what the association's scope unscopes, so a soft-deleted child is left
  alone) and by the association's scope. Each gets the event `delete_all` or `update_all` writes
  there (`delete_all`, `dependent_association` or `update_all`, as in Monitor); strict mode
  refuses `delete_all` as it does in Monitor. **A dependent association whose scope, or whose
  child's default scope, cannot be evaluated against the event store (an SQL string scope such
  as `-> { where("status = 'x'") }`) now raises `UnsupportedQuery` and the parent's destroy is
  refused**, rather than delete or nullify children the association might not select. The same
  applies to `delete_all`, `delete(record)` and assigning a new set on such an association;
  `delete(record)` and assignment raised `TypeError` before (a condition on a record's query
  constraints, `where(["id"] => [[1]])`, which `CachedRelation` now evaluates). The owner's
  in-memory counter cache is no longer lowered (it went negative): ES-NoProj does not maintain
  counter caches. `has_one` `:delete` and `:nullify` were not affected. Monitor, Hijack and
  ES-Sync are unchanged.
- **ES-NoProj answers `delete_by` and `destroy_by`,** as `where(...).delete_all` and
  `where(...).destroy_all`; they raised `UnsupportedQuery`. The partners of an in-memory join are
  read as Lyra's own read: under a purpose, a join on a model with a policy was refused for the
  partners' fields though no partner is returned; so are the children a `dependent: :nullify`
  rewrites, read for their events.
- **Monitor appended `Updated` after `Destroyed`** when a stale copy was saved after another
  process had destroyed the record. Its UPDATE reached no row, or, when nothing had changed, no
  UPDATE ran; Active Record still ran `after_update`, and the stream became
  `[Created, Destroyed, Updated]`. Monitor now records no update when the UPDATE reached no row or
  nothing changed.
- **Monitor appended a second `Destroyed`** when two stale copies of a record were both destroyed,
  when a copy was destroyed after `delete_all` or hand-written SQL had deleted its row, and when
  the same copy was destroyed twice. Without optimistic locking Active Record does not check what
  its DELETE reached, and it runs `after_destroy` even when the DELETE reached no row, or when it
  ran none for a record that is not persisted; the stream became `[Created, Destroyed, Destroyed]`,
  which no replay can apply. A destroy now records nothing unless it deleted the record's row, so
  a new record's `destroy` no longer appends an event without an id in any mode either. A row
  deleted by hand-written SQL keeps its stream open, as any write that bypasses Active Record does,
  until `lyra:repair` appends the `Destroyed`. Hijack and the event-sourcing modes refuse a stale
  destroy, as before; a soft delete (paranoia) and optimistic locking are unchanged.
- **`belongs_to ... touch: true` cascades published nothing.** Rails touches the parent through
  `touch_later`, which sets the timestamps and clears their change before `touch` runs at commit,
  so Lyra saw no change. The parent's row moved and its stream did not; with timestamps compared,
  DualView flagged every touched parent and the mode gate refused. Lyra now keeps the row's value
  before the first deferred touch and records the change.
- **An application's `metadata_proc` `source` was overwritten** by Lyra's (`lyra_interceptor`,
  `lyra_command_handler`). Lyra's value is now the default the application's keys override.
- **ES-NoProj: `where(...).touch_all` touched every record** (an unscoped `touch_all` through the
  scope branch, with an event each) and then raised `UnsupportedQuery`. It now touches only the
  selected records, with one time for all, as Rails's `touch_all` does.
- **The GDPR helpers lost a related record's updates and destroy** (Art. 15/17/20 reports):
  they matched the subject's foreign key in each event alone, and an update carries only its
  changes. Each record is now followed through the log, and an event is the subject's when the
  record pointed at them before or after it.
- **A record created in Monitor lost `created_at` and `updated_at` when the log became
  authoritative.** Monitor's event left the two columns out of its `attributes` snapshot (its
  `changes` carried them), and replay and projection read a create's `attributes`. After a switch
  to event sourcing an ES-NoProj read raised `MissingAttributeError` on them, and a rebuild reset
  them to the rebuild time; DualView ignored the two columns, so it reported neither. `attributes`
  now holds every column, timestamps included, in Monitor events and in the events of bypass writes
  that create or delete records (`insert_all`, `delete_all` and the like), as Hijack and the
  event-sourcing modes already did. Logs written before this change are not supported (see
  Breaking).
- **`ModelProjection.project_create` overwrote a string-keyed `created_at` or `updated_at` with
  the projection time.** It defaulted the two with symbol keys, and stringifying the keys let the
  default replace the value the event carried. A rebuild therefore reset the timestamps of every
  record whose event attributes had string keys, as Monitor's do.
- **A destroyed record could be written again after events that are not replayed.** The check
  that refuses an update or destroy of a destroyed record (0.9.3) looked at the stream's last
  event only. A destroy followed by an event that is not replayed (the additional domain event of
  an `also:` rule on destroy, an `ErasureApplied` from erasing the destroyed record, a
  `has_and_belongs_to_many` link made with a stale copy and linked into its stream) let a stale
  copy update the record in ES-NoProj, ES-Async and ES-Lazy, appending after the destroy. The
  check now looks at the stream's last replayed event: the last one `Lyra::Event.operation_of`
  gives an operation.
- **Strict data access tells Rails' association writes from the application's.** Any
  `update_all` setting one `*_id` column to nil was taken for a `dependent: :nullify` by its
  shape, and let through: `Article.where(...).update_all(author_id: nil)` cleared keys in strict
  mode. Rails' association code now marks the one relation or record it is about to write, just
  before the write (`Lyra::Associations::Maintenance`), and only that write is let through:
  a write the application makes meanwhile (in an `after_find` while the association loads its
  record, in a destroy callback) is its own, and refused. The marked writes are a `has_many`'s
  nullify (`dependent: :nullify`, and removing children with `delete`, `delete_all`, `clear` or
  by assigning a new set or ids), a `has_many :through`'s `dependent: :nullify` of its through
  records, a `has_one`'s `dependent: :nullify`, and the deletes of rows that link records:
  `has_and_belongs_to_many` join rows, the same rows through a model the application declared on
  the join table, and a `has_many :through`'s through records when records are removed from it.
  A `has_many`'s `dependent: :delete_all` of its children stays refused. The same writes made by
  the application are bulk writes like any other: refused in strict mode, and, where allowed,
  admitted by Genesis, checked against destroyed streams and the lock limit, and recorded as
  `update_all` or `delete_all` (an `update_all(fk: nil)` in ES-NoProj on the records the event
  store holds that the relation selects, as before). Several of Rails' own writes were refused
  in strict mode and now run: a polymorphic `dependent: :nullify` (two columns, `has_many` and
  `has_one`; a `has_many`'s is now recorded as `dependent_association`, with both columns'
  changes, where it was an `update_all`), a `has_many`'s removal of a child whose key is not named
  `*_id` (`foreign_key: :parent`), a `has_one`'s `dependent: :nullify` (its `update_columns`; the
  owner could not be destroyed), removing records from a `has_many :through` over a monitored
  model (its through records' `delete_all`, recorded as before), Rails' deletes through an
  application model on a join table, and, in ES-NoProj, a `has_many :through`'s
  `dependent: :nullify`, now recorded as `dependent_association` there as in the other modes. To
  mark the relation a `has_many :through` writes, Lyra reproduces Active Record's
  `HasManyThroughAssociation#delete_records`, checked identical in 8.0.5.1 and 8.1.4.1, and
  installs it for Rails 8.0 and 8.1 only; on another version Rails' own method runs with the
  through model marked for the whole of it (a write of that model made meanwhile is taken for
  Rails'), and a warning says so once.
- **Deleting `has_and_belongs_to_many` join rows yourself is refused in strict mode.** The
  association's own deletes (`delete`, `delete_all`, `clear`, `destroy`, `destroy_all`,
  assigning records or ids, destroying the owner) are Rails' bookkeeping, allowed as before, and
  each records its `AssociationUnlinked`. A `delete_all` the application makes on the join model
  (`Item.const_get(:HABTM_Tags)`) was always allowed; it is now refused in strict mode when either
  side's model is monitored, as is one on a model the application declared on the join table
  (not monitored itself), which deleted links with no event at all and is now recorded as an
  unlink where it runs. Several monitored models' `has_and_belongs_to_many` can share a join
  table (both sides of one association, a self-referential one, two owners on columns of their
  own): a delete through the application's model of it, its own or Rails' (a `has_many :through`
  over it, its `dependent: :delete_all`), records on the stream of every monitored owner the
  deleted rows name the `AssociationUnlinked` Rails' own unlink from that side records, linked
  into the associated records' streams that have none of their own; a side whose model is not
  monitored records nothing. Links made and removed from a side Lyra does not monitor (its
  `has_and_belongs_to_many` to a monitored model) were not recorded at all: Rails' link and
  unlink, and the application's `delete_all` where allowed, are now recorded on the monitored
  records' streams (appended to the first, linked into the others), as a link made from their
  side is seen there.
- **`insert_all` in ES-NoProj decides on primary keys as the event store has them.** The table
  decided: a record created through callbacks (no row there) was inserted again, a second
  `Created` on its live stream with its attributes overwritten, where Monitor skips the row
  (`insert_all!` raises `ActiveRecord::RecordNotUnique`); and a record inserted with `insert_all`
  and destroyed kept its row, so inserting its key again was skipped with no event, where
  Monitor creates the record again. The rows' keys are now locked and read from the event store:
  a record it holds is skipped (`insert_all`) or refused before anything is written
  (`insert_all!`, and `insert_all` whose `unique_by` is another index, whose `ON CONFLICT` does
  not cover the key), and the table's row of any other key, left by a destroyed record, is
  replaced (a row Genesis left without a stream is a record, and conflicts). A key whose record was destroyed is created again, `Created` after
  `Destroyed` as in Monitor, and the stream reads as the record created last (find, queries,
  `StreamTail`, the writes that follow). Rows that give no key take the table's sequence, as
  before.
- **An ES-Async or ES-Lazy `upsert_all` no longer brings back a destroyed record whose row is
  still in the table.** Before the destroy's projection job ran (ES-Async), or before the next
  catch-up (ES-Lazy, a destroy committed after the one the write began with), `ON CONFLICT`
  updated the row and appended an `Updated` after the `Destroyed`: the record read as live in the
  log, the job then deleted its row, and `find` raised. The rows the upsert conflicts with now
  have their aggregate locks taken (all or none, within `bulk_write_lock_limit`) and their streams
  read. In ES-Async (see the next entry) the rows are then brought up to date with their streams,
  and a destroyed record is inserted again, as in Monitor. In ES-Lazy a destroyed one refuses
  the whole upsert with `Lyra::RecordDestroyedError` before anything is written, as an update of
  a destroyed record is refused: replaying the destroy onto the row there would be applied again
  by the next catch-up, which would delete the new row. Once the destroy is in the table the
  upsert inserts, as in Monitor. In ES-Lazy the locked rows are brought up to date with their
  streams first, so the events carry the values the stream has. ES-Sync, Hijack and Monitor
  delete the row with the destroy and are unchanged; ES-NoProj refuses `upsert_all` as before.
- **ES-Async: `insert_all`, `insert_all!` and `upsert_all` conflict as Monitor's do while a
  projection job is pending.** The id of a record whose destroy was still waiting for its job met
  the dead row: `insert_all` skipped it (no event; the job then deleted the row), where Monitor
  creates the record again, and `upsert_all` was refused. The id of a record whose create was
  waiting had no row yet: the insert wrote one and logged a second `Created` on the live stream,
  where Monitor's `insert_all` skips it, `insert_all!` raises `ActiveRecord::RecordNotUnique` and
  `upsert_all` updates it. Deleting the dead row first was no answer: the destroy's job would then
  delete the new one. The records of the keys the rows give (and, for `upsert_all`, the rows its
  conflict key finds) are now locked (aggregate locks, within `bulk_write_lock_limit`) and their
  rows brought up to date with their streams, as their jobs would
  (`AsyncProjectionJob.project_pending`): under the job's own per-stream lock, the events after
  the stream's checkpoint are applied and the checkpoint moved past them, in the write's
  transaction. The pending jobs then apply only what is past the checkpoint, the write's own
  event at most, which is in the row already: a destroy is never applied to the row created
  again. A destroyed record is created again with the values given and the column defaults (not
  the dead row's), `Created` after `Destroyed`; a live one conflicts. `upsert_all` reads the rows
  its conflict key finds again once the locks are held, so a job that committed in between is
  seen. Rows already up to date cost one query. The write then moves the checkpoints of the
  records it brought up to date, and of those it created, to its own events (one statement):
  writing the same keys again finds nothing to project. Rows that give no key take the table's
  sequence; a conflict on another unique index is looked up in the event store (see the entry on
  ES-Sync, ES-Async and ES-Lazy below). A projection job no longer
  waits for its record's row while it holds the stream's lock: it takes the row with its lock
  (one statement more per job, no measurable time) and, when another transaction holds the row,
  lets the lock go and waits for the row first, so a transaction that holds the row and then
  inserts or upserts its key does not deadlock against the job.
- **ES-NoProj: `insert_all` and `insert_all!` check the model's other unique indexes against the
  event store.** Only the primary key was; the other unique indexes were checked against the
  table, which holds no row of a record created through callbacks: a duplicate (an email taken,
  no id given) was inserted, a second record with the value, where Monitor's `insert_all` skips it
  and `insert_all!` raises; and the row a destroyed record left there skipped a value that is free.
  Each row's values for each unique index (not partial, not an expression; NULL conflicts only
  under NULLS NOT DISTINCT) are now locked as a uniqueness validation of the value locks them
  and compared with the records the event store holds that may hold them (found through the
  values' streams, next entry) and with the table's rows holding them: a conflict is skipped
  (`insert_all`, on any index or on its `unique_by`) or raises `ActiveRecord::RecordNotUnique`
  before anything is written (`insert_all!`, and a conflict on an index other than `unique_by`).
  The table's rows of destroyed records holding the values are deleted, and the row of a live
  record that holds a value its record gave up since (updated through callbacks) is brought up to
  the record's values. A row Genesis left without a stream (`genesis_unrepresentable :skip`)
  conflicts, by its key and by its values, as in Monitor; it was deleted as a destroyed record's
  row, by its key. The values' locks and the keys' count together against
  `bulk_write_lock_limit`, so a model with several unique indexes reaches it at fewer rows. A
  `create` or `update` through callbacks is checked against the same indexes (next entry).
- **ES-NoProj: `create`, `update`, `update_columns`, `update_column` and `update_all` enforce the
  table's unique indexes.** ES-NoProj writes no row, so the index never saw these writes: a
  duplicate email was saved and recorded (unless a uniqueness validation caught it), where Monitor
  raises `ActiveRecord::RecordNotUnique` from the `INSERT` or `UPDATE`.
  - *Which indexes.* Unique, on columns, not partial, other than the primary key, and on no column
    with a nondeterministic collation (whose equality only the database knows; a uniqueness
    validation refuses such a column too): the list `insert_all` checks too
    (`Lyra::Projections::UniqueIndexes`). They are read from the database once per model and
    process, again after `reset_column_information` and every `config.unique_index_refresh`
    seconds (60), so an index a migration adds is enforced in a process started before it. An
    index is checked when the write sets one of its columns.
  - *When.* Where the table modes write the row: after the `before_*` callbacks and before the
    event is built, so a conflict raises `ActiveRecord::RecordNotUnique` (with PostgreSQL's
    message, naming the index) before any `after_*` callback and with nothing appended;
    `update_columns` after its destroyed-record check; `update_all` before any of its events, two
    of its records given one value conflicting with each other. An update claims the tuple the
    row would hold: the columns it does not write as the record's stream has them, read under the
    record's aggregate lock (a copy read before another writer moved the record to another shop
    claimed its old pair and saved a duplicate). NULL conflicts with nothing unless the index is
    `NULLS NOT DISTINCT`; values compare as the column holds them, a `citext` column's by the
    database's `LOWER`, as `citext` compares (Ruby's `downcase` disagreed on "İ"); a destroyed
    record holds no value, and a record keeps its own.
  - *Locks.* Each claimed value is locked with the key a uniqueness validation and `insert_all`
    take, so of two concurrent writers of one value the second waits and raises, as the index
    makes the second `INSERT` wait. An update, `update_columns` and `update_all` take the value
    locks after the records' aggregate locks, as Monitor's `UPDATE` takes the row and then the
    index entry, so they wait where Monitor waits and do not deadlock where it does not (taking
    them before deadlocked an `update_all` against a save of the same record, and two
    transactions crossing two records and one value). An update of a model with a uniqueness
    validation takes the record's aggregate lock before its validations (once, earlier), so the
    validation's value lock comes after it as well: a validated save and an `update_all` of the
    record and value, and two validated transactions crossing two records and one value, no
    longer deadlock. The lock key holds a keyed digest of the value, not the value, which reached
    the statement log (`hashtext('lyra_unique/User/email/ann@…')`); the `LOWER` of a `citext`
    value is asked for with the value bound. The links are caught up without waiting for another
    thread, the links' lock or a connection (a write that cannot have them checks against every
    record of the model, once), so a model's first use with every connection of the pool taken
    by its writers finishes. Without `config.value_digest_key` or `secret_key_base`, every environment but development and
    test raises `ValueDigest::KeyMissing` at first use. The unique indexes ES-NoProj leaves out
    (partial, expression, nondeterministic collation) are named in the log once per model.
  - *Lookup.* The value is looked up in a value stream (`"Model!column$<digest>"`, linked by
    `ReferenceLinks` for each event that sets an indexed column, in one `INSERT`): its cost is the
    value's history, not the model's size. The digest is an HMAC-SHA256 under a secret of the
    installation (`config.value_digest_key`, or derived from `secret_key_base`;
    `Lyra::Projections::ValueDigest`), so a dictionary does not reverse it; a value stream linked
    under another key is deleted and linked again on its next use. An erasure moves the links of
    the events it rewrites, so no digest of an erased value is kept. Each column's links have a
    checkpoint of their own: the first check of a model links only the columns behind (the
    foreign keys are not read again), before its value locks, in one read of the events; a column
    added to an index is linked from the first event. Processes that ran an earlier Lyra, or read
    the indexes before a migration added one, write without the column's links; once they are
    gone, `bin/rails lyra:link_values` links every value again (a process of this release that
    reads the new index links its own earlier writes itself).
  - *Cost.* On the development VM (PostgreSQL in Docker, 1,000 records, 200 interleaved writes) a
    create or an update that sets a fresh unique email costs three queries more (the lock, the
    stream read, the link's `INSERT`: 11 against 8 for a create, 12 against 9 for an update),
    about 90 more objects allocated (of some 2,500) and 2 to 3 ms (of 15 to 25, on a loaded VM);
    a model without such an index, and an update that sets none of its columns, are unchanged (the
    same queries, allocations within noise). On the testbed in ES-NoProj the benchmarked writes
    (`Registration` create, update and destroy: its unique indexes are all partial, so none is
    checked) are unchanged (12, 10 and 10.5 queries per write, as before), and a `BankPayment`
    create (a unique `remittance_info`, validated too) costs 13 queries against 10. ES-NoProj's
    `insert_all` reads the records the values' streams name instead of every record of the model
    (`Uniqueness::Snapshot`: 52.8 s at 10,000 records, cold), and `Model.insert_all` (and the
    other inserts on the model) no longer builds the relation of every record first (Active
    Record sends them through `Model.all`): a cold two-row `insert_all` at 3,000 records took
    10.2 s, now 77 ms. With `config.reference_links = false` every record of the model is read,
    as a uniqueness validation reads them.
  - *`create_or_find_by`.* In ES-NoProj it looked for a conflict on an index made of its
    attributes alone, so a value its block set was created twice; it now creates in a savepoint
    and, when the index refuses the record, finds it (`RecordNotFound` when the attributes select
    none), and `find_or_create_by` creates through it, as Active Record 8.1 does.
  - *Also.* An `update_columns` on a copy read before another writer changed the value it sets
    back recorded nothing in ES-NoProj and left the record as it was (its old value was the
    copy's): it now takes the old values from the record's stream, as the table's `UPDATE` writes
    the row. ES-Sync, ES-Async and ES-Lazy: next entry.
- **ES-Sync, ES-Async and ES-Lazy: a duplicate's event was appended before the projection met
  the unique index.** In these modes the event store is authoritative and the table a projection:
  a `create`, `save`, `update`, `update_columns` or `update_all` setting a value a unique index
  already held appended its event, then the projection's `INSERT` or `UPDATE` failed and was only
  logged (`strict_projections` off). The log held a record the table could not; in ES-Lazy the
  next read's catch-up then failed on it, and with it the reads of every model. Monitor raises
  `ActiveRecord::RecordNotUnique` and writes nothing. The writes are now checked before the event
  is built, as ES-NoProj's are (previous entry; `Lyra::Projections::UniqueIndexes`, the same
  indexes, claims, value locks and message, naming the mode), so a duplicate raises
  `ActiveRecord::RecordNotUnique` with no event appended, no projection job enqueued, no row
  written and nothing logged as a failed projection, and ES-Lazy's reads go on.
  - *Where the value is looked up.* ES-Sync: in its table, under the value's lock. Its projection
    writes the row in the writer's transaction, so once the lock is held the table has every
    committed claim and the transaction's own, compared by the database as its index compares
    them; one statement (the lock) and one `SELECT` per value claimed, and no links. ES-Async and
    ES-Lazy, whose tables lag the event store (a create whose job has not run, a write since the
    last read): in the value streams, as ES-NoProj, which are now linked in these modes too
    (`ReferenceLinks.values_enabled?`; the foreign-key links stay ES-NoProj's, and a model with
    no unique index links nothing). The first check of a model in a process links the events
    stored before (per column, once).
  - *Writes that skip callbacks.* `update_columns`, `update_column`, `update_all`, `insert_all`,
    `insert_all!` and `upsert_all` take the values' locks in these modes too, so a write through
    callbacks checking the table waits for them, as they wait for it (in ES-Sync
    `update_columns` locks its row first, `FOR NO KEY UPDATE`, and `update_all` its rows, as
    Monitor's `UPDATE` takes the row and then the index entry). ES-Sync's statement then checks
    the index itself. In ES-Async and ES-Lazy the values are first looked up in the event store,
    where a holder whose row is not projected yet was missed by the table: `update_columns` and
    `update_all` raise; `insert_all` leaves the row out (or raises, for an index other than its
    `unique_by`), `insert_all!` raises; `upsert_all` raises for a conflict on an index other than
    its conflict columns (the record it updates excepted), and on its conflict columns updates
    the holder, whose row ES-Async brings up to date first (it raises where that row is still not
    in the table). This was the known leftover of the ES-Async insert entry above.
  - *A holder destroyed or moved away, its row still in the table.* The value is free, as in
    Monitor, whose row is gone: a `create` (or any of the writes above) saves it. ES-Async brings
    such a row up to date with its stream in the write's transaction, as its job would, where that
    waits for nothing (the record's aggregate lock, its row and its stream's projection lock are
    only tried; a record one is taken for is left to its job), so neither the write's own `UPDATE`
    or `INSERT` nor its projection job meets the stale value. ES-Lazy's catch-up applies the
    destroy first (log order).
  - *Cost.* On the testbed (development VM, PostgreSQL in Docker, 100 writes each after warm-up),
    a model without a checked unique index and a write that sets none of its columns issue the
    same statements and locks as before in all three modes: the writes the benchmark campaign
    measures (`Registration` create, update and destroy, 8/8/13 statements in ES-Sync, 7/8/13 in
    ES-Async, 7/8/26.8 in ES-Lazy; its unique indexes are all partial, so none is checked; its
    `insert_all` and `update_all` likewise), and a `BankPayment` update of its amount (8). In
    ES-Async and ES-Lazy each append of such a model also looks the model up for its value
    columns, in memory (about 8 objects more per write; times within noise). A write that sets a
    checked value costs, per value: in ES-Sync the lock and a `SELECT` on the table (a
    `BankPayment` create, unique `remittance_info`, 11 statements against 9; an update of the
    code 11 against 9); in ES-Async and ES-Lazy the lock, the value stream's read and the link's
    `INSERT` (create 11 against 8 in ES-Async, 19 against 16 in ES-Lazy; update of the code 12
    against 9, 21 against 18), 1 to 3 ms, and a rebuild of the records the stream names when the
    value has a history. ES-Async's projection jobs are unchanged (10 to 12 statements).
  - *ES-Sync inside `ReadYourWrites.with_guaranteed_read`.* A write's row was deferred to the
    block's end, so the block's own reads missed it and so did the check of every write after it
    (which reads ES-Sync's table): two creates of one email in a block were both saved, the
    second's row dropped. ES-Sync now writes the row at once inside the block too, as outside it
    (and as `each_write: true` did); the block has nothing left to project there.
  - *A projected create that met another record's value inserted nothing, silently.* The
    projection's `INSERT ... ON CONFLICT DO NOTHING` skipped a row whose value another row held, as
    it skips a replay of the record's own row. In ES-Async, when the holder's row was held by
    another transaction (so the write left it to its job) and the new record's job ran before the
    holder's, the job completed and moved its checkpoint past the create: the log held a record
    the table never got, and nothing was logged. A create that inserts nothing although the table
    has no row with its key (looked up on the table's class: a record of an STI subclass whose
    type changed since keeps its row) now raises (one query, only then), after reading the rows
    that hold its values (a tuple with a NULL holds nothing, unless its index is `NULLS NOT
    DISTINCT`) and their records' streams. When each such record gave the value up and only its
    row lags, an ES-Async job brings those rows up to date itself, where nothing has to be waited
    for (so a holder whose own job was lost does not block it), and inserts again; a row still
    held by another transaction raises `Lyra::Projections::ProjectionBehind`, which the job
    retries at most every five minutes for about a day (`AsyncProjectionJob::BEHIND_ATTEMPTS`,
    300; the general retry gave up after about seven minutes of a held row, and the record never
    reached the table), then reports (log, `projection_error_handler`) and gives up, leaving the
    record to a rebuild. `Lyra::Projections::DuplicateInLog` when a live record holds the value in
    the log too (two records of the log hold it), a row with no stream holds it, or no holder is
    found once the insert was tried again (an expression index, which Lyra does not read): logged
    once per record and process (debug after; 10,000 remembered) and passed to
    `projection_error_handler`, the job discarded. Both are `ActiveRecord::RecordNotUnique`s:
    ES-Sync's write fails with either, a rebuild stops at it. ES-Lazy's catch-up logs it (once)
    and goes on, since raising there would stop every read for a record the log holds for good.
    An update whose value another row holds raised already.
  - *ES-Sync: a database error in the projection was logged inside an aborted transaction.* With
    `strict_projections` off, the error the projection's `INSERT` or `UPDATE` raised was logged and
    the save reported success, but PostgreSQL had aborted the transaction, so its `COMMIT` rolled
    the write and its event back: a value committed after a `REPEATABLE READ` transaction's
    snapshot, which the check's `SELECT` cannot see, ended in a save reported as done with no
    event. A database error there now fails the write (`ActiveRecord::StatementInvalid` and its
    subclasses: here `RecordNotUnique` or `SerializationFailure`), whatever `strict_projections`
    says; other errors are logged as before.
  - *Not covered.* Transactions at `REPEATABLE READ` or `SERIALIZABLE`, in every event-sourcing
    mode (as for a uniqueness validation): the check reads the transaction's snapshot, which
    misses a value another transaction committed after it began. ES-Sync's write then fails at
    its projection (above), as Monitor's does; ES-Async and ES-Lazy save both records, and the
    second's projection fails with `DuplicateInLog` (logged once; ES-Async discards the job,
    ES-Lazy's catch-up goes on). Partial and expression indexes, and columns with a nondeterministic collation,
    are left to the projection, as in ES-NoProj (named in the log once per model).
- **`insert_all` and `upsert_all` with `returning:` as raw SQL without the primary key recorded
  nothing.** `insert_all(rows, returning: Arel.sql("code"))` wrote the rows and published no
  event, in every mode: the keys could not be read back. The primary key is now returned with the
  caller's SQL under an alias of Lyra's own and taken out of the result the caller gets.
- **The result of `insert_all`, `insert_all!` and `upsert_all` with `returning:` is Active
  Record's own.** Where Lyra added the primary key to `RETURNING` (a symbol, an array, raw SQL,
  `Arel.sql("*")`) it rebuilt the result without its column types: `column_types` came back empty
  and `cast_values` cast nothing; `returning: false` lost the affected rows. The column types (by
  name and by index) and the affected rows are kept.
- **A model whose primary key has several columns** (one its table declares, enrolled before
  Active Record read it; Lyra refuses one it knows of) raised `PG::UndefinedColumn` on
  `insert_all` and `upsert_all` with `returning:` (the key was asked for as one quoted name) and,
  without it, wrote the rows with no event. In Monitor and Hijack each key column is now returned
  and taken out of the caller's result, and each row records its `Created`, the record's key
  being the array of its columns' values. The event-sourcing modes, whose projections, catch-ups
  and rebuilds cannot apply such an event (ES-Lazy's catch-up then failed on every read of every
  monitored model), refuse the three writes with an `ArgumentError` before anything is written,
  and Genesis refuses the model on its first use there (it failed with `PG::UndefinedColumn`).
- **`has_and_belongs_to_many`: the application's `insert_all`, `insert_all!` and `upsert_all`
  of join rows were neither refused nor recorded.** Through Rails' join model
  (`Item::HABTM_Tags`) or a model of the application's on the join table (and `insert`, `insert!`,
  `upsert`, and an owner's `item_tags.insert_all(...)`), they are now refused in strict mode
  unless inside `Lyra.without_strict_access`, as its `delete_all` of join rows is, when either
  side is monitored, and where they run each row written (read back with `RETURNING`) is recorded
  as the `AssociationLinked` Rails' own link from each side records, on every monitored owner's
  stream the row names; a row `ON CONFLICT` skipped records nothing, and an upsert that moves a
  row to another pair unlinks the old pair. Rails' own links are inserted one row at a time
  through the join model's callbacks, as before.
- **`has_and_belongs_to_many`: the join table of an owner Lyra does not monitor, whose monitored
  side has no association back onto it, was not recognised** for a model of the application's on
  that table: its deletes went unguarded and unrecorded, though Rails' own links and unlinks there
  are recorded on the monitored side's streams. Lyra now keeps every `has_and_belongs_to_many`
  declared (those of models loaded before its hook was installed included), and the table is a
  join table when one whose links it records names it. A
  `has_many :through` over a model Lyra does not monitor is not one: no link of it is recorded,
  from either side, as before.
- **`has_and_belongs_to_many`: Rails' own unlink of a join row naming another association's
  owner too** (two owners' columns filled on one row of a shared table, which only the
  application's code writes) recorded the unlink of the side Rails deleted from only; the other
  owner's stream kept a link whose row was gone. It is now recorded on every monitored owner's
  stream the row names, as the application's delete of the row already was. Rows naming no other
  owner record exactly what they did.
- **`config.bulk_write_lock_limit` takes `nil` or a whole number of at least 1.** 0 (or a
  negative number) refused every write that locks a record, a single `update_columns`, `touch` or
  `delete` included; any other value raises `ArgumentError` now, and a string is read as its
  number. `BulkWriteLockLimitError`'s message no longer reads "a update_columns of 1 ... records".
- **A bulk write is no longer aborted for the deadlocks of the transactions it waits behind.**
  `Lyra::AdvisoryLock.xact_lock_all` gave back every lock it had taken whenever one was held, and
  waited for that one without a limit, in its queue; there it was the one PostgreSQL aborted when
  the transactions ahead of it deadlocked among themselves, and transactions that came and went with
  a few of its records kept it out. A bulk write of 8 records, for 15 s, against three transactions
  that each updated one record and then bulk-wrote two others: in ES-NoProj it went through 2 times
  in 21 attempts and was aborted 19 times (four runs), in ES-Async 50 times in 66 attempts, 16
  aborted (three runs). A bulk write that holds no advisory lock of its own yet now keeps the locks
  it took while it waits for the others, for at most 100 ms in all, and waits holding none for at
  most half of `deadlock_timeout`; then it gives them back and tries again. No wait of its lasts as
  long as `deadlock_timeout`, so PostgreSQL never reports it deadlocked, and a transaction that
  holds one of its records and asks for another it took goes on once it gives way. The same runs:
  ES-NoProj 7 of 8 attempts went through (the one aborted already held locks, in a later round of
  the write), ES-Async 42 of 42 (four runs each); deadlocks in all, the three transactions' among
  themselves included, 47 against 56 in ES-NoProj, and in ES-Async 29 in four runs against 43 in
  three (the transactions' own: 46 against 37, and 29 against 27). A bulk write of 6 records, beside
  one of 4 and a transaction like those, went through 62 and 88 times (two runs) instead of 24 to 30
  in ES-Async, and 60 instead of 12 in ES-NoProj (the one of 4 records: 130 and 135 instead of 152
  to 160, and 121 as before), with no deadlock before or after; the runs took longer (ES-Async 42 s
  against 22 to 25, ES-NoProj 415 s against 236). It is no cure for starvation: in ES-NoProj a write
  still waited 2 to 28 s, and in ES-Async its turns cost the three transactions about a third of
  their throughput. A transaction that already holds locks of its own (it wrote a record, then
  bulk-writes others) waits as before, holding none of the new ones: keeping them, or taking all in
  sorted order and waiting, as Monitor's row locks do, made such a transaction deadlock nearly every
  time (119 of 120 in that ES-Async run, against none). The lock limit is still checked before any
  lock is taken, nothing is appended until every lock is held, and a write that finds its records
  free takes them as before, in one statement in a savepoint. A `lock_timeout` of the caller's own
  (session or transaction) shorter than the bounded wait stays in force, and its timeout raises
  `ActiveRecord::LockWaitTimeout`, as before, instead of being taken for the bounded wait's own
  limit and tried again.

### Changed
- **The gems' MIT-LICENSE copyright line no longer names the University of the Aegean**, which is
  the author's affiliation, not a copyright holder.
- **Ruby 4.0.9, Rails 8.1.4.1, pg 1.7.0.** Security releases: Ruby 4.0.9 fixes memory
  corruption when compiling crafted regular expressions, Rails 8.1.4.1 fixes advisories in
  Active Support and Action View (Active Record unchanged). Lyra's requirements are unchanged
  (Ruby 4.0+, Rails 8.0+); the project and the example app now run these versions.
- **Ruby 4.0.10.** The project and the example app run Ruby 4.0.10 (`.ruby-version`); Lyra's
  requirement is unchanged (Ruby 4.0+).
- **`config.erasure_max_copies`** (default 10) sets `everywhere`'s threshold for the application;
  `erase!(max_copies:)` and `lyra:erase MAX_COPIES=` still override it per call. Each value left
  as shared is reported in the new `result.shared` as `{ field:, type:, holders: }` (never the
  value); `result.shared_values` stays an Integer, their count. **`erase!(dry_run: true)`**
  (`lyra:erase DRY_RUN=1`) runs the erasure and rolls it back, reporting what it would do, the
  shared values and their holders included, and writing nothing: once a person's values are
  erased, a later run cannot find the copies left as shared, so the threshold is chosen with a dry
  run first, and the task's hint says so. `ErasureApplied` gains `row_only` and `imported`
  (above). The documentation now gives the operator's `VACUUM` step after an erasure (old row and
  event versions stay on disk, in WAL and in backups until reclaimed or expired), states that a
  database error logged by a failed bypass publish can contain the failing row, and describes a
  narrow wait between an erasure and a model's first use in another transaction.
- **Erasure can delete the subject's access log; off by default.** `Lyra::Erasure.erase!` left the
  record's access stream (`Lyra::DataAccess$<Model>$<id>`: who read the record, when, under which
  purpose and basis) whole and unreported, and `everywhere` never reached it, since it holds field
  names, not values. Whether it goes is the controller's decision (it may be evidence to keep, Art.
  5(2)). `config.erase_access_log` (default `false`) deletes it once the record is fully erased
  (this erasure and the earlier ones together cover every personal field);
  `erase!(access_log: true|false)` (`lyra:erase ACCESS_LOG=1|0`) decides per call, `true` at once. Its events are deleted
  from every stream and from the events table, in the erasure's transaction. `access_log_subjects:`
  (`ACCESS_LOG_SUBJECTS=`) names the ids the application passed as the person's subject
  (`validate_access!(…, subject: "user-7")`), whose logs follow the same rule. `ErasureApplied` and
  the `Result` record `access_log` (`"erased"` or `"kept"`) and `access_log_entries`, and
  `ErasureApplied` how many such ids (`access_log_subjects`), never which.
  `Lyra::AccessLog.erase!(subject, reason:, erased_by: nil)` (`lyra:erase_access_log SUBJECT=
  REASON= [OPERATOR=]`) deletes one subject's log alone, a record's or a bare id's, and records
  it as `AccessLogErased` in `Lyra::AccessLogErasures`. A model-wide entry (`Lyra::DataAccess$<Model>$*`, a `pluck`'s) names
  no subject and is refused (`Lyra::AccessLog::ModelWideSubject`). Retention's `:hard_delete` of a
  record erased before with its log kept deletes the log too when the setting is on, and records
  an `ErasureApplied` that names no fields: **code that reads `ErasureApplied` must allow an empty
  `fields`**. Not covered: the access logs of other records `everywhere` reaches, and an access
  recorded (on its own connection) while the erasure runs.
- **Mode switches, erasures and repairs record what the operating system says beside the operator's
  label.** The actor (`OPERATOR=`, `Current.user`, `LYRA_OPERATOR`) is a label nothing checks.
  `Lyra::Attribution` adds the user the process runs as (by uid, not the `USER` variable), the host
  and the pid: `lyra_mode_transitions` gains `os_user`, `host` and `pid` (added to an existing table
  on first use), the metadata of `ErasureApplied` and of `AccessLogErased` (an access log erased on
  its own) carries them beside `erased_by`, and a repair's events record
  `repaired_by` (the label: `lyra:repair` passes `OPERATOR`, `Lyra::Repair.run` takes `operator:`),
  `os_user`, `host` and `pid`, where a repair recorded no actor at all. `ErasureApplied`'s data gains
  `any_fields`, `requested_fields` (what the request named; `nil` for the declared columns) and
  `beyond_policy` (the columns erased only because of `any_fields`). This authenticates no one: it
  makes the label comparable with the OS and SSH audit logs, which remain the attribution control.
- **PAM DSL: restriction of processing (Art. 18) and the right to object (Art. 21).** PAM had no
  construct for either: a restriction could only be approximated by narrowing a purpose for
  everyone or withdrawing a consent, and a purpose on contract or legal obligation could not be
  stopped for one person. A purpose now declares the Art. 18(2) grounds on which it continues
  while a subject's processing is restricted (`allowed_when_restricted :consent`, `:legal_claims`,
  `:protection_of_rights`, or `:important_public_interest, reference: "<the law>"`), and whether
  it is direct marketing (`direct_marketing!`, Art. 21(2)) or research or statistics
  (`research_or_statistics! public_interest_task: true|false`, Art. 21(6)); `Purpose#objectable`
  derives the article that lets a subject object (Art. 21(1) for public task and legitimate
  interests, research or not), or none. `PamDsl.rights` records, per subject and independent of any policy,
  restrictions (`restrict!`, then `notify_lift!` and `lift!`, which raises without the Art. 18(3)
  notice) and objections (`object!`: upheld at once for direct marketing, pending and restricting
  that purpose for Art. 21(1) and 21(6) until `decide!`, recorded as rejected and raised as
  `ObjectionNotApplicableError` for a purpose with no right to object; `withdraw_objection!`), as
  events in `PamDsl.rights_store`, with an `on_rights_event` hook. An upheld objection to direct
  marketing stops every direct-marketing purpose for that subject; objecting again while an
  objection is in force returns it; times must be `Time` values that run forwards. `validate_access!` gains
  Condition 6, checked after every other condition: `RestrictedProcessingError` for a restriction
  that covers the access when the purpose declares no exception that applies, and
  `ObjectedProcessingError` for an upheld objection. The Article 30 report prints each purpose's
  right to object and its exceptions. PAM DSL ships the store protocol and an in-memory store
  only; the in-memory store refuses to record outside development and test
  (`RightsStoreNotDurableError`). Lyra's durable store and its enforcement on reads, erasure and
  retention are not in this change, and writes are not checked under a restriction in 1.0.0.
- **Lyra keeps the data subject's restrictions, objections and consent durably, shared by every
  process.** With PAM DSL loaded, Lyra installs `Lyra::Rights` into it. `PamDsl.rights_store`
  becomes Lyra's: each request, notice, decision and lift is an event in
  `Lyra::Rights$<subject key>` (linked to `Lyra::Rights`), appended with RubyEventStore's expected
  version so that two processes cannot both lift or decide one request (the second gets
  `PamDsl::RightsConcurrencyError` and nothing is stored), and an append that does not replay is
  refused before anything is written. The new table `lyra_rights` (one row per restriction or
  objection: subject key, kind, policy, purpose, fields, ground, state, times) is written in the
  same transaction and created on first use; `bin/rails lyra:rights:rebuild` rebuilds it.
  Condition 6 answers from a per-process snapshot of the committed requests in force, refreshed at
  most every `config.rights_refresh_interval` seconds (default 1, new) and on
  `Lyra::Rights.refresh!`, so a check costs a clock read when nothing is in force; a transaction
  that records a right sees it at once and other threads only after it commits, and a rebuild
  locks the table against transitions. `PamDsl.subject_key_resolver` maps a record to its own key
  and to the keys of the people it names, by the subject-access copy's selection rule (link
  columns a record was loaded without are read from its row, or the access fails with
  `Lyra::Rights::UnresolvedSubjectError`), so a restriction recorded against a person
  (`"Person$7"`) refuses a read of their invoice under a purpose with no Art. 18(2) exception.
  Lyra installs its stores when it loads, and at boot only where the application has not
  installed its own. Consent moves to the same store: PAM DSL's new `PamDsl.consent_store`, when set, is
  the store of every policy's `consent_policy`, and Lyra's keeps each request, grant and withdrawal
  as an event in `Lyra::Consent$<subject key>` with the table `lyra_consents` as its projection.
  Before, consent was held in memory, per process and per policy object: lost on restart, not seen
  by other processes or by another policy, and gone when a policy was defined again. A person's
  consent now covers the records that name them; a grant that repeats a granted consent records
  nothing. Limit: a consent check on a record that names more than one person (a payer and a
  payee) is refused with `Lyra::Rights::ConsentStore::SharedRecordConsentError`, a
  `PamDsl::ConsentRequiredError`, whatever each consented to; whose consent such a record needs
  is future work. Condition 4 and the `:consent` exception of Art. 18(2) read the same record (a
  consent store's refusal under that exception is now reported with the restriction rather than
  raised), and `consent_audit` lists the store's records (`recorded_consents`). Without Lyra, PAM
  DSL keeps consent in memory as before. Neither stream
  is erased by `Lyra::Erasure` or with the access log: they hold names, grounds and reasons, never
  values. Model-wide filtering of restricted subjects, `lyra_processable`, and restriction-aware
  erasure and retention are not in this change.
- **Lyra enforces restriction and objection where it checks reads, in erasure and in retention,
  and reports them.** Under a purpose (or `reads_without_purpose` `:audit`/`:deny`):
  - A record load that names no declared field (`select(:id, :payer_id)`) is checked too, for a
    restriction of all of its subjects' data, a pending objection's restriction of the purpose and
    an upheld objection (PAM DSL's new `validate_rights!`); before, such a load was never checked.
    A loaded restricted record raises, as a non-consenting one does.
  - Aggregates, `pluck`, `pick`, `ids`, `exists?` and `cache_version` (subject `Model$*`) leave the
    restricted subjects out: the record's own key `NOT IN` the restricted records and each link
    column `IS NULL OR NOT IN` the restricted people, so rows that name no one are kept; ES-NoProj
    filters its in-memory records by their keys, and fails closed
    (`Lyra::Rights::UnresolvedSubjectError`) when a record's links cannot be read. A field-scoped
    restriction applies only to queries naming one of its fields. Audit mode leaves no one out and
    logs it. With nothing in force for the query, its SQL is unchanged. Before, these queries
    included the restricted people.
  - A join, subquery or CTE that reaches a model with such a subject raises
    `PamDsl::RestrictedProcessingError` rather than include or silently drop them.
  - `Model.lyra_processable(fields: nil)`, a scope without the records the purpose in scope may not
    process, for batch jobs (Active Record and ES-NoProj).
  - The rights and consent are read afresh at the first check of each checking scope: a
    `Lyra.with_purpose` block, a web request (`Lyra::Rights::Middleware`, installed by the
    engine), an Active Job (`Lyra::Rights::Job`) and each batch of `in_batches`, `find_each` and
    `find_in_batches` (`Lyra::Rights.scope`). A right recorded in another process applies from the
    next scope; before, up to `rights_refresh_interval` later, mid-request included. The first
    check in a scope makes one indexed query; code that checks nothing (no purpose, `:allow`) makes
    none.
    `config.rights_refresh = :interval` (new; the default is `:scope`) keeps scopes but drops the
    forced read: rights and consent are read again only after `rights_refresh_interval`, as before.
  - `Lyra::Erasure.erase!` refuses a record that a restriction in force covers (its own, a person's
    it names, of all the data or of a field being erased) with `PamDsl::RestrictedProcessingError`;
    `lifting: restriction_id`, after the Art. 18(3) notice, lifts it and erases in one transaction.
    A dry run (`dry_run: true`) is refused the same way and, with `lifting:`, lifts nothing and
    lists in `Result#lifting` what it would lift (a real erasure lists what it lifted).
    `Lyra::Retention` skips restricted records with outcome `:restricted` (`Result#restricted`,
    printed by `lyra:retention:apply`). Before, both acted on data the subject had asked to be kept.
  - The subject-access copy (`data_export`) has `restrictions` and `objections`: the subject's own
    requests, never another person's. The per-subject `processing_activities` gives each declared
    purpose's right to object and Art. 18(2) exceptions (`rights_by_purpose`); with Lyra's
    per-model policies it gave none. A dashboard page, `privacy/rights`, lists the open requests
    with their age against the month of Art. 12(3); the policy page shows each purpose's
    declarations; `RestrictedProcessingError` and `ObjectedProcessingError` in a dashboard read
    answer 403.
  - `Lyra::Verification::DataLifecycleWorkflow` (the data lifecycle with a Restricted place,
    restrict, notice and lift) and `ObjectionWorkflow`, PetriFlow nets whose tests check that
    PAM DSL's transitions are exactly theirs and that Deleted is unreachable from Restricted
    without the lift.
  - After review: SQL strings are read for the tables they reach (`FROM`/`JOIN`, with aliases), so a
    string join or subquery reaching a restricted model is refused, and a subquery's words are
    checked against the policy of the table they belong to (a change to the purpose check too); a
    `FROM`/`JOIN` Lyra cannot name is refused while a right is in force (fail closed). A polymorphic
    filter covers STI subclass names. A subject's people are resolved only when a request in force
    could cover the access, and aggregate rows are not subjects (a grouped `select` or `find_by_sql`
    no longer raises `UnresolvedSubjectError` because of an unrelated right); ES-NoProj reads a
    narrowed record's people from the whole record. ES-NoProj's `Model.exists?(id)` and an undeclared
    purpose follow the rights. Erasure reads a record's people from its events when it has no row
    (ES-NoProj), refuses one it cannot resolve, lifts with `lifting:` only a restriction of the record
    erased, and with `everywhere:` leaves another record's restricted copy unmodified
    (`Result#restricted_copies`, printed by `lyra:erase`, which takes `LIFTING=`). The subject-access copy
    lists record restrictions under ES-NoProj too. The dashboard's event routes refuse (403) or leave
    out restricted records (`X-Lyra-Rights-Withheld`). The rights page gives a deadline only to an
    objection awaiting a decision. The excluded subjects are computed once per snapshot (one pass over
    the requests in force), the condition compiled once, and a scope whose rights did not change costs
    one single-row query: a count with 300 restrictions in force went from about 13 ms to about 1 ms.
  Writes (`update`, `destroy`, bulk writes) are not checked under a restriction in 1.0.0.
- **PAM DSL: a type for every Art. 9(1) special category, and for Art. 10 data.** Only `:health`
  and `:biometric` were special-category types, so a column of any other Art. 9(1) category had
  to be declared under another type (`:custom`), and a purpose with only an Art. 6 basis could
  read, say, trade-union membership without PAM raising anything. The new types `:genetic`,
  `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief` (religious or philosophical
  beliefs), `:trade_union_membership` and `:sex_life_orientation` are special categories: a purpose
  that reads one needs an `art9_basis`, else `PamDsl::SpecialCategoryViolationError`. Art. 10 data
  (criminal convictions and offences) gets the type `:criminal_offence` and a condition of its own,
  since Art. 10 permits processing only under official authority or when Union or Member State law
  authorises it, not on an Art. 9(2) ground: a purpose that reads such a field names that
  authorisation with `art10_authorisation "<the authority or the law>"`, else
  `PamDsl::CriminalDataViolationError` (strict raises it, audit records it, in `validate_access!`
  and `validate_fields!`). An Art. 9(2) basis does not satisfy Art. 10, nor an Art. 10
  authorisation Art. 9. The Article 30 report prints a purpose's Art. 9(2) bases and Art. 10
  authorisations where it reads such data, the export carries them, and `article_30_gaps` lists
  a purpose that reads such data without them. The detector, and so the policy generator,
  proposes the new types from names that say what a column holds (`ethnicity`, `political_party`,
  `religion`, `trade_union_member`, `sexual_orientation`, `criminal_record`), never from a bare
  `party`, `union`, `orientation` or `offence`, and the generator marks such fields with the
  condition a purpose reading them must meet. The dashboard refuses a read that raises the new
  error as it refuses the others. PAM now has 25 field types (18 before). No field of the Aegean
  testbed changes type.
- **The Art. 15 export is a copy of the data.** `Lyra::Privacy::GDPRCompliance#data_export` keeps
  its keys, but for `processing_activities` (see Breaking), and adds five. `records` holds each of the subject's records whole: every attribute (not
  only those a detector flags; encrypted columns in plaintext) and its stored history, `from`/`to`
  per change. A record is the subject's by what it is: the subject's own row, the rows of monitored
  models whose `<type>_id` names them (indexed queries), and the records the subject's events touch,
  so a row that pre-dates monitoring, a destroyed record and an ES-NoProj record are all in it
  (`state` `:current`, `:destroyed`, `:replayed`); a record whose foreign key moved is the
  subject's only for the periods it named them (`:reassigned`, `periods`). `accesses` is the access
  log for those records (`nil` when `record_access_events` is off). `processing_context` takes each
  record's purposes, bases, recipients, transfers, retention (field periods included) and sources
  from its own model's policy; `notice` is the policy's `access_notice`; `gaps` lists what the
  policy does not declare. Who acted is a role label (`"you"`, `"staff"`, `"system"`) unless
  `disclose_actors: true`. History and the access log are included by default; `history: false`
  and `accesses: false` are for a request the subject narrowed. A field the policy declares
  `withheld_from_access: "<basis>"` is named with that basis instead of its value, and one declared
  `about:` another person goes to `review`; Lyra picks no basis. See
  [PRIVACY_COMPLIANCE.md](docs/PRIVACY_COMPLIANCE.md#the-copy-of-the-data-from-100).
  - *Links.* A record refers to the subject through any `belongs_to` whose class is the subject's
    model (`belongs_to :owner, class_name: "Person"`), a polymorphic `belongs_to` whose type
    column names it, or the `<type>_id` column; the subject's own model is not linked to itself.
  - *Moved records.* An event that moves a record between people gives each only their side: the
    previous subject sees the old values and the link's new value as "moved to another person",
    the new one only the new values. A record whose links no longer name the subject is
    `:reassigned` with its state just before the move, whatever comes after. A value last set
    while the record was another person's is not given: the field is listed under `withheld` with
    the basis "set while the record was another person's". Accesses to a moved record are the
    subject's only within their periods.
  - *The old keys follow the copy's rules* (their content changes): `pii_inventory` and
    `data_lineage` leave out fields declared `withheld_from_access:` or `about:` another person,
    give encrypted values in plaintext, and, like `events`, see a moving event with the subject's
    side only.
  - *Retention* is what the policy declares: with no rule and no `default`, the period is `nil`
    and `gaps` lists "Art. 15(1)(d) retention not declared", rather than PAM's silent 7 years.
    Columns the policy does not declare (no purpose, basis or retention) are listed in `gaps`.
  - *Accesses* include those recorded under the bare subject id (`access_log_subjects:` on
    `GDPRCompliance.new` names others, or `[]` for none) and, with the access log off, the
    subject's earlier exports, with a gap saying the log is off.
- **Events record the acting user's class** (`user_type` in the metadata, beside `user_id`, from
  `Current.user`: the table's owner class for an Active Record user), in the write path, bulk
  writes and the access log. The copy's role labels compare id and class: "you" only when both
  are the subject's; "staff or you" when an event records an id equal to the subject's but no
  class (written before 1.0.0, or by a `metadata_proc` that sets none); "staff" otherwise.
- **Each explicit export is recorded,** as `Lyra::Events::SubjectAccessExported` in a stream of
  its own, `Lyra::SubjectAccessExports$<Type>$<id>`: when, which sections, how many records,
  `verified_by:` and who exported, never values. Erasing the subject's access log
  (`AccessLog.erase!`, or `Lyra::Erasure` with `access_log:`) leaves it, so the evidence that a
  request was answered outlives the log; the copy's `accesses` still lists earlier exports. Only an
  explicit `data_export` call is recorded: `data_export(record: false)`, `full_report` and the
  dashboard's subject and GDPR routes are views of the data and record nothing. On by default;
  `config.record_subject_access_exports = false` turns it off. Nothing is recorded in disabled mode.
- **The GDPR reports read each model's policy.** The wrapper passes PAM the policy of each record's
  model (its `privacy_policy`, else `config.privacy_policy`). `processing_activities` takes the
  purpose, legal basis, categories, recipients and retention from it, where it printed "Not
  specified" and guessed the purpose from `metadata[:source]`; `rectification_history` lists an
  update that changed a declared field as well as one the detector flags.
- **The privacy stamp's purposes are those the policy admits the field for,** from either side:
  the field's `allow_for` and every purpose that lists it in `requires` or `optionally`, as
  `Policy#allowed?` decides. A policy that lists its fields on the purpose side stamped every field
  with `"purposes" => []`. `allowed_purposes` on the PAM adapter follows.
- **PAM DSL field options and the notice declaration:** `withheld_from_access:`, `about:` and
  `collected_from` on `field`, and `access_notice` on the policy (see the PAM DSL changelog).
- **ES-Lazy reads cost less, with the same consistency.** The check before every read reads the
  checkpoint and the newest event id in one query instead of two. A reader that finds the log
  ahead of the tables tries the catch-up lock (`pg_try_advisory_xact_lock`); if another reader holds
  it, it waits for that catch-up to end, without holding the lock, and reads the checkpoint again.
  It is done if the checkpoint has reached the newest event it saw and no event the checkpoint
  lists as missing is visible to it; otherwise it catches up itself, as before. Before, it queued
  for the lock to repeat a catch-up that, under a write-heavy mix, had mostly been done already. A
  catch-up that applies nothing no longer rewrites the checkpoint. The three rules hold: only the
  lock's holder applies events or moves the checkpoint, in the log's order and in its own
  transaction, and a read sees every event it saw before (a late commit below the checkpoint
  still within `GAP_RECHECK` on the fast path). In a local profile (30% writes, 70% reads by id,
  one process) the mean read took about 45% less time at 16 threads and 30% less at 4.
- **PAM DSL: a Condition 5 failure raises `PamDsl::SpecialCategoryViolationError`,** where it
  raised `PamDsl::SensitivityViolationError`. The condition is about special categories (Art. 9,
  decided by the field's type); sensitivity is a separate Art. 32 risk tier that gates nothing,
  and the old name mixed the two. `SensitivityViolationError` stays as a deprecated alias of the
  new class until 2.0, so `rescue PamDsl::SensitivityViolationError` still catches it.
- **ModeSync adopts a switch the gate checks only if the gate cleared it.** It adopted the newest
  `applied` row of `lyra_mode_transitions` and checked nothing, so one `INSERT` moved every process
  from Monitor to ES-NoProj. A switch now records where it came from (`from_config`), whether the
  gate was overridden (`forced`) and the certificate of the clean check that cleared it
  (`certificate_id`). Other processes adopt a switch the gate checks (an escalation from Disabled
  or Monitor to Hijack or event sourcing, or leaving ES-NoProj, ES-Lazy or ES-Async for a mode
  that reads the tables) only if the row names that certificate (for the same `from -> to`,
  recorded before the row, named by no earlier switch) or is forced; whether the gate checks the
  switch is judged from the row's `from` and from where the previous switch left the application,
  so a row cannot claim a `from` that avoids the gate. A switch the gate does not check (Monitor to
  Disabled, ES-Sync to ES-NoProj) is adopted as recorded. No clock is compared, so a switch near
  the end of its certificate's life or under clock skew is adopted. With the gate off, switches are
  adopted as recorded. A refusal is logged once; an error while deciding leaves the
  row to be tried again. Columns Lyra adds to its own tables are added outside the caller's
  transaction and safely when two processes add one at once. This guards against mistakes and
  naive writes, not against anyone who can write the table.

- **The dashboard and `Lyra::EventFlow` read a window of the log, not all of it.** The flow and
  privacy routes read the newest `config.dashboard_max_events` events (10,000 by default; `?limit=`
  may only lower it), leaving out the access log's own entries, which would otherwise fill the
  window as soon as the access log is on, and report `window: { limit:, returned:, truncated:,
  skipped: }`. A subject's timeline reads that record's own stream (its newest events, up to the
  limit), not the log; what a user did to other records is the `flow/user_actions` route, which
  lists at most `?actions=` actions. With `config.record_access_events` on, a dashboard read is
  recorded in `Lyra::DataAccess$Dashboard` (route, scope, how much came back, never a value). The
  GDPR report helpers still read the whole log, a batch of 1,000 at a time.
- **A save that changes nothing records no event, in every mode.** Monitor, Hijack and event
  sourcing each appended an `Updated` with no changes for a `save` that changed no attribute.
  An update carries its changes, and there were none; Hijack and event sourcing still refuse such a
  save on a destroyed record, as for any write.
- **One event shape in every mode**. Monitor, the command handler of Hijack and event
  sourcing, bypass writes, Genesis and repair now build the payload with `Lyra::EventData`: a
  create or an import carries the record's `attributes` and no `changes`; an update carries its
  `changes` as `[old, new]` pairs and no `attributes`; a destroy carries neither. Before, Monitor's
  events carried the record on an update and a destroy and listed every column in a create's
  `changes`, and a Hijack or event-sourcing update stored its delta twice (`attributes: { changes: … }`
  beside `changes`). Every mode now sets `metadata[:source]` (`lyra_interceptor` for Monitor,
  `lyra_command_handler` for the others). Replay reads a create's `attributes` and an update's
  `changes`; events in the old per-mode shapes are not supported (see Breaking).
  The smaller events cost less to serialise and store, and copy less personal data into the log.
- **Personal data is detected in an event's fields.** `Lyra::Event.fields_of(event)` gives a create's
  attributes or an update's new values; the privacy and flow controllers, `EventFlow`, `EventGraph`,
  `Timeline`, Lyra's GDPR helpers and the PAM DSL's compliance reports use it. They read an event's
  `attributes` alone, so an update, which now carries none, would have reported no personal data
  (a Hijack or event-sourcing update already did, because its `attributes` held only `changes`).
- **A destroy no longer keeps the record's final state** in Monitor. It is in the events before it;
  the audit trail view shows no final state for a destroy.
- **DualView compares `created_at` and `updated_at`.** They were left out of the comparison; a row
  whose timestamp differs from its events is now a difference, and `lyra:repair` records it like
  any other.
- **A bare `touch_all` publishes an update per row** whose only change is `updated_at`, as an
  instance `touch` already did. Bulk bypass events (`update_all`, `upsert_all` and the like) now
  list `created_at` and `updated_at` among their changes when those moved, so an upsert's event
  carries `updated_at` beside the columns it set.
- **A cheaper destroyed check.** Before every update and destroy in ES-NoProj, ES-Async and
  ES-Lazy, the check that the record was not destroyed (0.9.3) read and deserialized the stream's
  last event through Rails Event Store, its data and metadata, to learn its operation. It now
  decides from the stream's last replayed event (Fixed, above), read with a query over the event
  store's own tables (`Lyra::StreamTail`) that returns each event's id, type and stored data and
  deserializes nothing. The usual update costs that one query: the last event is positively a
  replayed create, import or update when its type ends in `Created`, `Updated` or `Imported` and
  its data records no destroy's operation and no `replay: false`. Data in a `json` or `jsonb`
  column comes back as a Hash and is decided from directly. Any other event is read through Rails
  Event Store by its id, one query each, and an event that is not replayed sends the check to the
  one before it. The walk back reads one event, then pages of 50, and skips in SQL the events Lyra
  never replays (`AssociationLinked`, `AssociationUnlinked`, `ErasureApplied`), so a record linked
  by hundreds of others still costs one query. Domain-event rules and `event_mapping` may no longer
  use those three names (`ArgumentError`). The type alone cannot decide, since custom event names
  and domain events can store a destroy under any name. The shortcut is taken only with
  `RubyEventStore::ActiveRecord::EventRepository`, RES's default mapper and the YAML, JSON or
  `Lyra::EventSerializer` serializer, and for those it gives the answer a read through Rails Event
  Store gives. With a mapper that transforms records on load, another serializer or another
  repository, the stream is read through Rails Event Store. The same happens when the query fails
  the first time it is tried, for example after a Rails Event Store upgrade that changed its
  tables. That first try runs during the first check, in a savepoint when a transaction is open,
  so it cannot abort the write. The lock is unchanged. Locally (no YJIT), the check on a stream
  ending in an update takes 0.9 ms and 43 allocations instead of 2.3 ms and about 900, and an
  update or destroy in these three modes allocates about 860 fewer objects. Refusing a write to a
  destroyed record costs about what it did.
- **The bypass-write net (`Lyra::Verification::BypassWorkflow`) models the writes that skip
  callbacks as 1.0.0 makes them.** A third store, a table that lags the event store (ES-Async,
  ES-Lazy: `streams_checked` with `table_backed`, as `BypassEvents.checks_streams?` and
  `locks_rows?`), whose writes read each record's stream under its aggregate lock as ES-NoProj's
  do; a new ending, `unchanged`, for a write to a record destroyed since it was read (its stream
  ends in a destroy, or, in ES-Sync, Hijack and Monitor, its row is gone: no write, no event);
  the `Genesis::Refused` rejection of a row the model could not import, and the
  `BulkWriteLockLimitError` of a bulk write or `dependent: :nullify` over
  `bulk_write_lock_limit` or `upsert_all` where the streams are checked (and of `update_all`,
  `insert_all(!)` and `upsert_all` whose unique values' locks exceed it, ES-Sync included), and that upsert's
  `RecordDestroyedError` (see Fixed); and `insert_all(!)` as a class of its own (a new row:
  nothing to admit, written to the table in ES-NoProj too; a key already there is skipped by
  `insert_all`, unchanged, and fails `insert_all!`). `BypassWorkflow.coverage`
  counts a dead marking as covered only when it ends in exactly one way: `rejected` alone,
  `store_changed` with `event_logged`, or `unchanged` alone (and returns how many end
  unchanged, `unchanged:`); a store change without an event, an event logged for an unchanged
  write, or a rejection beside a write or an event is reported. `ROUTED` lists ES-NoProj's
  class-level `update_counters`, `increment_counter` and `decrement_counter`, which write through
  `update_all`. Rails' association writes (`Lyra::Associations::Maintenance`, see Fixed) enter
  past the strict guard: `request_nullify` is the nullify Rails marked (an application's
  `update_all(fk: nil)` is `request_bulk`), a `has_one`'s `dependent: :nullify` the column path
  (`request_association_column`), removing records from a `has_many :through` over a monitored
  model the bulk path (`request_through_delete`). `has_and_belongs_to_many` join-row deletes are
  a class of their own, `link`: Rails' marked deletes are never refused (`request_unlink`), the
  application's `delete_all` on a join model is guarded (`request_join`), and either writes the
  table, in every store, then logs `AssociationUnlinked` (`write_unlink`, `publish_unlink`); the
  application's `insert_all`, `insert_all!` and `upsert_all` of join rows are guarded the same
  way (`request_join_insert`), write, then log `AssociationLinked` (`write_link`, `publish_link`),
  or end unchanged (`skip_conflict_link`) or refused (`refuse_conflict_link`). Bulk inserts and
  upserts are first brought to the rows Monitor's table would have where the streams are checked
  (`bring_insert_keys_up_to_date`, `bring_upsert_rows_up_to_date`; `insert_as_given` and
  `upsert_as_given` elsewhere), and a bulk insert's locks can exceed the limit
  (`refuse_lock_limit_insert`); where it reads keys or unique values from the event store, Genesis
  refuses it for a model whose import was refused (`refuse_genesis_insert`). An `update_column(s)` or `update_all` whose value a unique index
  refuses is rejected, writing and logging nothing (`refuse_unique_column`, `refuse_unique_bulk`:
  the table's `UPDATE` raises, and in ES-NoProj, ES-Async and ES-Lazy the event store is checked,
  see Fixed), and so is an `upsert_all` whose value of an index other than its conflict columns
  another record holds (`refuse_unique_upsert`: the table's statement, or in ES-Async and ES-Lazy
  the event store). The net now has 38 places, 87 transitions and 181 reachable markings (was 25,
  36 and 72); it is 1-bounded, has no dead transition, and all 18 dead markings (was 7) are
  covered.

### Removed
- **`Lyra::Associations::EventAware`** (`event_aware_belongs_to`, `event_aware_has_many`), an
  opt-in concern that nothing used, superseded by the association interceptor, read-your-writes
  and ES-Lazy. Its `has_many` never added pending records (its `PendingRecords` returned none),
  and the records its `belongs_to` rebuilt from events (`VirtualRecord`) bypassed Lyra's read
  path: their values were the events' own, not converted to the attribute types; the target's
  default scopes were not applied, so a record the scoped lookup did not find (soft-deleted, say)
  came back from its events; and purpose-bound reads did not check them.

### Documented
- **`allow_for` widens, it does not restrict.** A field may be used for a purpose when its
  `allow_for` names the purpose or the purpose's `requires`/`optionally` names the field
  (`Policy#allowed?` takes the union, as before). The PAM DSL README, PRIVACY_COMPLIANCE.md,
  API_REFERENCE.md and the methods' comments now say so. No behaviour change.

 
### Known issues
- **ES-Lazy: a transaction that reads and then takes a record's aggregate lock can deadlock against a
  bulk write.** The catch-up a read begins with writes the rows of the records whose events it
  applies without their aggregate locks, and inside a transaction those rows stay locked until it
  ends. When the transaction then takes a record's aggregate lock (a write through callbacks,
  `update_all`) that a bulk write holds while it waits for one of those rows (to bring it up to
  date before writing it), the two wait for each other; PostgreSQL detects it and aborts one with
  `ActiveRecord::Deadlocked`, and nothing of the aborted one is written or recorded. Retry the
  transaction, or do the reads outside it (docs/TROUBLESHOOTING.md, Concurrency Issues). A
  transaction that writes several records in an order of its own can deadlock against another, or
  a bulk write, as plain Active Record's row locks do; take them in one order (by primary key) and
  retry on `ActiveRecord::Deadlocked` (same section).

## [0.9.3] - 2026-11-04

**Security update.** A thorough review of Lyra's code against the claims made for it found the
defects below. None of them touches the gradual migration itself: the modes, the interception
of writes, the mapping of operations to events, the checked transitions between modes, and the
results that rest on them are unchanged. The defects are in the dashboard, the GDPR helpers, the
hand-over from PaperTrail and the operator tasks. Upgrade if the dashboard is open to anyone, or if
the Art. 15/20 export, the retention check, `lyra:erase` or the policy generator is used. PAM DSL
moves to 0.9.3 for its policy generator, and PetriFlow to 0.9.3 for the way it runs Graphviz
(below).

### Security
- **The dashboard resolves only monitored models.** The routes that take a model
  (`dashboard/compare`, `discrepancies`, `model_overview`, `audit_trail`, `model_heatmap`,
  `event_list`, `flow/event_chain`, `flow/visualization`) called `constantize` on the request
  parameter and returned the record's attributes. Any user the dashboard admitted could therefore
  read the rows of any Active Record model, monitored or not, including password digests and
  tokens. They now answer 404 for a model Lyra does not monitor. List sizes, day ranges and graph
  depth are clamped (`limit` at most 1,000, 500 or 100 by route, `days` at most 90, `depth` at most
  3). As before, the dashboard is closed outside development and test unless
  `config.dashboard_authorization` admits the request.
- **The Art. 15/20 export gathers the subject's data, not the subject's edits.**
  `Lyra::Privacy::GDPRCompliance` selected every event whose metadata named the subject as its
  *actor*. A staff member's export therefore held the records they had edited, which is other
  people's data, while a subject's own records written by staff could be missed. It now gathers
  the events of the subject's own record, of records that refer to the subject by foreign key
  (`<subject_type>_id`, e.g. `user_id`), and of events that name the subject explicitly. The
  dashboard's subject timeline does the same; who did what remains the `user_actions` view.
- **PetriFlow runs Graphviz without a shell.** `VerificationRunner` (its PNG, PDF and SVG
  images) and `Visualization::Graphviz#render` built a shell command from the report directory,
  the workflow's name, the output path and the layout, so a path or name with shell syntax in it
  would have run as a command. They now pass Graphviz its arguments one by one, and `render`
  accepts only Graphviz's layout engines (`Graphviz::LAYOUTS`) and plain format names. The
  values come from the developer, not from a request; a static analysis (Brakeman) flagged both.

### Fixed
- **PaperTrail is switched off per model, not per request.** Where Lyra takes over a write
  (Hijack and the event-sourcing modes), it set `PaperTrail.request.enabled = false`. That turned
  versioning off for every model for the rest of the request or job thread and never turned it
  back on, so writes to versioned models Lyra does not monitor lost their versions, with no event
  in their place. Lyra now calls `PaperTrail.request.disable_model` for the model it takes over.
- **The retention check reads the policies.** `GDPRCompliance#retention_compliance_check` ignored
  the policies' `retention` blocks in favour of hard-coded periods for models named Payment,
  Invoice, Student and Enrollment, and raised `TypeError` when `config.retention_policy` was a
  single duration such as `7.years`. It now takes each monitored model's period from its policy,
  over the configured default. `retention_compliance_with_policy` called a method that did not
  exist.
- **Erasures and mode switches name who made them.** `rake lyra:erase` passes `OPERATOR=` as
  `erased_by`, falling back to `LYRA_OPERATOR`, then the operating-system user and process; before,
  it recorded no one. Every mode switch records the same in a new `actor` column of
  `lyra_mode_transitions`, added on first use to an existing table, and logs it. A switch to
  Disabled turns purpose checks and the access log off, so it is now attributable.
- **Erasure is limited to personal fields.** `Lyra::Erasure.erase!` (and `lyra:erase FIELDS=`)
  erased any column it was named, rewriting history in place under an Art. 17 reason. It now
  refuses a column that neither the record's policy declares personal nor the events' privacy
  stamps list, unless called with `any_fields: true` (`ANY_FIELDS=1`).
- **Bulk writes lock the rows they write.** `update_all` and `delete_all` (and the writes routed
  through them: `update_counters`, `touch_all`, `delete_by`, `dependent: :delete_all`) took their
  snapshot with a plain read, so under READ COMMITTED a row another transaction changed or
  inserted between the snapshot and the write could be written without an event. They now lock
  the matched rows (`FOR UPDATE`, through a subquery of keys so DISTINCT and joins work) and write
  exactly those, inside a transaction in every mode that keeps tables. A failed append rolls back
  only its savepoint, so in Monitor the write still stands.
- **A destroyed record is not written again.** Two writers of one record, a destroy and an
  update, could both pass: the second found no row to lock, fell back to the advisory lock and
  appended after the Destroyed event, leaving a stream that brought the record back
  (`Lyra.state_at`, DualView). An update or destroy of a record whose stream ends in a destroy now
  raises `Lyra::RecordDestroyedError` (a `RecordNotFound`). To check it, ES-NoProj and ES-Lazy now
  take the lock on the aggregate for updates and destroys, as the other event-sourcing modes did.
- **PAM DSL 0.9.3: the policy generator no longer chooses legal bases.** It wrote one for each
  purpose it drafted: contract for billing, which tax law often makes a legal obligation;
  legitimate interests for analytics, which a public authority cannot use for its tasks; consent
  without a consent block. A drafted purpose now reads `basis :undetermined` with the usual
  candidate and its caveats as a comment. Access under it is refused
  (`PamDsl::UndeterminedBasisError`), and the Article 30 register lists it as a gap, until the
  controller decides.

### Documented
- **The dashboard is a development tool.** Opening it in production with
  `config.dashboard_authorization` is at the deployer's risk: whoever the rule admits reads every
  data subject's records and history, with no declared purpose and no access-log entry, and the
  rule covers the whole dashboard. What bringing it to production would take is listed in the
  README (Dashboard) as a future feature.

### Dependencies
- **The development lockfile is updated against published advisories** (bundler-audit,
  2026-11-04): `rack`, `nokogiri`, `loofah`, `rails-html-sanitizer`, `crass` and `sqlite3` (tests
  only). The gems' own dependency declarations are unchanged: none pins a vulnerable version, and
  an application resolves its own.

### Known limitations (unchanged)
- PAM DSL keeps consent records in memory, per process. Persistent consent storage is future
  work; an application that relies on consent must store it. Documented in the PAM DSL README
  ("Runtime consent store"), on `ConsentStore`, and in `docs/PRIVACY_COMPLIANCE.md`.

## [0.9.2] - 2026-11-03

One fix in Lyra; PAM DSL and PetriFlow are unchanged (0.9.1).

### Released
- `orfeas_lyra` on RubyGems, built from tag `v0.9.2` and pushed on 2026-11-03

### Fixed
- **ES-Async read-your-writes no longer races a projection job.** With read-your-writes
  (`each_write: true`), the writer projected its own event without the per-stream lock that
  `AsyncProjectionJob` holds. A job that had read the record's stream before that event
  committed could write the row afterwards, putting it back to the older value until the newer
  event's job ran: a reader in between saw the record step back (an application's suite, run
  with real background projection, read a refund as "approved" just after it was "processed").
  `Lyra::Consistency::ReadYourWrites` now takes the job's lock before projecting, held to the
  end of the writer's transaction. Final states converged before as well. Plain ES-Async (no
  read-your-writes) was not affected. `test/concurrent_same_record_test.rb` reproduces the
  interleaving.

## [0.9.1] - 2026-11-02

Lyra's changes since 0.9.0; PAM DSL and PetriFlow change only in their gem descriptions.

### Released
- The gems on RubyGems (`orfeas_lyra`, `orfeas_petri_flow`, `orfeas_pam_dsl`), built from tag
  `v0.9.1` and pushed on 2026-11-02

### Added
- **Writes are grouped into causal chains by default** (`config.correlate_writes`, on). Before,
  Lyra carried correlation and causation only where the application called
  `Lyra::Correlation.with_id`/`Lyra::Causation.with_id`, which no example did: every event was its
  own chain. Now:
  - every event-producing write runs in a write scope (`around_save`/`around_destroy`, first in
    the chain) that fixes its event id before its callbacks run, so a write made inside them
    records that event as its `causation_id`; a record saving itself inside its own callbacks is
    caused by the outer save;
  - the outermost write opens the correlation when none is in scope, its own event id, as the
    event store does for a root event;
  - `Lyra::Correlation::Middleware`, installed by the engine, gives the writes of one HTTP request
    one correlation, the request id; a correlation already in scope is kept;
  - `Lyra::Correlation::Job`, included into `ActiveJob::Base` by the engine, gives the writes of
    one job the correlation in scope where the job was created, or the job id without one, and a
    write in scope there as their cause. Both are taken when the job is created, so a job deferred
    to after the commit (`enqueue_after_transaction_commit`) keeps them, and travel in its payload
    (`lyra_correlation_id`, `lyra_causation_id`), so a retry does too. A job created inside a
    transaction and sent at once (the Rails default) could outlive a rollback of its cause; its
    cause is kept when it runs only if that event is in the log, so no job names a cause the log
    lacks (one that runs before the enqueuing transaction commits loses the link).
  Monitor, Hijack and event-sourcing events alike (`DomainEvents.build` takes the pre-assigned
  `event_id:`, given once per write). The Olist replay runs each step as one request would
  (`test/write_correlation_test.rb`).

### Changed
- **ORFEAS is expanded as the words its letters stand for**: Object-Relational Framework for
  Event-Aware Systems (README, `docs/ARCHITECTURE.md` and its citation, gem descriptions). It
  read "Object-Relational to Event-Sourcing Architecture", which has no F.

### Fixed
- **Writes that skip callbacks name who made them.** Events of `update_columns`, `touch`,
  `delete`, `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify`, and
  `has_and_belongs_to_many` links, carried correlation and causation but neither `user_id` nor
  `request_id`, so the same request's writes named a user only if they ran callbacks. They now
  take both from `Current`, as the documentation already said. Events written before this keep no
  actor; their correlation still ties them to the request's other writes.
- **`AsyncProjectionJob` warns again when its event is not in the log.** The warning sat in a
  rescue of `RubyEventStore::EventNotFound`, which `read.event` never raises (it returns nil;
  `read.event!` raises), so it was never logged. The job still did nothing for a missing event.

## [0.9.0] - 2026-10-25

Everything since 0.8.0, the version the PAM article describes.

### Released
- The gems on RubyGems (`orfeas_lyra`, `orfeas_petri_flow`, `orfeas_pam_dsl`), built from tag
  `v0.9.0` (2026-10-19); the entries marked *after the tag* are not in them
- The replication package: https://doi.org/10.5281/zenodo.17770613
- The benchmark results: https://doi.org/10.5281/zenodo.23640846

### Added
- **`config.models` takes namespace patterns, `:all` and a denylist** (`Lyra::ModelSelection`):
  `config.models = %w[Spree::* Order]`, `config.models = :all`,
  `config.models = :all, except: %w[Session]`. Patterns and `:all` enrol only eligible models
  (concrete, named, with a table and a single-column primary key, base classes of an STI
  hierarchy), after eager-loading the application's code. The event store's tables, Lyra's own and
  those of Solid Cache/Queue/Cable, Active Storage, Action Text, Action Mailbox and PaperTrail are
  never enrolled; naming one fails the boot. A pattern matching nothing warns; `:all` outside
  Monitor mode warns. On a Solidus application `:all` enrols 90 models, excludes 28 and leaves 48
  abstract classes and STI subclasses to their bases (`test/model_selection_test.rb`).
- **`ReadYourWrites.with_guaranteed_read(each_write: true)`**: each write in the block is projected
  as it is made, so reads later in the same block see it (by default the block projects when it
  ends). For code that writes and reads back in one unit of work, as Solidus's checkout does
  (a replay of 2,000 Olist orders through Solidus under ES-Async matched the oracle for 135 orders,
  and for 1,992, as plain ActiveRecord does, with each step in such a block).
  `test/projections/read_your_writes_async_test.rb`. The controller concern takes it per
  controller, inherited by subclasses, so an application is adapted from an initializer:
  `Spree::BaseController.include Lyra::Consistency::ControllerConcern` and
  `Spree::BaseController.lyra_read_your_writes each_write: true`
  (`test/consistency/controller_concern_test.rb`). `docs/API_REFERENCE.md` named the concern
  `ReadYourWrites::ControllerConcern`, which does not exist; it is `Consistency::ControllerConcern`.
- **`config.lock_aggregate_before_append`** (default `true`): Hijack, ES-Sync and ES-Async lock
  the aggregate before appending. Two writers of one record could append in one order and write the
  row in the other, leaving the row at a value its log does not replay to; seen in the wild, 2
  rounds of 120 with 8 threads on one record, and reproduced deterministically
  (`test/concurrent_same_record_test.rb`). An update or destroy now locks the record's row before
  its event is appended, held to the end of the transaction (assumption L of Theorem 5), in the
  strength the write takes anyway (PostgreSQL `FOR NO KEY UPDATE` for an update, `FOR UPDATE` for
  a destroy), so a write takes the locks plain ActiveRecord takes, in the same order, and adds no
  deadlock. A first version took an advisory lock on the stream before the row lock; it deadlocked
  against a writer that holds the row first (`record.lock!`, `with_lock`) and then updates it,
  where plain ActiveRecord only makes the update wait. The advisory lock remains for a record with
  no row. `test/aggregate_lock_deadlock_test.rb`: writes to several records in one order never
  deadlock, opposite orders deadlock exactly as plain ActiveRecord does, a row lock held first
  does not deadlock a plain writer. SQLite needs no lock: it serialises writers from the first
  write, which is the append (`test/sqlite_same_record_test.rb`). ES-Async writers take the
  advisory lock on the stream (they do not write the row, the projection job does, so they never
  wait for the row's lock); it makes a record's events commit in append order, which the job's
  checkpoint relies on (below). Creates, Monitor, ES-Lazy and ES-NoProj are unchanged
  (`test/aggregate_lock_statements_test.rb`). Cost: an update issues three more SQL statements
  (the lock, then the savepoint pair the append now needs), so Hijack and ES-Sync updates go from
  5 to 8 statements and ES-Async's from 4 to 7, and a destroy one more; on one contended record
  Hijack's throughput falls from about 90 to about 52 ops/s. Set `false` for the previous
  behaviour and its numbers.
- **ES-Async's projection job applies only the events after the stream's checkpoint**
  (`Lyra::Projections::AsyncCheckpoint`, table `lyra_async_checkpoints`, created on first use)
  instead of replaying the record's whole stream, so a record's jobs cost what its history is
  long, not its square. Exact because the lock above makes a record's commits follow its
  appends; with the lock off, or without a usable checkpoint (its event gone), the job replays
  the whole stream. A checkpoint older than the row only re-applies events the row already has,
  which is harmless (`test/projections/async_checkpoint_test.rb`).
- `test/projections/cached_projection_concurrency_test.rb`: readers and writers of one record under
  ES-NoProj see only states the stream had, never go back, and converge.
- **Reference links for ES-NoProj** (`Lyra::Projections::ReferenceLinks`, `config.reference_links`,
  default `:auto`). An event that sets a `belongs_to` foreign key is also linked into the stream
  `Model.foreign_key$value`, the way Rails Event Store links events by metadata. A lookup by that
  key, including the dependent-association lookups Active Record makes on destroy, reads the
  stream for candidates and keeps those whose current state still matches, so moved and destroyed
  children drop out and the answer is exact, without rebuilding every record of the model.
  `:auto` writes links in ES-NoProj only, so no other mode pays; `true` and `false` force it.
  Events stored while linking was off are linked before a model's first lookup in a process, from
  a checkpoint kept in the store (`$lyra_reference_links$Model`). On the Aegean testbed this made
  an ES-NoProj delete about 30 times faster at 16 threads and about 250 times at 64.
- **`config.monitor_append_failure`** (opt-in; default `:log`, unchanged). With `:fail_write`,
  Monitor fails a write whose event cannot be stored, raising `EventStoreUnavailableError` and
  rolling the write back (bulk writes included), as Hijack and the event-sourcing modes always
  do. Row and event already commit together; the setting decides only what a failed append
  does. Validated on assignment.
- **Trace conformance test** (`test/verification/trace_conformance_test.rb`). It records the
  steps Lyra takes on real writes in every mode (event built, applied to the aggregate, stored;
  row written; commit) and replays each trace token by token on a PetriFlow net: the paper's
  core net with the row write placed as each mode places it. Every trace must be a firing
  sequence ending in the net's final place, each operation must build exactly one event of its
  own type, and a trace in another order is rejected. It found that Hijack and the
  event-sourcing modes apply the event to the aggregate before storing it, the order the formal
  model now uses.
- **`LYRA_DISABLE_PETRI_FLOW=true`** — runs Lyra as without petri_flow, as
  `LYRA_DISABLE_PAM_DSL=true` does for PAM DSL.
- **`lyra:workflows:generate OUTPUT_DIR=... REPORTS_DIR=...`** — write the workflow files and
  the reports to other directories than `app/workflows/` and `reports/`.
- **Dashboard authorization** (`config.dashboard_authorization`) — a proc run on the engine's
  controller before every action (`instance_exec`, and given the controller when it takes an
  argument); truthy allows, falsy answers 403. Unset, the dashboard is open in development and
  test only and refused everywhere else with a log line, since its privacy pages show a data
  subject's personal data. Example: `->(controller) { controller.current_user&.admin? }`.
- **`mode=` and `projection_mode=` validate** — one of `Configuration::MODES` and the new
  `Configuration::PROJECTION_MODES`; a string is taken as its symbol, anything else raises
  `ArgumentError` naming the valid values.
- **`lyra:erase MAX_COPIES=n`** — passed to `Lyra::Erasure.erase!` as `max_copies:`; the task
  also prints how many values were left as shared.
- **The blog example runs again** (`examples/blog_app`) — rebuilt for Rails 8.1,
  RailsEventStore 3 and PostgreSQL, with `bin/setup` and a passing test suite.
- **ES-NoProj runs Solidus** — the Olist replay passes under `projection_mode :disabled`
  (6 of 6 orders end as Olist records them). Association queries (`variant.prices.find_by`,
  `.where`, `.find_or_create_by!`) run on the records the event store holds for the owner, and
  `:through`, polymorphic (`as:`) and scoped associations are read correctly: a `:through`
  association was filtered on a foreign key its target does not have. Calculations and plucks on
  an association (`payment.refunds.sum(:amount)`) read the events instead of the empty table.
  Building through an association or a `where` takes its conditions, as ActiveRecord's
  `scope_for_create` does. `CachedRelation` gains `group` with grouped `count`/`sum`/`average`/
  `minimum`/`maximum`, `extending`, class attributes (`discard_column`), records as condition
  values (mapped to their ids) and the relation readers ActiveRecord's calculations ask for.
- **Erasure driven by the policy, opt-in** (`Lyra::Retention`, `config.retention_executor`,
  `config.retention_anchors`, `bin/rails lyra:retention:apply [DRY_RUN=1] [MODELS=]`,
  `Lyra::RetentionJob`) — applies the policy's retention rules: for each monitored model with a
  rule, a record past its period gets the rule's `on_expiry` — `:anonymize` (Lyra::Erasure),
  `:hard_delete` (erase, then destroy through the write path), `:soft_delete` (`deleted_at` /
  `discarded_at` through the write path; skipped without one), `:archive` (skipped: no archive
  is named). Attributes with a shorter period of their own are erased first; rule conditions get
  the record; already-erased attributes are skipped, so runs are idempotent. The period runs
  from `created_at` or the column named per model. Off by default; a dry run works either way.
  The privacy interface gains `Policy#retention_rule`.
- **Erasure finds copies by value, and optionally everywhere** — `Lyra::Erasure` now also
  replaces an erased value wherever the record's events copy it under another name (a payload's
  `payer_email`). `everywhere: true` (`EVERYWHERE=1`) searches the whole log for the values:
  other records' events are scrubbed, their rows get the value replaced where they hold it, and
  each gets an `ErasureApplied`; `Result#copies` lists them. A value held by more than
  `max_copies` other records (default 10) is shared by many people, not a copy, and is left
  (`Result#shared_values` counts them): on the Olist replay a placeholder address shared by
  every customer took all 1,954 addresses with it. Only direct identifiers (the policy's email,
  phone, identifier, card, payment-token, IP, credential types) are searched for in other
  records: a name, city or postal code can be another customer's by coincidence (erasing one
  Olist customer's postal-code prefix took two other customers' addresses). Erasure writes rows with one `UPDATE` by id,
  so a record the application marks read-only (a Solidus address once an order uses it) is
  erased too.
- **Purpose-bound `pluck` and `pick`** — checked by the declared attributes they name (also
  inside SQL fragments), with the model (`"Registration$*"`) as subject, so a purpose whose
  consent the policy requires refuses them.
- **Purpose-bound reads** (`Lyra::PurposeBoundReads`, `Lyra.with_purpose`, `lyra_purpose` for
  controllers and jobs, `config.reads_without_purpose`) — a read of a monitored model with a
  privacy policy, made within a declared purpose, is checked through the policy's
  `validate_access!` with the record as subject: every declared attribute the query loaded must be
  allowed for the purpose, so loading more than the purpose needs is refused (data minimisation).
  No setting turns it on: the purpose does. Reads with no purpose follow
  `config.reads_without_purpose`: `:allow` (default), `:audit` (logged, and recorded as an audited
  access with purpose `none` when the access log is on) or `:deny` (`PurposeRequiredError`).
  Lyra's own reads (projections, bypass snapshots, Genesis, DualView, mode checks, repair,
  erasure) are exempt; reads that load no model are not checked. Every monitored model gains an
  `after_find`, which returns at once when no purpose is in scope and reads without one are
  allowed.
- **Erasure executor** (`Lyra::Erasure.erase!`, `bin/rails lyra:erase MODEL= ID= REASON=
  [FIELDS=]`, `Lyra::Events::ErasureApplied`) — erases one record's personal attributes (declared
  by its policy or listed by its events' privacy stamps, or exactly `fields:`) from the row and
  from every event in its stream, overwriting each event in place (same id, position, time):
  attributes, both sides of each change, and payload keys with the attribute's name. Appends
  `ErasureApplied` (fields, reason, who; never a value), which replay skips; the stream still
  replays to the anonymized row. Replacement is nil where allowed, `"erased:<id>"` for a NOT NULL
  string, else the column default. Works in every mode, with strict data access on and inside a
  purpose. On request only; not policy-driven, and crypto-shredding remains future work.
- **Event store failure policies, named** (`Lyra::EventStoreUnavailableError`, `Lyra.append_events`)
  — every event Lyra writes now goes through `Lyra.append_events`, which
  raises `EventStoreUnavailableError` (the store's error as its `cause`, the stream in its message)
  when the store fails. The policy is fixed by the mode: **fail-closed** in Hijack and every
  event-sourcing mode (the write fails with the error and rolls back), **log-and-continue** in
  Monitor (the write stands; the log line names the stream and points to `lyra:repair`). No
  in-memory retry queue: the store shares the application's database, a queue dies with its
  process, and a retried event could land behind a later one in its stream.
- **Repair after lost events** (`Lyra::Repair`, `bin/rails lyra:repair [DRY_RUN=1] [MODELS=...]`) —
  brings the event log back in line with the tables after Monitor lost events: an `Imported` event
  for a row with no events (or one its stream says was destroyed), an `Updated` event with the
  differing columns for a row that differs from its events, a `Destroyed` event for events with no
  row. Each record is re-checked and repaired under a lock on its row; repair events carry
  metadata `source: "lyra_repair"` and the problem repaired. Refused in Hijack and event sourcing,
  where the events are authoritative (rebuild the tables instead). `ModeTransition.record_ids` and
  `ModeTransition.discrepancy` expose the check it uses.
- **Access log** (`config.record_access_events`, default false; `Lyra::AccessLog`,
  `Lyra::Events::DataAccessed`, `Lyra::Events::DataAccessDenied`) — when on,
  every access the privacy policy validates (`validate_access!`) is recorded in the subject's
  access stream (`Lyra::DataAccess$<Model>$<id>`): `DataAccessed` when it went ahead (outcome
  `granted`, or `audited` with the violations audit mode let through), `DataAccessDenied` when
  strict mode refused it. Each carries the policy, purpose, legal basis, field names (never
  values) and outcome. Who accessed goes in the metadata: `user_id` and `ip_address` from the
  application's `Current.user` / `Current.ip_address`, request and correlation ids, and whatever
  `config.access_metadata_proc` returns for the access (for consoles, jobs and API tokens that
  `Current` does not know; a failing proc is logged and skipped). Every access is
  recorded, with no sampling; an access the store cannot record does not go ahead. Nothing is
  recorded in disabled mode, and the record's own stream is untouched. `AccessLog.for(subject)`
  reads them back. Off by default because reads can outnumber writes by orders of magnitude; the
  Aegean testbed turns it on with `LYRA_RECORD_ACCESS=1`, which also makes the benchmark's reads
  validate access, and records it in its benchmark reports. The Article 30 register stays
  PAM's `article_30_report`, generated from the declared policy.
- **Privacy stamps on events** (`config.annotate_privacy`, default false; `Lyra::Privacy.stamp`,
  `Lyra::Privacy.stamp_of`) — when on, every event that carries an
  attribute the model's privacy policy declares is stamped as it is built with
  `metadata[:privacy]`: the policy's name and, per attribute, its type, sensitivity, allowed
  purposes, retention period (ISO 8601) and the contexts it has a transformation for — never a
  value. Every declared attribute the event carries is annotated: a create's, import's or
  destroy's attributes, and an update's changes together with the whole row Monitor also records
  (annotating only the changes left 28,374 of an Olist replay's events carrying personal data
  unannotated). All four places events are built stamp them: Monitor, the command handler (Hijack,
  event sourcing, and so domain events), bypass events and Genesis imports. The stamp records the
  policy as it was when the data was written, unlike `annotations_for`, which reads today's
  policy; `stamp_of(event)` reads it back with string keys. Off by default because it adds work
  to every write (no SQL statements); the Aegean testbed turns it on with
  `LYRA_ANNOTATE_PRIVACY=1` and records it in its benchmark reports. The privacy `Annotation`
  gains a `transformations` member.
- **ModeSync: one mode per application** (`Lyra::ModeSync`, `config.mode_sync`,
  `config.mode_sync_interval`) — the latest switch recorded in `lyra_mode_transitions` is the
  application's mode; every process adopts a newer one within `mode_sync_interval` seconds
  (default 5), checking before each web request (Rack middleware), each background job and each
  write to a monitored model, never inside an open transaction. A runtime switch
  (`ModeTransition.to!`) used to change only the process that made it. `to!` now logs what the
  switch reaches. On wherever the Mode Transition Safety gate is (not in the test environment);
  the raw `config.mode =` setter is left alone. the migration guide (`docs/MIGRATION_GUIDE.md`, Switching modes) documents the
  deploy-time rule.
- **Mode Transition Safety** (`Lyra::ModeTransition`, `rake lyra:mode:check`)
  — a mode switch that changes the authoritative store is allowed only when rows and events
  agree for every monitored record: escalating from Disabled or Monitor to Hijack or event
  sourcing (rows that predate Lyra are imported by Genesis first), and leaving ES-NoProj,
  ES-Lazy or ES-Async for a mode that reads tables (`rebuild: true` rebuilds them first). The
  check compares every row and every stream in batches, reading the real table, then
  re-checks what changed while it ran, and stores a clean result as a certificate.
  `ModeTransition.to!` and the `enable_*!` helpers accept a fresh certificate after
  re-checking only what changed since, else run the full check, and raise `Refused` with the
  discrepancies; `force: true` overrides. At boot, a switch from the mode the application last
  ran in needs a certificate (`LYRA_FORCE_MODE_TRANSITION=1` overrides; rake processes are
  exempt). `config.mode_transition_gate`: nil (default) gates everywhere but the test
  environment; `config.mode = ...` stays the raw, ungated setter.
- **Sampled DualView verification** (`config.dual_view_sample_rate`, default 0.0, off;
  `config.dual_view_discrepancy_handler`) — after a write commits, a sampled share of writes
  is compared with its events; a discrepancy is logged and passed to the handler, and the write
  is never failed. Skipped in ES-NoProj, ES-Lazy and ES-Async, whose tables lag by design.
- **Domain events** (`monitor_with_lyra domain_events: [...]`, `Lyra::DomainEvents`)
  — rules name a write's event after what it means instead of the CRUD
  operation: `{ name: "PaymentCompleted", on: %i[create update], if: ->(payment, changes) { ... } }`.
  The first matching rule names the write's own event, which keeps Lyra's envelope (model, id,
  operation, attributes, changes), so replay, projections, DualView and `Lyra.state_at` work
  unchanged; a write no rule matches keeps its CRUD event. `payload:` adds fields for the
  event's consumers under `data[:payload]`; `class:` uses an event class of your own (a
  `RubyEventStore::Event` subclass) instead of a generated `Lyra::Events::<name>`;
  `also: true` emits an additional event from the same write, in the same stream and
  transaction, marked `replay: false` and pointing to the write's own event through its
  `causation_id`. Works in Monitor, Hijack and every event-sourcing mode; writes that skip
  callbacks are still recorded as CRUD bypass events. Generated event classes are registered
  at boot. A rule whose block raises fails the write where events are the record (Hijack,
  event sourcing) and is logged in Monitor. Commands now carry their `record`.
- **Configuration surface**: `config.models = %w[Order Payment]` (or a
  hash of name => options) declares the monitored models by name in the initializer; once the
  application's code has loaded, each is given `monitor_with_lyra`, with no model file edited,
  and a name that does not resolve fails the boot. `config.verify_mapping!` verifies the
  CRUD-to-event mapping at boot (`Lyra.verify_mapping!`: the PetriFlow lifecycle, mode and
  bypass nets through `CrudVerifier`, and a table and primary key for every monitored model)
  and stops the boot with `Lyra::MappingVerificationError` naming each failed check; called
  after boot it runs at once. `config.privacy_policy = :name` is the default policy for
  monitored models that name none of their own.
- **Point-in-time reconstruction** (`Lyra.state_at(model, id, time)`, `Model.as_of(time)`,
  `Lyra::Temporal`) — a record's attributes at a given time, rebuilt by replaying its stream up
  to the last event stored at or before then: `nil` if it did not exist yet or had been
  destroyed. `Model.as_of(time).find(id)` / `.find_by_id(id)` return read-only records and
  `.all` every record that existed then. For a row imported by Genesis, a time before its
  import raises `Lyra::Temporal::HistoryNotRecorded` instead of guessing (a time before its own
  `created_at` is `nil`). Works in every mode that records events, Monitor included.
- **ES-NoProj joins, evaluated in memory** (`Lyra::Projections::CachedJoins`) — `joins`,
  `left_joins`/`left_outer_joins`, `where.missing` and `where.associated` on `belongs_to`,
  `has_many` and `has_one` associations, with hash conditions on the joined table
  (`where(programs: { available: true })`, by table or association name), used to raise
  `UnsupportedQuery`. They are now evaluated as SQL would: a joined relation holds rows of a
  record and its partners; an inner join drops records without a partner; a `has_many` join
  repeats the record per partner (so `count` agrees, and `distinct` removes the repeats); a
  missing left-join partner behaves like NULL, including under `where.not`. Partners come from
  the joined model's streams if it is an ES-NoProj model, otherwise from one SQL query on its
  table. Still refused: SQL-string, nested, `:through`, polymorphic and scoped joins, a
  condition on a table not joined first, and `merge` with an arbitrary relation (so Solidus
  still needs ES-Lazy). `where` with no arguments now returns the where-chain, as in
  ActiveRecord.
- **Privacy provider interface** (`Lyra::Privacy`) — `Policy` (declared attributes and their
  `Annotation`s), `Detector` (name-based PII heuristic) and `Provider`, with null defaults when
  no provider is installed. PAM is an adapter (`Lyra::Privacy::Adapters::Pam`), loaded when
  `pam_dsl` is present. `Lyra::Privacy.annotations_for(event)` returns the annotation of every
  declared attribute an event touched. The foundation for `config.privacy_policy=` and PII
  annotation in event metadata. The testbed binds `Registration` and `PaymentTransaction` to its
  `:epay_data` policy, which adds nothing to the write path.
- **`Lyra::IdGenerator.reserves_safely?(model)`** — true for UUID keys and for integer keys
  backed by a PostgreSQL sequence. It uses the cached sequence lookup, so it adds no query per
  write once a table's sequence is known.
- **Bypass events for bulk writes** (`Lyra::BypassEvents`) — `update_all`, `delete_all`,
  `insert`/`insert_all(!)`, `upsert`/`upsert_all` and `dependent: :nullify` on a monitored model
  now publish one event per affected row, whatever the `strict_data_access` setting
  (`update_column(s)`, `touch` and `delete` already did). `update_all` publishes "updated" per
  row that changed; `delete_all` "destroyed" per row; inserts "created" per row; `upsert_all`
  finds existing rows by its conflict key (primary key, `unique_by:` columns or index name) and
  publishes "updated" for those, "created" for the rest. The caller's `returning:` result is
  unchanged, and the instance methods (`update_column(s)`, `touch`, `delete`) still build their
  events after the write.
- **`Lyra.projection_write { ... }`** — Lyra's own read-model writes: skips strict data access
  and publishes no bypass events. `ModelProjection` and `Rebuild` use it; use it for writes that
  must not reach the event stream, such as seeding or wiping a table.
- **Genesis: event streams for rows that predate Lyra** (`Lyra::Genesis`,
  `config.genesis`, `rake lyra:genesis`) — a row written before Lyra was enabled had no
  stream, so its first `Updated` event started a stream with no head, and DualView,
  `Rebuild` and ES-NoProj reads saw the record wrongly or not at all. On a model's first
  use in a process (its first write, or in ES-NoProj its first read or aggregate), every
  row without a stream now gets one `Imported` event holding the row as it is. `Imported`
  is replayed like `Created` everywhere state is rebuilt. Later uses cost nothing; when
  every row already has a stream the check is one query and takes no lock. The import
  runs under a per-model advisory lock on a connection of its own, so a long caller
  transaction does not block other first uses and a caller's rollback does not undo it.
  `config.genesis`: `:auto` (default, event-sourcing mode only), `true` (also Monitor and
  Hijack) or `false`. `rake lyra:genesis MODEL=...` imports ahead of time for large tables.
- **ES-NoProj SQL aggregates computed from streams only, with SQL semantics** —
  `count(column)`, `sum`, `average`, `minimum`, `maximum` and `calculate` on an ES-NoProj
  relation run over the records rebuilt from streams (rows that predate Lyra included, via
  Genesis). `sum` used to go through `to_f` (losing decimal precision) and now keeps the
  column's type, returning 0 over no rows; `average` returns a `BigDecimal` for integer and
  decimal columns, as ActiveRecord does; `count(column)` counts non-NULL values, where it
  used `present?` and dropped `""` and `false`. An SQL expression (`sum("price * qty")`)
  raises `UnsupportedQuery` instead of being guessed. Known difference: `average` keeps
  every digit of the quotient, while PostgreSQL rounds a numeric `AVG` to about 16
  significant digits.
- **ES-Lazy: event sourcing that projects on read** (`projection_mode :lazy`, in
  event-sourcing mode; `Lyra::Projections::LazyProjection`, `Lyra::Interceptors::LazyReads`)
  — writes store events only, as in ES-NoProj; before any database read, the tables are
  brought up to date from the event log, and the read runs as real SQL, so joins, merged
  relations, SQL fragments and aggregates all work. The log stays the only source of
  truth; the tables are a cache that `Rebuild` can recreate. Events are applied in the
  log's global order under a PostgreSQL advisory lock, against a checkpoint that also
  tracks ids still in flight (filled by replaying the record when they commit, forgotten
  after 5 minutes). Read-your-writes consistent. Needs no migration: the checkpoint table
  is created on first use. It runs Solidus, which ES-NoProj cannot: on 20 real Olist
  orders it matches plain ActiveRecord with DualView clean. Cost: every read first checks
  the log (about half ES-Sync's throughput in the replays).
- **`Lyra::EventSerializer`** — a JSON serializer for RailsEventStore that keeps time
  precision. Ruby's `JSON` writes `Time` with `Time#to_s`, dropping fractional seconds, so
  apps passing `serializer: JSON` stored `09:51:15.304` as `"09:51:15 UTC"`, and an update
  from `.304` to `.352` as no change at all. `Lyra::EventSerializer` writes times as ISO 8601
  with microseconds and `BigDecimal` as its exact decimal string; `load` is plain
  `JSON.parse`. Opt in with
  `EventRepository.new(serializer: Lyra::EventSerializer)`. Lyra's default client (RES's
  YAML serializer) was not affected. Found by replaying the BPI Challenge 2017 log
  (`examples/bpi2017_loan_app`), whose timestamps carry milliseconds.
### Changed
- **Documentation** (*after the tag*) — `docs/PERFORMANCE.md` gives the 0.9.0 measurement (three runs, with
  controls for PaperTrail and for the lock on the aggregate), the SQL statements per write under the
  lock, and the published runs (https://doi.org/10.5281/zenodo.23640846); the install instructions
  take the gems from RubyGems (`"~> 0.9"`); the case studies, benchmark harness and formal-model
  scripts are referred to as the replication package (https://doi.org/10.5281/zenodo.17770613).
  Comments no longer cite issue numbers; `lib/` changes in comments only.
- **The Rakefile's testbed tasks** (*after the tag*) say where the testbed is when it is absent, and `stats:all`
  skips it.
- **ES-NoProj reads**: a stale cache entry is brought up to date from the events after its stamp
  instead of a full replay; cache entries have a process-local copy in front of the shared cache;
  an association's records are read when first needed, and a reference-link lookup intersects
  every indexed key and takes candidate ids from the stream table; `Model.new` reads no record.
  A replay of 640 Olist orders through Solidus took 855 s where it took 2,229 s, with the same
  end state.
- **`ModeTransition.to!` links before switching into ES-NoProj.** Entering `event_sourcing`
  with `projection_mode: :disabled` first runs a full reference-link pass over the monitored
  models, so lookups are complete from the first one.
- **Documentation regrouped.** `docs/ADOPTION.md` and `docs/MODE_TRANSITIONS.md` are now
  sections of `docs/MIGRATION_GUIDE.md` (Adopting Lyra in an existing application; Switching
  modes); `docs/ORFEAS_FRAMEWORK_OVERVIEW.md` is the opening of `docs/ARCHITECTURE.md` (About
  ORFEAS); `docs/PROJECTIONS_DATA_ACCESS_MONITORING.md` is split between `ARCHITECTURE.md`
  (projections, write-side monitoring) and `docs/PRIVACY_COMPLIANCE.md` (read-side monitoring).
  Claims were checked against the code on the way. `docs/PERFORMANCE.md` no longer presents the
  withdrawn July 2026 figures: it explains each mode's cost in SQL statements per write, and
  the throughput is being re-measured.
- **The workflow generator's mode nets name what Lyra does.** Their steps were labelled with
  methods that do not exist (`CommandHandler.validate`, `CommandHandler.execute`,
  `Projection.apply`, `EventStore.append_to_stream`) or with `Aggregate.apply(command)`, and
  the Monitor net called the event store through `Lyra::Event.publish`. Each step now names the
  method Lyra calls, in the order the trace conformance test observes; the generator no longer
  claims to introspect the implementation (the mode nets are written by hand). The shipped
  `app/workflows/*_mode_workflow.rb` files are regenerated.
- **Ruby 4.0 or later is required** (`required_ruby_version >= 4.0`, was `>= 3.4.5`); CI tests
  Ruby 4.0. The project runs 4.0.7.
- **Article 30 register (PAM)** — `pam_dsl:report:article_30` states only what the policy declares (data subjects, recipients, transfers, security measures) and lists the rest as not declared; see `gems/pam_dsl/CHANGELOG.md`.
- **PII detection (PAM)** — Lyra's detector fallback (`Lyra::Privacy::PIIDetector`, `PolicyIntegration`) uses PAM's merged dictionary: more personal columns found (street, postal code, IP columns, card digits, account tokens), foreign keys and generic `*_name` columns no longer flagged. See `gems/pam_dsl/CHANGELOG.md`.
- **Hijack fails a write whose event cannot be stored with `EventStoreUnavailableError`**, as event
  sourcing does, instead of a refused save (`save` returning false with the store's message on
  `errors[:base]`). A store failure is not a validation error; `save` now raises it, as it raises
  database errors.
- **ES-Async can run out of line in tests** — `async_projections_inline` now decides: unset
  (the new default, `nil`) projects inline in the test environment only, as before; `true`
  always; `false` never, so a test with an `:async` job adapter exercises the real background
  path. The test environment used to force inline projection whatever the setting said, so no
  test could run ES-Async as it runs in production. `Configuration#async_projections_inline?`
  gives the effective value.
- **ES-NoProj cache: entries stamped with their stream's last event** (`CachedProjection`) — each
  record's cached rebuild carries the id of the last event it was built from and is used only
  while that is still the stream's last event, so it is exactly right or detectably out of date.
  Collection reads (`all`, `where`, `find_by` on non-key attributes, `count`) are assembled from
  those entries: one query for every stream's last event, one bulk cache read, and a replay of
  only the streams that changed. They used to be cached as whole collections that every write
  threw away, so after any write the next collection read replayed every stream of the model.
  A `dependent: :nullify` delete, which must find the children by attribute, cost 1.7-3.5 s in
  the Aegean smoke runs; it now costs 0.1-0.4 s (that cell: 10-16 → 49-101 ops/s). ES-NoProj
  SQL statements per write: 12 → 11 per create, 9 → 8 per update (a write no longer deletes
  collection keys; it reads its stream's last event). Cache entries are versioned `v2`; old
  ones are ignored.
- **`Lyra.privacy_features_available?`** asks the installed privacy provider instead of
  checking for `pam_dsl` directly. `PIIDetector` and `PolicyIntegration` load always and work
  through the interface; `PIIMasker` and `GDPRCompliance` stay PAM-only.
- **Hijack creates reserve an id only where it cannot collide** (`reserves_safely?`). Elsewhere
  (an integer key without a PostgreSQL sequence, e.g. SQLite or MySQL) hijack falls back to the
  `pending-<hex>` placeholder with a one-time warning, rather than guessing an id the database
  may also hand out. On PostgreSQL nothing changes, and SQL statements per write are unchanged
  in every mode.
- **Bulk writes on monitored models publish events** (see Added). Code that relied on
  `update_all`/`delete_all`/`insert_all` leaving the event stream untouched should wrap them in
  `Lyra.projection_write`. Bulk-write guards are on `ActiveRecord::Relation`
  (`Lyra::StrictDataAccessRelation`); `Lyra::StrictDataAccessClassMethods` is removed.
- **ES-NoProj bulk writes are events.** With projections disabled the records exist only in
  the stream, so `CachedRelation#delete_all`/`update_all` publish the events that are the write
  (a `delete_all`d record used to reappear on the next read). `upsert_all` raises
  `ArgumentError` there: its `ON CONFLICT` would check the table, not the stream. Cost: a
  `dependent: :nullify` delete must find the children, which in ES-NoProj rebuilds every stream
  of the child model.
- Instance bypass events (`update_column(s)`, `touch`, `delete`) go through
  `BypassEvents.publish`, which also invalidates the ES-NoProj read cache.
- **ES-NoProj answers exactly or raises** (`Lyra::Projections::CachedRelation`, new
  `Lyra::Projections::UnsupportedQuery`) — reading from the event store, `CachedRelation`
  used to answer queries it could not evaluate anyway, with the wrong records: a
  SQL-string `where` kept every record, unrecognised conditions (`!=`, ranges written as
  SQL, ORs) were dropped, `joins` and `where.missing`/`where.associated` were ignored, a
  condition on an unknown column matched nothing, and a scope that failed, carried
  `order`/`limit`/`group` and the like, or was not a scope at all, returned the whole set.
  Each now raises `UnsupportedQuery`, naming the query and the alternatives. Hash
  conditions, ordering, limits, loading hints and scopes made of hash conditions work as
  before. This found the Aegean benchmark's own cleanup, `where("email LIKE ?")` under
  ES-NoProj, silently matching every registration.
- **RailsEventStore 3** — `lyra.gemspec` now requires `rails_event_store ~> 3.0` (3.2.0 in the
  lockfile), on Ruby 4.0.7 and Rails 8.1.4 (8.1.3.1 and RES 3.1.0 until 2026-10-19). RES 3 moved
  the ActiveRecord repository to
  `RubyEventStore::ActiveRecord::EventRepository` and the event base class and errors to
  `RubyEventStore`; `Lyra::Event`, `Lyra::Aggregate` and the default client follow. Apps
  that build their own client must switch from `RailsEventStoreActiveRecord::EventRepository`.
- **`IdGenerator` caches the PostgreSQL sequence name** — `pg_get_serial_sequence` ran on
  every reserved ID, a round trip whose answer never changes. Since hijack mode now reserves
  its IDs here too, that was one extra SQL statement on every hijack-mode create (two
  instead of one). The name is now looked up once per table and cached; only `nextval`
  runs per ID.

### Removed
Dead code, none of it on the write path. Initializers that set `config.event_backend`, or models
that pass `command_handler:`, must drop it: the former now raises `NoMethodError`, the latter is
ignored like any unknown option.
- **`Lyra::EventMapper` and `Lyra::AuditMapper`** (`lib/lyra/event_mapper.rb`). The interceptor
  and the command handler build their events themselves (`CrudInterceptor#publish_event`,
  `CommandHandler#create_event`, both through `Lyra::DomainEvents.build`); nothing called the
  mappers.
- **`Lyra::EventStoreAdapter`, `RailsEventStoreAdapter`, `CustomEventStoreAdapter` and
  `config.event_backend`**, read only by `EventStoreAdapter.build`. Lyra uses the RailsEventStore
  client in `config.event_store` directly; `Lyra.append_events` and `EventStoreUnavailableError`
  stay.
- **The `command_handler` model option** (`monitor_with_lyra command_handler:`,
  `ModelConfiguration#command_handler`) and its dashboard line. It was stored and shown, but the
  write path always uses `Lyra::CommandHandler`.

### Fixed
- **`trace_conformance_test.rb` on a fresh database** (*after the tag*) — the recorder took the commit of Lyra's own
  checkpoint table, created on a connection of its own, for part of the write; it now records only
  the write's connection. Test only.
- **A thread that wrote through Lyra kept a database connection until it ended.** Lyra
  called `Model.connection` (Rails' `lease_connection`) in its write, lock and read paths: the
  aggregate lock, the id generator, Genesis, ES-Async's job, ES-NoProj's cache and reference links,
  ES-Lazy's catch-up, and its maintenance calls (DualView, Rebuild, mode checks, erasure). Since
  Rails 7.2 that keeps the connection for the thread, even inside `with_connection`, which then does
  not return it. So in Hijack and every event-sourcing mode, a thread of the application's own (a
  job runner, a worker pool) ended still holding one, and the pool got it back only by reaping: the
  first thread to find the pool full reset every dead thread's connection, one by one, while the
  others waited. In the benchmark's 64-thread cells such a wait now and then passed the 5 s checkout
  timeout (0.3 to 3 operations per trial of 12,800 in Hijack, Hijack+PT and ES-Sync; part of
  ES-NoProj's 14 to 18), and the contention benchmark reset each round's connections inside its
  timed window. Lyra now uses `with_connection` throughout: inside a transaction it is the
  transaction's own connection, outside one it is returned after use. `OwnConnection`'s thread
  returns whatever its work leased. `test/connection_release_test.rb`: in every mode, a thread that
  writes and reads, bare or in `with_connection`, ends without a connection, and `lib/` has no
  `Model.connection` call left.
- **Genesis and the reference-link catch-up assumed a second connection.** Inside an open
  transaction both ran their work on a thread that checked out a connection of its own and waited
  for it. Under Rails' transactional tests the pool's connection is pinned, every checkout returns
  the caller's own, locked connection, and the wait never ended: the Aegean testbed suite in
  ES-NoProj deadlocked at its first indexed lookup. Under load each caller took a second
  connection, and at 64 threads the pool ran out (5 s checkout timeouts, about 0.1% of ES-NoProj's
  operations in the benchmark's 64-thread cells). `Lyra::OwnConnection` now runs such work: on a
  connection of its own when one can be had, otherwise inline in the caller's transaction, with
  the model recorded as linked or imported only once that transaction commits (after a rollback
  the work runs again on the next use). The catch-up runs once per model and process; concurrent
  first lookups wait for it without a second connection. `test/projections/reference_links_test.rb`:
  a pinned connection, and concurrent first lookups inside transactions.
- **`has_and_belongs_to_many` links were not recorded.** The join table has no model of its own
  (Active Record writes it through an anonymous class), so `item.tags << tag` wrote the join row
  and no event recorded it: a rebuild lost the association and DualView did not compare it. Every
  insert into and delete from a HABTM join table is now an `AssociationLinked` or
  `AssociationUnlinked` event on the owner's stream, linked into each monitored associated
  record's stream (`Lyra::Associations::HabtmLinks`), in every mode. DualView compares each HABTM
  association's links with the join table, `Rebuild` restores join tables from the events, and
  Genesis records the links pre-existing rows had. Under ES-NoProj, HABTM writes failed before
  reaching Lyra (`CachedRelation` lacked `where_values_hash`); they now work and read back
  (`test/habtm_links_test.rb`, every mode).
- **Optimistic locking: a stale update silently won under event sourcing.** Active Record checks
  `lock_version` in the UPDATE or DELETE that writes the row; ES-Sync, ES-Async, ES-NoProj and
  ES-Lazy skip that statement, so a stale `update` or `destroy` overwrote the newer write (a lost
  update), and `touch` raised `StaleObjectError` on every call under ES-NoProj, where no row
  matches. No mode's events recorded the version's increment, so the log replayed to a
  `lock_version` the row did not have (DualView: `lock_version: { crud: 1, event_sourced: 0 }`).
  Every write's event now records the increment, `touch` included; the event-sourcing modes check
  the version against the log before appending, under the lock on the aggregate (taken for such a
  model in every event-sourcing mode), and raise `ActiveRecord::StaleObjectError` as Active Record
  does (`Lyra::OptimisticLocking`). A record that expects a newer version than the log's passes,
  so streams written before the change keep working (`test/optimistic_locking_test.rb`, every
  mode, concurrent writers included).
- **Encrypted attributes (Active Record `encrypts`) reached the event log in clear** while their
  row held ciphertext: events are built from attributes Active Record has already decrypted.
  `Lyra.append_events`, through which every event passes, now stores those attributes' values (in
  `attributes` and `changes`) as the ciphertext Active Record writes to the column
  (`Lyra::EncryptedAttributes`); projections, rebuilds and DualView decrypt them, and records
  instantiated from events are decrypted by Active Record. Events written before keep their clear
  values and still read; rows written from them are encrypted. No mode leaks the value, no value is
  encrypted twice (`test/encrypted_attributes_test.rb`).
- **ES-Lazy stopped projecting after the event store was emptied or restored without its
  checkpoint table**: the checkpoint then lay past the newest event, and every new event looked
  applied. A checkpoint past the newest event is now recognised, warned about and reset (applying
  is idempotent). It made two tests fail in some orders, since the test suite reloads the event
  tables but not the checkpoint table (`test/projections/lazy_projection_test.rb`).
- **Single-table inheritance: a record's events were filed under its concrete class's stream**
  (`Spree::Calculator::Shipping::FlatRate$1`), and anything given the base class read
  `Spree::Calculator$1` and found none: DualView reported the row as missing from the log, and
  under ES-NoProj, ES-Lazy or a rebuild the base class saw an empty stream. A record's stream is
  now named after the class that owns the table (`Lyra.stream_name`, `Lyra.stream_prefix`), at
  every one of the 21 places that built it; reference links and Lyra's caches follow the table.
  Under ES-NoProj a subclass reads only its own records and its subclasses', as ActiveRecord's
  type condition does; events naming a subclass of a monitored model resolve to it
  (`Configuration#monitored_model_named`, used by ES-Lazy's catch-up and erasure). Event types
  still name the concrete class. **Upgrade**: `bin/rails lyra:streams:migrate_sti`
  (`Lyra::StiStreamMigration`) links events written before into the base streams, once; it
  reports a base stream that already holds newer events instead of linking out of order
  (`test/sti_streams_test.rb`, every mode).
- **ES-Async projected inline could leave the row behind the log.** With
  `async_projections_inline` (the test environment's default) a write applied only its own event,
  inside its transaction and under no lock: of two writers of one record, the one that projected
  last could leave the row at its older value. Inline now runs what `AsyncProjectionJob` runs, in
  the writer's thread once its transaction has committed, under the per-stream lock. The job path
  was not affected (`test/concurrent_same_record_test.rb`).
- **ES-NoProj: a named scope called on an association was ignored** (`order.payments.completed`
  returned every payment) and its body loaded every record of the model; records an association
  loaded did not point back at their owner instance.
- **Documentation: `ReadYourWrites` projects a block's writes when the block ends**, so a read
  after the block sees them and a read inside it does not; `docs/API_REFERENCE.md` said or
  implied the latter.
- **ES-Lazy: concurrent first reads no longer fail creating the checkpoint table.** Two threads
  that both found `lyra_projection_checkpoints` missing both created it, and the second `CREATE`
  failed the write that triggered it (one write of the full BPI 2017 replay at two threads).
  `Lyra.create_own_table` now defines the table in one transaction and ignores a failed create
  once the table exists.
- **Leaving ES-Lazy skipped its catch-up** — `ModeTransition.to!` from `event_sourcing/lazy`
  calls `LazyProjection.catch_up!(force: true)`. Without `force:`, `catch_up!` returns 0 outside
  ES-Lazy, and the mode had already changed by the time the transition ran it, so the tables
  could be left behind the log.
- **Locks on databases other than PostgreSQL** — Genesis, ES-Lazy catch-up and ES-Async
  projection take their transaction-level advisory lock through `Lyra::AdvisoryLock.xact_lock`.
  On SQLite (which serialises writers) it does nothing; on other adapters it logs once per
  purpose that the step runs unlocked and is safe in a single process only. Before, those
  adapters ran unlocked silently.
- **`upsert_all` under ES-NoProj raised `ArgumentError`**; it now raises
  `Lyra::Projections::UnsupportedQuery`, like every other query ES-NoProj cannot answer, naming
  the reason (the `ON CONFLICT` check runs against the table, not the event stream) and the
  per-record alternative.
- **`DualView` reported a record for a stream of only `replay: false` events** — such a stream
  describes no record, so `exists` is now false.
- **`lyra.rb` required ActiveRecord and ActiveJob implicitly**, relying on the host to load them
  first; loading the gem after only `require "rails"` raised `NameError`. It now requires both.
- **`Lyra::Projection.subscribe_to` raised `RubyEventStore::InvalidHandler`** — RailsEventStore
  3.1 subscribers must respond to `call`. A projection class now does (`call(event)` hands the
  event to a new instance's `handle`), and `subscribe_to` returns the unsubscribe procs.
  `handle` takes the `apply_<name>` method from `event.event_type`, so an event read back as a
  plain `RubyEventStore::Event` reaches its handler too.
- **Nested `with_guaranteed_read` lost the outer block's writes** — the inner block reset the
  list of pending writes, then cleared it. An inner block now projects its own writes when it
  ends and restores the outer list; if it raises, its unprojected writes pass to the outer
  block. Every write is projected by the time the outermost block ends.
- **A process that only reads got plain `RubyEventStore::Event`s** — in a lazily loaded process
  (console, rake, development) no event class was registered, so events came back without
  Lyra's readers (`operation`, `attributes`, `changes`, ...). `Lyra::Events` now defines the
  class on first reference for a name a monitored model or the stored schema writes, loading
  the model from the name's stem (`PostCreated` → `Post`, `SpreeOrderCreated` →
  `Spree::Order`); other names still raise `NameError`. A model with a custom `event_prefix` or
  `event_mapping` that is not loaded resolves only through the schema store.
- **petri_flow was not optional** — `app/workflows/*.rb` subclass `PetriFlow::Workflow`, so
  without the gem eager loading (production boot, `lyra:mode:*`, `lyra:repair`,
  `lyra:schema:*`) raised `NameError`. Without petri_flow the engine neither autoloads nor
  eager-loads `app/workflows`.
- **`lyra:workflows:generate MODE=...` wrote a class its file did not name** — `MODE=monitor`
  defined `MonitorModeWorkflowWorkflow`, which Zeitwerk could not load. A mode's file and class
  are now the same whether one mode or all are generated (`monitor_mode_workflow.rb` defines
  `MonitorModeWorkflow`, `es_sync_mode_workflow.rb` `EsSyncModeWorkflow`;
  `WorkflowGenerator.workflow_file_basename(mode)`, `.workflow_class_name(mode)`).
- **`already initialized constant Lyra::VERSION` in a checkout holding a nested copy of the
  engine** — Bundler's default gemspec search also loaded the nested copy's `lyra.gemspec`. The root `Gemfile`
  uses `gemspec glob: "lyra.gemspec"`, and the example apps' Gemfiles `glob: "lyra.gemspec"`.
- **Hijack and event-sourcing events lost who wrote them** — the command handler wrote only
  the causal chain, so `user_id`, `request_id`, the user action and `config.metadata_proc`
  reached Monitor events alone. Every mode now carries the same attribution metadata
  (`record.lyra_event_metadata(operation)`), plus `source: "lyra_command_handler"`.
- **`ReadYourWrites` had no effect under ES-Async** — only the ES-Sync path recorded writes
  for it. Writes inside `with_guaranteed_read` are now projected when the block ends; the job
  is still enqueued and converges on the same row.
- **Aggregates never loaded their history** — `GenericAggregate.load` raised `NoMethodError`
  (no model class for its stream name) and the command handler swallowed it. A model's own
  `aggregate_class` is now loaded with its stream's history for updates and destroys; the
  default `GenericAggregate`, which decides nothing from history, starts empty and reads no
  stream, so its writes issue no extra SQL. A programming error while loading now fails the
  command instead of being swallowed.
- **`AuditProjection.audit_trail` always gave `user_id: nil`** — it read the user from the
  event data, which no longer holds the metadata; it reads the event's metadata now.
- **DualView reported every destroyed record as `exists_mismatch`** — a destroyed record
  whose row is gone now compares clean (`event_sourced_state` gains `destroyed:`).
- **The engine's root redirect was hard-coded to `/lyra/dashboard`** — it is now relative
  to wherever the engine is mounted.
- **`strict_schema` stopped the boot on any schema drift** — including info-level changes
  such as an added column. It now refuses to boot only on a breaking change (model or column
  removed, column type or event name changed) and logs the rest.
- **`PIIMasker.mask_events` was broken** — it built events with keywords
  `RubyEventStore::Event` does not accept. It returns masked copies now (same class, id and
  metadata; attributes and changes masked).
- **`Erasure::Result#shared_values` was sometimes `[]`, sometimes an Integer** — always an
  Integer count now.
- **`EventFlow#crud_to_event_mapping` found nothing for a class** — it accepts a class or its
  name, and string operations and ids (as the dashboard passes them); `data_lineage` likewise.
- **A test left a guard on `Article#body=`** (`multi_mode_integration_test`), failing 11 later
  tests under some seeds; it now removes it.
- **ES-NoProj answers more queries exactly instead of refusing them** — scopes with `order` or
  `limit` (their conditions, then the order and limit); `relation.or(other)` over the same model
  (the union); and `where` fragments of `col OP ?` terms joined all by AND or all by OR, with OP
  one of `= != <> < <= > >= LIKE ILIKE` (values cast to the column type, NULL never matching, LIKE
  patterns with `%`, `_` and `\` escapes). Anything else is still refused. `order("col DESC")`
  strings and Arel orderings are read, and an ordering it cannot read now raises: it used to
  compare as equal and leave the result silently unordered. The testbed suite under ES-NoProj
  goes from 20 failures to none (the domain-events tests also created their records before
  switching mode, so under ES-NoProj the parents existed only as events).
- **ES-NoProj lost `update_columns` and `touch`** — in the events-only store the `UPDATE` matched no
  row and returned false, so no event was published and the change was lost, against Bypass
  Coverage ("the events are the write"). The event is now published whatever the row count.
- **ES-Lazy lost a callback-bypassing write made right after a write** — a write appends events
  only, so the record's row did not exist until the next read; `update_columns`, `update_all`
  or `delete_all` on it matched nothing, recorded no event, and the change was lost.
  `BypassEvents.atomically` now brings the tables up to date first, as a read does.
- **Lyra's own tables vanished with a rolled-back transaction** — `lyra_projection_checkpoints`
  and `lyra_mode_transitions` were created inside whatever transaction was open, and remembered
  as created; when it rolled back (a failed request, every transactional test) the table was
  gone and every later use failed. Under ES-Lazy the testbed suite failed 395 tests this way.
  They are now created on a connection of their own when a transaction is open
  (`Lyra.create_own_table`).
- **ES-NoProj ignored `select` and hid purpose refusals as "not found"** — `CachedRelation#select`
  returned whole records, and the record builder swallowed a policy error, dropping the record.
  Query results are now narrowed to the selected columns and checked when returned
  (`CachedRelationDelivery`), as are the class-level `find`, `find_by` and `find_by!`.
- **The all-modes runner skipped ES-Lazy** — `lyra:test:all_modes` and the PAM-less run now cover
  all seven configurations.
- **Lyra's rake tasks ran twice, and host apps got the development checkout's maintenance tasks** — Rails
  loads every `lib/tasks/*.rake` under an engine's root, and the engine also loaded its three
  task files explicitly, so each `lyra:mode:*`, `lyra:projections:*` and `lyra:schema:*` task
  ran twice (`lyra:mode:check` ran its full check twice), and `gems:*`, `public:*`, `stats:*` and
  the other maintenance tasks appeared in every host app. The engine now loads `lyra_*.rake` only,
  once.
- **`lyra:mode:check` could certify a switch having checked nothing** — monitored models register
  as their classes load, which a rake task in development does not do, so the check saw no
  models, found no discrepancy and certified the switch. The mode, repair, projection and schema
  tasks now load the application's models first; check and repair refuse when none are monitored.
- **Renamed events were skipped on replay** — `Rebuild`, the ES-NoProj cache and the aggregate
  decided what an event did from the end of its name (`…Created`, `…Updated`, `…Destroyed`).
  An event renamed with `event_mapping` (or, now, a domain event) was skipped: `Rebuild` left
  the record's row empty and ES-NoProj could not read it. Every replay site now dispatches on
  the operation each event records in its data (`Lyra::Event.operation_of`); only events too
  old to carry one fall back to the name.
- **Event sourcing lost writes whose event could not be stored** — `lyra_store_events` logged a
  failed append and carried on (unless `strict_projections`, a setting about projections, was
  on): ES-NoProj reported a write that existed nowhere, and ES-Sync projected a row from an
  event that was never stored. In Hijack and the event-sourcing modes a write whose event
  cannot be stored now fails and is rolled back, bypass writes included
  (`BypassEvents.required?`, `BypassEvents.atomically`: the write and its events share a
  transaction). Monitor, where the table stays authoritative, still logs the failure and keeps
  the write.
- **A failed event-sourced create made the next insert on its thread vanish** — the
  skip-insert signal was cleared only at the end of a successful finalize, so after any
  failure the next insert of any model on that thread (a Puma thread, say) skipped its row while
  reporting success. It is now cleared as soon as the record's own INSERT has run, and
  finalize clears its state on every exit.
- **ES-NoProj evaluated association conditions record by record, and some wrongly** —
  `where(program: x)` loaded each cached record's association (one query per record: about
  10,000 for one `count` in the mode-comparison benchmark) and compared objects;
  `find_by(program: x)` compared against a `program` attribute the record does not have and
  silently found nothing; `where(program_id: record)` matched nothing. Conditions are now
  rewritten as ActiveRecord does (`Lyra::Projections::AssociationConditions`): a `belongs_to`
  becomes its foreign key (polymorphic: type and id), and a record given as a column value
  becomes its id. A `has_many`/`has_one` condition, which ActiveRecord accepts only with a
  join, raises `UnsupportedQuery`, as does a polymorphic condition over several types.
- **ES-NoProj could serve out-of-date records from its cache** — a write warmed its record's
  entry inside the write's transaction, so a rollback left a record cached that never existed;
  two processes filling one key could leave a stale entry for up to an hour; and
  `where`/`find_by` results were cached for five minutes and never invalidated, so they could
  return records a write had already changed. Stamped entries (see Changed) make all three
  impossible: a stale entry is never used.
- **An explicit id was replaced** — `CommandHandler#handle_create` generated an id even when the
  application set one; it now keeps it, in the event and in the row.
- **ES-NoProj `insert_all` ran, then raised** — through `CachedRelation`'s scope branch the
  insert executed and the caller then got `UnsupportedQuery` ("not a scope"). Inserts and
  upserts now go to the table relation and return its result.
- **Genesis left a cached "not found" in place on Solid Cache** — an ES-NoProj lookup
  made before a record was imported (in an earlier process, or before the event store
  was reset) caches `nil` for it. Genesis cleared the cache with
  `CachedProjection.invalidate_all`, which cannot delete per-record entries on a store
  without prefix deletion (Solid Cache, the Rails 8 default), so the imported record stayed
  "not found" until the entry expired, up to an hour. Genesis now drops each imported
  record's entry by id. Found by the Aegean benchmark harness, which empties the event
  store between modes.
- **`CachedRelation#delete_all`/`destroy_all`/`update_all` wiped the whole table**
  (`Lyra::Projections::CachedRelation`, from `stack/latest-ruby-rails-res`) — the
  `method_missing` scope fallback rebuilt them from `model_class.unscoped` and ran them
  before checking the result, so `Model.where(id: ids).delete_all` under ES-NoProj issued
  a bare `DELETE FROM` the whole table (found when the Aegean benchmark's ES-NoProj
  cleanup emptied `registrations` mid-sweep). They now act only on the relation's own
  records. `where(column: [a, b])` (an `IN` with several values) is no longer silently
  dropped.
- **Projection wrote through the read-from-events override** (`Lyra::Projections::ModelProjection`)
  — with `projection_mode :disabled` (ES-NoProj) a monitored model's `where`/`all` answer
  from the event store. Projection's update and destroy go through
  `model_class.where(...)`, so they acted on event-store records instead of rows: a
  record destroyed in the log is absent there, so its row was never deleted.
  `Rebuild` (`rake lyra:projections:rebuild`) and `AsyncProjectionJob` both project
  through this path in any mode. Projection now always addresses the table.
- **`invalidate_all` raised on Solid Cache, and keyed `find_by` replayed every stream**
  (`Lyra::Projections::CachedProjection`) — `invalidate_all` guarded prefix deletion with
  `respond_to?(:delete_matched)`, which every cache store answers true; Solid Cache, the
  Rails 8 default, then raised `NotImplementedError`. The raise is now rescued and the
  fallback used. `find_by` took its single-stream path only when the primary key was the
  sole condition, so `find_by(id: 5, email: x)` replayed every stream of the model; any
  lookup that pins the primary key now reads that one stream and checks the remaining
  conditions against the record it yields.
- **ES-Async projected a record's events out of order** (`Lyra::Projections::AsyncProjectionJob`)
  — each job applied its one event, and a worker pool runs jobs concurrently, so an
  earlier update's job could land after a later one's and roll the row back; a late
  create job could even resurrect a destroyed record. The Olist replay through Solidus
  left 2 of 100 orders at `confirm` whose events ended at `complete`. Each job now
  brings its record up to date with the whole stream (`Rebuild.replay_record`, in place),
  under a PostgreSQL advisory lock held per stream, so jobs converge in any order. Cost:
  each job re-reads its stream, so projections lag more and ES-Async's read-after-write
  window widens (Olist, 100 orders: 151 -> 183 such failures).
- **Hijack and event-sourcing modes built events before the model's own callbacks**
  (`Lyra::Interceptors::CrudInterceptor`, new `WriteHooks`) — the create/update/destroy
  commands ran in `before_*` callbacks registered on `ActiveRecord::Base`, so ahead of
  every model's own `before_*` callbacks. Values those set were missing from the event:
  in Hijack mode the event disagreed with the row; under event sourcing, where the row is
  projected from the event, they were lost from the table, and DualView could not tell
  (both sides agreed). Replaying Olist orders through Solidus 4.7 under ES-Sync lost every
  order's `guest_token` and every payment's `number`. The commands now run in
  `WriteHooks`, prepended to `ActiveRecord::Persistence`: after all `before_*` callbacks,
  just before the SQL write. A failed command returns false (save returns false, the
  transaction rolls back) instead of throwing `:abort`. PaperTrail is still switched off
  first. SQL statements per write are unchanged in every mode, in order and count.
- **Hijack creates re-assigned every attribute** (`Lyra::Interceptors::CrudInterceptor`) —
  after the create command, the interceptor called `assign_attributes` with all of the
  record's attributes, although only the reserved ID had changed. That fails on models
  that guard a writer: Solidus makes `StockItem#count_on_hand=` unusable so stock moves
  only through `set_count_on_hand`, and Hijack mode could not create a variant. Only the
  ID is assigned now.
- **Writes that bypass callbacks went missing from the event log** (`Lyra::StrictDataAccess`)
  — three holes, found by the Olist replay through Solidus 4.7, where DualView then
  disagreed with the table for 17 of 20 orders and every shipment:
  - *Assign, then `update_columns`* published nothing. The old value was read from the
    in-memory attribute, which already held the new value, so no change was seen
    (Solidus's `Shipment#persist_amounts`). The old value now comes from
    `attribute_in_database` and the new one from the record after the write, which also
    covers the timestamps `touch: true` sets.
  - *`touch`* was not intercepted at all (Solidus records completion with
    `touch(:completed_at)`). It now publishes a bypass event; it is not a strict-mode
    violation, since Rails itself calls it for `belongs_to ... touch: true`.
  - *`update_column`* published its event twice (Lyra's override and Rails'
    `update_columns` underneath both published), and the override dropped Rails 8's
    `touch:` keyword, so callers passing it raised `ArgumentError`.
- **Hijack and event-sourcing modes failed on namespaced models** (`Lyra::CommandHandler`) —
  the event class name was built from the model name without stripping `::`, so
  `Spree::Price` produced the invalid constant `Spree::PriceCreated` and every create
  failed. The failure surfaced only as a parent record left unsaved, with no exception
  (`Spree::Product.create!` returned an unsaved product). Every other event path already
  stripped the separator; this one now does too. Found by the Olist replay through
  Solidus 4.7, where it, not STI or polymorphism, kept Solidus out of these modes.
- **Optional gems that failed to load were reported as missing** (`lyra.rb`,
  `Lyra::OptionalDependency`) — PAM DSL and PetriFlow were loaded inside a bare
  `rescue LoadError`, so a gem that was installed but could not load (PetriFlow without
  `rexml`) was treated as absent and left half-defined; eager-loading `app/workflows`
  then failed with `uninitialized constant PetriFlow::Workflow`. Only a gem that is itself
  not installed now counts as unavailable; any other load failure raises. PetriFlow now
  declares `rexml` (see `gems/petri_flow/CHANGELOG.md`).
- **DualView compared times at whole seconds** (`Lyra::DualView`) — `normalize_value` turned
  every time into `iso8601` with no fraction, so `15:49:11.420` in the table and
  `15:49:11 UTC` in a lossy event compared equal. That is how the sub-second loss fixed by
  `Lyra::EventSerializer` passed dual-view checks under Monitor mode. Times now compare at
  microseconds, the resolution of a PostgreSQL timestamp.
- **Hijack mode filed `Created` under a placeholder stream** (`Lyra::CommandHandler`) — for
  integer primary keys, hijack mode stored the Created event under `"pending-<hex>"` and let
  the database assign the ID afterwards. Nothing linked the two: later events went to the
  real `Model$<id>` stream, so every record's history began with an update and rebuilding it
  from events (dual view, projection rebuild) found no attributes. Hijack now reserves the
  ID up front through `IdGenerator`, as event-sourcing mode does, and the row is inserted
  under the ID the event carries. Hijack is now covered by the event-correctness
  integration tests it had been left out of.
- **ES-Async lost projections silently** (`Lyra::Projections::AsyncProjectionJob`) — the job
  was enqueued inside the transaction that stores its event, so a worker could run it
  before the commit, find no event, complete, and never project the row (no error, no
  retry). Replaying 40 BPI 2017 applications left 37 missing. The job now sets
  `enqueue_after_transaction_commit`, so it runs only once its event is visible and is
  never enqueued after a rollback. Eventual consistency itself is unchanged. The test dummy
  app now loads `active_job/railtie`.

## [0.8.0] - 2026-08-09

The version the PAM article (Requirements Engineering, 2026) describes, released from
lyra-engine commit `b863d2e`. Not published to RubyGems until 2026-10-10.

### Added
- **Projection rebuild from the event log** (`Lyra::Projections::Rebuild`) - Reconstruct
  read-model tables from the event streams alone, the load-bearing invariant of event
  sourcing (log is source of truth; tables are a derived projection):
  - `Lyra::Projections::Rebuild.rebuild(Model)` clears the read model and replays each
    stream through the same `ModelProjection.project` path used by live sync/async
    projection, so a rebuilt table matches what live projection would have produced.
  - `Lyra::Projections::Rebuild.rebuild_all` rebuilds every monitored model (or an
    explicit list); `truncate: false` reconstructs streamed rows in place.
  - `rake lyra:projections:rebuild [MODEL=Namespace::Model[,Other]] [TRUNCATE=false]`
    rake task wrapping the above.
  - Invalidates ES-NoProj cached reconstructions so reads reflect the rebuild.
  - Integration tests (`test/projections/rebuild_test.rb`) covering surviving-record
    reconstruction, destroyed-record omission, dual-view consistency after rebuild, and
    `rebuild_all` over monitored models.
- **PAM DSL** aligned with its formal foundations — see `gems/pam_dsl/CHANGELOG.md`.
- **Performance characterization** (`docs/PERFORMANCE.md`) — measured overhead of every
  Lyra mode against a plain-ORM baseline: throughput and P95 latency across 1–64 threads,
  the measurement controls used, and a SQL-level account of why Hijack mode outperforms
  Monitor mode. The benchmark harness itself is published on acceptance of the
  accompanying papers.

### Fixed
- **`:disabled` mode emitted events** (`Lyra::Interceptors::CrudInterceptor`) — the monitor
  callbacks were gated on `lyra_monitored?`, a class attribute carrying no mode check, so a
  model that had ever called `monitor_with_lyra` kept writing to the event store after Lyra
  was disabled. A 150-write workload emitted 150 `event_store_events` rows in `:disabled`
  mode, identical to `:monitor`. `:disabled` is now gated on `lyra_events_enabled?`
  (monitored **and** not disabled), making it a true plain-ORM baseline. Hijack and
  event-sourcing modes still pass the guard and are unaffected — their `after_*` callbacks
  already return early via `@lyra_hijacked`.

  If you have been using `:disabled` as an off switch on models that call
  `monitor_with_lyra`, those models were still writing events before this fix.

  The existing `test_disabled_mode_captures_no_events` could not catch this: it redefines the
  model *without* the interceptor, asserting the outcome by construction. The new
  `test_disabled_mode_writes_no_events_for_a_monitored_model` keeps the model monitored and
  flips only the mode — what a migrating team actually does — and counts rows directly.
- **Empty-stream reads raised `NameError`** (`Lyra::Projections::CachedProjection`) —
  `load_events` rescued `RubyEventStore::StreamNotFound`, which does not exist in
  `ruby_event_store` 2.18/3.0; the real class is `EventNotFoundInStream`. The bad constant
  reference raised instead of catching the empty-stream case, surfacing as silent failed
  operations on the ES (No Projection) read path.

## [0.6.0] - 2026-01-05

### Added

#### Core CRUD-to-Event Sourcing Engine
- Monitor mode for non-intrusive CRUD operation logging
- Hijack mode for full event sourcing transformation
- Rails Event Store integration
- CRUD interceptor using ActiveRecord callbacks
- Event mapping layer (CRUD operations → Domain events)
- Command/Aggregate pattern for hijack mode
- Dual-view comparison (CRUD state vs Event-sourced state)
- State reconstruction from event streams
- Audit trail generation
- Dashboard API endpoints
- ERB-based dashboard views
- Pluggable event store backend
- Custom aggregate support
- Custom event mapper support
- Projection system for read models
- **Custom Metadata Proc** (`metadata_proc`) - Inject custom metadata into every event:
  - Capture user context from `Current`/`CurrentAttributes`
  - Support for Devise/Warden authentication
  - Thread-safe per-request metadata
  - Graceful error handling (returns `{}` on failure)
- **Rails Engine Namespaced Model Support** - Properly handle namespaced models:
  - `MyEngine::Order` → `MyEngineOrderCreated` (sanitized event class name)
  - Preserves original namespace in `model_class` attribute
  - Supports deeply nested namespaces (e.g., `MyEngine::Admin::Widget`)

#### Privacy Extraction to PAM DSL
- **PAM DSL as Optional Dependency** - Privacy features gracefully degrade without PAM DSL
- **PIIDetector Delegation** - `Lyra::Privacy::PIIDetector` delegates to `PamDsl::PIIDetector`
- **PIIMasker Delegation** - `Lyra::Privacy::PIIMasker` delegates to `PamDsl::PIIMasker`
- **GDPRCompliance Delegation** - `Lyra::Privacy::GDPRCompliance` delegates to `PamDsl::GDPRCompliance`
- **PolicyIntegration Enhancements**:
  - `use_detector: true` option (default) - Falls back to PIIDetector for fields not in policy
  - `use_detector: false` - Policy-only mode, no pattern-based detection
  - `pam_dsl_available?` - Check if PAM DSL is loaded
  - `source: :policy` or `source: :detector` in detection results
  - Retention returns `nil` (infinite/manual) when no policy defined
  - 28 new tests for PolicyIntegration

#### Unified PII Detection System
- **Consolidated PIIDetector** - Lyra now delegates to `PamDsl::PIIDetector` for unified PII detection
- **Partial Matching Mode** (default) - Detects PII in compound field names using word boundaries
  - Matches prefixed fields: `customer_email`, `billing_phone`, `user_name`
  - Matches suffixed fields: `home_phone`, `work_email`, `shipping_address`
  - Supports camelCase suffix boundaries: `emailAddress`, `phoneNumber`
- **Exact Matching Mode** - Optional strict mode for specific known field names only
- **Configurable via `PamDsl::PIIDetector.partial_match`** - Toggle between matching modes
- **New PII Types**:
  - `:identifier` - VAT numbers, tax IDs, passport numbers, AFM (Greek tax ID)
  - `:financial` - IBAN, bank accounts, salary, income
  - `:health` - Medical records, diagnosis, prescriptions
  - `:biometric` - Fingerprints, face ID, retina scans
  - `:location` - GPS coordinates, latitude/longitude
- **Exclusion Patterns** - Prevents false positives on:
  - Timestamps: `*_at`, `*_on`, `*_date`, `*_time`
  - Counters/amounts: `*_count`, `*_amount`, `*_total`
  - Flags: `*_verified`, `*_confirmed`, `*_enabled`, `is_*`, `has_*`
  - Codes: `*_code` (except `postal_code`, `zip_code`)
  - Security: `*_digest`, `*_token`, `*_hash`, `encrypted_*`
- **Sensitivity Levels with Legislative Background**:
  - `:public` - Publicly accessible data
  - `:internal` - Low risk, basic protection (GDPR Art. 6)
  - `:confidential` - Medium risk, enhanced protection (GDPR Art. 6, Art. 32)
  - `:restricted` - High risk, special categories (GDPR Art. 9, PCI DSS)
- **PII Masking** - Type-specific masking for safe display
- **56 tests with 188 assertions** for comprehensive coverage

#### Event Schema Validation System
- **Schema Store** (`lib/lyra/schema/store.rb`) - Versioned schema file persistence in `db/lyra_schemas/`
- **Schema Generator** (`lib/lyra/schema/generator.rb`) - Generates schemas from monitored ActiveRecord models
- **Schema Diff** (`lib/lyra/schema/diff.rb`) - Compares schemas with severity classification (BREAKING, WARNING, INFO)
- **Schema Validator** (`lib/lyra/schema/validator.rb`) - Enforces schema consistency with strict mode support
- **Schema Reporter** (`lib/lyra/schema/reporter.rb`) - Human-readable model→event mapping reports
- **Rake Tasks** for schema management:
  - `rake lyra:schema:create` - Generate initial schema
  - `rake lyra:schema:update` - Create new schema version
  - `rake lyra:schema:verify` - Check for schema changes
  - `rake lyra:schema:report` - Display model→event mappings
  - `rake lyra:schema:history` - Show version history
  - `rake lyra:schema:diff[v1,v2]` - Compare two schema versions

#### Event Class Registration for RailsEventStore Compatibility
- **EventClassRegistrar** (`lib/lyra/schema/event_class_registrar.rb`) - Pre-registers event classes at Rails startup
- Ensures `Object.const_get()` works when RailsEventStore deserializes events after app restart
- Registers events from both monitored models configuration and stored schema (for legacy events)

#### Event Sourcing with Disabled Projections (Sixth Mode)
- **CachedRelation** (`lib/lyra/projections/cached_relation.rb`) - ActiveRecord::Relation-like wrapper for in-memory cached data
  - Full query interface: `where`, `order`, `limit`, `offset`, `first`, `last`, `find`, `find_by`
  - Type coercion for string/integer and boolean comparisons (handles params from controllers)
  - Aggregation methods: `sum`, `average`, `minimum`, `maximum`, `pluck`
  - Pagination support: `page`, `per` (Kaminari-compatible)
  - Chainable no-ops for AR methods: `includes`, `joins`, `preload`, `distinct`
  - Rails 8 Arel predicate value extraction support

- **AssociationInterceptor** (`lib/lyra/interceptors/association_interceptor.rb`) - Patches AR associations for cache-based loading
  - `BelongsToAssociationPatch` - Intercepts belongs_to association loading
  - `HasOneAssociationPatch` - Intercepts has_one association loading
  - `HasManyAssociationPatch` - Intercepts has_many association loading with count/size support
  - Polymorphic association support for belongs_to
  - Rails 8 async: keyword argument compatibility

- **EventStoreReader** (`lib/lyra/projections/event_store_reader.rb`) - Reads and caches entity state from event store
  - Reconstructs current state by replaying events
  - Solid Cache / Rails.cache integration for fast reads
  - Cache warming and invalidation on writes
  - Full query interface via CachedRelation

- **CrudInterceptor first/last overrides** - Proper ordering by primary key
  - `Model.first` now orders by `primary_key ASC` before returning first record
  - `Model.last` now orders by `primary_key DESC` before returning first record

#### Benchmark Infrastructure
- **Mode Comparison Benchmark** (`perf/run_mode_comparison_benchmark.rb`)
  - Comprehensive benchmarking across all 7 Lyra modes
  - Scales from 500 to 100,000 operations
  - Four scenarios: CRUD, batch, query, mixed workloads
  - Checkpoint/resume support for long-running benchmarks
  - Automatic chart generation (PNG) via gnuplot
  - JSON, CSV, and Markdown report output
  - **Object allocations tracking** - measures Ruby allocations per operation via GC.stat
  - **Allocations charts** - per-scale bar charts and scaling comparison line chart
- Warmup phase for JIT/cache priming
- Cache warming for ES Disabled mode before measurements

#### Testing Infrastructure
- **Comprehensive CachedRelation test suite** (`test/projections/cached_relation_test.rb`)
  - 37 tests covering enumerable, finders, where filtering, type coercion, ordering, pagination, aggregations
  - Isolated unit tests with MockRecord and MockModel classes

- **Unified 6-mode test runner** - All Lyra modes tested together
  - `rake lyra:test:all_modes` runs all 6 configurations in single execution
  - Configurations: disabled, monitor, hijack, event_sourcing+sync, event_sourcing+async, event_sourcing+disabled
  - Comprehensive report with pass/fail status per configuration

#### Configuration Options
- `strict_schema` - Fail startup if schema changes detected (recommended for production)
- `schema_path` - Custom path for schema files (defaults to `db/lyra_schemas/`)

#### Database Support
- PostgreSQL primary database support
- SQLite alternative for small deployments

#### Example Application
- Aegean E-Pay Testbed with student registrations
- Payment processing with multiple channels
- Complete database schema and seed data

### Fixed

#### StrictDataAccess Compatibility with Event Sourcing Mode
- Fixed conflict between `StrictDataAccess` and ES mode sync projections
- Projections now correctly bypass strict access checks (using `Thread.current[:lyra_bypass_strict_access]`)
- This is safe because projections are internal Lyra operations with events already recorded
- Fixed require order in `lib/lyra.rb` to load `strict_data_access` before projections

#### CachedRelation Exception Handling in ES Disabled Mode
- Fixed `CachedRelation.method_missing` swallowing `StrictDataAccessViolation` exceptions
- `update_all` and `delete_all` on `CachedRelation` now correctly raise violations when strict mode is enabled
- The generic scope delegation rescue clause now re-raises framework violations instead of suppressing them

#### Automatic Event Creation for `dependent: :nullify` Operations
- When `dependent: :nullify` triggers `update_all(foreign_key: nil)`, Lyra now creates events for affected child records
- This ensures the event stream captures foreign key nullification when parent records are destroyed
- Events include `nullify_source: "dependent_association"` in metadata for traceability
- Works in both DB-backed modes (plucks from DB) and ES Disabled mode (queries event store cache)
- Resolves event stream completeness gap where child state changes were previously invisible

#### Automatic Event Creation for Callback-Bypassing Operations
- `update_columns` and `update_column` now create events when allowed (strict mode off or bypassed)
- `delete` now creates a "Destroyed" event when allowed
- Events include `bypass_source: "update_columns"` or `bypass_source: "delete"` in metadata
- This ensures the event stream remains complete even when developers intentionally bypass callbacks
- Only applies to Lyra-monitored models when mode is not `:disabled`

#### Test Isolation Issues
- Fixed test contamination between controller and integration tests
- Integration tests now create their own event store if none exists
- Added `create_event_store` helper to `multi_mode_integration_test.rb` and `event_sourcing_mode_test.rb`
- Fixed `assert_not_nil` → `refute_nil` (Minitest syntax)
- Added proper `Lyra.config.monitor_model` calls for correct event naming

### Changed

#### Test Coverage Configuration
- Increased SimpleCov minimum coverage thresholds (50% line, 47% branch)
- Added coverage groups for Projections and Schema modules
- All 584 tests now pass with proper isolation
- Added comprehensive tests for Schema::Diff (column limit changes, event renames, config changes)
- Added comprehensive tests for Schema::Reporter (report generation, PII summaries, model mappings)
- Added comprehensive tests for Visualization::Timeline (Mermaid, ASCII, D3.js output)
- Added comprehensive tests for EventAnalyzer (timeline, operations, privacy analysis)
- Added comprehensive tests for CommandHandler (event data, metadata, error handling)
- Added comprehensive tests for DualView (value normalization, type coercion)

### Core Components
- `CrudInterceptor` - ActiveRecord callback integration
- `EventMapper` - CRUD to event mapping
- `Command` - Command pattern implementation
- `CommandHandler` - Command processing
- `Aggregate` - Domain aggregate base class
- `GenericAggregate` - Default aggregate for monitored models
- `Projection` - Read model projection base
- `StateProjection` - State reconstruction
- `AuditProjection` - Audit trail generation
- `DualView` - CRUD vs Event-sourced comparison
- `StateAnalyzer` - State analysis and recommendations
- `EventStoreAdapter` - Pluggable event storage
- `Configuration` - Centralized configuration
