# Migration Guide: CRUD to Event Sourcing with Lyra

## Overview

This guide provides step-by-step instructions for migrating your existing CRUD-based Rails application to event sourcing using Lyra. The migration follows a gradual, low-risk approach that minimizes disruption to your application.

## Table of Contents

1. [Migration Philosophy](#migration-philosophy)
2. [Pre-Migration Assessment](#pre-migration-assessment)
3. [Phase 1: Setup and Monitoring](#phase-1-setup-and-monitoring)
4. [Phase 2: Analysis and Validation](#phase-2-analysis-and-validation)
5. [Phase 3: Gradual Transformation](#phase-3-gradual-transformation)
6. [Phase 4: Full Event Sourcing](#phase-4-full-event-sourcing)
7. [Rollback Strategies](#rollback-strategies)
8. [Common Challenges](#common-challenges)
9. [Best Practices](#best-practices)

---

## Migration Philosophy

Lyra follows a **gradual, reversible** migration philosophy:

### Key Principles

1. **Non-Intrusive Start**: Begin with zero changes to existing code
2. **Continuous Validation**: Verify correctness at every step
3. **Rollback Safety**: Maintain CRUD as a safety net
4. **Incremental Adoption**: Transform one model at a time
5. **Business Continuity**: No downtime or data loss

### Migration Modes

| Mode | Purpose | Risk | Benefits |
|------|---------|------|----------|
| **Monitor** | Observe and log events | Zero | Learn patterns, no commitment |
| **Hybrid** | Event sourcing for some operations | Low | Gradual transformation |
| **Hijack** | Full event sourcing | Medium | Complete benefits |

---

## Pre-Migration Assessment

### Step 1: Identify Candidates

Evaluate which models are good candidates for event sourcing:

#### Good Candidates
- ✅ Models with complex lifecycle (e.g., Order, Invoice)
- ✅ High audit requirements (e.g., PaymentTransaction)
- ✅ Temporal queries needed (e.g., AccountBalance)
- ✅ Frequent state changes (e.g., ShipmentStatus)
- ✅ GDPR compliance needs (e.g., UserData)

#### Poor Candidates
- ❌ Simple lookup tables (e.g., Country, Category)
- ❌ Rarely changing data (e.g., Configuration)
- ❌ High-volume, low-value data (e.g., PageView)
- ❌ External system constraints

### Step 2: Analyze Dependencies

Map relationships between models:

```ruby
# Create a dependency map
rails console
> models = ApplicationRecord.descendants
> models.each do |model|
>   associations = model.reflect_on_all_associations
>   puts "#{model.name}: #{associations.map(&:name).join(', ')}"
> end
```

### Step 3: Review Data Patterns

Understand your data:

```ruby
# Analyze operation patterns
User.all.each do |user|
  created = user.created_at
  updated = user.updated_at
  changes_count = # estimate from updated_at frequency
  puts "User #{user.id}: Created #{created}, Last updated #{updated}"
end
```

### Step 4: Set Success Criteria

Define what success looks like:

- [ ] Zero data loss during migration
- [ ] No performance degradation > 10%
- [ ] 100% state consistency (CRUD == Event-sourced)
- [ ] Complete audit trail captured
- [ ] Privacy policies enforced
- [ ] Ability to rollback within 5 minutes

---

## Phase 1: Setup and Monitoring

**Duration**: 1-2 weeks
**Risk**: Zero
**Goal**: Understand event patterns without changing behavior

### Step 1.1: Install Lyra

```ruby
# Gemfile
gem 'lyra', path: 'path/to/lyra'  # or from git/rubygems
gem 'rails_event_store', '~> 2.14'

# Install
bundle install
rails generate rails_event_store_active_record:migration
rails db:migrate
```

### Step 1.2: Configure Event Store

```ruby
# config/application.rb
module YourApp
  class Application < Rails::Application
    config.to_prepare do
      Rails.configuration.event_store = RailsEventStore::Client.new
    end
  end
end
```

### Step 1.3: Initialize Lyra in Monitor Mode

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  # Start in monitor mode (non-intrusive)
  config.mode = :monitor

  # Configure event store
  config.event_store = Rails.configuration.event_store

  # Enable privacy features
  config.privacy_enabled = true

  # Set retention policy
  config.retention_policy = 7.years

  # Optional: log to file for analysis
  config.logger = Logger.new(Rails.root.join('log', 'lyra_events.log'))
end
```

### Step 1.4: Enable Monitoring on First Model

Start with one non-critical model:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  # Enable Lyra monitoring
  monitor_with_lyra event_prefix: "User"

  # All existing code remains unchanged
  validates :email, presence: true, uniqueness: true
  has_many :posts
end
```

### Step 1.5: Generate Traffic

Let your application run normally. Monitor mode will capture all CRUD operations as events without changing behavior.

```bash
# Watch event accumulation
rails console
> Rails.configuration.event_store.read.count
# => Shows event count

# Sample recent events
> Rails.configuration.event_store.read.limit(10).to_a
```

### Step 1.6: Review Initial Data

After a few days of monitoring:

```ruby
# Analyze event patterns
User.find_each do |user|
  stream = "User-#{user.id}"
  events = Rails.configuration.event_store.read.stream(stream).to_a

  puts "User #{user.id}: #{events.count} events"
  puts "  Operations: #{events.group_by { |e| e.data[:operation] }.transform_values(&:count)}"
end
```

---

## Phase 2: Analysis and Validation

**Duration**: 1-2 weeks
**Risk**: Zero
**Goal**: Verify event capture and state consistency

### Step 2.1: State Consistency Checks

Verify that event-sourced state matches CRUD state:

```ruby
# Check individual record
user = User.first
comparison = Lyra::DualView.new(User, user.id).compare

if comparison[:differences][:no_differences]
  puts "✓ States match!"
else
  puts "✗ Discrepancy found:"
  pp comparison[:differences]
end
```

### Step 2.2: Batch Consistency Analysis

Check all records:

```ruby
# Find all discrepancies
discrepancies = Lyra::DualView.find_discrepancies(User)

if discrepancies.empty?
  puts "✓ All #{User.count} users have consistent state!"
else
  puts "✗ Found #{discrepancies.count} discrepancies:"
  discrepancies.each do |disc|
    puts "  User #{disc[:metadata][:model_id]}: #{disc[:differences].keys.join(', ')}"
  end
end
```

### Step 2.3: Event Flow Analysis

Understand event patterns:

```ruby
# Analyze event flows
User.limit(100).each do |user|
  stream = "User-#{user.id}"
  events = Rails.configuration.event_store.read.stream(stream).to_a

  event_flow = Lyra::EventFlow.new(events)
  analysis = event_flow.analyze

  puts "User #{user.id}:"
  puts "  Operations/day: #{analysis[:metrics][:operations_per_day]}"
  puts "  PII events: #{analysis[:privacy][:events_with_pii]}"
end
```

### Step 2.4: Privacy Impact Assessment

Evaluate PII handling:

```ruby
# Check PII detection
User.first(10).each do |user|
  pii_fields = Lyra::Privacy::PIIDetector.detect(user.attributes)

  puts "User #{user.id}:"
  pii_fields.each do |field, info|
    puts "  #{field}: #{info[:type]} (#{info[:sensitivity]})"
  end
end
```

### Step 2.5: Performance Measurement

Measure overhead of event capture:

```ruby
# Benchmark CRUD operations
require 'benchmark'

Benchmark.bm do |x|
  x.report("create") { 100.times { User.create!(email: "test@example.com", name: "Test") } }
  x.report("update") { User.limit(100).each { |u| u.update!(name: "Updated") } }
  x.report("destroy") { User.where(email: "test@example.com").destroy_all }
end

# Compare with and without Lyra monitoring
```

### Step 2.6: Document Findings

Create a migration report:

```markdown
# Migration Assessment Report

## Summary
- Total records monitored: X
- Events captured: Y
- Average events/record: Z

## State Consistency
- Records with consistent state: X / Y (Z%)
- Discrepancies found: N
- Discrepancy types: ...

## Privacy Analysis
- PII fields detected: [list]
- Events with PII: X%
- Compliance status: ✓/✗

## Performance
- Create overhead: +X%
- Update overhead: +Y%
- Read overhead: 0% (monitor mode)

## Recommendation
- Proceed to Phase 3: YES/NO
- Models ready for transformation: [list]
- Concerns to address: [list]
```

---

## Phase 3: Gradual Transformation

**Duration**: 2-4 weeks
**Risk**: Low-Medium
**Goal**: Enable event sourcing for selected operations

### Step 3.1: Define Privacy Policies

Before transforming, define PAM policies:

```ruby
# config/initializers/privacy_policies.rb
PamDsl.define_policy :user_data do
  # Define PII fields
  field :email, type: :email, sensitivity: :confidential do
    allow_for :authentication, :communication
    transform :display { |v| "#{v[0..2]}***@#{v.split('@').last}" }
  end

  field :name, type: :name, sensitivity: :internal do
    allow_for :authentication, :display
    transform :logging { |v| "[REDACTED]" }
  end

  # Define purposes
  purpose :authentication do
    legal_basis :contract
    required_fields [:email, :name]
  end

  purpose :communication do
    legal_basis :consent
    required_fields [:email]
    retention 2.years
  end

  # Configure retention
  retention do
    default 7.years
    for_model 'User' do
      keep_for 7.years
      field :email, duration: 2.years
      on_expiry :anonymize
    end
  end
end

# Apply policy
class User < ApplicationRecord
  monitor_with_lyra(
    event_prefix: "User",
    privacy_policy: :user_data
  )
end
```

### Step 3.2: Create Custom Aggregates

Define business logic in aggregates:

```ruby
# app/aggregates/user_aggregate.rb
class UserAggregate < Lyra::Aggregate
  def email
    get_state(:email)
  end

  def name
    get_state(:name)
  end

  def active?
    !get_state(:deleted)
  end

  private

  def apply_user_created(event)
    @id = event.model_id
    set_state(:email, event.attributes['email'])
    set_state(:name, event.attributes['name'])
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
end

# Link to model
class User < ApplicationRecord
  monitor_with_lyra(
    event_prefix: "User",
    aggregate_class: UserAggregate,
    privacy_policy: :user_data
  )
end
```

### Step 3.3: Enable Hybrid Mode

Selectively enable event sourcing for specific operations:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  # Enable hybrid mode
  config.mode = :hybrid

  # Specify which operations to hijack
  config.hijack_operations = [:create]  # Start with creates only

  config.event_store = Rails.configuration.event_store
  config.privacy_enabled = true
end
```

Now creates go through event sourcing, updates/deletes still use CRUD.

### Step 3.4: Test Hybrid Mode

Verify behavior in development:

```ruby
# Creates are now event-sourced
user = User.create!(email: "test@example.com", name: "Test User")
# => CreateUserCommand processed
# => UserCreated event published
# => Aggregate updated
# => Database record created

# Updates still use CRUD (but monitored)
user.update!(name: "Updated Name")
# => Traditional ActiveRecord update
# => UserUpdated event logged

# Check consistency
comparison = Lyra::DualView.new(User, user.id).compare
pp comparison[:differences]  # Should be: { no_differences: true }
```

### Step 3.5: Gradual Operation Expansion

Incrementally add more operations:

```ruby
# Week 1: Creates only
config.hijack_operations = [:create]

# Week 2: Creates and updates
config.hijack_operations = [:create, :update]

# Week 3: All operations
config.hijack_operations = [:create, :update, :destroy]
```

After each expansion:
1. Run consistency checks
2. Monitor performance
3. Check for errors
4. Verify business logic

### Step 3.6: Model-by-Model Rollout

Add more models incrementally:

```ruby
# Week 1: User only
class User < ApplicationRecord
  monitor_with_lyra aggregate_class: UserAggregate
end

# Week 2: Add Post
class Post < ApplicationRecord
  monitor_with_lyra aggregate_class: PostAggregate
  belongs_to :user
end

# Week 3: Add Comment
class Comment < ApplicationRecord
  monitor_with_lyra aggregate_class: CommentAggregate
  belongs_to :user
  belongs_to :post
end
```

---

## Phase 4: Full Event Sourcing

**Duration**: 2-4 weeks
**Risk**: Medium
**Goal**: Complete transformation to event sourcing

### Step 4.1: Enable Hijack Mode

After successful hybrid operation:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  # Enable full hijack mode
  config.enable_hijack!

  config.event_store = Rails.configuration.event_store
  config.privacy_enabled = true
  config.retention_policy = 7.years
end
```

### Step 4.2: Verify Full Transformation

All CRUD operations now routed through event sourcing:

```ruby
# Test complete lifecycle
user = User.create!(email: "fulltest@example.com", name: "Full Test")
# => CreateUserCommand
# => UserCreated event
# => Aggregate loads

user.update!(name: "Updated")
# => UpdateUserCommand
# => UserUpdated event
# => Aggregate applies changes

user.destroy!
# => DestroyUserCommand
# => UserDestroyed event
# => Aggregate marks deleted

# State entirely rebuilt from events
aggregate = UserAggregate.load(user.id)
aggregate.name  # => "Updated"
aggregate.active?  # => false
```

### Step 4.3: Production Deployment

Deploy to production with care:

```bash
# Deploy Phase 4 to production
git push production main

# Monitor closely
tail -f log/production.log | grep Lyra
tail -f log/lyra_events.log

# Watch for errors
rails console --environment=production
> Rails.logger.level = Logger::DEBUG
> # Monitor for 24-48 hours
```

### Step 4.4: Performance Tuning

Optimize event store queries:

```ruby
# Add indexes for common queries
add_index :event_store_events_in_streams, [:stream, :position]
add_index :event_store_events, :event_type
add_index :event_store_events, :created_at

# Configure caching
Lyra.configure do |config|
  config.cache_aggregates = true
  config.snapshot_frequency = 100  # Snapshot every 100 events
end
```

### Step 4.5: Monitoring and Observability

Set up comprehensive monitoring:

```ruby
# config/initializers/lyra_monitoring.rb
ActiveSupport::Notifications.subscribe('lyra.event_published') do |name, start, finish, id, payload|
  duration = (finish - start) * 1000

  Rails.logger.info "Event published: #{payload[:event_type]} (#{duration}ms)"

  # Send to metrics system (StatsD, Prometheus, etc.)
  StatsD.increment('lyra.events.published')
  StatsD.timing('lyra.event_publish_duration', duration)
end

ActiveSupport::Notifications.subscribe('lyra.aggregate_loaded') do |name, start, finish, id, payload|
  duration = (finish - start) * 1000
  events_count = payload[:events_count]

  Rails.logger.info "Aggregate loaded: #{payload[:aggregate_id]} (#{events_count} events, #{duration}ms)"

  StatsD.timing('lyra.aggregate_load_duration', duration)
  StatsD.histogram('lyra.aggregate_events_count', events_count)
end
```

### Step 4.6: Continuous Validation

Run consistency checks regularly:

```ruby
# lib/tasks/lyra.rake
namespace :lyra do
  desc "Check state consistency for all models"
  task check_consistency: :environment do
    models = [User, Post, Comment]  # Your event-sourced models

    models.each do |model|
      puts "Checking #{model.name}..."
      discrepancies = Lyra::DualView.find_discrepancies(model)

      if discrepancies.empty?
        puts "  ✓ All #{model.count} records consistent"
      else
        puts "  ✗ Found #{discrepancies.count} discrepancies"
        # Alert, log, or fix
      end
    end
  end
end

# Schedule via cron
# 0 * * * * cd /app && bundle exec rake lyra:check_consistency
```

---

## Rollback Strategies

### Immediate Rollback (< 5 minutes)

If issues detected in production:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  # Revert to monitor mode
  config.mode = :monitor

  # This immediately stops hijacking
  # CRUD operations resume normally
end

# Restart application
```

### Partial Rollback

Rollback specific models or operations:

```ruby
# Rollback User model only
class User < ApplicationRecord
  # Remove event sourcing
  # monitor_with_lyra  # Comment out
end

# Or rollback specific operations
Lyra.configure do |config|
  config.mode = :hybrid
  config.hijack_operations = [:create]  # Only creates, revert updates/deletes
end
```

### Data Rollback

If data corruption detected:

```ruby
# Rebuild CRUD state from events
User.find_each do |user|
  # Get event-sourced state
  state = Lyra::StateProjection.rebuild_state(User, user.id)

  # Update CRUD record
  user.update_columns(state)
end
```

---

## Common Challenges

### Challenge 1: Eventual Consistency

**Problem**: Event processing may be async, causing temporary inconsistencies.

**Solution**:
```ruby
# Use synchronous event handlers
Lyra.configure do |config|
  config.async_event_handlers = false
end

# Or implement polling for critical operations
def wait_for_consistency(model, id, timeout: 5)
  Timeout.timeout(timeout) do
    loop do
      comparison = Lyra::DualView.new(model, id).compare
      break if comparison[:differences][:no_differences]
      sleep 0.1
    end
  end
end
```

### Challenge 2: High Event Volume

**Problem**: Too many events slow down aggregate loading.

**Solution**:
```ruby
# Implement snapshotting
class UserAggregate < Lyra::Aggregate
  snapshot_frequency 100  # Snapshot every 100 events
end

# Clean up old events (after retention period)
rails lyra:cleanup_old_events
```

### Challenge 3: Schema Evolution

**Problem**: Event schemas change over time.

**Solution**:
```ruby
# Use event versioning
class UserCreated < Lyra::Event
  schema_version 2

  def migrate_from_v1(old_data)
    old_data.merge(new_field: default_value)
  end
end

# Or use upcasters
class UserEventUpcaster
  def call(event)
    return event if event.metadata[:version] >= 2

    # Transform v1 to v2
    event.data[:new_field] = default_value
    event.metadata[:version] = 2
    event
  end
end
```

### Challenge 4: Transaction Boundaries

**Problem**: Need CRUD transaction semantics.

**Solution**:
```ruby
# Wrap in transaction
ActiveRecord::Base.transaction do
  user = User.create!(...)
  post = user.posts.create!(...)

  # Both succeed or both rollback
  # Events published only on commit
end
```

### Challenge 5: Complex Queries

**Problem**: Event-sourced data harder to query.

**Solution**:
```ruby
# Create read model projections
class UserStatsProjection < Lyra::Projection
  subscribe_to "UserCreated", "UserUpdated"

  def apply_user_created(event)
    UserStats.create!(
      user_id: event.model_id,
      posts_count: 0,
      comments_count: 0
    )
  end

  def apply_post_created(event)
    UserStats.find_by(user_id: event.data[:user_id])
      .increment!(:posts_count)
  end
end

# Query read model instead of events
UserStats.where("posts_count > 100").order(posts_count: :desc)
```

---

## Best Practices

### 1. Start Small
- Begin with one non-critical model
- Expand gradually as confidence grows
- Don't rush to hijack mode

### 2. Comprehensive Testing
```ruby
# test/integration/event_sourcing_test.rb
class EventSourcingTest < ActionDispatch::IntegrationTest
  test "user lifecycle maintains consistency" do
    user = User.create!(email: "test@example.com", name: "Test")
    user.update!(name: "Updated")
    user.destroy!

    # Verify events
    stream = "User-#{user.id}"
    events = Rails.configuration.event_store.read.stream(stream).to_a
    assert_equal 3, events.count

    # Verify state consistency
    comparison = Lyra::DualView.new(User, user.id).compare
    assert comparison[:differences][:no_differences]
  end
end
```

### 3. Monitor Everything
- Log all events
- Track performance metrics
- Alert on discrepancies
- Regular consistency checks

### 4. Document Decisions
Keep a migration journal:

```markdown
# Migration Journal

## 2025-01-15: Enabled monitoring for User model
- Decision: Start with User (10k records)
- Reason: Non-critical, good lifecycle
- Next review: 2025-01-22

## 2025-01-22: Review findings
- Events captured: 15,234
- Discrepancies: 0
- Performance: +5% on creates
- Decision: Proceed to hybrid mode
```

### 5. Plan for Failure
- Always have rollback plan
- Test rollback procedure
- Keep CRUD as safety net
- Monitor error rates closely

### 6. Privacy First
- Define PAM policies before transformation
- Test PII masking
- Verify retention policies
- Document legal basis

---

## Conclusion

Migrating from CRUD to event sourcing is a journey, not a destination. Lyra's gradual approach allows you to:

- ✅ Learn and adapt along the way
- ✅ Minimize risk at every step
- ✅ Maintain business continuity
- ✅ Rollback if needed
- ✅ Achieve full event sourcing benefits

**Remember**: There's no rush. Monitor mode has value on its own (audit trails, privacy compliance). Take time to understand your system before committing to full event sourcing.

**Next Steps**:
1. Review [Architecture Documentation](ARCHITECTURE.md)
2. Explore [Example Application](../examples/blog_app/README.md)
3. Study [Privacy Compliance Guide](PRIVACY_COMPLIANCE.md)

Good luck with your migration!
