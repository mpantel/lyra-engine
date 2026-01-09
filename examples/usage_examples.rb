# Lyra Usage Examples
# This file demonstrates how to use Lyra in different modes

# ============================================
# 1. MONITOR MODE - Non-intrusive logging
# ============================================

# Configure Lyra in monitor mode (in config/initializers/lyra.rb)
Lyra.configure do |config|
  config.mode = :monitor
end

# Regular CRUD operations work as normal, but events are logged
customer = Customer.create!(name: "John Doe", email: "john@example.com")
# => CRUD: Record saved to database
# => EVENT: CustomerCreated event published to event store

customer.update!(name: "Jane Doe")
# => CRUD: Record updated in database
# => EVENT: CustomerUpdated event published to event store

customer.destroy!
# => CRUD: Record deleted from database
# => EVENT: CustomerDestroyed event published to event store

# ============================================
# 2. DUAL VIEW COMPARISON
# ============================================

# Compare CRUD state vs Event-sourced state
comparison = Lyra::DualView.new(Customer, customer.id).compare

puts comparison[:crud_view]
# => { exists: true, attributes: {...}, timestamps: {...} }

puts comparison[:event_sourced_view]
# => { exists: true, state: {...}, events_count: 3, events_summary: [...] }

puts comparison[:differences]
# => { no_differences: true } or { field_name: { crud: val1, event_sourced: val2 } }

# Get audit trail from events
audit_trail = Lyra::DualView.new(Customer, customer.id).audit_trail
# => [
#      { operation: :created, timestamp: ..., user_id: ..., changes: {...} },
#      { operation: :updated, timestamp: ..., user_id: ..., changes: {...} },
#      { operation: :destroyed, timestamp: ..., user_id: ..., changes: {...} }
#    ]

# ============================================
# 3. BATCH ANALYSIS
# ============================================

# Find all discrepancies across all customers
discrepancies = Lyra::DualView.find_discrepancies(Customer)
# => Array of comparisons where CRUD state != Event-sourced state

# Analyze a specific record
analysis = Lyra::StateAnalyzer.analyze(Customer, customer.id)
puts analysis[:recommendations]
# => ["CRUD record exists but no events found - may have been created before Lyra was enabled"]

# ============================================
# 4. HIJACK MODE - Replace CRUD with Event Sourcing
# ============================================

# Switch to hijack mode
Lyra.configure do |config|
  config.mode = :hijack
  config.enable_hijack!
end

# Now CRUD operations are intercepted and routed through event sourcing
order = Order.create!(customer: customer, total: 100.00, status: 'pending')
# => COMMAND: CreateCommand processed
# => EVENT: OrderCreated event published
# => AGGREGATE: OrderAggregate updated
# => CRUD: Record saved with ID from event sourcing

order.update!(status: 'confirmed')
# => COMMAND: UpdateCommand processed
# => EVENT: OrderUpdated event published
# => AGGREGATE: OrderAggregate updated
# => CRUD: Record updated

order.destroy!
# => COMMAND: DestroyCommand processed
# => EVENT: OrderDestroyed event published
# => AGGREGATE: OrderAggregate updated
# => CRUD: Record deleted

# ============================================
# 5. REBUILDING STATE FROM EVENTS
# ============================================

# Rebuild current state from event stream
state = Lyra::StateProjection.rebuild_state(Order, order_id)
# => { total: 100.00, status: 'confirmed', customer_id: 1, ... }

# Load aggregate from events
aggregate = OrderAggregate.load(order_id)
# => OrderAggregate instance with state rebuilt from events

# ============================================
# 6. CUSTOM EVENT MAPPING
# ============================================

# Register a custom event mapper
class OrderEventMapper < Lyra::EventMapper
  def event_data
    super.merge(
      order_specific_data: {
        total: data[:attributes]['total'],
        items_count: data[:attributes]['items_count']
      }
    )
  end
end

Lyra::EventMapper.register_mapper(Order, OrderEventMapper)

# ============================================
# 7. DASHBOARD API
# ============================================

# Access dashboard endpoints:
# GET /lyra/dashboard
# => Overview of all monitored models

# GET /lyra/dashboard/model/Customer
# => Overview for Customer model

# GET /lyra/dashboard/compare/Customer/123
# => Compare CRUD vs Event-sourced state for Customer 123

# GET /lyra/dashboard/discrepancies/Customer
# => Find all discrepancies for Customer model

# ============================================
# 8. CUSTOM AGGREGATES
# ============================================

class OrderAggregate < Lyra::Aggregate
  def total
    get_state(:total)
  end

  def status
    get_state(:status)
  end

  def can_be_cancelled?
    !['shipped', 'delivered', 'cancelled'].include?(status)
  end

  private

  def apply_order_created(event)
    @id = event.model_id
    set_state(:total, event.attributes['total'])
    set_state(:status, 'pending')
  end

  def apply_order_confirmed(event)
    set_state(:status, 'confirmed')
  end

  def apply_order_cancelled(event)
    set_state(:status, 'cancelled')
  end
end

# Use custom aggregate
Order.monitor_with_lyra(aggregate_class: OrderAggregate)

# ============================================
# 9. SWITCHING BETWEEN MODES
# ============================================

# Start in monitor mode to observe behavior
Lyra.config.enable_monitor!

# Perform operations and analyze
100.times { |i| Customer.create!(name: "Customer #{i}", email: "customer#{i}@example.com") }

# Check for discrepancies
discrepancies = Lyra::DualView.find_discrepancies(Customer)

# If everything looks good, switch to hijack mode
if discrepancies.empty?
  Lyra.config.enable_hijack!
  puts "Switched to event sourcing mode!"
end

# ============================================
# 10. PLUGGABLE EVENT BACKEND
# ============================================

# Use custom event store
class MyCustomEventStore < Lyra::CustomEventStoreAdapter
  def publish(event, stream_name:)
    # Custom implementation
  end

  def read_stream(stream_name)
    # Custom implementation
  end
end

Lyra.configure do |config|
  config.event_backend = :custom
  config.event_store = MyCustomEventStore.new
end
