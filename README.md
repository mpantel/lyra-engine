# Lyra

**CRUD to Event Sourcing Transformation Engine**

*Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) Framework*

## Author

**Michail Pantelelis** (mpantel@aegean.gr)
PhD Candidate, University of the Aegean
Department of Information and Communication Systems Engineering

---

## Table of Contents

1. [Overview](#overview)
2. [The Problem](#the-problem)
3. [The Solution: ORFEAS Framework](#the-solution-orfeas-framework)
4. [Key Features](#key-features)
5. [Architecture](#architecture)
6. [Components](#components)
7. [Installation](#installation)
8. [Quick Start](#quick-start)
9. [Usage Guide](#usage-guide)
10. [Example Application](#example-application)
11. [Benefits](#benefits)
12. [Documentation](#documentation)
13. [Research Foundation](#research-foundation)
14. [Development Methodology](#development-methodology)
15. [Contributing](#contributing)
16. [Citation](#citation)
17. [Support](#support)

---

## Overview

Lyra is a Rails engine that enables **gradual, non-intrusive transformation** of traditional CRUD (Create, Read, Update, Delete) operations into Event Sourcing architectures, with built-in privacy compliance capabilities. It is the practical implementation of the **ORFEAS (Object-Relational to Event-Sourcing Architecture)** framework, developed as part of a PhD thesis addressing the fundamental challenge of bridging 40+ years of ORM dominance with modern event-driven, GDPR-compliant application architectures.

### What Makes Lyra Unique?

- **Dual-Mode Operation**: Monitor existing applications non-intrusively, then gradually transform to full event sourcing
- **Formal Mathematical Foundation**: Built on Petri nets (P/T nets for verification, CPNs for advanced modeling) and matrix analysis for rigorous CRUD-to-event mapping
- **Privacy-First Design**: Integrated Privacy Attribute Matrix (PAM) for GDPR compliance
- **Zero-Downtime Migration**: Maintain CRUD as a safety net while transitioning to event sourcing
- **Research-Backed**: Grounded in peer-reviewed research on event sourcing patterns and privacy preservation

---

## The Problem

Modern enterprise systems face a critical architectural challenge:

### The Legacy Dilemma
- **40+ Years of ORM Investment**: Decades of business logic encoded in Object-Relational Mapping systems
- **CRUD Limitations**: State-based systems lose behavioral history and temporal context
- **Privacy Requirements**: GDPR mandates comprehensive data lineage and processing transparency
- **Migration Risk**: Complete rewrites from CRUD to Event Sourcing are expensive and risky

### The Event Sourcing Promise
- **Complete Audit Trails**: Every state change recorded as an immutable event
- **Temporal Queries**: Query system state at any point in time
- **Behavioral Analysis**: Understand *how* and *why* state changes occurred
- **Microservices Alignment**: Natural fit for distributed, event-driven architectures

### The Gap
**There is no formal, proven method for gradually migrating CRUD systems to event sourcing while maintaining operational safety and privacy compliance.**

---

## The Solution: ORFEAS Framework

The **ORFEAS (Object-Relational to Event-Sourcing Architecture)** framework provides:

1. **Formal Mathematical Models**: Petri nets map CRUD operations to event sequences with formal verification (P/T nets for structural proofs, CPNs optional for data modeling)
2. **Privacy Compliance**: Privacy Attribute Matrix (PAM) ensures GDPR compliance throughout the transformation
3. **Gradual Migration Path**: Two operational modes support safe, incremental transition
4. **Dual-View Analysis**: Compare CRUD and event-sourced views to verify correctness
5. **Practical Tooling**: Lyra implements ORFEAS as a production-ready Rails engine

### Theoretical Foundation

ORFEAS is built on three pillars:

1. **Petri Nets**: Model CRUD-to-event transformations (P/T nets for verification proofs; CPNs with tokens, guards, and arc expressions for advanced data modeling)
2. **Matrix Analysis**: Complementary linear algebra approach for causation and lineage tracking
3. **Privacy Attribute Matrix (PAM)**: DSL for declaring field-level privacy policies and transformations

[Read the complete theoretical foundation →](docs/ORFEAS_FRAMEWORK_OVERVIEW.md)

---

## Key Features

### Operational Features
- ✅ **Non-intrusive Monitoring** - Works with existing Rails applications without code changes
- ✅ **Dual Operational Modes** - Monitor or hijack CRUD operations
- ✅ **Automatic Event Mapping** - CRUD operations automatically mapped to domain events
- ✅ **State Reconstruction** - Rebuild state from event streams
- ✅ **Dual-View Dashboard** - Compare CRUD state vs event-sourced state

### Technical Features
- ✅ **Rails Event Store Integration** - Built on proven event sourcing infrastructure
- ✅ **Pluggable Event Backends** - Support for custom event storage (Kafka, EventStoreDB)
- ✅ **Aggregate Support** - Custom domain aggregates for complex business logic
- ✅ **Command/Query Separation** - CQRS-ready architecture
- ✅ **Event Versioning** - Support for event schema evolution

### Privacy & Compliance
- ✅ **Privacy Attribute Matrix (PAM)** - Built-in PAM DSL for defining privacy policies
- ✅ **GDPR Compliance** - Purpose-based access control, consent management, retention policies
- ✅ **PII Detection & Transformation** - Automatic PII field identification and transformation
- ✅ **Audit Trails** - Complete lineage tracking for regulatory compliance

---

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Rails Application                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ActiveRecord Models (with monitor_with_lyra)                │
│           │                                                   │
│           ▼                                                   │
│  ┌──────────────────┐                                        │
│  │ CRUD Interceptor │                                        │
│  └────────┬─────────┘                                        │
│           │                                                   │
│      ┌────┴────┐                                             │
│      │         │                                             │
│   MONITOR    HIJACK                                          │
│    MODE       MODE                                           │
│      │         │                                             │
│      ▼         ▼                                             │
│  ┌─────┐   ┌─────────┐                                      │
│  │ Log │   │ Command │                                      │
│  │Event│   │ Handler │                                      │
│  └──┬──┘   └────┬────┘                                      │
│     │           │                                            │
│     └─────┬─────┘                                            │
│           ▼                                                   │
│  ┌─────────────────┐                                        │
│  │  Event Store    │                                        │
│  │ (Rails Event    │                                        │
│  │   Store)        │                                        │
│  └─────────────────┘                                        │
│           │                                                   │
│           ▼                                                   │
│  ┌─────────────────┐                                        │
│  │  Aggregates &   │                                        │
│  │  Projections    │                                        │
│  └─────────────────┘                                        │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Operational Modes

#### 1. Monitor Mode (Non-intrusive)
- Observes CRUD operations and logs them as domain events
- **No changes** to application behavior
- Perfect for **analysis and planning** migration
- Zero risk to production systems

#### 2. Hijack Mode (Transformative)
- Intercepts CRUD operations and routes through event sourcing
- Replaces traditional relational backend
- Maintains CRUD interface for **backward compatibility**
- Full event sourcing benefits

[See detailed architecture documentation →](docs/ARCHITECTURE.md)

---

## Components

### Lyra Engine (Core)
The main Rails engine providing:
- CRUD interception and monitoring
- Event mapping and publishing
- Dual-view analysis
- Command/Query handlers
- State reconstruction

### PetriFlow Gem
Complete Petri net and Colored Petri Net library:
- Core Petri net components (places, transitions, arcs)
- Colored extensions (guards, arc expressions, token types)
- Matrix analysis (CRUD-event mapping, causation, lineage)
- Visualization (GraphViz, Mermaid, ASCII)
- Formal verification (reachability, boundedness, liveness)
- Export functionality (PNML, CPN Tools, JSON, YAML)

[Read the PetriFlow documentation →](gems/petri_flow/README.md)

### PAM DSL Gem
Privacy Attribute Matrix Domain-Specific Language:
- Field-level PII classification with sensitivity levels
- Purpose-based access control aligned with GDPR
- Retention policies with field-level granularity
- Consent management with expiration tracking
- Data transformation for different contexts (display, logging, API)

[Read the PAM DSL documentation →](gems/pam_dsl/README.md)

### Monorepo Structure

This repository is organized as a monorepo:
- **`/` (root)** - Lyra Rails engine
- **`gems/petri_flow/`** - PetriFlow Petri net library
- **`gems/pam_dsl/`** - PAM DSL privacy policy language
- **`docs/`** - Theoretical documentation
- **`docs-site/`** - Jekyll documentation site
- **`examples/`** - Example applications

[See complete monorepo structure →](docs/MONOREPO.md)

---

## Installation

### Prerequisites

- Ruby 3.4.5+ (tested up to Ruby 4.0) and Rails 8.0+
- PostgreSQL 14+ (recommended for Rails Event Store)
- Bundler

### Add to Gemfile

```ruby
gem 'lyra', path: 'path/to/lyra'  # or from git/rubygems when published
gem 'pam_dsl', '~> 0.1.0'         # Privacy Attribute Matrix DSL
gem 'petri_flow', '~> 0.1.0'      # Petri net library
```

### Install Dependencies

```bash
bundle install
rails generate rails_event_store_active_record:migration
rails db:migrate
```

---

## Quick Start

### 1. Configure Lyra

Create `config/initializers/lyra.rb`:

```ruby
Lyra.configure do |config|
  # Start in monitor mode (non-intrusive)
  config.mode = :monitor

  # Configure event store
  config.event_backend = :rails_event_store
  config.event_store = RailsEventStore::Client.new

  # Optional: User tracking for audit trails (see User Tracking section below)
  # config.metadata_proc = ->(record, operation) { { user_id: Current.user&.id } }
end
```

### 2. Monitor a Model

Add monitoring to your ActiveRecord models:

```ruby
class Order < ApplicationRecord
  # Enable Lyra monitoring
  monitor_with_lyra

  # Your existing code continues to work normally
  validates :total, presence: true
  belongs_to :customer
end
```

### 3. Observe Events

All CRUD operations are now logged as events:

```ruby
order = Order.create!(total: 100, customer: customer)
# => Publishes OrderCreated event

order.update!(total: 150)
# => Publishes OrderUpdated event

order.destroy!
# => Publishes OrderDestroyed event
```

### 4. Analyze State

Compare CRUD vs event-sourced views:

```ruby
comparison = Lyra::DualView.new(Order, order.id).compare

puts comparison[:differences]
# => { no_differences: true }

# View complete audit trail
audit = Lyra::DualView.new(Order, order.id).audit_trail
# => [{ timestamp: ..., operation: :created, changes: {...} }, ...]
```

[Continue to full usage guide →](#usage-guide)

---

## Usage Guide

### Basic Model Monitoring

Add monitoring to any ActiveRecord model:

```ruby
class Order < ApplicationRecord
  monitor_with_lyra

  validates :total, presence: true
  belongs_to :customer
end
```

### Privacy Policies with PAM DSL

Define privacy policies for your models:

```ruby
# config/privacy_policies.rb
PamDsl.define_policy :order_system do
  # Define PII fields
  field :email, type: :email, sensitivity: :internal do
    allow_for :order_processing, :communication
    transform :display { |v| "#{v[0]}***@#{v.split('@').last}" }
  end

  field :credit_card, type: :credit_card, sensitivity: :restricted do
    allow_for :payment_processing
    transform :display { |v| "****-****-****-#{v[-4..]}" }
  end

  # Define processing purposes
  purpose :order_processing do
    basis :contract
    requires :email
  end

  purpose :marketing do
    basis :consent
    requires :email
  end

  # Configure retention
  retention do
    for_model 'Order' do
      keep_for 7.years
      on_expiry :anonymize
    end
  end
end

# Apply to model
class Order < ApplicationRecord
  monitor_with_lyra privacy_policy: :order_system
end
```

[See complete PAM DSL guide →](gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md)

### Schema Validation (Strict Mode)

Lyra can enforce schema consistency to prevent silent breaking changes in production:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor

  # Enable strict schema validation (recommended for production)
  config.strict_schema = Rails.env.production?

  # Custom schema storage path (optional, defaults to db/lyra_schemas/)
  config.schema_path = Rails.root.join('db/lyra_schemas')

  config.monitor_model User
  config.monitor_model Order
end
```

#### Schema Management Rake Tasks

```bash
# Generate initial schema from monitored models
rake lyra:schema:create

# Check for schema changes without updating
rake lyra:schema:verify

# Create new schema version (after migrations)
rake lyra:schema:update

# Display model → event mappings
rake lyra:schema:report

# Show schema version history
rake lyra:schema:history

# Compare two schema versions
rake lyra:schema:diff[1,2]
```

#### Schema Validation Workflow

1. **Development**: Run `rake lyra:schema:create` to generate initial schema
2. **After migrations**: Run `rake lyra:schema:verify` to detect changes
3. **If changes detected**: Run `rake lyra:schema:update` to create new version
4. **Production**: With `strict_schema = true`, app fails to start if schema changes

#### Schema Change Severity Levels

| Severity | Changes | Impact |
|----------|---------|--------|
| **BREAKING** | model_removed, column_removed, column_type_changed | Requires new schema version |
| **WARNING** | column_nullable_changed, pii_field_added | Review recommended |
| **INFO** | model_added, column_added | Documentation update |

### User Tracking (metadata_proc)

Lyra can capture custom metadata with each event, such as the current user, for audit trails and GDPR compliance.

#### Configuration

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor
  config.event_backend = :rails_event_store

  # Custom metadata proc - called for every event
  # Signature: ->(record, operation) { Hash }
  config.metadata_proc = lambda do |record, operation|
    {
      user_id: Current.user&.id,
      user_email: Current.user&.email,
      ip_address: Current.request&.remote_ip,
      source: 'my_app'
    }
  end
end
```

#### Using with Rails CurrentAttributes

Rails 5.2+ provides `CurrentAttributes` for request-scoped state:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :request_id, :request
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_current_attributes

  private

  def set_current_attributes
    Current.user = current_user
    Current.request_id = request.request_id
    Current.request = request
  end
end
```

#### Using with Devise/Warden

For Devise-based authentication:

```ruby
config.metadata_proc = lambda do |record, operation|
  user = if defined?(Warden) && Thread.current[:request_env]
    Warden::Proxy.new(Thread.current[:request_env], Warden::Manager.new(nil)).user
  end

  { user_id: user&.id, user_email: user&.email }
end
```

#### Using with Rails Engines (Solidus, Spree, etc.)

Many Rails Engines provide their own `Current` class:

```ruby
config.metadata_proc = lambda do |record, operation|
  user_id = nil

  # Try standard Current
  user_id ||= Current.user&.id if defined?(Current)

  # Try Spree/Solidus Current
  user_id ||= Spree::Current.user&.id if defined?(Spree::Current)

  { user_id: user_id }
end
```

#### Metadata in Events

The custom metadata is merged with Lyra's built-in metadata:

```ruby
event = Lyra.event_store.read.last
event.metadata
# => {
#   user_id: 123,
#   user_email: "admin@example.com",
#   ip_address: "127.0.0.1",
#   source: "my_app",
#   request_id: "abc-123",        # Built-in from Current
#   correlation_id: "corr-456",   # Built-in from Correlation context
#   causation_id: "cause-789"     # Built-in from Causation context
# }
```

### Advanced Configuration

Use custom event names and aggregates:

```ruby
class Order < ApplicationRecord
  monitor_with_lyra(
    event_prefix: 'Order',
    aggregate_class: OrderAggregate
  )
end

class OrderAggregate < Lyra::Aggregate
  def total
    get_state(:total)
  end

  private

  def apply_order_created(event)
    @id = event.model_id
    set_state(:total, event.attributes['total'])
    set_state(:status, 'pending')
  end

  def apply_order_updated(event)
    event.changes.each { |k, (old, new)| set_state(k.to_sym, new) }
  end
end
```

### Event Capture Behavior

Lyra uses ActiveRecord `after_commit` callbacks to capture events. This means **all** operations that go through ActiveRecord are captured, regardless of source:

| Source | Captured |
|--------|----------|
| Web requests | ✓ |
| Rails console (`rails c`) | ✓ |
| Background jobs (Sidekiq, etc.) | ✓ |
| Rake tasks | ✓ |
| Rails runner scripts | ✓ |
| Seeds (`db:seed`) | ✓ |

**Operations NOT captured** (bypass ActiveRecord callbacks):

| Operation | Captured | Alternative |
|-----------|----------|-------------|
| `update_columns` / `update_column` | ✗ | Use `update!` |
| `update_all` / `delete_all` | ✗ | Iterate with `find_each` |
| `insert_all` / `upsert_all` | ✗ | Use `create!` |
| Raw SQL (`connection.execute`) | ✗ | Use ActiveRecord methods |
| `touch` with no callbacks | ✗ | Use `update!` |

### Strict Data Access Mode

To prevent inconsistencies between CRUD state and event store, enable strict mode to raise errors on callback-bypassing operations:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.strict_data_access = true  # Raises on update_columns, etc.
  # Or only in specific environments:
  config.strict_data_access = Rails.env.development? || Rails.env.test?
end
```

When enabled, monitored models will raise `Lyra::StrictDataAccessViolation` if you attempt:

| Operation | Alternative | Scope |
|-----------|-------------|-------|
| `update_columns` | `update!` | Instance |
| `update_column` | `update!` | Instance |
| `delete` | `destroy` | Instance |
| `update_all` | `find_each { \|r\| r.update!(...) }` | Relation |
| `delete_all` | `find_each(&:destroy)` | Relation |
| `insert_all` | `records.each { \|attrs\| create!(attrs) }` | Class |
| `upsert_all` | `find_or_create_by!(...).update!(...)` | Class |

```ruby
user.update_columns(name: "New")
# => raises Lyra::StrictDataAccessViolation:
#    "update_columns bypasses callbacks and won't be captured by Lyra.
#     Use update! instead. Disable strict_data_access mode if this is intentional."

Registration.where(status: "pending").update_all(status: "expired")
# => raises Lyra::StrictDataAccessViolation:
#    "update_all bypasses callbacks. Use find_each { |r| r.update!(...) } instead."
```

#### Bypassing Strict Mode

For legitimate bulk operations in migrations, seeds, or admin tasks, use `Lyra.without_strict_access`:

```ruby
# Temporarily bypass strict mode for bulk operations
Lyra.without_strict_access do
  User.where(active: false).delete_all  # No error raised
end
```

**Note:** Rails association operations (like `dependent: :nullify`) are automatically allowed since they're internal framework operations.

### Dual View Analysis

Compare CRUD state with event-sourced state:

```ruby
# Single record comparison
comparison = Lyra::DualView.new(Order, order_id).compare

puts comparison[:crud_view]
# => { exists: true, attributes: {...} }

puts comparison[:event_sourced_view]
# => { exists: true, state: {...}, events_count: 5 }

puts comparison[:differences]
# => { no_differences: true } or differences hash

# Audit trail
audit = Lyra::DualView.new(Order, order_id).audit_trail
# => Array of all operations with timestamps and changes
```

### Batch Analysis

Find discrepancies across all records:

```ruby
discrepancies = Lyra::DualView.find_discrepancies(Order)
# => Returns all orders where CRUD state != Event-sourced state

analysis = Lyra::StateAnalyzer.analyze(Order, order_id)
puts analysis[:recommendations]
# => Actionable recommendations based on state comparison
```

### Switching to Hijack Mode

After analyzing in monitor mode, switch to full event sourcing:

```ruby
# In config/initializers/lyra.rb
Lyra.configure do |config|
  config.enable_hijack!
end
```

Now CRUD operations are intercepted and routed through event sourcing:

```ruby
order = Order.create!(total: 100, customer: customer)
# => CreateCommand processed
# => OrderCreated event published
# => Aggregate updated
# => Database record created with event-sourced ID
```

### Dashboard

Lyra provides a web dashboard for monitoring and analyzing event-sourced data.

#### Mounting the Dashboard

Add to your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Lyra::Engine, at: "/lyra"
  # ... rest of your routes
end
```

#### Available Routes

| Route | Description |
|-------|-------------|
| `/lyra/dashboard` | Main dashboard with monitored models overview |
| `/lyra/dashboard/model/:class` | Model-specific overview (e.g., `/lyra/dashboard/model/Order`) |
| `/lyra/dashboard/compare/:class/:id` | Dual View - Compare CRUD state vs Event-sourced state |
| `/lyra/dashboard/discrepancies/:class` | List records with state discrepancies |

**Event Flow Routes:**

| Route | Description |
|-------|-------------|
| `/lyra/flow/timeline` | Global event timeline |
| `/lyra/flow/event_chain/:class/:id` | Event chain for a specific record |
| `/lyra/flow/crud_mapping` | CRUD operation to event type mapping |
| `/lyra/flow/correlation/:correlation_id` | Events by correlation ID |
| `/lyra/flow/user_actions/:user_id` | Events by user |

**Visualization Routes:**

| Route | Description |
|-------|-------------|
| `/lyra/visualizations/event_graph` | Interactive event graph (HTML + Mermaid) |
| `/lyra/visualizations/event_graph.json` | Event graph data with filters |
| `/lyra/visualizations/entity_graph/:class/:id.json` | Entity lifecycle graph |
| `/lyra/visualizations/heatmap` | Activity heatmap view |
| `/lyra/visualizations/heatmap.json` | Heatmap data for time period |
| `/lyra/visualizations/event_list.json` | List of entities with event counts |

**Event Graph Features:**

The event graph provides an interactive visualization of entity lifecycles:

- **Entity Picker**: Filter by model class, select specific entities to view
- **Changed Fields**: Each event node displays which fields were modified (📝 prefix)
- **Link Types**:
  - Solid lines → Same entity lifecycle (chronological order)
  - Dashed lines → Correlated events (same transaction/request)
- **Node Details**: Includes operation type, timestamp, and changed field names

Example node display:
```
┌─────────────────────┐
│      UPDATED        │
│     14:30:45        │
│ 📝 status, amount   │
└─────────────────────┘
```

Timestamp fields (`*_at`) are automatically excluded from the changed fields display.

**Schema Management Routes:**

| Route | Description |
|-------|-------------|
| `/lyra/dashboard/schema` | Current schema with pending changes |
| `/lyra/dashboard/schema/history` | Schema version history |
| `/lyra/dashboard/schema/:version` | View specific schema version |

**Formal Verification Routes (requires PetriFlow):**

| Route | Description |
|-------|-------------|
| `/lyra/verification` | Verification dashboard |
| `/lyra/verification.json` | Verification results (JSON) |

**Privacy & GDPR Routes:**

| Route | Description |
|-------|-------------|
| `/lyra/privacy/pii_detection` | Automatic PII field detection |
| `/lyra/privacy/gdpr_report/:type/:id` | GDPR Article 15 compliant report |
| `/lyra/privacy/subject/:type/:id` | View all data for a subject |

#### Securing Dashboard Access

**IMPORTANT**: The Lyra dashboard exposes sensitive data including PII fields, event history, and audit trails. Always restrict access in production.

##### Option 1: Authentication Constraint (Recommended)

```ruby
# config/routes.rb
Rails.application.routes.draw do
  # Restrict to authenticated admin users
  authenticate :user, ->(u) { u.admin? } do
    mount Lyra::Engine, at: "/lyra"
  end
end
```

##### Option 2: Basic HTTP Authentication

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Lyra::Engine, at: "/lyra", constraints: ->(req) {
    Rack::Auth::Basic::Request.new(req.env).provided? &&
    Rack::Auth::Basic::Request.new(req.env).credentials ==
      [ENV['LYRA_USER'], ENV['LYRA_PASSWORD']]
  }
end
```

##### Option 3: IP Whitelist

```ruby
# config/routes.rb
Rails.application.routes.draw do
  constraints ->(req) { ['127.0.0.1', '::1'].include?(req.remote_ip) } do
    mount Lyra::Engine, at: "/lyra"
  end
end
```

##### Option 4: Custom Middleware

```ruby
# lib/lyra_auth_middleware.rb
class LyraAuthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['PATH_INFO'].start_with?('/lyra')
      # Your authentication logic here
      return [403, {}, ['Forbidden']] unless authorized?(env)
    end
    @app.call(env)
  end

  private

  def authorized?(env)
    # Implement your authorization logic
    env['warden']&.user&.admin?
  end
end

# config/application.rb
config.middleware.use LyraAuthMiddleware
```

##### Option 5: Disable in Production

```ruby
# config/routes.rb
Rails.application.routes.draw do
  unless Rails.env.production?
    mount Lyra::Engine, at: "/lyra"
  end
end
```

#### Environment-Based Configuration

```ruby
# config/routes.rb
Rails.application.routes.draw do
  case Rails.env
  when 'development'
    # Open access in development
    mount Lyra::Engine, at: "/lyra"
  when 'staging'
    # Basic auth in staging
    mount Lyra::Engine, at: "/lyra", constraints: LyraBasicAuth
  when 'production'
    # Full authentication in production
    authenticate :user, ->(u) { u.admin? } do
      mount Lyra::Engine, at: "/lyra"
    end
  end
end
```

### Custom Event Mappers

Create custom event mapping logic:

```ruby
class OrderEventMapper < Lyra::EventMapper
  def event_data
    super.merge(
      business_context: {
        total: data[:attributes]['total'],
        items_count: data[:attributes]['items_count']
      }
    )
  end
end

Lyra::EventMapper.register_mapper(Order, OrderEventMapper)
```

### State Reconstruction

Rebuild current state from events:

```ruby
# Using projection
state = Lyra::StateProjection.rebuild_state(Order, order_id)
# => { total: 150, status: "confirmed", ... }

# Using aggregate
aggregate = OrderAggregate.load(order_id)
aggregate.total  # => 150
aggregate.status # => "confirmed"
```

### Pluggable Backends

Implement custom event storage:

```ruby
class MyEventStore < Lyra::CustomEventStoreAdapter
  def publish(event, stream_name:)
    # Custom implementation (e.g., Kafka, EventStoreDB)
  end

  def read_stream(stream_name)
    # Custom implementation
  end
end

Lyra.configure do |config|
  config.event_backend = :custom
  config.event_store = MyEventStore.new
end
```

---

## Example Applications

### Blog App (Getting Started)

A simpler example for learning Lyra basics is in `examples/blog_app/`:

```bash
cd examples/blog_app
bundle install
rails db:create db:migrate db:seed
rails console
```

[Explore the blog example →](examples/blog_app/README.md)

---

## Benefits

### For Research
- **Orthogonal Analysis**: Compare static vs. dynamic views of system state
- **Behavioral Analysis**: Understand system evolution over time
- **Migration Patterns**: Study CRUD-to-ES transformation strategies
- **Formal Verification**: Prove correctness using Petri net theory
- **Privacy Compliance**: Research privacy-preserving event sourcing patterns

### For Development
- **Zero Downtime Migration**: Gradually transition to event sourcing
- **Audit Trail**: Complete history of all state changes
- **Temporal Queries**: Query state at any point in time
- **Debugging**: Replay events to understand issues
- **CQRS Support**: Natural separation of commands and queries

### For Operations
- **Non-intrusive**: Deploy without code changes
- **Rollback Safety**: Keep CRUD as safety net during transition
- **Real-time Monitoring**: Compare CRUD vs event-sourced state
- **Validation**: Verify event sourcing correctness before full migration
- **Performance Analysis**: Measure overhead before committing

---

## Documentation

### Core Documentation
- **[Getting Started Guide](docs/GETTING_STARTED.md)** - Installation and first steps
- **[Architecture Overview](docs/ARCHITECTURE.md)** - System design and components
- **[Monorepo Structure](docs/MONOREPO.md)** - Repository organization

### Theoretical Foundation
- **[ORFEAS Framework Overview](docs/ORFEAS_FRAMEWORK_OVERVIEW.md)** - Complete framework description
- **[Petri Nets Model](gems/petri_flow/docs/THEORETICAL_MODEL_PETRI_NETS.md)** - P/T nets for verification, CPNs for data modeling
- **[Matrix Analysis Model](gems/petri_flow/docs/THEORETICAL_MODEL_MATRICES.md)** - Linear algebra approach

### Privacy & Compliance
- **[PAM DSL Integration](gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md)** - Privacy policy DSL guide
- **[Privacy Compliance](docs/PRIVACY_COMPLIANCE.md)** - GDPR compliance details

### Components
- **[PetriFlow Export](gems/petri_flow/docs/PETRIFLOW_EXPORT.md)** - Export formats and integration
- **[PetriFlow Gem](gems/petri_flow/README.md)** - Petri net library documentation
- **[PAM DSL Gem](gems/pam_dsl/README.md)** - Privacy DSL documentation

### Development
- **[Testing Guide](docs/TESTING.md)** - Testing strategy and setup

---

## Research Foundation

ORFEAS and Lyra are grounded in peer-reviewed research:

### Published Papers

**Pantelelis, M., & Kalloniatis, C. (2022).** *Mapping CRUD to Events: Towards an object to event-sourcing framework.*
26th Pan-Hellenic Conference on Informatics (PCI 2022).
DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)

### Research Areas

- **Event Sourcing Patterns**: Formal models for CRUD-to-event transformation
- **Privacy-Preserving Systems**: GDPR compliance in event-driven architectures
- **Petri Net Theory**: P/T nets for workflow verification, CPNs for advanced data modeling
- **Matrix Analysis**: Linear algebra approaches to causation and lineage
- **Software Architecture**: Gradual migration strategies for legacy systems

---

## Development Methodology

This proof-of-concept was developed using **AI-assisted code generation** to accelerate implementation while maintaining focus on theoretical contributions.

### AI Tools Used

- **Claude Code** (Anthropic's agentic coding tool) - Primary development assistant for code implementation, testing, and documentation
- **Claude** (Anthropic) - For architectural discussions and design decisions

**Important**: All architectural decisions, design patterns, and theoretical foundations were specified by the researcher. AI assistance was used for:
- Code implementation following defined specifications
- Test generation based on requirements
- Documentation formatting and organization
- Code review and refactoring

This methodology enabled rapid prototyping while ensuring the theoretical rigor required for academic research.

---

## Contributing

Lyra is research software for the ORFEAS framework. Contributions and feedback are welcome!

### Ways to Contribute

- **Bug Reports**: Submit issues on GitHub
- **Feature Requests**: Suggest improvements or new features
- **Research Collaboration**: Collaborate on research extensions
- **Documentation**: Improve documentation and examples
- **Testing**: Add test cases and improve coverage

### Development Setup

```bash
# Clone the repository
git clone https://github.com/mpantel/lyra-engine.git lyra
cd lyra

# Install dependencies
bundle install

# Run tests
rake test

# Build gems
cd gems/petri_flow && rake build
cd gems/pam_dsl && rake build
```

---

## Citation

If you use this software in academic research, please cite:

### Software Citation

```bibtex
@software{lyra2026,
  title={Lyra: CRUD to Event Sourcing Transformation Engine},
  author={Pantelelis, Michail},
  year={2026},
  note={Part of ORFEAS Framework},
  url={https://github.com/mpantel/lyra-engine}
}
```

### Research Paper Citation

```bibtex
@inproceedings{pantelelis2022mapping,
  title={Mapping CRUD to Events: Towards an object to event-sourcing framework},
  author={Pantelelis, Michail and Kalloniatis, Christos},
  booktitle={26th Pan-Hellenic Conference on Informatics (PCI 2022)},
  year={2022},
  doi={10.1145/3575879.3576006}
}
```

### References

- [Rails Event Store](https://railseventstore.org/) - Event Store implementation
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html) - Martin Fowler
- [CQRS](https://martinfowler.com/bliki/CQRS.html) - Command Query Responsibility Segregation
- [Petri Net Theory](http://www.informatik.uni-hamburg.de/TGI/PetriNets/) - Formal foundation
- [GDPR Compliance](https://gdpr.eu/) - Privacy regulation

---

## Support

For questions, issues, and collaboration:

- **Email**: mpantel@aegean.gr
- **GitHub Issues**: [Repository Issues](https://github.com/mpantel/lyra-engine/issues)
- **Institution**: University of the Aegean, Department of Information and Communication Systems Engineering

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Built with Ruby, Petri Net Theory, and Formal Methods**
**Part of the ORFEAS PhD Research Project**
