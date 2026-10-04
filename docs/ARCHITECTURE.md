# Lyra Architecture

## Overview

Lyra is built as a Rails Engine with a modular architecture that enables both non-intrusive monitoring and transformative hijacking of CRUD operations.

## Technology Stack

- **Ruby**: 3.4.5+ (tested up to 4.0)
- **Rails**: 8.0+
- **Rails Event Store**: Event persistence and stream management
- **PostgreSQL**: Primary database backend
- **SQLite**: Alternative for small deployments and testing
- **ERB**: View layer for dashboard
- **ActiveRecord**: ORM integration and callbacks

## Core Architecture

### Layer 1: Interception Layer

**CrudInterceptor** (`lib/lyra/interceptors/crud_interceptor.rb`)
- Injected into `ActiveRecord::Base` through the Rails Engine
- Uses ActiveRecord callbacks (`after_create`, `after_update`, `after_destroy`)
- Monitors all CRUD operations on registered models
- Routes operations based on operational mode

**Event Capture Coverage:**

Because Lyra uses ActiveRecord callbacks, events are captured from ALL sources:
- Web requests, Rails console, background jobs, rake tasks, seeds, runner scripts

Operations that **bypass callbacks** and are NOT captured:
- `update_columns` / `update_column` → Use `update!` instead
- `update_all` / `delete_all` → Iterate with `find_each`
- `insert_all` / `upsert_all` → Use `create!`
- Raw SQL (`connection.execute`) → Use ActiveRecord methods
- `delete` → Use `destroy` instead

**Strict Data Access Mode** (`config.strict_data_access = true`):
When enabled, Lyra overrides callback-bypassing methods on monitored models to raise `Lyra::StrictDataAccessViolation`, preventing inconsistencies between CRUD state and event store.

Intercepted operations:
- Instance: `update_columns`, `update_column`, `delete`
- Relation: `update_all`, `delete_all`
- Class: `insert_all`, `insert_all!`, `upsert_all`

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

| # | Configuration | Config | Description |
|---|------|--------|-------------|
| 1 | **Disabled** | `mode: :disabled` | Lyra completely disabled (baseline) |
| 2 | **Monitor** | `mode: :monitor` | Records an event for every write; the table stays authoritative |
| 3 | **Hijack** | `mode: :hijack` | Full CRUD interception, events as source of truth |
| 4 | **ES-Sync** | `mode: :event_sourcing, projection_mode: :sync` | Event sourcing with synchronous projections |
| 5 | **ES-Async** | `mode: :event_sourcing, projection_mode: :async` | Event sourcing with background projections |
| 6 | **ES-NoProj** | `mode: :event_sourcing, projection_mode: :disabled` | No projections; reads rebuild records from events and are evaluated in Ruby |
| 7 | **ES-Lazy** | `mode: :event_sourcing, projection_mode: :lazy` | Writes store events only; before a read the tables are brought up to date from the log, and the read runs as real SQL |

Benchmarks add **Hijack+PT** (Hijack with the application's PaperTrail left
on) to isolate PaperTrail's share of the cost; it is a measurement
configuration, not a mode.

**Mode Details:**

1. **Disabled Mode** (`config.mode = :disabled`)
   - Lyra completely bypassed
   - Standard ActiveRecord behavior
   - Use for baseline benchmarks

2. **Monitor Mode** (`config.mode = :monitor`)
   - Non-intrusive observation
   - CRUD operations complete normally
   - The event is appended inside the row write's transaction (in a
     savepoint), not asynchronously
   - A failed append is logged and the write stands; `lyra:repair` recovers
     the missing events

3. **Hijack Mode** (`config.mode = :hijack`)
   - Intercepts CRUD before execution
   - Routes through Command/Aggregate pattern
   - Event sourcing becomes source of truth
   - CRUD database kept for compatibility

4. **Event Sourcing Mode** (`config.mode = :event_sourcing`)
   - Full event sourcing with configurable projection modes:
     - `:sync` - Projections updated synchronously in same transaction
     - `:async` - Projections updated via background jobs
     - `:disabled` (ES-NoProj) - No projections; reads rebuild records from
       the event store and evaluate the query in Ruby (see Layer 5)
     - `:lazy` (ES-Lazy) - Projection on read; the tables are a disposable
       cache of the log (see Layer 5)

### Layer 2: Event Layer

**Event** (`lib/lyra/event.rb`)
- Base class extending `RailsEventStore::Event`
- Standard event structure with data and metadata
- Dynamic event class creation
- Event registry for tracking

