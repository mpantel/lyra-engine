# Lyra API Reference

Complete API documentation for the Lyra framework.

## Table of Contents

1. [Configuration](#configuration)
2. [Model Integration](#model-integration)
3. [Events](#events)
4. [Commands](#commands)
5. [Aggregates](#aggregates)
6. [Projections](#projections)
7. [Dual View](#dual-view)
8. [Event Flow Analysis](#event-flow-analysis)
9. [Privacy & PII](#privacy--pii)
10. [PAM DSL](#pam-dsl)

---

## Configuration

### Lyra.configure

Configure Lyra globally.

```ruby
Lyra.configure do |config|
  config.mode = :monitor            # :disabled, :monitor, :hijack, :event_sourcing
  config.event_store = event_store  # Event store instance
  config.privacy_enabled = true     # Enable PII detection
  config.retention_policy = 7.years # Default retention
  config.logger = Rails.logger      # Logger instance

  # Event sourcing specific
  config.projection_mode = :sync    # :sync, :async, :disabled
  config.strict_schema = true       # Fail on schema changes (production)
  config.schema_path = 'db/lyra_schemas'
end
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `mode` | Symbol | `:monitor` | Operational mode (`:disabled`, `:monitor`, `:hijack`, `:event_sourcing`) |
| `projection_mode` | Symbol | `:sync` | Projection mode (`:sync`, `:async`, `:disabled`) - only for event_sourcing mode |
| `event_store` | Object | `nil` | RailsEventStore client instance |
| `metadata_proc` | Proc | `nil` | Custom metadata proc for events: `->(record, operation) { Hash }` |
| `privacy_enabled` | Boolean | `false` | Enable PII detection and masking |
| `retention_policy` | ActiveSupport::Duration | `nil` | Default event retention period |
| `logger` | Logger | `Rails.logger` | Logger for Lyra operations |
| `async_event_handlers` | Boolean | `false` | Process events asynchronously |
| `cache_aggregates` | Boolean | `false` | Cache aggregate instances |
| `snapshot_frequency` | Integer | `nil` | Snapshot aggregates every N events |
| `strict_schema` | Boolean | `false` | Fail startup if schema changes detected |
| `schema_path` | String | `db/lyra_schemas` | Path for schema version files |

### Lyra.config

Access current configuration:

```ruby
Lyra.config.mode  # => :monitor
Lyra.config.monitor_mode?       # => true
Lyra.config.hijack_mode?        # => false
Lyra.config.event_sourcing_mode? # => false
Lyra.config.disabled_mode?      # => false
Lyra.config.projection_mode     # => :sync
```

### Mode Switching

```ruby
# Enable monitor mode
Lyra.config.enable_monitor!

# Enable hijack mode
Lyra.config.enable_hijack!

# Check mode
Lyra.config.monitor_mode?  # => true/false
Lyra.config.hijack_mode?   # => true/false
```

---

## Model Integration

### monitor_with_lyra

Enable Lyra monitoring on an ActiveRecord model.

```ruby
class User < ApplicationRecord
  monitor_with_lyra(
    event_prefix: "User",
    aggregate_class: UserAggregate,
    privacy_policy: :user_data,
    track_changes: true
  )
end
```

#### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `event_prefix` | String | Model name | Prefix for event types |
| `aggregate_class` | Class | `Lyra::Aggregate` | Custom aggregate class |
| `privacy_policy` | Symbol | `nil` | PAM policy name |
| `track_changes` | Boolean | `true` | Include attribute changes in events |
| `metadata_proc` | Proc | `nil` | Custom metadata generation |

#### Example with Custom Metadata

```ruby
class Order < ApplicationRecord
  monitor_with_lyra(
    event_prefix: "Order",
    metadata_proc: ->(record, operation) {
      {
        user_id: Current.user&.id,
        request_id: Current.request_id,
        ip_address: Current.ip,
        custom: "value"
      }
    }
  )
end
```

#### Namespaced Model Support

Lyra fully supports Rails engine namespaced models. When monitoring a namespaced model, the namespace is preserved in event metadata while the event class name is sanitized for Ruby constant naming.

```ruby
# In a Rails engine
module Billing
  class Invoice < ApplicationRecord
    monitor_with_lyra event_prefix: "Billing::Invoice"
  end
end

# Or with deeply nested namespaces
module MyEngine
  module Admin
    class Widget < ApplicationRecord
      monitor_with_lyra event_prefix: "MyEngine::Admin::Widget"
    end
  end
end
```

**Event Class Naming:**

| Model Class | Event Type | Event Class |
|-------------|------------|-------------|
| `Order` | `OrderCreated` | `Lyra::Events::OrderCreated` |
| `Billing::Invoice` | `Billing::InvoiceCreated` | `Lyra::Events::BillingInvoiceCreated` |
| `MyEngine::Admin::Widget` | `MyEngine::Admin::WidgetCreated` | `Lyra::Events::MyEngineAdminWidgetCreated` |

The original namespace is preserved in the event's `model_class` attribute for accurate type resolution:

```ruby
event = Lyra::Events::BillingInvoiceCreated.new(data: { ... })
event.model_class  # => "Billing::Invoice" (original namespace preserved)
event.class.name   # => "Lyra::Events::BillingInvoiceCreated" (sanitized for Ruby)
```

---

## Events

### Lyra::Event

Base event class representing a domain event.

#### Attributes

```ruby
event = Lyra::Event.new(data: event_data)

event.model_class    # => "User"
event.model_id       # => 123
event.operation      # => :created
event.attributes     # => { name: "Alice", email: "..." }
event.changes        # => { name: ["Old", "New"] }
event.timestamp      # => Time object
event.metadata       # => { user_id: ..., correlation_id: ... }
```

#### Methods

```ruby
# Check operation type
event.created?    # => true/false
event.updated?    # => true/false
event.destroyed?  # => true/false

# Access data
event.data            # => Full event data hash
event.event_type      # => "UserCreated"
event.stream_name     # => "User-123"
```

### Lyra::EventMapper

Maps CRUD operations to domain events.

```ruby
# Map a create operation
event = Lyra::EventMapper.map_operation(
  User,
  :create,
  {
    attributes: { name: "Alice", email: "alice@example.com" },
    changes: {},
    user_id: current_user.id,
    metadata: { custom: "value" }
  }
)

# Map an update operation
event = Lyra::EventMapper.map_operation(
  User,
  :update,
  {
    attributes: user.attributes,
    changes: { name: ["Old Name", "New Name"] },
    user_id: current_user.id
  }
)

# Map a destroy operation
event = Lyra::EventMapper.map_operation(
  User,
  :destroy,
  {
    attributes: user.attributes,
    user_id: current_user.id
  }
)
```

#### Custom Event Mapper

```ruby
class OrderEventMapper < Lyra::EventMapper
  def event_data
    super.merge(
      business_context: {
        total: data[:attributes]['total'],
        status: data[:attributes]['status'],
        items_count: calculate_items_count
      }
    )
  end

  private

  def calculate_items_count
    # Custom logic
  end
end

# Register mapper
Lyra::EventMapper.register_mapper(Order, OrderEventMapper)
```

---

## Commands

### Lyra::Command

Base command class for CQRS pattern.

```ruby
class CreateUserCommand < Lyra::Command
  def execute
    # Validation
    validate_email_format

    # Business logic
    user_id = generate_user_id
    attributes = prepare_attributes

    # Publish events
    event = Lyra::EventMapper.map_operation(
      User,
      :create,
      { attributes: attributes, user_id: current_user.id }
    )

    publish_event(event)

    # Return result
    CommandResult.success(attributes: attributes, events: [event])
  end

  private

  def validate_email_format
    # ...
  end
end

# Usage
command = CreateUserCommand.new(User, { email: "...", name: "..." })
result = command.execute

if result.success?
  puts "User created: #{result.attributes}"
else
  puts "Error: #{result.error}"
end
```

### Lyra::CommandResult

Result object returned by commands.

```ruby
# Success result
result = Lyra::CommandResult.success(
  attributes: { id: 1, name: "Alice" },
  events: [event1, event2],
  aggregate: aggregate_instance
)

result.success?   # => true
result.failure?   # => false
result.attributes # => { id: 1, name: "Alice" }
result.events     # => [event1, event2]
result.aggregate  # => aggregate_instance

# Failure result
result = Lyra::CommandResult.failure(
  error: "Validation failed",
  details: { email: "is invalid" }
)

result.success?  # => false
result.failure?  # => true
result.error     # => "Validation failed"
result.details   # => { email: "is invalid" }
```

---

## Aggregates

### Lyra::Aggregate

Base aggregate class for domain logic and state management.

```ruby
class UserAggregate < Lyra::Aggregate
  # Public interface
  def email
    get_state(:email)
  end

  def full_name
    "#{get_state(:first_name)} #{get_state(:last_name)}"
  end

  def active?
    !get_state(:deleted)
  end

  # Business logic
  def can_post?
    active? && !suspended?
  end

  private

  # Event handlers (must be private)
  def apply_user_created(event)
    @id = event.model_id
    set_state(:email, event.attributes['email'])
    set_state(:first_name, event.attributes['first_name'])
    set_state(:last_name, event.attributes['last_name'])
    set_state(:created_at, event.timestamp)
  end

  def apply_user_updated(event)
    event.changes.each do |field, (old_val, new_val)|
      set_state(field.to_sym, new_val)
    end
    set_state(:updated_at, event.timestamp)
  end

  def apply_user_destroyed(event)
    set_state(:deleted, true)
    set_state(:deleted_at, event.timestamp)
  end

  def apply_user_suspended(event)
    set_state(:suspended, true)
    set_state(:suspended_at, event.timestamp)
    set_state(:suspension_reason, event.data[:reason])
  end
end
```

#### Loading Aggregates

```ruby
# Load from event stream
aggregate = UserAggregate.load(user_id)
aggregate.email       # => "alice@example.com"
aggregate.full_name   # => "Alice Smith"
aggregate.active?     # => true

# Check internal state
aggregate.version     # => Number of events applied
aggregate.changes     # => Array of applied events
```

#### State Management

```ruby
# In event handlers (private methods)
def apply_some_event(event)
  # Set state
  set_state(:field_name, value)

  # Get state
  current_value = get_state(:field_name)

  # Check if state exists
  if has_state?(:field_name)
    # ...
  end
end
```

#### Snapshotting

```ruby
class UserAggregate < Lyra::Aggregate
  snapshot_frequency 100  # Snapshot every 100 events

  def take_snapshot
    {
      version: version,
      state: @state.dup,
      taken_at: Time.current
    }
  end

  def load_snapshot(snapshot)
    @version = snapshot[:version]
    @state = snapshot[:state]
  end
end
```

---

## Projections

### Lyra::Projection

Base projection class for building read models.

```ruby
class UserStatsProjection < Lyra::Projection
  # Subscribe to events
  subscribe_to "UserCreated", "PostCreated", "CommentCreated"

  # Event handlers (can be private)
  def apply_user_created(event)
    UserStats.create!(
      user_id: event.model_id,
      posts_count: 0,
      comments_count: 0,
      created_at: event.timestamp
    )
  end

  def apply_post_created(event)
    stats = UserStats.find_by(user_id: event.data[:user_id])
    stats.increment!(:posts_count) if stats
  end

  def apply_comment_created(event)
    stats = UserStats.find_by(user_id: event.data[:user_id])
    stats.increment!(:comments_count) if stats
  end
end

# Projections are automatically called when events are published
```

### Lyra::StateProjection

Rebuild model state from events.

```ruby
# Rebuild state for a specific record
state = Lyra::StateProjection.rebuild_state(User, user_id)
# => { email: "...", name: "...", ... }

# Rebuild from event array
projection = Lyra::StateProjection.new
events = Rails.configuration.event_store.read.stream("User-#{user_id}").to_a
state = projection.rebuild_from_events(events)
```

### Lyra::AuditProjection

Generate audit trails.

```ruby
# Get complete audit trail
audit = Lyra::AuditProjection.audit_trail(User, user_id)
# => [
#   {
#     operation: :created,
#     timestamp: Time,
#     user_id: "...",
#     changes: {},
#     attributes: { ... }
#   },
#   ...
# ]

# Format audit trail
audit.each do |entry|
  puts "#{entry[:timestamp]}: #{entry[:operation]} by #{entry[:user_id]}"
  if entry[:changes].any?
    puts "  Changes: #{entry[:changes].keys.join(', ')}"
  end
end
```

### Lyra::Projections::CachedRelation

ActiveRecord::Relation-like wrapper for in-memory cached data. Used when `projection_mode: :disabled`.

```ruby
# Created automatically when querying in sixth mode
relation = User.where(status: "active")  # Returns CachedRelation

# Chainable query methods
relation.where(role: "admin")
        .order(name: :asc)
        .limit(10)
        .offset(5)

# Finders
relation.find(123)                  # Find by ID
relation.find_by(email: "a@b.com")  # Find by attributes
relation.first                      # First record (ordered by PK)
relation.last                       # Last record (ordered by PK desc)

# Aggregations
relation.count
relation.sum(:balance)
relation.average(:age)
relation.minimum(:score)
relation.maximum(:score)
relation.pluck(:id, :name)

# Pagination (Kaminari-compatible)
relation.page(2).per(25)

# AR compatibility (no-ops that return self)
relation.includes(:posts)
relation.joins(:comments)
relation.preload(:tags)
relation.distinct
```

#### Type Coercion

CachedRelation handles type mismatches automatically:

```ruby
# String IDs work with integer columns
User.where(id: "123")         # Matches id=123
User.where(id: ["1", "2"])    # Matches id IN (1, 2)

# String booleans work with boolean columns
User.where(active: "true")    # Matches active=true
User.where(active: "false")   # Matches active=false
```

### Lyra::Projections::EventStoreReader

Reads and caches entity state from event store.

```ruby
# Find by ID (cache-first, falls back to event replay)
user = Lyra::Projections::EventStoreReader.find(User, 123)

# Find by attributes
user = Lyra::Projections::EventStoreReader.find_by(User, email: "test@example.com")

# Check existence
exists = Lyra::Projections::EventStoreReader.exists?(User, 123)

# Get all records (cached)
users = Lyra::Projections::EventStoreReader.all(User)

# Get relation for chaining
relation = Lyra::Projections::EventStoreReader.relation(User)
relation.where(active: true).order(:name).to_a

# Cache management
Lyra::Projections::EventStoreReader.warm(User, 123)       # Pre-load cache
Lyra::Projections::EventStoreReader.invalidate(User, 123) # Clear cache
```

### Lyra::Interceptors::AssociationInterceptor

Patches AR associations to load from cache in sixth mode.

```ruby
# Automatically installed by Lyra engine
# Patches these association types:

# BelongsTo - order.customer loads from cache
order.customer  # => User from cache

# HasOne - user.profile loads from cache
user.profile    # => Profile from cache

# HasMany - returns CachedRelation
user.orders           # => CachedRelation
user.orders.count     # => Integer (no full load)
user.orders.empty?    # => Boolean

# Polymorphic associations supported
comment.commentable   # => Resolves type from cache
```

---

## Web Dashboard

Lyra provides a comprehensive web dashboard for visualizing events, auditing changes, and monitoring the event-sourced system.

### Mounting the Engine

Add to your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Lyra::Engine, at: '/lyra'
  # ... other routes
end
```

### Dashboard Routes

#### Core Dashboard

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra` | GET | Redirects to dashboard |
| `/lyra/dashboard` | GET | Main dashboard - shows monitored models and mode |
| `/lyra/dashboard/model/:model_class` | GET | Model overview with record/event counts |
| `/lyra/config/projections` | GET | Projection configuration and event stats per model |

#### Dual View & Comparison

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/dashboard/compare/:model_class/:id` | GET | Compare CRUD vs event-sourced state (JSON) |
| `/lyra/dashboard/discrepancies/:model_class` | GET | Find records with state differences (HTML/JSON) |

#### Audit Trail

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/dashboard/audit_trail` | GET | Audit trail browser with model/record picker |
| `/lyra/dashboard/audit_trail/:model_class/:id` | GET | Audit trail for specific record (HTML/JSON) |

#### Schema Management

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/dashboard/schema` | GET | Current schema with pending changes (HTML/JSON) |
| `/lyra/dashboard/schema/history` | GET | Schema version history |
| `/lyra/dashboard/schema/:version` | GET | View specific schema version |

#### Visualizations

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/visualizations/event_graph` | GET | Interactive event graph view (HTML) |
| `/lyra/visualizations/event_graph.json` | GET | Event graph data with filters |
| `/lyra/visualizations/entity_graph/:model_class/:id.json` | GET | Entity lifecycle graph |
| `/lyra/visualizations/event_list.json` | GET | List of entities with event counts |
| `/lyra/visualizations/heatmap` | GET | Activity heatmap view (HTML) |
| `/lyra/visualizations/heatmap.json` | GET | Heatmap data for time period |
| `/lyra/visualizations/model_heatmap/:model_class.json` | GET | Model-specific heatmap |

#### Event Flow

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/flow/timeline` | GET | Event timeline (JSON) |
| `/lyra/flow/event_chain/:model_class/:model_id` | GET | Event chain for entity |
| `/lyra/flow/crud_mapping` | GET | CRUD to event mapping |
| `/lyra/flow/visualization/:model_class/:model_id` | GET | Flow visualization |
| `/lyra/flow/correlation/:correlation_id` | GET | Events by correlation ID |
| `/lyra/flow/user_actions/:user_id` | GET | Events by user |

#### Privacy & GDPR

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/privacy/subject/:subject_type/:subject_id` | GET | Subject data overview |
| `/lyra/privacy/gdpr_report/:subject_type/:subject_id` | GET | GDPR compliance report |
| `/lyra/privacy/portable_export/:subject_type/:subject_id` | GET | Data portability export |
| `/lyra/privacy/pii_inventory/:subject_type/:subject_id` | GET | PII inventory |
| `/lyra/privacy/data_lineage/:field_name` | GET | Data lineage for field |
| `/lyra/privacy/pii_detection` | GET | PII detection overview |
| `/lyra/privacy/policy` | GET | Privacy policy configuration |

#### Formal Verification (requires PetriFlow)

| Route | Method | Description |
|-------|--------|-------------|
| `/lyra/verification` | GET | Verification dashboard (HTML) |
| `/lyra/verification.json` | GET | Verification results (JSON) |

### Query Parameters

Many routes accept query parameters for filtering:

```ruby
# Event graph with filters
GET /lyra/visualizations/event_graph.json?model_class=User&operation=created&limit=50

# Heatmap for specific period
GET /lyra/visualizations/heatmap.json?days=30

# Entity graph with depth
GET /lyra/visualizations/entity_graph/User/123.json?depth=2

# Event list filtered by model
GET /lyra/visualizations/event_list.json?model_class=Order&limit=20
```

### Dashboard Controller Methods

The dashboard is powered by `Lyra::DashboardController` which provides:

```ruby
# Available helper methods in views
user_display_name(user_id)  # Looks up user name from User model
```

---

## Dual View

### Lyra::DualView

Compare CRUD state with event-sourced state.

```ruby
dual_view = Lyra::DualView.new(User, user_id)
```

#### Methods

##### #compare

Compare both views:

```ruby
comparison = dual_view.compare

# Structure:
{
  crud_view: {
    exists: true,
    attributes: { ... },
    timestamps: { created_at: ..., updated_at: ... }
  },
  event_sourced_view: {
    exists: true,
    state: { ... },
    events_count: 10,
    first_event_at: Time,
    last_event_at: Time,
    events_summary: [...]
  },
  differences: { ... } or { no_differences: true },
  metadata: {
    model_class: "User",
    model_id: 123,
    timestamp: Time,
    mode: :monitor
  }
}
```

##### #crud_state

Get CRUD view:

```ruby
crud = dual_view.crud_state
# => {
#   exists: true,
#   attributes: { id: 123, email: "...", ... },
#   timestamps: { created_at: ..., updated_at: ... }
# }
```

##### #event_sourced_state

Get event-sourced view:

```ruby
es = dual_view.event_sourced_state
# => {
#   exists: true,
#   state: { email: "...", name: "...", ... },
#   events_count: 10,
#   first_event_at: Time,
#   last_event_at: Time,
#   events_summary: [...]
# }
```

##### #audit_trail

Get audit trail:

```ruby
audit = dual_view.audit_trail
# Delegates to Lyra::AuditProjection.audit_trail
```

#### Class Methods

##### .compare_all

Compare all records for a model:

```ruby
comparisons = Lyra::DualView.compare_all(User)
# => Array of comparison hashes
```

##### .find_discrepancies

Find records with differences:

```ruby
discrepancies = Lyra::DualView.find_discrepancies(User)
# => Array of comparisons where differences exist
```

---

## Event Flow Analysis

### Lyra::EventFlow

Analyze event streams for patterns and metrics.

```ruby
# Load events
events = Rails.configuration.event_store.read.stream("User-#{user_id}").to_a

# Create analyzer
event_flow = Lyra::EventFlow.new(events)

# Analyze
analysis = event_flow.analyze
```

#### Analysis Structure

```ruby
{
  timeline: {
    first_event: Time,
    last_event: Time,
    duration_seconds: Float,
    duration_minutes: Float,
    duration_hours: Float,
    duration_days: Float
  },
  operations: {
    created: 1,
    updated: 5,
    destroyed: 0
  },
  metrics: {
    total_events: 6,
    operations_per_day: 2.5,
    average_time_between_events: Float
  },
  privacy: {
    events_with_pii: 4,
    percentage: 66.67,
    pii_fields: {
      email: { type: :email, sensitivity: :confidential },
      name: { type: :name, sensitivity: :internal }
    }
  }
}
```

---

## Privacy & PII

### Lyra::Privacy::PIIDetector

Detect personally identifiable information. Lyra delegates to `PamDsl::PIIDetector` for the core detection logic, providing a unified implementation across both Lyra and PAM DSL.

```ruby
# Detect PII in attributes
attributes = { email: "alice@example.com", name: "Alice", age: 30 }
pii_fields = Lyra::Privacy::PIIDetector.detect(attributes)

# => {
#   email: { type: :email, value: "alice@example.com", sensitive: false, sensitivity: :confidential },
#   name: { type: :name, value: "Alice", sensitive: false, sensitivity: :internal }
# }

# Check specific field
Lyra::Privacy::PIIDetector.contains_pii?(:email)  # => true
Lyra::Privacy::PIIDetector.contains_pii?(:customer_email)  # => true (partial matching)

# Mask PII for display
Lyra::Privacy::PIIDetector.mask("alice@example.com", :email)  # => "a***@example.com"
```

#### Configuration

PII detection supports two matching modes via `PamDsl::PIIDetector`:

```ruby
# Partial matching (default) - detects prefixed/suffixed field names
PamDsl::PIIDetector.partial_match = true
PamDsl::PIIDetector.contains_pii?(:customer_email)  # => true

# Exact matching - only specific known field names
PamDsl::PIIDetector.partial_match = false
PamDsl::PIIDetector.contains_pii?(:customer_email)  # => false
PamDsl::PIIDetector.contains_pii?(:email)           # => true

# Reset to default
PamDsl::PIIDetector.reset!
```

#### Detected PII Types

| Type | Examples | Sensitivity | GDPR Category |
|------|----------|-------------|---------------|
| `:email` | `email`, `user_email`, `contact_email` | `:confidential` | Regular (Art. 6) |
| `:name` | `name`, `first_name`, `last_name` | `:internal` | Regular (Art. 6) |
| `:phone` | `phone`, `telephone`, `mobile` | `:confidential` | Regular (Art. 6) |
| `:address` | `address`, `street`, `city`, `postal_code` | `:confidential` | Regular (Art. 6) |
| `:ssn` | `ssn`, `social_security`, `national_id` | `:restricted` | National ID (Art. 87) |
| `:credit_card` | `credit_card`, `card_number`, `cvv` | `:restricted` | Financial (PCI DSS) |
| `:financial` | `iban`, `bank_account`, `salary` | `:restricted` | Financial |
| `:identifier` | `vat_number`, `tax_id`, `passport`, `afm` | `:restricted` | National ID |
| `:ip_address` | `ip_address`, `remote_ip`, `client_ip` | `:internal` | Regular (Art. 6) |
| `:date_of_birth` | `date_of_birth`, `birthday`, `dob` | `:confidential` | Regular (Art. 6) |
| `:health` | `medical`, `health`, `diagnosis` | `:restricted` | Special (Art. 9) |
| `:biometric` | `fingerprint`, `face_id`, `biometric` | `:restricted` | Special (Art. 9) |
| `:location` | `latitude`, `longitude`, `gps` | `:confidential` | Regular (Art. 6) |

See [PAM DSL README](../gems/pam_dsl/README.md#sensitivity-levels-and-legislative-background) for detailed regulatory mapping.

### Lyra::Privacy::PIIMasker

Mask PII for safe display.

```ruby
attributes = {
  email: "alice@example.com",
  name: "Alice Smith",
  phone: "555-1234",
  age: 30
}

masked = Lyra::Privacy::PIIMasker.mask(attributes)
# => {
#   email: "a***@example.com",
#   name: "A***",
#   phone: "***-1234",
#   age: 30  # Non-PII unchanged
# }

# Custom masking strategy
masked = Lyra::Privacy::PIIMasker.mask(attributes, strategy: :full)
# => {
#   email: "[REDACTED]",
#   name: "[REDACTED]",
#   phone: "[REDACTED]",
#   age: 30
# }
```

---

## PAM DSL

### PamDsl.define_policy

Define privacy policies.

```ruby
PamDsl.define_policy :my_policy do
  # Field definitions
  field :email, type: :email, sensitivity: :confidential do
    allow_for :authentication, :communication
    transform :display { |v| "#{v[0..2]}***@#{v.split('@').last}" }
    transform :logging { |v| "[REDACTED]" }
  end

  field :credit_card, type: :credit_card, sensitivity: :restricted do
    allow_for :payment_processing
    transform :display { |v| "****-****-****-#{v[-4..]}" }
  end

  # Purpose definitions
  purpose :authentication do
    legal_basis :contract
    required_fields [:email, :password]
    retention 7.years
  end

  purpose :marketing do
    legal_basis :consent
    required_fields [:email]
    consent_required true
    retention 2.years
  end

  # Retention policies
  retention do
    default 7.years

    for_model 'User' do
      keep_for 7.years
      field :email, duration: 2.years
      on_expiry :anonymize
    end

    for_model 'Order' do
      keep_for 10.years
      on_expiry :archive
    end
  end

  # Consent management
  consent do
    expiry 2.years
    renewal_reminder 60.days
    withdrawal_allowed true
  end
end
```

### Policy Methods

```ruby
# Access policies
policy = PamDsl.policies[:my_policy]

# Get field definitions
field_def = policy.field_definitions[:email]
field_def[:type]        # => :email
field_def[:sensitivity] # => :confidential
field_def[:allowed_for] # => [:authentication, :communication]

# Get transformations
transform = policy.transformations[:email][:display]
masked = transform.call("alice@example.com")  # => "ali***@example.com"

# Get purposes
purpose = policy.purposes[:authentication]
purpose[:legal_basis]      # => :contract
purpose[:required_fields]  # => [:email, :password]

# Get retention for model
model_policy = policy.find_model_policy("User")
model_policy[:retention][:default]              # => 7.years
model_policy[:retention][:fields][:email]       # => 2.years
```

---

## Correlation & Causation

### Lyra::Correlation

Track related events.

```ruby
# Generate correlation ID for a workflow
Lyra::Correlation.with_id do |correlation_id|
  # All events within this block share the correlation ID
  user = User.create!(email: "...")
  post = user.posts.create!(title: "...")
  comment = post.comments.create!(body: "...")

  # correlation_id is added to event metadata automatically
end

# Access current correlation ID
id = Lyra::Correlation.current_id

# Set specific correlation ID
Lyra::Correlation.set_id("custom-correlation-id")

# Clear correlation ID
Lyra::Correlation.clear!
```

### Lyra::Causation

Track causal relationships.

```ruby
# Set causation ID (usually the triggering event ID)
Lyra::Causation.set_id(triggering_event.event_id)

# Events generated will include this causation ID
user.update!(name: "New Name")

# Clear causation
Lyra::Causation.clear!
```

---

## Testing Helpers

### RSpec

```ruby
# spec/support/lyra_helpers.rb
RSpec.configure do |config|
  config.include LyraHelpers

  config.before(:each) do
    Lyra.config.mode = :monitor
    clear_event_store
  end
end

module LyraHelpers
  def clear_event_store
    Rails.configuration.event_store.read.each do |event|
      # Clear events
    end
  end

  def expect_event(event_type)
    events = Rails.configuration.event_store.read.of_type(event_type).to_a
    expect(events).not_to be_empty
  end

  def last_event_of_type(event_type)
    Rails.configuration.event_store.read.of_type(event_type).last
  end
end

# Usage
it "publishes UserCreated event" do
  user = User.create!(email: "test@example.com")

  expect_event("UserCreated")

  event = last_event_of_type("UserCreated")
  expect(event.data[:attributes]['email']).to eq("test@example.com")
end
```

### Minitest

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  setup do
    Lyra.config.mode = :monitor
    clear_event_store
  end

  def clear_event_store
    # Clear events
  end

  def assert_event_published(event_type)
    events = Rails.configuration.event_store.read.of_type(event_type).to_a
    assert events.any?, "Expected #{event_type} event to be published"
  end

  def refute_event_published(event_type)
    events = Rails.configuration.event_store.read.of_type(event_type).to_a
    assert events.empty?, "Expected no #{event_type} events"
  end
end

# Usage
test "publishes UserCreated event" do
  user = User.create!(email: "test@example.com")

  assert_event_published("UserCreated")
end
```

---

## Next Steps

- [Usage Guide](../README.md#usage-guide)
- [Migration Guide](MIGRATION_GUIDE.md)
- [Example Application](../examples/blog_app/README.md)
- [Troubleshooting](TROUBLESHOOTING.md)
