# Lyra Example Blog Application

A comprehensive example Rails application demonstrating all features of the Lyra framework for CRUD-to-Event-Sourcing transformation with GDPR compliance.

## Overview

This blog application showcases:

- **Event Sourcing**: All CRUD operations automatically captured as events
- **Dual-View Architecture**: Simultaneous CRUD and event-sourced state
- **Privacy Compliance**: GDPR-compliant PII detection and handling
- **Audit Trails**: Complete history of all data changes
- **State Reconstruction**: Rebuild state from events at any point in time
- **Monitor Mode**: Non-invasive event capture alongside existing CRUD

## Application Structure

### Models

- **User**: Blog authors with PII (email, name)
  - Email validation and uniqueness
  - Soft delete capability
  - Biography field

- **Post**: Blog posts with publishing workflow
  - Draft → Published → Archived lifecycle
  - View count tracking
  - Author association

- **Comment**: User interactions on posts
  - Body content
  - User and Post associations

### Event Sourcing Integration

All models use `monitor_with_lyra` to automatically:
- Capture create, update, and destroy operations as events
- Track PII fields (email, name)
- Maintain event streams for each record
- Enable state reconstruction from events

## Setup

### Prerequisites

- Ruby 3.0 or higher
- Rails 7.1
- SQLite3 (or your preferred database)

### Installation

1. Install dependencies:
   ```bash
   cd examples/blog_app
   bundle install
   ```

2. Setup database:
   ```bash
   rails db:create
   rails db:migrate
   ```

3. Load sample data:
   ```bash
   rails db:seed
   ```

## Usage

### Running Example Workflows

The application includes four comprehensive example workflows:

#### 1. User Lifecycle Workflow

Demonstrates creating, updating, and soft-deleting users with complete event tracking.

```bash
rails runner lib/examples/user_lifecycle.rb
```

**Features demonstrated:**
- User creation and event capture
- Multiple profile updates
- Event stream accumulation
- State reconstruction from events
- Dual-view comparison (CRUD vs Event-sourced)
- Soft delete with data retention
- Audit trail generation

**Key concepts:**
- Every state change creates an immutable event
- State can be rebuilt from events at any time
- CRUD and event-sourced views remain consistent
- Soft deletes preserve data for compliance

#### 2. Post Publishing Workflow

Shows the complete lifecycle of a blog post from draft to publication to archival.

```bash
rails runner lib/examples/post_workflow.rb
```

**Features demonstrated:**
- Draft post creation
- Multiple editorial revisions
- Event flow analysis
- Publishing workflow
- View count tracking
- Post archival
- Time-travel state reconstruction

**Key concepts:**
- Draft → Published → Archived lifecycle
- Every revision captured as event
- Time-travel: view state at any point in history
- Event flow analysis provides content insights

#### 3. Event Inspection and Analysis

Comprehensive queries and analysis of the event store.

```bash
rails runner lib/examples/event_inspection.rb
```

**Features demonstrated:**
- Reading all events from store
- Grouping by model type and operation
- Event stream analysis per record
- Event flow timeline analysis
- Privacy impact assessment
- Correlation and causation tracking
- System health checks
- Event store statistics

**Key concepts:**
- Event store contains complete system history
- Events queryable by stream, type, metadata
- Privacy analysis identifies PII
- Health checks ensure consistency

#### 4. Privacy Compliance and GDPR

Demonstrates GDPR compliance features including PII handling and retention policies.

```bash
rails runner lib/examples/privacy_compliance.rb
```

**Features demonstrated:**
- PII detection in attributes and events
- PII masking for safe display
- Privacy Attribute Matrix (PAM) policy application
- Data export (Right to Data Portability)
- Audit trail for accountability
- Data anonymization
- Right to be forgotten implementation
- Retention policy enforcement

**Key concepts:**
- Automatic PII detection
- PAM policies define legal basis and retention
- Complete audit trail for compliance
- Support for GDPR rights (portability, erasure)

### Interactive Console

Start a Rails console to explore interactively:

```bash
rails console
```

#### Example Console Commands

```ruby
# View event store statistics
all_events = Rails.configuration.event_store.read.to_a
puts "Total events: #{all_events.count}"

# Analyze a specific user
user = User.first
stream_name = "User-#{user.id}"
events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "Events for #{user.name}: #{events.count}"

# Rebuild state from events
projection = Lyra::StateProjection.new
state = projection.rebuild_from_events(events)
puts state.inspect

# Compare CRUD and event-sourced views
dual_view = Lyra::DualView.new(User, user.id)
comparison = dual_view.compare
puts comparison.inspect

# Detect PII
pii_fields = Lyra::Privacy::PIIDetector.detect(user.attributes)
puts "PII fields: #{pii_fields.keys.join(', ')}"

# Mask PII
masked = Lyra::Privacy::PIIMasker.mask(user.attributes)
puts "Masked email: #{masked['email']}"

# Event flow analysis
event_flow = Lyra::EventFlow.new(events)
analysis = event_flow.analyze
puts analysis.inspect

# Audit trail
audit = Lyra::AuditProjection.audit_trail(User, user.id)
audit.each { |entry| puts "#{entry[:operation]} at #{entry[:timestamp]}" }

# Check retention policy
policy = PamDsl.policies[:blog_data]
model_policy = policy.find_model_policy("User")
puts "Retention: #{model_policy[:retention][:default]}"
```

## Architecture

### Event Sourcing

Every CRUD operation is captured as an immutable event:

```ruby
# When you do this:
user = User.create!(email: "alice@example.com", name: "Alice")

# Lyra automatically creates an event like:
{
  model_class: "User",
  model_id: user.id,
  operation: :created,
  attributes: { email: "alice@example.com", name: "Alice", ... },
  changes: {},
  timestamp: Time.current
}
```

