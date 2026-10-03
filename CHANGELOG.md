# Changelog

All notable changes to the Lyra project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

### Fixed
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
