# Getting Started with Lyra

This guide will walk you through setting up Lyra in your Rails application.

## Prerequisites

- Ruby 3.4.5+ (tested up to 4.0)
- Rails 8.0+
- PostgreSQL (recommended) or SQLite

## Installation

### Step 1: Add Lyra to your Gemfile

```ruby
# Gemfile
gem 'orfeas_lyra', path: 'path/to/lyra'  # For local development
# or
gem 'orfeas_lyra', git: 'https://github.com/mpantel/lyra-engine'  # From git
```

### Step 2: Install Dependencies

```bash
bundle install
```

### Step 3: Generate Rails Event Store Migration

```bash
rails generate rails_event_store_active_record:migration
```

> **Note**: Lyra requires RailsEventStore v2.0+ which includes the `valid_at` column for bi-temporal event sourcing. The generator will create the appropriate schema.

### Step 4: Run Migrations

```bash
rails db:migrate
```

### Step 5: Create Lyra Initializer

Create `config/initializers/lyra.rb`:

```ruby
Lyra.configure do |config|
  # Start with monitor mode (non-intrusive)
  config.mode = :monitor

  # Configure event store
  config.event_backend = :rails_event_store
  config.event_store = RailsEventStore::Client.new
end
```

### Step 6: Enable Monitoring on Models

Add `monitor_with_lyra` to your ActiveRecord models:

```ruby
class Order < ApplicationRecord
  # Enable Lyra monitoring
  monitor_with_lyra

  # Your existing code
  validates :total, presence: true
  belongs_to :customer
  has_many :line_items
end
```

### Step 7: Mount Lyra Routes (Optional)

To access the dashboard, add to `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Lyra::Engine => "/lyra"

  # Your other routes...
end
```

## Quick Start Example

### 1. Create a Simple Model

```bash
rails generate model Product name:string price:decimal stock:integer
rails db:migrate
```

### 2. Enable Lyra Monitoring

```ruby
# app/models/product.rb
class Product < ApplicationRecord
  monitor_with_lyra

  validates :name, presence: true
  validates :price, numericality: { greater_than: 0 }
  validates :stock, numericality: { greater_than_or_equal_to: 0 }
end
```

### 3. Perform CRUD Operations

```ruby
# Rails console
rails console

# Create a product
product = Product.create!(name: "Widget", price: 19.99, stock: 100)
# => CRUD: Product saved to database
# => EVENT: ProductCreated event published

# Update the product
product.update!(stock: 95)
# => CRUD: Product updated
# => EVENT: ProductUpdated event published

# Delete the product
product.destroy!
# => CRUD: Product deleted
# => EVENT: ProductDestroyed event published
```

### 4. Analyze Events

```ruby
# Compare CRUD state with event-sourced state
comparison = Lyra::DualView.new(Product, product.id).compare

puts comparison[:crud_view]
# => { exists: false } # (deleted)

puts comparison[:event_sourced_view]
# => { exists: true, state: {...}, events_count: 3 }

# View audit trail
audit = Lyra::DualView.new(Product, product.id).audit_trail
# => [
#      { operation: :created, timestamp: ..., attributes: {...} },
#      { operation: :updated, timestamp: ..., changes: { stock: [100, 95] } },
#      { operation: :destroyed, timestamp: ... }
#    ]
```

### 5. Access Dashboard

Visit `http://localhost:3000/lyra/dashboard` to see:
- All monitored models
- Event counts
- State comparisons
- Discrepancies

## Advanced Configuration

### Custom Event Names

```ruby
class Order < ApplicationRecord
  monitor_with_lyra(
    event_prefix: 'Order'  # Events will be OrderCreated, OrderUpdated, etc.
  )
end
```

### Namespaced Models

Lyra supports Rails engine namespaced models:

```ruby
module Billing
  class Invoice < ApplicationRecord
    monitor_with_lyra event_prefix: "Billing::Invoice"
  end
end
```

Event naming follows the convention `Billing::InvoiceCreated` → `Lyra::Events::BillingInvoiceCreated`.

### Custom Aggregates

```ruby
class OrderAggregate < Lyra::Aggregate
  def total
    get_state(:total)
  end

  def can_be_cancelled?
    !['shipped', 'delivered'].include?(get_state(:status))
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

class Order < ApplicationRecord
  monitor_with_lyra(
    event_prefix: 'Order',
    aggregate_class: OrderAggregate
  )
end
```

### Switching to Hijack Mode

After testing in monitor mode, enable hijack mode:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :hijack  # or config.enable_hijack!
  config.event_store = RailsEventStore::Client.new
end
```

Now CRUD operations will be routed through event sourcing!

## Example Applications

### Aegean E-Pay Testbed (Comprehensive)

For a complete working example, see the Aegean E-Pay testbed in `examples/aegean_epay_testbed/`.

```bash
cd examples/aegean_epay_testbed
bundle install
rails db:create db:migrate db:seed

# Run integration tests demonstrating all Lyra features
ruby test_lyra_integration.rb
```

### Blog App (Getting Started)

For a simpler introduction, see `examples/blog_app/`:

```bash
cd examples/blog_app
bundle install
rails db:create db:migrate db:seed
rails console
```

## Next Steps

1. **Read the Architecture Guide**: See `ARCHITECTURE.md` for detailed design
2. **Explore Examples**: Check `examples/usage_examples.rb` for code samples
3. **Customize Aggregates**: Create domain-specific aggregates
4. **Build Projections**: Create read models for queries
5. **Monitor Performance**: Track event publishing and state reconstruction
6. **Switch to Hijack**: When ready, enable full event sourcing

## Troubleshooting

### Events Not Being Published

1. Check that `monitor_with_lyra` is called in the model
2. Verify Rails Event Store is configured
3. Check database migrations are run
4. Look for errors in logs

### State Discrepancies

1. Use `Lyra::DualView.find_discrepancies(Model)` to identify issues
2. Check if records existed before Lyra was enabled
3. Verify event store tables exist

### Performance Issues

1. Consider async event publishing
2. Use snapshots for large event streams
3. Cache aggregates
4. Use projections for read-heavy queries

## Support

- Documentation: See README.md and ARCHITECTURE.md
- Examples: Check `examples/` directory
- Issues: Open a GitHub issue

## Resources

- [Rails Event Store Docs](https://railseventstore.org/)
- [Event Sourcing Pattern](https://martinfowler.com/eaaDev/EventSourcing.html)
- [CQRS](https://martinfowler.com/bliki/CQRS.html)