### Dual-View Architecture

Lyra maintains two views of your data:

1. **CRUD View**: Traditional database records (mutable)
2. **Event-Sourced View**: State rebuilt from events (immutable)

This enables:
- Consistency verification
- Time-travel debugging
- Audit compliance
- Graceful migration from CRUD to event sourcing

### Privacy Compliance

The PAM (Privacy Attribute Matrix) DSL defines:

```ruby
PamDsl.define_policy :blog_data do
  # Field definitions with sensitivity
  field :email, type: :email, sensitivity: :confidential
  field :name, type: :name, sensitivity: :internal

  # Legal basis for processing
  purpose :user_account do
    legal_basis :contract
    required_fields [:email, :name]
  end

  # Retention policies
  retention do
    default 7.years
    for_model "User" do
      keep_for 7.years
      field :email, duration: 2.years  # Email removed after 2 years
    end
  end
end
```

## Key Features Demonstrated

### 1. Automatic Event Capture

All CRUD operations automatically generate events without code changes:

```ruby
user.update!(name: "New Name")  # Event automatically created
```

### 2. State Reconstruction

Rebuild state from events at any point in time:

```ruby
events = Rails.configuration.event_store.read.stream("User-#{user.id}").to_a
projection = Lyra::StateProjection.new
state = projection.rebuild_from_events(events.take(5))  # State after 5 events
```

### 3. PII Detection and Masking

Automatic detection and safe handling of personally identifiable information:

```ruby
pii = Lyra::Privacy::PIIDetector.detect(user.attributes)
masked = Lyra::Privacy::PIIMasker.mask(user.attributes)
```

### 4. Audit Trails

Complete history for regulatory compliance:

```ruby
audit = Lyra::AuditProjection.audit_trail(User, user.id)
# Returns all operations with timestamps, changes, and user attribution
```

### 5. Dual-View Comparison

Verify consistency between CRUD and event-sourced state:

```ruby
dual_view = Lyra::DualView.new(User, user.id)
comparison = dual_view.compare
# Shows both views and any differences
```

### 6. Event Flow Analysis

Analyze patterns and metrics in event streams:

```ruby
event_flow = Lyra::EventFlow.new(events)
analysis = event_flow.analyze
# Timeline, operation counts, privacy impact, metrics
```

## Testing the Application

Run the test suite:

```bash
# From the Lyra root directory
rake test
```

The test suite includes:
- Unit tests for all Lyra components
- Integration tests for CRUD workflows
- Privacy compliance tests
- State reconstruction tests

## Configuration

### Lyra Configuration

See `config/initializers/lyra.rb`:

```ruby
Lyra.configure do |config|
  config.mode = :monitor              # :monitor or :hijack
  config.event_store = Rails.configuration.event_store
  config.privacy_enabled = true       # Enable PII detection
  config.retention_policy = 7.years   # Default retention
end
```

### Monitor vs Hijack Mode

- **Monitor Mode** (default): Events captured alongside CRUD operations
  - Non-invasive
  - Existing code continues to work
  - Gradual migration path

- **Hijack Mode**: Events replace CRUD operations
  - Full event sourcing
  - State rebuilt from events
  - Command-query separation

## GDPR Compliance Features

This application demonstrates all GDPR requirements:

### Article 13-14: Transparency
- PAM policy defines what data is collected and why
- Legal basis documented for each purpose

### Article 15: Right of Access
- Complete audit trail via `AuditProjection`
- Event history shows all data processing

### Article 16: Right to Rectification
- Update operations captured as events
- Full history of corrections maintained

### Article 17: Right to Erasure
- Soft delete with anonymization
- Retention policy enforcement
- PII removal after retention period

### Article 18: Right to Restriction
- Event streams can be frozen
- Processing restrictions tracked

### Article 20: Right to Data Portability
- Complete data export from events
- Machine-readable format

### Article 30: Records of Processing
- Complete audit trail
- Purpose and legal basis documented
- Retention periods defined

### Article 32: Security
- Immutable event log
- PII masking for safe operations
- Audit trail for security monitoring

## Troubleshooting

### Events not appearing in store

Check that:
1. `monitor_with_lyra` is called in your model
2. Lyra configuration is loaded (`config/initializers/lyra.rb`)
3. Event store is configured in `config/application.rb`

### PII not detected

Ensure field names match detection patterns:
- Email: `email`, `email_address`, `contact_email`
- Name: `name`, `first_name`, `last_name`, `full_name`
- Phone: `phone`, `telephone`, `phone_number`

See `Lyra::Privacy::PIIDetector` for complete patterns.

### State inconsistencies

Run a health check:

```ruby
User.find_each do |user|
  dual_view = Lyra::DualView.new(User, user.id)
  comparison = dual_view.compare

  unless comparison[:differences][:no_differences]
    puts "Inconsistency for User #{user.id}"
    puts comparison[:differences]
  end
end
```

## Next Steps

1. **Customize Models**: Add your own models with Lyra integration
2. **Define Policies**: Create PAM policies for your data
3. **Build Projections**: Create custom read models from events
4. **Add Commands**: Implement business logic with Commands and Aggregates
5. **Migrate Gradually**: Start with Monitor mode, then move to Hijack mode

## Resources

- [Lyra Documentation](../../README.md)
- [Event Sourcing Patterns](../../docs/event_sourcing.md)
- [Privacy Compliance Guide](../../docs/privacy_compliance.md)
- [Migration Guide](../../docs/migration_guide.md)

## License

This example application is part of the Lyra project and shares the same license.
