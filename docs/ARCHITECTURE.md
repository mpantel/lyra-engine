# Lyra Architecture

## Contents

- [About ORFEAS](#about-orfeas)
- [Overview](#overview)
- [Technology Stack](#technology-stack)
- [Core Architecture](#core-architecture)
- [Data Flow](#data-flow)
- [Projections](#projections)
- [Write-Side Monitoring](#write-side-monitoring)
- [Configuration System](#configuration-system)
- [Database Schema](#database-schema)
- [Extensibility Points](#extensibility-points)
- [Performance Considerations](#performance-considerations)
- [Security Considerations](#security-considerations)
- [Testing Strategy](#testing-strategy)
- [Monitoring and Observability](#monitoring-and-observability)
- [Deployment](#deployment)
- [File Locations](#file-locations)
- [Future Directions](#future-directions)
- [Research Context](#research-context)

## About ORFEAS

Lyra is the engine of ORFEAS (Object-Relational to Event-Sourcing
Architecture), a framework for moving applications built on Object-Relational
Mapping (ORM) to event sourcing one checked step at a time, with privacy
compliance built in. ORFEAS is developed by Michail Pantelelis as part of his
PhD research at the University of the Aegean, Department of Information and
Communication Systems Engineering (see [Research Context](#research-context)).

### Naming

The name comes from Greek mythology. **Orpheus** (Ὀρφεύς, *Orfeas* in Modern
Greek) was a musician and poet whose music could charm all living things. His
instrument was the **lyre** (λύρα).

- **ORFEAS** is the overall architecture that carries out the transformation.
- **Lyra** is the transformation engine, the instrument through which ORFEAS
  does its work.

As Orpheus used his lyre to cross between the world of the living and the
underworld, ORFEAS uses Lyra to cross from ORM architectures to event sourcing.

### Vision

The problem:

1. **Legacy ORM architecture**: decades of investment in ORM-based systems
2. **Event sourcing benefits**: audit trails, temporal queries, alignment with
   event-driven systems
3. **Privacy requirements**: GDPR asks for data lineage and transparency about
   processing
4. **Migration risk**: rewriting an application's architecture is costly and
   risky

The ORFEAS approach is a gradual transformation path that:

- leaves the application's models and controllers unchanged;
- introduces event sourcing one checked step at a time, through seven
  configurations;
- integrates privacy policies with the events;
- verifies the CRUD-to-event mapping formally.

### Framework Components

```
┌─────────────────────────────────────────────────────────────────┐
│                      ORFEAS Framework                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐          │
│  │     Lyra     │  │   PAM DSL    │  │   PetriFlow   │          │
│  │Transformation│  │Privacy Attr. │  │Formal Analysis│          │
│  │    Engine    │  │    Matrix    │  │& Verification │          │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────┘          │
│         │                  │                  │                 │
│         └──────────────────┼──────────────────┘                 │
│                            ▼                                    │
│              ┌──────────────────────────┐                       │
│              │   Application Layer      │                       │
│              │  (Rails/ORM/CRUD)        │                       │
│              └──────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

PAM DSL and PetriFlow are optional: Lyra works without either.

**Lyra** (gem `orfeas_lyra`): the CRUD-to-event-sourcing transformation.

- Seven configurations: the mode is application-wide, and event sourcing takes
  one of four projection modes (see [Operational Modes](#layer-1-interception-layer)).
- Checked mode switches: a switch that makes the events authoritative is
  checked first ([MIGRATION_GUIDE.md, Switching modes](MIGRATION_GUIDE.md#switching-modes)).
- Genesis: rows that predate Lyra get Imported events.
- DualView: compares each row with the state replayed from its events.
- Point-in-time state: `Lyra.state_at(Order, 42, 3.days.ago)` and
  `Order.as_of(3.days.ago).find(42)`, in every mode that records events.
- Built as a Rails engine on RailsEventStore, intercepting writes through
  ActiveRecord callbacks and persistence and relation overrides.

Research foundation:

> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". *26th Pan-Hellenic Conference on Informatics (PCI 2022)*. DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)

**PAM DSL** (gem `orfeas_pam_dsl`): declarative privacy policy definition and
enforcement using the Privacy Attribute Matrix (PAM) model.

- Field-level classification: PII type and sensitivity level
- Purpose-based access: GDPR Article 6 legal bases
- Consent requirements per purpose
- Retention policies with field-level durations
- GDPR reports: access (Art. 15), erasure planning (Art. 17), portability
  (Art. 20)

Research foundation:

> Pantelelis, M., & Kalloniatis, C. (2024). "Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR". *19th International Conference on Availability, Reliability and Security (ARES 2024)*. DOI: [10.1145/3664476.3669932](https://doi.org/10.1145/3664476.3669932)

**PetriFlow** (gem `orfeas_petri_flow`): modeling and formal verification of
event flows.

- Colored Petri nets: typed tokens, guards, arc expressions
- Matrix analysis: CRUD-event mapping, correlation, causation, lineage
- Verification: reachability, boundedness, liveness (including
  deadlock-freedom except at terminal places), invariants
- Simulation: step-by-step and Monte Carlo, with traces
- Visualization and export: GraphViz, Mermaid; PNML, CPN Tools, JSON, YAML

Research foundation: Jensen & Kristensen (2009), *Coloured Petri Nets*;
Murata (1989), "Petri nets: Properties, analysis and applications".

### Migration Path

The full procedure, with every check, is in
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md). In outline:

**Phase 1: Observation (Monitor).**

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor
  config.models = %w[Student]
end

# The application runs unchanged
student = Student.create!(name: "Alice", email: "alice@uni.edu")
# → the row is written as before
# → a StudentCreated event is appended in the same transaction
```

**Phase 2: Verification.**

```ruby
Lyra::DualView.new(Student, student.id).compare[:differences]
# => { no_differences: true }

Lyra::DualView.find_discrepancies(Student)   # every row whose events disagree with it

Lyra.verify_mapping!   # PetriFlow nets for the mapping; raises Lyra::MappingVerificationError on failure
```

`bin/rails lyra:genesis` imports rows that predate Lyra, and
`bin/rails lyra:repair` brings the event log back in line with the tables if
Monitor lost events.

**Phase 3: Hijack.**

```bash
bin/rails lyra:mode:check TO=hijack   # check the switch and certify it
```

Then deploy with `config.mode = :hijack`. Application code is unchanged; each
write becomes a command, its event is appended first, and the row is written
from it.

**Phase 4: Event sourcing.**

```ruby
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :sync   # or :async, :disabled, :lazy
end
```

The event log is the source of truth; the tables are a projection of it (or,
in ES-NoProj, absent).

### Privacy Compliance Features

Details are in [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md) and
[API_REFERENCE.md](API_REFERENCE.md#privacy). In short:

- GDPR reports (need PAM DSL): `Lyra::Privacy::GDPRCompliance` builds the
  Art. 15 export, the Art. 17 erasure plan (it changes nothing) and the
  Art. 20 portable export.
- Erasure (Art. 17): `Lyra::Erasure.erase!(Student, id, reason: ...)` erases
  the record's personal data from its row and from every event in its stream,
  overwriting the events in place, and appends an `ErasureApplied` event. Also
  `bin/rails lyra:erase`.
- Purpose-bound reads: `Lyra.with_purpose(:enrollment) { Student.find(id) }`
  checks the declared attributes read against the policy.
- Consent as a Petri net guard:
  `PetriFlow::Colored::Guards.has_consent(:email_marketing)`.
- Opt-in: privacy stamps on events (`config.annotate_privacy`), the access log
  (`config.record_access_events`), and retention (`config.retention_executor`,
  `Lyra::Retention.apply!`).

### Formal Verification

| Question | How Lyra answers it |
|---|---|
| Does every CRUD operation produce an event? | `Lyra.verify_mapping!` runs PetriFlow nets for the CRUD lifecycle and for create, update and destroy across the modes, and checks that their terminal places are reachable, that they are safe (1-bounded), and that they are deadlock-free except at terminal places. See [WORKFLOW_GENERATOR.md](WORKFLOW_GENERATOR.md). |
| Can a write change the store without an event? | `Lyra::Verification::BypassWorkflow` models `update_column(s)`, `delete`, `touch`, `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify`; `BypassWorkflow.coverage` checks that every reachable end state is a rejection or a store change with an event logged. |
| Does replaying the events produce the row? | `Lyra::DualView.new(Student, id).compare[:differences] == { no_differences: true }`; `config.dual_view_sample_rate` checks a share of committed writes as they happen (opt-in). |
| Can every change to a field be traced, and a record's state at any time be recovered? | `Lyra::EventFlow#data_lineage`, `Lyra.state_at` and `Model.as_of` (see [Analysis Projections](#analysis-projections)). |

The formal model orders a write as P_crud → T_map → P_event → T_apply →
P_aggregate → T_publish → P_published: the aggregate applies the event before
it is stored. How each configuration places the row write around these steps
is shown under [Data Flow](#data-flow).

A workflow of your own can be verified the same way:

```ruby
class OrderFlow < PetriFlow::Workflow
  workflow_name "Order Flow"
  places :created, :paid, :shipped
  initial_place :created
  terminal_places :shipped

  transition :process_payment, from: :created, to: :paid
  transition :ship, from: :paid, to: :shipped
end

results = OrderFlow.new.verify!
results[:liveness][:terminates_properly]   # deadlock-free except at terminal places
results[:boundedness][:is_safe]
```

### Use Cases

Each evaluation application in the monorepo exercises Lyra on a different
domain: a university payment system (the Aegean e-Pay testbed), a
loan-application process (the BPI Challenge 2017 replay), and an e-commerce
platform (the Solidus case study with the Olist orders). Typical uses:

- **Audit trail without code changes**: Monitor mode records every write as an
  event.
- **Access accountability**: with `config.record_access_events`, who accessed
  which declared attributes, for which purpose, is recorded as events.
- **Temporal reconstruction**: `Lyra.state_at` and `Model.as_of` recover a
  record or a table as it was at a given time.
- **Data subject requests**: `GDPRCompliance` reports and `Lyra::Erasure`.

## Overview

Lyra is built as a Rails Engine with a modular architecture that supports both
non-intrusive monitoring and the hijacking of CRUD operations.

## Technology Stack

- **Ruby**: 4.0 or later
- **Rails**: 8.0 or later
- **RailsEventStore**: `~> 3.0`, event persistence and stream management
- **PostgreSQL**: the supported database (`pg` gem); Genesis, ES-Lazy's catch-up
  and ES-Async's projection job take PostgreSQL advisory locks
- **SQLite**: used in development and the test suites (it serialises writers,
  so it needs no lock); other adapters run without a lock, with a warning
- **ERB**: view layer for the dashboard
- **ActiveRecord**: ORM integration and callbacks

Gems:

1. **orfeas_lyra** (entry file `lyra`): transformation engine
2. **orfeas_pam_dsl** (`pam_dsl`): privacy policy DSL, optional
3. **orfeas_petri_flow** (`petri_flow`): formal verification, optional

Development tools: Minitest with minitest-reporters and Mocha (the gems' test
suites), SimpleCov (coverage), RuboCop (code style), GraphViz and Mermaid
(diagram output formats).

## Core Architecture

### Layer 1: Interception Layer

**CrudInterceptor** (`lib/lyra/interceptors/crud_interceptor.rb`)
- Included in every ActiveRecord model by the Rails Engine;
  `monitor_with_lyra` (or `config.models`) turns it on for a model
- Monitor: ActiveRecord `after_create`, `after_update` and `after_destroy`
  callbacks record the event after the row write
- Hijack and event sourcing: `WriteHooks`, prepended to
  `ActiveRecord::Persistence`, take over the write after every `before_*`
  callback of the model and before the row write
- Routes operations based on operational mode

**Event Capture Coverage:**

Because Lyra hooks into ActiveRecord, events are captured from all sources
that write through it: web requests, Rails console, background jobs, rake
tasks, seeds, runner scripts.

Writes that skip callbacks (`update_columns`, `update_column`, `touch`,
`delete`, `update_all`, `delete_all`, `insert_all`, `upsert_all`,
`dependent: :nullify`) are recorded as bypass events, one per affected record
(`lib/lyra/bypass_events.rb`, `lib/lyra/strict_data_access.rb`). In Hijack and
the event-sourcing modes a bypass write whose event cannot be stored fails and
is rolled back; in Monitor the failure is logged and the write stands, unless
`config.monitor_append_failure = :fail_write`. Raw SQL
(`connection.execute`), triggers and other applications writing the same
tables are not seen.

**Strict Data Access Mode** (`config.strict_data_access = true`):
Lyra makes callback-bypassing methods on monitored models raise
`Lyra::StrictDataAccessViolation` instead.

Intercepted operations:
- Instance: `update_columns`, `update_column`, `delete`
- Relation: `update_all`, `delete_all`
- Class: `insert_all`, `insert_all!`, `upsert_all`

`touch` is not a violation (Rails itself calls it for `belongs_to ... touch: true`);
it is recorded as a bypass event.

For legitimate bulk operations, use `Lyra.without_strict_access`:
```ruby
Lyra.without_strict_access do
  User.where(active: false).delete_all
end
```

Rails association operations (e.g., `dependent: :nullify`) are automatically allowed.

**Operational Modes:**

Lyra has four principal modes; event sourcing takes one of four projection
modes, which gives seven configurations:

| # | Configuration | Config | Authoritative store | What a write does |
|---|------|--------|---|-------------|
| 1 | **Disabled** | `mode: :disabled` | tables | plain ActiveRecord, no events (baseline) |
| 2 | **Monitor** | `mode: :monitor` | tables | row written, then the event appended in the same transaction |
| 3 | **Hijack** | `mode: :hijack` | events | event appended, then the row written |
| 4 | **ES-Sync** | `mode: :event_sourcing, projection_mode: :sync` | events | event appended; the row projected in the same transaction |
| 5 | **ES-Async** | `mode: :event_sourcing, projection_mode: :async` | events | event appended; the row projected by a background job after commit |
| 6 | **ES-NoProj** | `mode: :event_sourcing, projection_mode: :disabled` | events | event appended; no row; reads rebuild records from events and are evaluated in Ruby |
| 7 | **ES-Lazy** | `mode: :event_sourcing, projection_mode: :lazy` | events | event appended; before a read the tables are brought up to date from the log, and the read runs as real SQL |

Benchmarks add **Hijack+PT** (Hijack with the application's PaperTrail left
on) to isolate PaperTrail's share of the cost; it is a measurement
configuration, not a mode. The modes are also described in
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#the-modes-at-a-glance) and
[API_REFERENCE.md](API_REFERENCE.md).

**Mode Details:**

1. **Disabled Mode** (`config.mode = :disabled`)
   - Lyra completely bypassed
   - Standard ActiveRecord behavior
   - Use for baseline benchmarks

2. **Monitor Mode** (`config.mode = :monitor`)
   - Non-intrusive observation; no command or aggregate is involved
   - CRUD operations complete normally
   - The event is built and appended in an `after_*` callback, inside the row
     write's transaction (in a savepoint), not asynchronously
   - A failed append is logged and the write stands; `lyra:repair` recovers
     the missing events (`config.monitor_append_failure = :fail_write` fails
     the write instead)

3. **Hijack Mode** (`config.mode = :hijack`)
   - Intercepts CRUD before the row write
   - Routes through the Command/Aggregate pattern
   - Event sourcing becomes source of truth
   - CRUD database kept for compatibility

4. **Event Sourcing Mode** (`config.mode = :event_sourcing`)
   - Full event sourcing with configurable projection modes:
     - `:sync` (default) - Projections updated synchronously in same transaction
     - `:async` - Projections updated via background jobs
     - `:disabled` (ES-NoProj) - No projections; reads rebuild records from
       the event store and evaluate the query in Ruby
     - `:lazy` (ES-Lazy) - Projection on read; the tables are a disposable
       cache of the log

   See [Table Projections in Each Configuration](#table-projections-in-each-configuration).

### Layer 2: Event Layer

**Event** (`lib/lyra/event.rb`)
- Base class extending `RailsEventStore::Event`
- Standard event structure with data and metadata
- Dynamic event class creation
- Event registry for tracking
- `Lyra::Event.operation_of(event)`, the operation an event replays as (see
  [Streams and Replay](#streams-and-replay))

**Event construction**
- Monitor: `CrudInterceptor#build_event_data` and `#publish_event`
- Hijack and event sourcing: `CommandHandler#create_event` and `#create_events`
- Both hand the write's own event to `Lyra::DomainEvents.build`, which
  renames it or adds events by the model's `domain_events:` rules
- Event names from `event_prefix:` / `event_mapping:`; namespaced model
  support (`Billing::Invoice` → `BillingInvoiceCreated`)

**Event Structure:**
```ruby
{
  data: {
    model_class: String,    # ActiveRecord model class name
    model_id: Integer,      # Record ID
    operation: Symbol,      # :created, :updated, :destroyed (:imported for Genesis and repair)
    attributes: Hash,       # Record attributes (without created_at, updated_at in Monitor)
    changes: Hash,          # Before/after changes
    timestamp: Time         # When event occurred
  },
  metadata: {
    user_id: Integer,       # Current user (if available)
    request_id: String,     # Request tracking
    correlation_id: String, # Causal chain (Lyra::Correlation)
    causation_id: String,   # Causal chain (Lyra::Causation)
    action_id: String,      # User action in scope (Lyra::UserActionContext)
    user_action: Hash,
    source: String          # "lyra_command_handler" on Hijack and event-sourcing events
  }
}
```

`config.metadata_proc` adds its hash to every mode's events. The keys each
write path records are listed under [Metadata](API_REFERENCE.md#metadata).

### Layer 3: Command/Aggregate Layer

**Command** (`lib/lyra/command.rb`)
- Represents intent to change state
- Three command types: `CreateCommand`, `UpdateCommand`, `DestroyCommand`
- Immutable value objects
- Contains all data needed for state transition

**CommandHandler** (`lib/lyra/command_handler.rb`)
- Processes commands in Hijack and the event-sourcing modes
- Loads aggregates
- Applies the event to the aggregate, then stores it
- Returns result object

**Aggregate** (`lib/lyra/aggregate.rb`)
- Minimal base class: domain entity with behavior
- Loads state from event stream
- Applies events (`apply_<event class name>`) to rebuild state
- Validates business rules
- Emits new events

**GenericAggregate**
- Default aggregate for monitored models, and the class to subclass for a
  custom aggregate: its stream is the model's (`"Model$id"`), and it applies
  events by the operation they record (`apply_created`, `apply_updated`, ...)
- Handles standard CRUD event patterns
- Used when no custom aggregate is specified; it decides nothing from
  history, so it starts empty rather than reading the stream. Only a model's
  own `aggregate_class` is loaded with its stream's history

### Layer 4: Storage Layer

**Event store** (`config.event_store`, a `RailsEventStore::Client`)
- Lyra uses the client directly; every event is appended through
  `Lyra.append_events` (`lib/lyra/event_store_adapter.rb`), which raises
  `Lyra::EventStoreUnavailableError` when the store fails
- Stores events in `event_store_events` table
- Maintains stream positions in `event_store_events_in_streams`
- Serialization is the client's (configurable)

**Stream Organization:**
- One stream per record: `"#{model_class}$#{id}"`
- Events appended in order
- Access events go to separate streams, `"Lyra::DataAccess$<subject>"` (see
  [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#the-access-log))

### Layer 5: Query Layer

**Projection**, **StateProjection**, **AuditProjection**
(`lib/lyra/projection.rb`): custom read models, replay of a record's state,
and its audit trail. See [Projection Classes](#projection-classes).

**Point-in-time state** (`lib/lyra/temporal.rb`)
- `Lyra.state_at(Model, id, time)` replays a record's stream up to `time`
  (attributes then, or nil)
- `Model.as_of(time)` builds read-only records as they were then

**Table projections**: `ModelProjection` (ES-Sync), `AsyncProjectionJob`
(ES-Async), reads from the event store (ES-NoProj) and projection on read
(ES-Lazy). See [Table Projections in Each Configuration](#table-projections-in-each-configuration).

### Layer 6: Analysis Layer

**DualView** (`lib/lyra/dual_view.rb`)
- Compares CRUD state vs Event-sourced state
- Identifies discrepancies
- Provides recommendations
- Batch analysis capabilities

**StateAnalyzer** (`lib/lyra/dual_view.rb`)
- Generates analysis reports
- Recommends actions
- Identifies issues (missing events, state drift)

**EventFlow** (`lib/lyra/event_flow.rb`): event flows, data lineage and
privacy impact. See [Analysis Projections](#analysis-projections).

### Layer 7: Presentation Layer

**DashboardController** (`app/controllers/lyra/dashboard_controller.rb`)
- REST API for monitoring
- JSON responses
- Model overview
- Comparison endpoints

**ERB Views**
- Template-based UI
- Real-time state comparison
- Event stream visualization
- Discrepancy highlighting

### Layer 8: Privacy Layer (PAM DSL Integration)

Lyra integrates with **PAM DSL** (Privacy Attribute Matrix DSL) for privacy
management. PAM DSL is an optional dependency; without it no policy loads,
nothing is detected as PII, and purpose checks and the access log do nothing.

**Privacy Delegation:**
- `Lyra::Privacy::PIIDetector` → delegates to `PamDsl::PIIDetector`
- `Lyra::Privacy::PIIMasker` → delegates to `PamDsl::PIIMasker`
- `Lyra::Privacy::GDPRCompliance` → delegates to `PamDsl::GDPRCompliance`

**PolicyIntegration** (`lib/lyra/privacy/policy_integration.rb`)
- Bridges Lyra events with PAM DSL policies
- Field-level PII classification with sensitivity levels
- Purpose-based access control aligned with GDPR
- Retention policies with field-level granularity
- Fallback to name-based detection for fields the policy does not declare

**PII Detection Modes:**
- **Partial matching** (default): Detects PII in compound field names (`customer_email`, `billing_phone`)
- **Exact matching**: Strict mode for specific known field names only

**Sensitivity Levels:**
| Level | Description | Legal Basis |
|-------|-------------|-------------|
| `:public` | Publicly accessible | - |
| `:internal` | Low risk, basic protection | GDPR Art. 6 |
| `:confidential` | Medium risk, enhanced protection | GDPR Art. 6, Art. 32 |
| `:restricted` | High risk, special categories | GDPR Art. 9, PCI DSS |

Policies, purpose-bound reads and the access log are described in
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

## Data Flow

### Monitor Mode Flow

```
ActiveRecord CRUD Operation (one transaction)
    │
    ├─→ Database (PostgreSQL/SQLite)
    │   └─→ Record saved/updated/deleted
    │
    └─→ after_* callback (no command, no aggregate)
        └─→ CrudInterceptor
            └─→ build_event_data
                └─→ publish_event (Lyra::DomainEvents.build)
                    └─→ Event created
                        └─→ Lyra.append_events (savepoint)
                            └─→ event_store_events table
                                └─→ Projections updated (if subscribed)
```

### Hijack Mode Flow

```
ActiveRecord CRUD Operation
    │
    └─→ model's before_* callbacks
        └─→ WriteHooks (_create_record / _update_record / destroy)
            └─→ Command created
                └─→ CommandHandler
                    ├─→ Load Aggregate (from its stream, for a custom aggregate)
                    ├─→ Create new event
                    ├─→ Apply event to aggregate
                    ├─→ Store event (Lyra.append_events)
                    └─→ Return result
                        └─→ Row write
                            └─→ Database (PostgreSQL/SQLite)
```

The event-sourcing modes follow the same path to the stored event; then
ES-Sync projects the row in the same transaction, ES-Async's job writes it
after commit, ES-NoProj writes no row, and ES-Lazy projects it before the
next read.

### Dual View Comparison Flow

```
DualView.new(ModelClass, id).compare
    │
    ├─→ crud_state
    │   └─→ ModelClass.find_by(id: id)
    │       └─→ Database query
    │
    ├─→ event_sourced_state
    │   └─→ event_store.read.stream("ModelClass$#{id}")
    │       └─→ StateProjection#rebuild_from_events
    │
    └─→ calculate_differences
        └─→ Compare attributes
            └─→ Return discrepancies
```

## Projections

A projection is a read model built from events. Lyra uses projections in
three ways:

- **Replay**: rebuild one record's state from its stream (`StateProjection`),
  or list what happened to it (`AuditProjection`).
- **Table projections**: in the event-sourcing configurations the events are
  authoritative and the model's table is a projection of them, kept up to
  date synchronously, by a background job, lazily before each read, or not at
  all (reads then come from the events themselves).
- **Analysis**: event flows and data lineage (`EventFlow`), row-versus-events
  comparison (`DualView`), and GDPR reports (`GDPRCompliance`).

The exact API is in [API_REFERENCE.md](API_REFERENCE.md).

### Streams and Replay

Each record has one stream, `"#{Model.name}$#{id}"` (`"Student$1"`,
`"Spree::Price$7"`). Its events carry the data envelope shown under
[Layer 2](#layer-2-event-layer) (see also
[API_REFERENCE.md](API_REFERENCE.md#lyraevent)).

Replay dispatches on the operation each event recorded, read by
`Lyra::Event.operation_of(event)`:

| Operation | Effect on the replayed state |
|---|---|
| `:created` | the event's attributes become the state |
| `:imported` | the same; written by Genesis for a row that predates Lyra, and by repair |
| `:updated` | the new value of each change is applied |
| `:destroyed` | the record is marked destroyed |
| `nil` | not replayed (an additional domain event declared with `also: true`, for example) |

`operation_of` reads the operation from the event's data and falls back to the
event name's suffix only for events that carry none, so a domain event that
replaces a CRUD event (`PaymentCompleted` for an update) replays as the
operation it stands for. The same rule is used by every replay in Lyra:
`StateProjection`, the ES-NoProj reader, rebuilds, DualView and the mode
check.

### Projection Classes

**Location:** `lib/lyra/projection.rb`

**`Lyra::Projection`.** The base class for custom read models.
`handle(event)` calls `apply_<event type, demodulized and underscored>` if the
projection defines it, so `Lyra::Events::StudentCreated` goes to
`apply_student_created`. The name comes from the event's type, so an event
read back as a plain `RubyEventStore::Event` still reaches its handler.
`Projection.handle(event)` does the same on a new instance, and
`Projection.call(event)` calls it, so the class itself is a RubyEventStore
handler. `Projection.subscribe_to(*event_types)` subscribes the class on
Lyra's event store and returns RubyEventStore's unsubscribe procs:

```ruby
class EnrollmentStats < Lyra::Projection
  private

  def apply_student_created(event)
    # update your read model
  end
end

EnrollmentStats.subscribe_to(Lyra::Events::StudentCreated)
```

**`Lyra::StateProjection`.** `StateProjection.rebuild_state(model_class, id)`
reads the record's stream and returns the replayed attributes, following the
table in [Streams and Replay](#streams-and-replay). A destroyed record's state
keeps its last attributes and gains `deleted: true` and `deleted_at`. DualView
uses it for the event-sourced side of a comparison.

**`Lyra::AuditProjection`.** `AuditProjection.audit_trail(model_class, id)`
returns one hash per event of the record's stream, in order: `operation`,
`timestamp`, `user_id` (from the event's metadata), `changes` and
`attributes`. Which write paths record a `user_id` is listed under
[Metadata](API_REFERENCE.md#metadata).

### Table Projections in Each Configuration

Event sourcing (`config.mode = :event_sourcing`) has four projection modes.
Together with Disabled, Monitor and Hijack they make the seven configurations
listed under [Operational Modes](#layer-1-interception-layer).

| Configuration | `projection_mode` | How the table follows the events |
|---|---|---|
| ES-Sync | `:sync` (default) | `Lyra::Projections::ModelProjection` writes the row in the write's transaction |
| ES-Async | `:async` | `Lyra::Projections::AsyncProjectionJob` (queue `lyra_projections`, enqueued after commit) replays the record's stream onto the row |
| ES-NoProj | `:disabled` | no row is written; reads are answered from the events |
| ES-Lazy | `:lazy` | no row at write time; pending events are applied before each read |

In ES-Sync and ES-Async a failed projection is logged and passed to
`config.projection_error_handler`, or re-raised with
`config.strict_projections = true`. ES-Async's job is enqueued only once the
writing transaction commits, so a worker never looks for an event that is not
yet visible, and a rolled-back write enqueues nothing; it retries transient
failures.

#### ES-NoProj: Reads from the Event Store

**Locations:** `lib/lyra/projections/event_store_reader.rb`,
`cached_projection.rb`, `cached_relation.rb`, `cached_joins.rb`,
`lib/lyra/interceptors/association_interceptor.rb`

```ruby
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :disabled
end
```

**Write path.** The command stores the event, the record's cache entry is
rebuilt (or dropped, for a destroy), and the SQL statement is skipped.

**Read path.** On a monitored model, `find`, `find_by`, `find_by!`,
`exists?` with an id, `where`, `all`, `first` and `last` go to
`Lyra::Projections::EventStoreReader`. It rebuilds each record by replaying
its stream, through `Lyra::Projections::CachedProjection`:

- One `Rails.cache` entry per record, under
  `lyra_projections/<Model>/records/<id>/v2`, holding the attributes and the
  id of the last event they were built from. An entry is used only while that
  is still the stream's last event, so a stale entry is detected rather than
  served. Entries expire after an hour. There is no cache entry for a whole
  collection.
- A collection (`all`, `where`, `count`, `find_by` on other attributes) is
  assembled from the record entries: one query for the last event of every
  stream of the model, one bulk cache read, and a replay of the streams whose
  entry is missing or out of date.

Collections are `Lyra::Projections::CachedRelation` objects, evaluated in
Ruby. They support hash conditions (values, arrays, ranges, `nil`, records),
`where.not`, `or`, simple SQL fragments of `"column OP ?"` terms and common
search fragments, ordering, `limit`/`offset`, `page`/`per`, `joins` on direct
associations (evaluated in memory), `count`, `sum`, `average`, `minimum`,
`maximum`, `group` with grouped aggregates, `pluck`, batches, and scopes that
reduce to hash conditions; the complete list is in
[API_REFERENCE.md](API_REFERENCE.md#es-noproj-projection_mode-disabled).
Query values are compared as controller parameters arrive: the string `"2"`
matches the integer `2`, and `"true"`/`"false"` match booleans.

Anything it cannot answer exactly raises
`Lyra::Projections::UnsupportedQuery` rather than returning an unfiltered or
partly filtered answer: other SQL fragments, string, nested, `:through`,
polymorphic or scoped joins, conditions on tables not joined, conditions
nested more than one level, and scopes it cannot reduce. Use ES-Lazy or a
projected configuration for such queries.

**Associations.** The engine installs
`Lyra::Interceptors::AssociationInterceptor`, so `belongs_to`, `has_one` and
`has_many` associations whose target is a monitored model are read the same
way, `:through` associations (read through the intermediate records),
association scopes and calculations on associations included; a `has_many`
returns a `CachedRelation`, and a polymorphic `belongs_to` resolves its class
from the type column.

**Genesis.** In ES-NoProj a model's first read in a process, as well as its
first write, imports rows that predate Lyra, so they have streams to read.

**Cost.** Every query scans the rebuilt records, so reads slow down as the log
grows. ES-NoProj is an audit and replay mode rather than a way to serve
application reads.

#### ES-Lazy: Tables Brought Up to Date Before Each Read

**Locations:** `lib/lyra/projections/lazy_projection.rb`,
`lib/lyra/interceptors/lazy_reads.rb`

Writes store events only, as in ES-NoProj. Before any ActiveRecord read on any
model (record loads, associations, calculations, `pluck`, `exists?`), not only
monitored ones, since a query on an unmonitored model can join or merge a
monitored table, `LazyProjection.catch_up!` applies the events the tables have
not seen, one by one in the log's global order; the read then runs as real SQL,
so joins, merged relations, fragments and aggregates all work. SQL sent
directly through the connection (`connection.select_all`) does not trigger a
catch-up.

- A checkpoint (`lyra_projection_checkpoints`, created on first use, no
  migration) records the last event applied and the ids missing below it.
  Catch-up runs under a PostgreSQL advisory lock and in the reader's
  transaction, so concurrent readers never apply an event twice and a
  rolled-back write leaves nothing behind.
- Event ids are assigned before commit, so a slow transaction can commit an
  earlier id late: missing ids are watched as gaps and re-checked at most
  every `GAP_RECHECK` (1 s); a late event replays its record in full. A gap
  still empty after `LazyProjection::GAP_TTL` (300 s) is taken as a rollback,
  which bounds the mode: a single transaction open longer than that has its
  events skipped by the tables.
- Once caught up, a read costs two small queries to see whether the log has
  moved on. The tables can be dropped and rebuilt from the log at any time.

#### Rebuild

**Location:** `lib/lyra/projections/rebuild.rb`

`Lyra::Projections::Rebuild.rebuild(Model)` clears the table (unless
`truncate: false`) and replays every stream through the same projection code
live writes use; `rebuild_all` does every monitored model, and
`replay_record(Model, id)` one record. `bin/rails lyra:projections:rebuild
[MODEL=A,B] [TRUNCATE=false]` runs it from the command line. Rows without a
stream are lost by a truncating rebuild, so run Genesis first; see
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#recovery).

### Analysis Projections

**`Lyra::EventFlow`** (`lib/lyra/event_flow.rb`).
`Lyra::EventFlow.new(subject_id: nil, subject_type: nil, time_range: nil)`
reads events from the whole store, keeps those of the subject (by `user_id` in
the metadata, or by model and id) when both subject arguments are given, and
those in the time range (default: the last 30 days).

| Method | Returns |
|---|---|
| `flow_data` | `{ timeline:, flows:, statistics:, privacy_impact: }`, events grouped by correlation id |
| `data_lineage(field_name, model_name = nil)` | `{ field:, model_class:, total_modifications:, first_seen:, last_modified:, lineage: }`; each lineage entry has `timestamp`, `event_id`, `model`, `record_id`, `operation`, `old_value`, `new_value`, `source`, `user_id`, `action` |
| `privacy_impact_analysis` | `{ total_events:, events_with_pii:, pii_categories:, pii_fields_count:, sensitive_operations:, data_flows:, risk_assessment: }` |
| `crud_to_event_mapping(model_name, operation, model_id = nil)` | the events of one operation |
| `reconstruct_state_chain(model, id)` | the state after each event of a record's stream |

**`Lyra::DualView`** (`lib/lyra/dual_view.rb`). Compares a record's row with
the state replayed from its stream. `DualView.new(model, id).compare` returns
`crud_view`, `event_sourced_view`, `differences` and `metadata`;
`differences` is `{ no_differences: true }`, `{ exists_mismatch: true }`, or
one entry per differing column (`{ "name" => { crud: ..., event_sourced: ... } }`).
`created_at` and `updated_at` are not compared.
`DualView.find_discrepancies(model)` runs the comparison for every row;
`config.dual_view_sample_rate` compares a share of committed writes after
commit. Details: [API_REFERENCE.md](API_REFERENCE.md#dualview-and-verification).

**`Lyra::Privacy::GDPRCompliance`** (`lib/lyra/privacy/gdpr_compliance.rb`,
needs pam_dsl). `GDPRCompliance.new(subject_id:, subject_type: "User")` wraps
PAM's report builder (`PamDsl::GDPRCompliance`) over Lyra's event store. It
selects the events whose metadata or data name the subject as `user_id`, or
whose `model_class` and `model_id` are the subject. Reports: `data_export`
(Art. 15), `rectification_history` (Art. 16), `right_to_be_forgotten_report`
(Art. 17, a plan of affected streams and models; it deletes nothing),
`portable_export(format: :json)` (Art. 20), `processing_activities`,
`retention_compliance_check`, `consent_audit` and `full_report`. See
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

### Working Examples

The examples assume a `Student` model monitored in Monitor mode (with the
`:university_system` policy shown in
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#policies)).

Audit trail:

```ruby
student = Student.create!(name: "John Doe", email: "john@example.com", student_id: "S1")
student.update!(email: "john.doe@university.edu")

Lyra::AuditProjection.audit_trail(Student, student.id).map { _1[:operation] }
# => [:created, :updated]
```

Data lineage:

```ruby
flow = Lyra::EventFlow.new(subject_type: "Student", subject_id: student.id)
lineage = flow.data_lineage(:email, "Student")
lineage[:total_modifications]                    # => 2
lineage[:lineage].map { _1[:new_value] }         # => ["john@example.com", "john.doe@university.edu"]
```

Row versus events:

```ruby
Lyra::DualView.new(Student, student.id).compare[:differences]
# => { no_differences: true }
```

Point-in-time state:

```ruby
Lyra.state_at(Student, student.id, 6.months.ago)   # attributes then, or nil
Student.as_of(6.months.ago).find(student.id)       # a read-only Student as it was
```

## Write-Side Monitoring

**Location:** `lib/lyra/interceptors/crud_interceptor.rb`

Every write to a monitored model is recorded as an event with who made it and
in which causal chain. What a write does depends on the configuration:

- **Monitor**: the row is written, then `build_event_data` assembles the
  envelope (attributes without `created_at` and `updated_at`, the write's
  `previous_changes`, a timestamp) and the event is appended to the record's
  stream in the same transaction.
- **Hijack and event sourcing**: the write becomes a command
  (`Lyra::Commands::CreateCommand`, `UpdateCommand`, `DestroyCommand`) run by
  `Lyra::CommandHandler`; the event is applied to the aggregate and stored
  first, and then the row is written, projected, or skipped, as
  [Table Projections in Each Configuration](#table-projections-in-each-configuration)
  describes.

Both paths attach the same attribution metadata to the event: the user, the
request, the correlation and causation ids in scope
(`Lyra::Correlation.with_id`, `Lyra::Causation.with_id`), the user action in
scope (`Lyra::UserActionContext`) and `config.metadata_proc`'s hash; the
command handler adds `source: "lyra_command_handler"`. A command without a
record (direct `CommandHandler` use) carries only the causal chain and the
user action. The keys each path writes are listed under
[Metadata](API_REFERENCE.md#metadata).

Writes that skip callbacks are recorded as bypass events, as described under
[Layer 1](#layer-1-interception-layer); with `config.strict_data_access` they
raise `Lyra::StrictDataAccessViolation` instead (see
[API_REFERENCE.md](API_REFERENCE.md#callback-bypassing-writes)).

Reads are monitored separately, through purpose-bound reads and the access
log; see [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#read-side-monitoring).

### Privacy Stamps (opt-in)

With `config.annotate_privacy = true`, each event of a model whose policy is
loaded carries `metadata[:privacy]`: the policy name and, for every declared
attribute the event touches, its type, sensitivity, purposes, retention and
transformations, as the policy stood when the data was written. Values are
never copied into the stamp. `Lyra::Privacy.stamp_of(event)` reads it back
(`nil` for an unstamped event).

### Scope and Limits

- **What is recorded.** Writes through ActiveRecord to monitored models, in
  every mode but Disabled. Raw SQL, triggers and other applications are not
  seen. Reads are covered in
  [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#scope-and-limits).
- **The log is append-only, with one exception.** `Lyra::Erasure.erase!`
  (Art. 17) overwrites a record's events in place (same event id, position
  and time) to remove personal values, and records an
  `Lyra::Events::ErasureApplied` event naming the fields, the reason and who
  erased them. The event log therefore is not tamper-evident by itself:
  anyone with write access to the event store tables can change it.
- **Monitor can lose events.** In Monitor a failed append is logged and the
  write stands by default; `bin/rails lyra:repair` brings the streams back in
  line, but the detail of the lost changes is not recovered.
  `config.monitor_append_failure = :fail_write` makes Monitor fail the write
  instead. Hijack and the event-sourcing modes always fail the write.

## Configuration System

**Configuration** (`lib/lyra/configuration.rb`)
- Centralized configuration
- Model registration
- Per-model configuration
- Mode switching
- Event store setup

**ModelConfiguration**
- Per-model settings
- Custom event prefixes
- Custom aggregate classes
- Event name mapping

## Database Schema

### Rails Event Store Tables

```sql
-- Events table
CREATE TABLE event_store_events (
  id SERIAL PRIMARY KEY,
  event VARCHAR(36) NOT NULL UNIQUE,
  event_type VARCHAR NOT NULL,
  metadata TEXT,
  data TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL
);

-- Streams table
CREATE TABLE event_store_events_in_streams (
  id SERIAL PRIMARY KEY,
  stream VARCHAR NOT NULL,
  position INTEGER,
  event VARCHAR(36) NOT NULL,
  created_at TIMESTAMP NOT NULL,
  UNIQUE(stream, position),
  UNIQUE(stream, event)
);
```

Lyra's own tables, such as ES-Lazy's `lyra_projection_checkpoints`, are
created on first use and need no migration.

### Application Tables (Example: Aegean E-Pay Testbed)

See `examples/aegean_epay_testbed/db/migrate/*` for complete schema.

## Extensibility Points

### 1. Event Names and Domain Events

```ruby
MyModel.monitor_with_lyra(
  event_mapping: { created: "MyModelOpened" },
  domain_events: [{ name: "MyModelClosed", on: :update,
                    if: ->(record, changes) { changes.key?("closed_at") } }]
)
```

### 2. Custom Aggregates

A custom aggregate subclasses `Lyra::GenericAggregate` (`Lyra::Aggregate` is a
minimal base class). It is loaded with its stream's history, so its checks can
use it:

```ruby
class StudentAggregate < Lyra::GenericAggregate
  private

  def apply_updated(event)
    super
    # domain checks; raise to fail the write
  end
end

class Student < ApplicationRecord
  monitor_with_lyra aggregate_class: StudentAggregate, privacy_policy: :student_system
end
```

### 3. Custom Projections

Subclass `Lyra::Projection` and subscribe it to the events it reads; see
[Projection Classes](#projection-classes).

### 4. Event Store Client

```ruby
Lyra.configure do |config|
  config.event_store = RailsEventStore::Client.new(
    repository: RubyEventStore::ActiveRecord::EventRepository.new(
      serializer: RubyEventStore::Serializers::YAML
    )
  )
end
```

## Performance Considerations

The measured overhead of each configuration is in
[PERFORMANCE.md](PERFORMANCE.md). Monitor costs more throughput than Hijack
there, for reasons explained in that document; the July 2026 baseline is being
re-measured.

### Monitor Mode
- The event is appended in the write's own transaction, in a savepoint; there
  is no asynchronous publishing
- **Failure Handling**: a failed append is logged and the write stands, unless
  `config.monitor_append_failure = :fail_write`

### Hijack Mode
- Each write runs a command; the default `GenericAggregate` reads no history,
  so only a custom aggregate adds a stream read per update and destroy
- **Consistency**: the event and the row are written in one transaction; a
  failed append fails the write

### Event Sourcing Projection Modes
- **ES-Sync / ES-Async**: reads are plain SQL on projected tables; ES-Async
  trades read-after-write consistency for a cheaper write
- **ES-NoProj**: the slowest way to read; cost grows with the log (on the
  1,000-order Olist replay through Solidus it ran about 3x slower than
  Monitor, slowing as the log grew). Its published benchmark figure was
  inflated by a since-fixed harness defect and is being re-measured
- **ES-Lazy**: write cost as ES-NoProj; a read pays only for the events since
  the last read. It runs Solidus at about half ES-Sync's throughput

### Storage
- **PostgreSQL**: Recommended for production
  - Better concurrency
  - Advisory locks for Genesis, ES-Lazy and ES-Async
  - JSONB for event data (future enhancement)
  - Partitioning for large event tables
- **SQLite**: For development/testing
  - Single file database
  - No server required
  - Limited concurrency

## Security Considerations

1. **Event Data**: May contain sensitive information
   - Encrypt at rest
   - Control access to event store
   - Sanitize before logging

2. **Audit Trail**: Events provide complete history
   - The log is append-only except for erasure, which overwrites a record's
     events in place and records that it did (see
     [Scope and Limits](#scope-and-limits))
   - It is not tamper-evident by itself: restrict write access to the event
     store tables
   - Consider GDPR implications

3. **User Context**: Track who made changes
   - Store user_id in metadata
   - Link to authentication system

## Testing Strategy

### Unit Tests
- Test individual components in isolation
- Mock event store
- Test event mapping logic
- Test aggregate behavior

### Integration Tests
- Test CRUD interceptor integration
- Test event publishing
- Test state reconstruction
- Test dual view comparison

### End-to-End Tests
- Test complete workflows
- Test mode switching
- Test error handling
- Test with real database

## Monitoring and Observability

### Metrics
- Events published per second
- Event store latency
- Aggregate load time
- Projection lag
- Discrepancy count

### Logging
- Event publication
- Command execution
- Aggregate state changes
- Errors and failures

### Debugging
- Event stream inspection
- State reconstruction
- Aggregate history
- Dual view comparison

## Deployment

See [GETTING_STARTED.md](GETTING_STARTED.md) for a full walkthrough.

### As Rails Engine
```ruby
# Gemfile (the gems are named orfeas_*, their entry files are not)
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"          # optional, privacy
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"  # optional, verification

# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor
  config.event_store = RailsEventStore::Client.new
end
```

### Database Setup
```bash
rails generate rails_event_store_active_record:migration
rails db:migrate
```

### Mount Routes
```ruby
# config/routes.rb
mount Lyra::Engine => "/lyra"
```

## File Locations

| Component | File |
|---|---|
| Projection, StateProjection, AuditProjection | `lib/lyra/projection.rb` |
| Event envelope, `operation_of` | `lib/lyra/event.rb` |
| Appending events | `lib/lyra/event_store_adapter.rb` |
| CRUD interception | `lib/lyra/interceptors/crud_interceptor.rb` |
| Callback-bypassing writes | `lib/lyra/bypass_events.rb`, `lib/lyra/strict_data_access.rb` |
| Commands and aggregates | `lib/lyra/command.rb`, `lib/lyra/command_handler.rb`, `lib/lyra/aggregate.rb` |
| Association interception (ES-NoProj) | `lib/lyra/interceptors/association_interceptor.rb` |
| Read hooks (ES-Lazy) | `lib/lyra/interceptors/lazy_reads.rb` |
| Table projection (ES-Sync) | `lib/lyra/projections/model_projection.rb` |
| Async projection job (ES-Async) | `lib/lyra/projections/async_projection_job.rb` |
| EventStoreReader, CachedProjection, CachedRelation (ES-NoProj) | `lib/lyra/projections/event_store_reader.rb`, `cached_projection.rb`, `cached_relation.rb`, `cached_joins.rb` |
| LazyProjection (ES-Lazy) | `lib/lyra/projections/lazy_projection.rb` |
| Rebuild | `lib/lyra/projections/rebuild.rb` |
| Point-in-time state | `lib/lyra/temporal.rb` |
| Event flow analysis | `lib/lyra/event_flow.rb` |
| DualView | `lib/lyra/dual_view.rb` |
| Privacy stamps | `lib/lyra/privacy/interface.rb` |
| Erasure | `lib/lyra/erasure.rb` |
| Configuration | `lib/lyra/configuration.rb` |

Privacy components are listed in
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md#file-locations).

## Future Directions

1. **Snapshots and replay performance**: replaying long streams is slow;
   periodic aggregate snapshots and incremental materialization
2. **Event versioning and schema evolution**: event schemas change over time;
   automated upcasting and version migration tools
3. **Sagas**: distributed transaction support
4. **Automated aggregate discovery**: aggregate design requires domain
   expertise; clustering of events to identify aggregate boundaries
5. **Real-time verification**: verification runs on demand or at boot;
   streaming Petri net analysis and live invariant monitoring
6. **Multi-system event correlation**: events span multiple services;
   distributed event sourcing with cross-boundary lineage
7. **Crypto-shredding**: erasure currently rewrites events in place; per-subject
   keys whose deletion makes the data unreadable while the log stays untouched

## Research Context

### Research Contributions

1. **Gradual event sourcing migration**
   - Seven configurations, from Disabled through Monitor and Hijack to four
     event-sourcing projection modes
   - Interception of ActiveRecord writes without changes to models or
     controllers
   - Automatic event generation from CRUD
   - State consistency checks (DualView) and checked mode switches
2. **Privacy-aware event sourcing**
   - Declarative privacy policy DSL (PAM)
   - PII detection and privacy stamps on events
   - Purpose-bound reads and an access log
   - Data lineage from events
   - Erasure of personal data from rows and events
3. **Formal verification of event flows**
   - Colored Petri net formalization of event flows
   - Matrix-based causation and lineage analysis
   - Automated property verification of the CRUD-to-event mapping, including
     writes that bypass callbacks
   - Simulation and visualization tools

### Academic Context

- **Institution**: University of the Aegean
- **Department**: Information and Communication Systems Engineering
- **Candidate**: Michail Pantelelis (mpantel@aegean.gr)
- **Supervisor**: Prof. Christos Kalloniatis
- **Thesis title**: "Objects or Events? A Methodology to Enable Different
  Views on the Same Software System"

Research questions, from the thesis:

1. **RQ1**: Can we model software systems using object-oriented tools but
   result in systems where events play the leading role?
2. **RQ2**: Can we automate the transformation from ORM to Event Sourcing?
3. **RQ3**: Can formal methods verify the correctness of such
   transformations?
4. **RQ4**: Can privacy regulations (GDPR) be enforced at the architectural
   level during migration?

Publications:

1. Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". *PCI 2022*. DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)
2. Pantelelis, M., & Kalloniatis, C. (2024). "Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR". *ARES 2024*. DOI: [10.1145/3664476.3669932](https://doi.org/10.1145/3664476.3669932)

The sources of the other papers, the thesis and the proposal are in the
monorepo's `papers/` directory.

### Citation

```bibtex
@software{orfeas2026,
  title={ORFEAS: Object-Relational to Event-Sourcing Architecture Framework},
  author={Pantelelis, Michail},
  year={2026},
  url={https://github.com/mpantel/lyra-engine},
  note={Includes Lyra, PAM DSL, and PetriFlow gems}
}
```

### License, Contributing and Contact

MIT License; see the LICENSE file. All gems in the ORFEAS framework are open
source.

This is academic research software. Contributions are welcome as issue
reports (bugs, feature requests), pull requests (code and documentation),
research collaboration, and case studies from real applications.

Contact: Michail Pantelelis, mpantel@aegean.gr, University of the Aegean.
GitHub: https://github.com/mpantel/lyra-engine

### Acknowledgments

- **Prof. Christos Kalloniatis**: PhD supervision and research guidance
- **University of the Aegean**: research support and resources
- **Open source community**: the tools and libraries this work builds on
- **Research community**: feedback on the approach