**EventMapper** (`lib/lyra/event_mapper.rb`)
- Maps CRUD operations to domain events
- Pluggable mapper system
- Default mapper for standard behavior
- Custom mappers for domain-specific logic
- Namespaced model support (`Billing::Invoice` → `BillingInvoiceCreated`)

**Event Structure:**
```ruby
{
  data: {
    model_class: String,    # ActiveRecord model class name
    model_id: Integer,      # Record ID
    operation: Symbol,      # :created, :updated, :destroyed
    attributes: Hash,       # Record attributes
    changes: Hash,          # Before/after changes
    timestamp: Time         # When event occurred
  },
  metadata: {
    user_id: Integer,       # Current user (if available)
    request_id: String,     # Request tracking
    source: String          # Event source identifier
  }
}
```

### Layer 3: Command/Aggregate Layer

**Command** (`lib/lyra/command.rb`)
- Represents intent to change state
- Three command types: `CreateCommand`, `UpdateCommand`, `DestroyCommand`
- Immutable value objects
- Contains all data needed for state transition

**CommandHandler** (`lib/lyra/command_handler.rb`)
- Processes commands in hijack mode
- Loads aggregates
- Applies business logic
- Publishes events
- Returns result object

**Aggregate** (`lib/lyra/aggregate.rb`)
- Domain entity with behavior
- Loads state from event stream
- Applies events to rebuild state
- Validates business rules
- Emits new events

**GenericAggregate**
- Default aggregate for monitored models
- Handles standard CRUD event patterns
- Rebuilds state from events
- Used when no custom aggregate specified

### Layer 4: Storage Layer

**EventStoreAdapter** (`lib/lyra/event_store_adapter.rb`)
- Abstraction over event storage
- Primary: Rails Event Store with PostgreSQL
- Alternative: SQLite for small deployments
- Pluggable: Custom adapters supported

**RailsEventStoreAdapter**
- Uses `RailsEventStore::Client`
- Stores events in `event_store_events` table
- Maintains stream positions in `event_store_events_in_streams`
- YAML serialization (configurable)

**Stream Organization:**
- One stream per aggregate: `"ModelClass-{id}"`
- Events appended in order
- Stream name format: `"#{model_class}-#{id}"`

### Layer 5: Query Layer

**Projection** (`lib/lyra/projection.rb`)
- Rebuilds read models from events
- Subscribe to specific event types
- Maintain denormalized views
- Supports real-time updates

**StateProjection**
- Rebuilds current state from event stream
- Used for dual-view comparison
- Applies events in chronological order
- Returns hash of current attributes

**AuditProjection**
- Creates audit trail from events
- Chronological list of all changes
- Includes user, timestamp, changes
- Used for compliance and debugging

**Point-in-time state** (`lib/lyra/temporal.rb`)
- `Lyra.state_at(Model, id, time)` replays a record's stream up to `time`
- `Model.as_of(time)` builds read-only records as they were then

**Reads without projected tables: ES-NoProj**
(`lib/lyra/projections/cached_relation.rb`, `event_store_reader.rb`)
- `find`, `where`, `all` and associations are answered from records rebuilt
  from their event streams, as a `CachedRelation`
- Evaluates conditions, ordering, `or`, joins through associations, grouped
  aggregates and common search fragments in Ruby; association scopes,
  `:through` associations and calculations on associations included
- Anything else raises `Lyra::Projections::UnsupportedQuery` rather than
  return wrong records
- Every query scans the rebuilt records, so reads slow down as the log grows;
  an audit and replay mode rather than a way to serve application reads

**Projection on read: ES-Lazy** (`lib/lyra/projections/lazy_projection.rb`,
`lib/lyra/interceptors/lazy_reads.rb`)
- Writes append events only, as in ES-NoProj
- Before any read of a monitored model, `LazyProjection.catch_up!` applies
  the events the tables have not seen, one by one in the log's global order,
  then the read runs as real SQL: joins, merged relations, fragments and
  aggregates all work
- A checkpoint (`lyra_projection_checkpoints`, created on first use, no
  migration) records the last event applied and the ids missing below it.
  Catch-up runs under a PostgreSQL advisory lock and in the reader's
  transaction, so concurrent readers never apply an event twice and a
  rolled-back write leaves nothing behind
- Event ids are assigned before commit, so a slow transaction can commit an
  earlier id late: missing ids are watched as gaps and re-checked at most every
  `GAP_RECHECK` (1 s); a late event replays its record in full. A gap still
  empty after `GAP_TTL` (300 s) is taken as a rollback, which bounds the mode:
  a single transaction open longer than that would have its events skipped
