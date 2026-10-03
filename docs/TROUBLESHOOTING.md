# Lyra Troubleshooting Guide

Common issues, debugging techniques, and solutions for Lyra.

## Table of Contents

1. [Quick Diagnostics](#quick-diagnostics)
2. [Installation Issues](#installation-issues)
3. [Event Store Issues](#event-store-issues)
4. [State Consistency Issues](#state-consistency-issues)
5. [Performance Issues](#performance-issues)
6. [Privacy & PII Issues](#privacy--pii-issues)
7. [Mode Switching Issues](#mode-switching-issues)
8. [Debugging Techniques](#debugging-techniques)
9. [Common Error Messages](#common-error-messages)
10. [Getting Help](#getting-help)

---

## Quick Diagnostics

Run these checks first to identify the issue category:

```ruby
# Check Lyra configuration
rails console
> Lyra.config.mode
> Lyra.config.event_store
> Lyra.config.privacy_enabled

# Check event store connectivity
> Rails.configuration.event_store.read.count
> # Should return a number, not an error

# Check if models are monitored
> User.respond_to?(:lyra_monitored?)
> # Should return true

# Check recent events
> Rails.configuration.event_store.read.limit(10).to_a
> # Should return array of events

# Check for discrepancies
> Lyra::DualView.find_discrepancies(User).count
> # Should return 0 for consistency
```

---

## Installation Issues

### Error: "uninitialized constant Lyra"

**Cause**: Lyra not properly installed or loaded.

**Solution**:
```bash
# Verify installation
bundle list | grep lyra

# If not installed
bundle install

# Restart Rails
rails restart  # or kill and restart server
```

### Error: "uninitialized constant RailsEventStore"

**Cause**: RailsEventStore not installed or configured.

**Solution**:
```ruby
# Add to Gemfile
gem 'rails_event_store', '~> 2.14'

# Install
bundle install

# Generate migration
rails generate rails_event_store_active_record:migration

# Run migration
rails db:migrate

# Configure in application.rb
module YourApp
  class Application < Rails::Application
    config.to_prepare do
      Rails.configuration.event_store = RailsEventStore::Client.new
    end
  end
end
```

### Error: "LoadError: cannot load such file -- lyra"

**Cause**: Lyra path incorrect in Gemfile.

**Solution**:
```ruby
# Gemfile
gem 'orfeas_lyra', path: '../path/to/lyra'  # Adjust path

# Or from git
gem 'orfeas_lyra', git: 'https://github.com/mpantel/lyra-engine.git'

# Then
bundle install
```

---

## Event Store Issues

### Events Not Being Captured

**Symptom**: CRUD operations execute but no events in event store.

**Diagnosis**:
```ruby
# Check if model is monitored
rails console
> User.instance_methods.grep(/lyra/)
> # Should show lyra-related methods

# Check event store count before/after operation
> before = Rails.configuration.event_store.read.count
> User.create!(email: "test@example.com", name: "Test")
> after = Rails.configuration.event_store.read.count
> puts "Events created: #{after - before}"
```

**Solutions**:

1. **Missing monitor_with_lyra call**:
```ruby
class User < ApplicationRecord
  monitor_with_lyra  # Add this line
end

# Restart Rails
```

2. **Lyra not in monitor or hijack mode**:
```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor  # Must be :monitor or :hijack
end
```

3. **Event store not configured**:
```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.event_store = Rails.configuration.event_store  # Set this
end
```

### Error: "PG::UndefinedTable: ERROR: relation 'event_store_events' does not exist"

**Cause**: Event store tables not created.

**Solution**:
```bash
rails generate rails_event_store_active_record:migration
rails db:migrate

# If already generated but not run
rails db:migrate

# Check tables exist
rails dbconsole
> \dt event_store_events
```

### Events Not Readable from Event Store

**Symptom**: Events published but `read.count` returns 0.

**Diagnosis**:
```ruby
# Check if events are in database
ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM event_store_events").first
```

**Solution**:

1. **Wrong repository configuration**:
```ruby
# config/application.rb
config.to_prepare do
  Rails.configuration.event_store = RailsEventStore::Client.new(
    repository: RailsEventStoreActiveRecord::EventRepository.new(
      serializer: YAML  # or JSON
    )
  )
end
```

2. **Transactions not committed** (in tests):
```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  self.use_transactional_tests = false  # Disable for event store tests
end
```

### Error: `Lyra::EventStoreUnavailableError` / "Failed to publish event … run bin/rails lyra:repair"

**Symptom:** an event could not be stored. The error's `cause` is the store's own error, and its
message names the stream.

What happened to the write depends on the mode:

| Mode | Policy | The write |
|---|---|---|
| Hijack, event sourcing (any projection mode) | fail-closed | raises `EventStoreUnavailableError` and rolls back: nothing in the table, nothing in the log |
| Monitor | log-and-continue | stands; the error is logged, and the record's stream falls behind its row |

**Solution:** fix the cause (look at `error.cause`). In Monitor, then bring the lagging streams
back in line from the tables:

```bash
bin/rails lyra:repair DRY_RUN=1        # list the records out of line
bin/rails lyra:repair                  # append the events that bring them back
bin/rails lyra:repair MODELS=User,Order
```

Each repaired stream gets one event (`Imported`, `Updated` with the differing columns, or
`Destroyed`, metadata `source: "lyra_repair"`) that makes it replay to its row; the detail of the
lost changes is not recoverable. Repair refuses to run in Hijack or event sourcing, where the
events are authoritative: there, rebuild the tables (`bin/rails lyra:mode:check ... REBUILD=1`).
Sampled verification (`config.dual_view_sample_rate`) reports such records as they happen.

---

## State Consistency Issues

### CRUD State != Event-Sourced State

**Symptom**: `Lyra::DualView` shows differences between views.

**Diagnosis**:
```ruby
user = User.first
comparison = Lyra::DualView.new(User, user.id).compare

pp comparison[:differences]
# Examine which fields differ
```

**Common Causes and Solutions**:

#### 1. Events Missing

**Cause**: Some CRUD operations occurred before Lyra was enabled.

**Solution**:
```ruby
# Backfill events for existing records
User.find_each do |user|
  event = Lyra::EventMapper.map_operation(
    User,
    :created,
    {
      attributes: user.attributes,
      changes: {},
      user_id: 'system'
    }
  )

  stream = "User-#{user.id}"
  Rails.configuration.event_store.publish(event, stream_name: stream)
end
```

#### 2. Event Data Incorrect

**Cause**: Event handlers not applying changes correctly.

**Solution**:
```ruby
# Check aggregate event handlers
class UserAggregate < Lyra::Aggregate
  private

  def apply_user_updated(event)
    # Make sure this applies ALL changes
    event.changes.each do |field, (old_val, new_val)|
      set_state(field.to_sym, new_val)  # Apply new value
    end
  end
end
```

#### 3. Timestamp Differences

**Cause**: CRUD uses `updated_at`, events use `timestamp`.

**Solution**: Timestamps may differ slightly; this is normal. Ignore timestamp fields in comparisons if needed.

#### 4. Database Updates Outside Rails

**Cause**: Direct SQL updates bypass Lyra.

**Solution**: Always use ActiveRecord for updates, or manually publish events:
```ruby
# After direct SQL update
connection.execute("UPDATE users SET name = 'New' WHERE id = 123")

# Manually publish event
event = Lyra::EventMapper.map_operation(User, :updated, {
  attributes: User.find(123).attributes,
  changes: { name: ["Old", "New"] }
})
Rails.configuration.event_store.publish(event, stream_name: "User-123")
```

### State Reconstruction Fails

**Symptom**: `StateProjection.rebuild_state` raises error or returns incorrect state.

**Diagnosis**:
```ruby
events = Rails.configuration.event_store.read.stream("User-#{user_id}").to_a
puts "Event count: #{events.count}"
events.each_with_index do |event, i|
  puts "#{i + 1}. #{event.event_type}: #{event.data[:operation]}"
end

# Try rebuilding step by step
projection = Lyra::StateProjection.new
state = {}
events.each do |event|
  puts "Before: #{state.inspect}"
  state = projection.send(:apply_operation, state, event)
  puts "After: #{state.inspect}"
rescue => e
  puts "Error at event #{event.event_type}: #{e.message}"
  break
end
```

**Solution**: Check event handler implementation in `StateProjection#rebuild_from_events`.

---

## Performance Issues

### Slow Event Publishing

**Symptom**: CRUD operations take much longer with Lyra enabled.

**Diagnosis**:
```ruby
require 'benchmark'

Benchmark.bm do |x|
  x.report("create") { User.create!(email: "test@example.com", name: "Test") }
  x.report("update") { User.first.update!(name: "Updated") }
end
```

**Solutions**:

#### 1. Synchronous Event Handlers

**Cause**: Event handlers processing synchronously.

**Solution**:
```ruby
# Enable async processing
Lyra.configure do |config|
  config.async_event_handlers = true
end

# Or use background jobs
class MyProjection < Lyra::Projection
  include ActiveJob::Performs

  def handle(event)
    perform_later(event)  # Process in background
  end
end
```

#### 2. Too Many Projections

**Cause**: Many projections subscribed to same events.

**Solution**: Consolidate projections or make them async.

#### 3. Event Store Write Contention

**Cause**: High write volume to event store.

**Solution**:
```ruby
# Add database indexes
add_index :event_store_events_in_streams, [:stream, :position]
add_index :event_store_events, :event_type
add_index :event_store_events, :created_at

# Or use partitioning for high volume
```

### Slow Aggregate Loading

**Symptom**: Loading aggregates takes too long.

**Diagnosis**:
```ruby
require 'benchmark'

time = Benchmark.realtime do
  aggregate = UserAggregate.load(user_id)
end

stream = "User-#{user_id}"
events = Rails.configuration.event_store.read.stream(stream).to_a

puts "Time: #{time}s"
puts "Events: #{events.count}"
puts "Time per event: #{(time / events.count * 1000).round(2)}ms"
```

**Solutions**:

#### 1. Enable Snapshotting

```ruby
class UserAggregate < Lyra::Aggregate
  snapshot_frequency 100  # Snapshot every 100 events

  def take_snapshot
    {
      version: version,
      state: @state.dup,
      timestamp: Time.current
    }
  end

  def load_snapshot(snapshot)
    @version = snapshot[:version]
    @state = snapshot[:state]
  end
end
```

#### 2. Cache Aggregates

```ruby
Lyra.configure do |config|
  config.cache_aggregates = true
  config.aggregate_cache_ttl = 5.minutes
end
```

#### 3. Reduce Event Count

Archive or compact old events:
```ruby
# Compact events older than 1 year
User.find_each do |user|
  stream = "User-#{user.id}"
  events = Rails.configuration.event_store.read.stream(stream).to_a

  old_events = events.select { |e| e.timestamp < 1.year.ago }
  next if old_events.empty?

  # Create snapshot
  projection = Lyra::StateProjection.new
  snapshot_state = projection.rebuild_from_events(old_events)

  # Create compacted event
  compacted_event = Event.new(
    event_type: "UserStateSnapshot",
    data: { state: snapshot_state, original_events: old_events.count }
  )

  # Archive old events, keep snapshot
  # (Implementation depends on event store)
end
```

---

## Privacy & PII Issues

### PII Not Detected

**Symptom**: Fields that should be PII are not detected.

**Diagnosis**:
```ruby
attributes = { email: "test@example.com", user_email: "test@example.com" }
pii = Lyra::Privacy::PIIDetector.detect(attributes)

pp pii
# Check if expected fields are present
```

**Solution**:

PII detection uses regex patterns. Field must match patterns like:
- Email: `email`, `email_address`, `e_mail`
- Name: `name`, `first_name`, `last_name`, `full_name`

If your field has a different name:

```ruby
# Option 1: Rename field to match pattern
rename_column :users, :user_email, :email

# Option 2: Define custom PII pattern
class CustomPIIDetector < Lyra::Privacy::PIIDetector
  def self.pii_patterns
    super.merge(
      custom_email: /user_email|contact/
    )
  end
end

Lyra::Privacy::PIIDetector = CustomPIIDetector
```

### PII Not Masked

**Symptom**: `PIIMasker.mask` not masking expected fields.

**Solution**:

PIIMasker only masks detected PII. Check detection first:
```ruby
pii_fields = Lyra::Privacy::PIIDetector.detect(attributes)
# If field not in pii_fields, it won't be masked

# Force masking
masked = attributes.transform_values { |v| v.is_a?(String) ? "[REDACTED]" : v }
```

### PAM Policy Not Applied

**Symptom**: Privacy policy not enforcing rules.

**Diagnosis**:
```ruby
policy = PamDsl.policies[:my_policy]
pp policy

# Check if model references policy
User.lyra_config[:privacy_policy]  # Should return :my_policy
```

**Solution**:
```ruby
# Make sure policy is defined
# config/initializers/privacy_policies.rb
PamDsl.define_policy :my_policy do
  # ...
end

# Make sure model references it
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_policy
end

# Restart Rails
```

---

## Mode Switching Issues

### Can't Switch from Monitor to Hijack

**Symptom**: `enable_hijack!` doesn't take effect.

**Solution**:
```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.enable_hijack!
end

# Restart Rails (required!)
rails restart

# Verify
rails console
> Lyra.config.hijack_mode?  # Should return true
```

### Operations Still Using CRUD in Hijack Mode

**Symptom**: Database records updated directly, not through events.

**Diagnosis**:
```ruby
# Check mode
Lyra.config.mode  # Should be :hijack

# Check if model is monitored
User.lyra_monitored?  # Should be true

# Try operation and check events
before = Rails.configuration.event_store.read.count
user = User.create!(email: "test@example.com")
after = Rails.configuration.event_store.read.count

puts "Events created: #{after - before}"  # Should be > 0
puts "User ID: #{user.id}"  # Should be set
```

**Solution**:

Hijack mode requires full Lyra integration. Check:

1. **Commands implemented**:
```ruby
# lib/lyra/commands/ should have:
# - create_command.rb
# - update_command.rb
# - destroy_command.rb
```

2. **Callbacks configured**:
```ruby
# In monitor_with_lyra, callbacks should intercept
class User < ApplicationRecord
  monitor_with_lyra  # This sets up callbacks

  # Callbacks should be present:
  # before_create :lyra_handle_create (in hijack mode)
end
```

---

## Debugging Techniques

### Enable Debug Logging

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.logger = Logger.new(Rails.root.join('log', 'lyra_debug.log'))
  config.logger.level = Logger::DEBUG
end

# Or temporarily in console
Lyra.config.logger.level = Logger::DEBUG
```

### Inspect Events in Detail

```ruby
# View latest event
event = Rails.configuration.event_store.read.last

puts "Event Type: #{event.event_type}"
puts "Event ID: #{event.event_id}"
puts "Timestamp: #{event.timestamp}"
puts "\nData:"
pp event.data
puts "\nMetadata:"
pp event.metadata

# View event stream for record
stream = "User-123"
events = Rails.configuration.event_store.read.stream(stream).to_a

events.each_with_index do |event, i|
  puts "#{i + 1}. #{event.event_type} at #{event.timestamp}"
  puts "   Data: #{event.data.inspect}"
end
```

### Trace Event Flow

```ruby
# Enable event tracing
module EventTracer
  def publish(event, stream_name:)
    puts "=== Publishing Event ==="
    puts "Stream: #{stream_name}"
    puts "Type: #{event.event_type}"
    puts "Data: #{event.data.inspect}"
    puts "======================="

    super
  end
end

Rails.configuration.event_store.singleton_class.prepend(EventTracer)
```

### Check Aggregate State

```ruby
# Load aggregate and inspect
aggregate = UserAggregate.load(user_id)

puts "Version: #{aggregate.version}"
puts "Changes: #{aggregate.changes.count}"
puts "\nState:"
pp aggregate.instance_variable_get(:@state)

# Manually rebuild to see each step
events = Rails.configuration.event_store.read.stream("User-#{user_id}").to_a
aggregate = UserAggregate.new

events.each_with_index do |event, i|
  puts "\n=== Event #{i + 1}: #{event.event_type} ==="
  puts "Before: #{aggregate.instance_variable_get(:@state)}"

  aggregate.apply(event)

  puts "After: #{aggregate.instance_variable_get(:@state)}"
end
```

### Profile Performance

```ruby
# Benchmark operations
require 'benchmark'

Benchmark.bm(20) do |x|
  x.report("create (no Lyra)") do
    # Temporarily disable Lyra
    Lyra.configure { |c| c.mode = :disabled }
    100.times { User.create!(email: "#{rand}@example.com", name: "Test") }
  end

  x.report("create (monitor)") do
    Lyra.configure { |c| c.mode = :monitor }
    100.times { User.create!(email: "#{rand}@example.com", name: "Test") }
  end

  x.report("aggregate load") do
    100.times { UserAggregate.load(User.first.id) }
  end
end
```

---

## Common Error Messages

### "NoMethodError: undefined method `lyra_monitored?'"

**Cause**: Model not properly configured with `monitor_with_lyra`.

**Solution**: Add `monitor_with_lyra` to model class.

### "NameError: uninitialized constant UserAggregate"

**Cause**: Aggregate class not defined or not loaded.

**Solution**:
```ruby
# Create aggregate class
# app/aggregates/user_aggregate.rb
class UserAggregate < Lyra::Aggregate
  # ...
end

# Ensure autoloading configured
# config/application.rb
config.eager_load_paths << Rails.root.join('app', 'aggregates')
```

### "TypeError: no implicit conversion of Symbol into String"

**Cause**: Event data keys mismatch (String vs Symbol).

**Solution**: Ensure consistent key types:
```ruby
# Use string keys
event.data['model_class']  # Correct

# Or symbolize
event.data.symbolize_keys[:model_class]
```

### "ArgumentError: Stream name cannot be nil"

**Cause**: Event published without stream name.

**Solution**:
```ruby
# Always provide stream name
stream_name = "User-#{user.id}"
Rails.configuration.event_store.publish(event, stream_name: stream_name)
```

### "ActiveRecord::RecordInvalid: Validation failed"

**Cause**: Validation errors when creating/updating records.

**Solution**: Check validation errors:
```ruby
user = User.new(email: "invalid")
unless user.valid?
  pp user.errors.full_messages
end

# In hijack mode, validations still apply
# Ensure event data passes validations
```

---

## Getting Help

### Gather Information

Before asking for help, collect:

1. **Lyra Configuration**:
```ruby
rails console
> pp Lyra.config
```

2. **Rails Version**:
```bash
rails --version
ruby --version
```

3. **Event Store Info**:
```ruby
> Rails.configuration.event_store.class
> Rails.configuration.event_store.read.count
```

4. **Error Details**:
```ruby
# Full stack trace
> begin
>   # ... operation that fails
> rescue => e
>   puts e.full_message
> end
```

5. **Model Configuration**:
```ruby
> User.lyra_config
```

### Check Logs

```bash
# Rails log
tail -f log/development.log

# Lyra log (if configured)
tail -f log/lyra_events.log

# Look for errors
grep ERROR log/development.log
```

### Minimal Reproduction

Create minimal example:
```ruby
# test_lyra.rb
require_relative 'config/environment'

Lyra.configure do |config|
  config.mode = :monitor
  config.event_store = Rails.configuration.event_store
end

class TestModel < ApplicationRecord
  self.table_name = 'users'
  monitor_with_lyra
end

# Test operation
TestModel.create!(email: "test@example.com")

# Check events
puts Rails.configuration.event_store.read.count
```

### Contact Support

- **Email**: mpantel@aegean.gr
- **GitHub Issues**: [Repository Issues](https://github.com/mpantel/lyra-engine/issues)
- **Stack Overflow**: Tag questions with `lyra` and `event-sourcing`

Include:
- Lyra version
- Rails version
- Ruby version
- Error message and stack trace
- Configuration
- Minimal reproduction steps

---

## Additional Resources

- [API Reference](API_REFERENCE.md)
- [Migration Guide](MIGRATION_GUIDE.md)
- [Example Application](../examples/blog_app/README.md)
- [Main Documentation](../README.md)
