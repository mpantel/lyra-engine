# Changelog

All notable changes to the Lyra project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2026-10-05

### Added
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
- **Event store failure policies, named** (`Lyra::EventStoreUnavailableError`, `Lyra.append_events`;
  FEATURE_GAP_PLAN F1) — every event Lyra writes now goes through `Lyra.append_events`, which
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
  `Lyra::Events::DataAccessed`, `Lyra::Events::DataAccessDenied`; FEATURE_GAP_PLAN F6) — when on,
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
  `Lyra::Privacy.stamp_of`; FEATURE_GAP_PLAN F5) — when on, every event that carries an
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
- **Mode Transition Safety** (`Lyra::ModeTransition`, `rake lyra:mode:check`; FEATURE_GAP_PLAN F3)
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
- **Domain events** (`monitor_with_lyra domain_events: [...]`, `Lyra::DomainEvents`;
  FEATURE_GAP_PLAN F8) — rules name a write's event after what it means instead of the CRUD
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
- **Configuration surface** (FEATURE_GAP_PLAN F2): `config.models = %w[Order Payment]` (or a
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
  `created_at` is `nil`). Works in every mode that records events, Monitor included
  (FEATURE_GAP_PLAN F7).
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
  annotation in event metadata (`FEATURE_GAP_PLAN.md`, F2 and F5). From `thesis-restructure`
  (1adadfe); the testbed binds `Registration` and `PaymentTransaction` to its `:epay_data`
  policy (d0df542), which adds nothing to the write path.
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
  unchanged. Brought over from the `thesis-restructure` branch (3ba39bb, 975dc6e), keeping
  master's instance methods (events built after the write).
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

### Changed
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
- **RailsEventStore 3** — `lyra.gemspec` now requires `rails_event_store ~> 3.0` (3.1.0 in the
  lockfile), on Ruby 4.0.7 and Rails 8.1.3.1. RES 3 moved the ActiveRecord repository to
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
- **`already initialized constant Lyra::VERSION` in the monorepo** — Bundler's default gemspec
  search also loaded the nested `lyra-engine/` checkout's `lyra.gemspec`. The root `Gemfile`
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
- **Lyra's rake tasks ran twice, and host apps got the monorepo's maintenance tasks** — Rails
  loads every `lib/tasks/*.rake` under an engine's root, and the engine also loaded its three
  task files explicitly, so each `lyra:mode:*`, `lyra:projections:*` and `lyra:schema:*` task
  ran twice (`lyra:mode:check` ran its full check twice), and `gems:*`, `public:*`, `stats:*` and
  the other monorepo tasks appeared in every host app. The engine now loads `lyra_*.rake` only,
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
  application set one; it now keeps it, in the event and in the row. From `thesis-restructure`
  (526908e), applied to master's own Hijack fix (cd3ea89).
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