- Once caught up, a read costs two small queries to see whether the log has
  moved on. The tables can be dropped and rebuilt from the log at any time

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

Lyra integrates with **PAM DSL** (Privacy Attribute Matrix DSL) for comprehensive privacy management. PAM DSL is an optional dependency - privacy features gracefully degrade without it.

**Privacy Delegation:**
- `Lyra::Privacy::PIIDetector` → delegates to `PamDsl::PIIDetector`
- `Lyra::Privacy::PIIMasker` → delegates to `PamDsl::PIIMasker`
- `Lyra::Privacy::GDPRCompliance` → delegates to `PamDsl::GDPRCompliance`

**PolicyIntegration** (`lib/lyra/privacy/policy_integration.rb`)
- Bridges Lyra events with PAM DSL policies
- Field-level PII classification with sensitivity levels
- Purpose-based access control aligned with GDPR
- Retention policies with field-level granularity
- Fallback to pattern-based detection when no policy defined

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

## Data Flow

### Monitor Mode Flow

```
ActiveRecord CRUD Operation
    │
    ├─→ Database (PostgreSQL/SQLite)
    │   └─→ Record saved/updated/deleted
    │
    └─→ after_* callback
        └─→ CrudInterceptor
            └─→ build_event_data
                └─→ EventMapper
                    └─→ Event created
                        └─→ EventStore.publish
                            └─→ event_store_events table
                                └─→ Projections updated (if subscribed)
```

### Hijack Mode Flow

```
ActiveRecord CRUD Operation
    │
    └─→ before_* callback
        └─→ CrudInterceptor (hijack mode)
            └─→ Command created
                └─→ CommandHandler
                    ├─→ Load Aggregate from event stream
                    ├─→ Apply business logic
                    ├─→ Create new event
                    ├─→ Apply event to aggregate
                    ├─→ Store event
                    └─→ Return result
                        └─→ Update ActiveRecord model
                            └─→ Database (PostgreSQL/SQLite)
```

### Dual View Comparison Flow

```
DualView.compare(ModelClass, id)
    │
    ├─→ crud_state
    │   └─→ ModelClass.find(id)
    │       └─→ Database query
    │
    ├─→ event_sourced_state
    │   └─→ EventStore.read.stream("ModelClass-#{id}")
    │       └─→ StateProjection.rebuild_from_events
    │
    └─→ calculate_differences
        └─→ Compare attributes
            └─→ Return discrepancies
```

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
- Custom command handlers
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

### Application Tables (Example: Aegean E-Pay Testbed)

See `examples/aegean_epay_testbed/db/migrate/*` for complete schema.

## Extensibility Points

### 1. Custom Event Mappers

```ruby
class CustomMapper < Lyra::EventMapper
  def event_data
    super.merge(custom_field: calculate_custom_data)
  end
end

Lyra::EventMapper.register_mapper(MyModel, CustomMapper)
```

### 2. Custom Aggregates

```ruby
class MyAggregate < Lyra::Aggregate
  def my_business_logic
    # Custom logic
  end

  private

  def apply_my_event(event)
    # Custom event handling
  end
end

MyModel.monitor_with_lyra(aggregate_class: MyAggregate)
```

### 3. Custom Projections

```ruby
class MyProjection < Lyra::Projection
  def self.handle(event)
    # Update read model
  end
end

MyProjection.subscribe_to(MyEvent)
```

### 4. Custom Event Store

```ruby
class MyEventStore < Lyra::CustomEventStoreAdapter
  def publish(event, stream_name:)
    # Custom implementation
  end
end

Lyra.configure do |config|
  config.event_backend = :custom
  config.event_store = MyEventStore.new
end
```

## Performance Considerations

### Monitor Mode
- **Overhead**: ~1-5ms per operation (event creation + publishing)
- **Optimization**: Use async event publishing
- **Failure Handling**: Event failures don't affect CRUD

### Hijack Mode
- **Overhead**: ~10-50ms per operation (full event sourcing)
- **Optimization**:
  - Use snapshots for large event streams
  - Cache aggregates in memory
  - Use read models for queries
- **Consistency**: Transactions ensure atomicity

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
   - Immutable event log
   - Cannot delete events
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

### As Rails Engine
```ruby
# Gemfile
gem 'orfeas_lyra', path: 'path/to/lyra'

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

## Future Enhancements

1. **Snapshots**: Periodic aggregate snapshots for performance
2. **Event Versioning**: Support for event schema evolution
3. **Sagas**: Distributed transaction support
