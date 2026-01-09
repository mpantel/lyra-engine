# Projections for Data Access Monitoring in Lyra

## Overview

Lyra implements a sophisticated projection system for monitoring data access through event sourcing. Projections are "read models" that reconstruct application state from immutable events, providing complete audit trails and privacy compliance capabilities.

---

## 1. Core Projection Architecture

### Base Projection Class

**Location:** `/lib/lyra/projection.rb`

```ruby
module Lyra
  class Projection
    def self.handle(event)
      new.handle(event)
    end

    def self.subscribe_to(*event_types)
      event_types.each do |event_type|
        Lyra.config.event_store.subscribe(self, to: [event_type])
      end
    end

    def handle(event)
      method_name = "apply_#{event.class.name.demodulize.underscore}"
      send(method_name, event) if respond_to?(method_name, true)
    end
  end
end
```

**Key Features:**
- Projections subscribe to specific event types
- Event handlers use convention-based method dispatch (`apply_*`)
- Non-intrusive event processing
- Composable read model system

---

## 2. Projection Types

### StateProjection - Current State Reconstruction

Rebuilds the current state of an entity from its complete event stream:

```ruby
class StateProjection < Projection
  def self.rebuild_state(model_class, model_id)
    stream_name = "#{model_class.name}-#{model_id}"
    events = Lyra.config.event_store.read.stream(stream_name).to_a
    new.rebuild_from_events(events)
  end

  def rebuild_from_events(events)
    state = {}
    events.each do |event|
      case event.operation
      when :created
        state = event.attributes
      when :updated
        state.merge!(event.changes.transform_values { |v| v.last })
      when :destroyed
        state[:deleted] = true
        state[:deleted_at] = event.timestamp
      end
    end
    state
  end
end
```

**Use Cases:**
- Verify current record state matches database
- State validation in dual-view comparisons
- Aggregate reconstruction

### AuditProjection - Complete Access History

Provides complete audit trail of all CRUD operations:

```ruby
class AuditProjection < Projection
  def self.audit_trail(model_class, model_id)
    stream_name = "#{model_class.name}-#{model_id}"
    events = Lyra.config.event_store.read.stream(stream_name).to_a

    events.map do |event|
      {
        operation: event.operation,
        timestamp: event.timestamp,
        user_id: event.metadata[:user_id],
        changes: event.changes,
        attributes: event.attributes
      }
    end
  end
end
```

**Provides:**
- Complete who-what-when audit logs
- Field-level change tracking
- User action attribution
- Temporal data lineage

---

## 3. Data Access Monitoring Integration

### CrudInterceptor

**Location:** `/lib/lyra/interceptors/crud_interceptor.rb:171-196`

The interception layer monitors all CRUD operations:

```ruby
module Lyra::Interceptors::CrudInterceptor
  # Monitor mode: after callbacks that log events
  def lyra_intercept_create
    event_data = build_event_data(:created)
    publish_event(:created, event_data)
  end

  def build_event_data(operation)
    {
      model_class: self.class.name,
      model_id: id,
      operation: operation,
      attributes: attributes.except("created_at", "updated_at"),
      changes: previous_changes,
      timestamp: Time.current,
      metadata: {
        user_id: lyra_current_user_id,
        request_id: lyra_current_request_id,
        correlation_id: Lyra::Correlation.current_id,
        action_id: lyra_current_action_id,
        user_action: lyra_current_user_action
      }
    }
  end
end
```

**Tracking Includes:**
- User ID and request context
- Request correlation IDs
- User actions and controller context
- Complete attribute snapshots
- Before/after changes

---

## 4. Privacy-Aware Data Access Monitoring

### PolicyIntegration

**Location:** `/lib/lyra/privacy/policy_integration.rb:37-62`

Integrates PAM DSL privacy policies with projection system:

```ruby
class Lyra::Privacy::PolicyIntegration
  def validate_access!(field_names, purpose, consent_status = {})
    @policy.validate_access!(
      field_names,
      purpose,
      consent_granted: consent_status[:granted] || false,
      consent_granted_at: consent_status[:granted_at]
    )
  end

  def detect_pii(attributes)
    pii_fields = {}
    attributes.each do |key, value|
      field_name = key.to_sym
      begin
        field = @policy.get_field(field_name)
        pii_fields[key] = {
          type: field.type,
          value: value,
          sensitive: field.sensitive?,
          sensitivity: field.sensitivity
        }
      rescue PamDsl::InvalidFieldError
        # Fallback to PIIDetector
      end
    end
    pii_fields
  end

  def mask_pii(field_name, value, context = :display)
    field = @policy.get_field(field_name)
    field.apply_transformation(context, value)
  end
end
```

**Key Capabilities:**
- Purpose-based access validation
- Field-level sensitivity classification
- Context-aware PII masking (display, logging, API)
- Consent requirement checking
- Retention duration enforcement

---

## 5. Privacy Policies Configuration

### Policy Definition

**Location:** `/config/privacy_policies.rb`

Example: University System Policy with PAM DSL:

```ruby
PamDsl.define_policy :university_system do
  # Field definitions
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication, :enrollment, :payment_processing
    transform :display do |value|
      local, domain = value.split('@')
      "#{local[0]}***@#{domain}"
    end
    transform :log do |value|
      "***EMAIL***"
    end
  end

  field :ssn, type: :ssn, sensitivity: :restricted do
    allow_for :legal_compliance, :financial_aid
    transform :display do |value|
      "***-**-#{value[-4..]}"
    end
  end

  # Purpose definitions
  purpose :enrollment do
    describe "Student enrollment and registration"
    basis :contract
    requires :email, :name, :student_id
    optionally :phone, :address
  end

  # Retention policies
  retention do
    for_model 'Student' do
      keep_for 10.years
      field :email, duration: 2.years
      field :academic_records, duration: 50.years
      on_expiry :archive
    end
  end

  # Consent requirements
  consent do
    for_purpose :marketing do
      required!
      granular!
      expires_in 2.years
    end
  end
end
```

**Policy Components:**
- **Fields**: PII classification with sensitivity levels (public, internal, confidential, restricted)
- **Purposes**: Data processing reasons with GDPR legal bases
- **Retention**: Duration rules per model/field with expiry strategies
- **Consent**: Requirements, granularity, and withdrawal management

---

## 6. Event Flow Analysis

### EventFlow Class

**Location:** `/lib/lyra/event_flow.rb`

Advanced projection system for analyzing data access patterns:

```ruby
class Lyra::EventFlow
  def flow_data
    events = load_events
    grouped = group_by_correlation(events)
    {
      timeline: build_timeline(events),
      flows: build_flows(grouped),
      statistics: calculate_statistics(events),
      privacy_impact: analyze_privacy_impact(events)
    }
  end

  def data_lineage(field_name, model_class = nil)
    lineage = []
    events.each do |event|
      if event.attributes.key?(field_name) || event.changes.key?(field_name)
        lineage << {
          timestamp: event.timestamp,
          event_id: event.event_id,
          model: event.model_class,
          record_id: event.model_id,
          operation: event.operation,
          old_value: event.changes.dig(field_name, 0),
          new_value: event.changes.dig(field_name, 1),
          user_id: event.metadata[:user_id],
          action: event.metadata[:user_action]
        }
      end
    end
    lineage
  end

  def privacy_impact_analysis
    pii_inventory = Lyra::Privacy::PIIDetector.extract_from_event_stream(events)
    {
      total_events: events.count,
      events_with_pii: events.count { |e| has_pii?(e) },
      pii_categories: pii_inventory.keys,
      sensitive_data_present: pii_inventory.keys.any? { |k|
        [:ssn, :credit_card, :health, :biometric].include?(k)
      }
    }
  end
end
```

**Provides:**
- Complete event chains with correlation IDs
- Data lineage tracking (field-level history)
- Privacy impact assessment
- Risk calculation (sensitive data exposure)

---

## 7. Dual-View Comparison System

### DualView

**Location:** `/lib/lyra/dual_view.rb`

Compares database state with event-sourced projections:

```ruby
class Lyra::DualView
  def compare
    {
      crud_view: crud_state,
      event_sourced_view: event_sourced_state,
      differences: calculate_differences,
      metadata: {
        model_class: model_class.name,
        model_id: model_id,
        timestamp: Time.current,
        mode: Lyra.config.mode
      }
    }
  end

  def event_sourced_state
    stream_name = "#{model_class.name}-#{model_id}"
    events = Lyra.config.event_store.read.stream(stream_name).to_a
    state = StateProjection.new.rebuild_from_events(events)
    {
      exists: true,
      state: state,
      events_count: events.count,
      events_summary: events.map { |e|
        { type: e.class.name, operation: e.operation, timestamp: e.timestamp }
      }
    }
  end

  def audit_trail
    AuditProjection.audit_trail(model_class, model_id)
  end
end
```

**Validation Features:**
- State consistency verification
- Access pattern auditing
- Discrepancy detection
- Migration safety verification

---

## 8. PII Detection and Masking

### PIIDetector

**Location:** `/lib/lyra/privacy/pii_detector.rb`

Pattern-based PII detection with masking:

```ruby
class Lyra::Privacy::PIIDetector
  PII_PATTERNS = {
    email: /email/i,
    phone: /\b(phone|telephone|mobile|cell)\b/i,
    ssn: /\b(ssn|social_security|national_id)\b/i,
    credit_card: /\b(credit_card|card_number|ccn)\b/i,
    health: /\b(medical|health|diagnosis|prescription)\b/i,
    # ... more patterns
  }

  def self.detect(attributes)
    pii_fields = {}
    attributes.each do |key, value|
      pii_type = detect_field_type(key.to_s)
      if pii_type
        pii_fields[key] = {
          type: pii_type,
          value: value,
          sensitive: sensitive?(pii_type)
        }
      end
    end
    pii_fields
  end

  def self.mask(value, pii_type)
    case pii_type
    when :email
      mask_email(value)          # "u***@example.com"
    when :phone
      "***-***-#{value[-4..]}"  # "***-***-1234"
    when :ssn, :credit_card
      "***REDACTED***"
    when :name
      mask_name(value)           # "John ***"
    end
  end

  def self.extract_from_event_stream(events)
    pii_inventory = Hash.new { |h, k| h[k] = [] }
    events.each do |event|
      pii_fields = detect(event.attributes)
      pii_fields.each do |field, info|
        pii_inventory[info[:type]] << {
          event_id: event.event_id,
          field: field,
          timestamp: event.timestamp,
          model_class: event.model_class
        }
      end
    end
    pii_inventory
  end
end
```

**Capabilities:**
- Field pattern matching for automatic PII detection
- Fallback detection when policy not defined
- Context-aware masking
- Event stream PII inventory extraction

---

## 9. GDPR Compliance Projections

### GDPRCompliance

**Location:** `/lib/lyra/privacy/gdpr_compliance.rb`

Projections for GDPR rights implementation:

```ruby
class Lyra::Privacy::GDPRCompliance
  def data_export
    # Article 15: Right to Access
    {
      subject: { id: subject_id, type: subject_type },
      generated_at: Time.current,
      events: collect_all_events,
      pii_inventory: collect_pii_inventory,
      data_lineage: trace_data_lineage,
      processing_activities: collect_processing_activities
    }
  end

  def right_to_be_forgotten_report
    # Article 17: Right to be Forgotten
    events = collect_all_events
    {
      subject: { id: subject_id, type: subject_type },
      total_events: events.count,
      affected_streams: affected_streams(events),
      affected_models: affected_models(events),
      deletion_strategy: recommend_deletion_strategy(events),
      dependencies: find_dependencies(events)
    }
  end

  def rectification_history
    # Article 16: Track corrections
    corrections = events.select do |event|
      event.operation == :updated && has_subject_pii?(event)
    end
    corrections.map do |event|
      {
        timestamp: event.timestamp,
        model: event.model_class,
        changes: event.changes,
        corrected_fields: identify_pii_changes(event.changes)
      }
    end
  end
end
```

**GDPR Support:**
- Article 15: Right to Access (complete data export)
- Article 16: Rectification tracking
- Article 17: Right to be Forgotten analysis
- Article 20: Data portability
- Article 30: Processing activities record

---

## 10. Configuration and Integration

### Model Configuration

**Location:** `/lib/lyra/configuration.rb`

```ruby
class Lyra::ModelConfiguration
  attr_accessor :event_prefix, :aggregate_class, :privacy_policy

  def initialize(model_class, options = {})
    @model_class = model_class
    @privacy_policy = options[:privacy_policy]  # Privacy policy integration
    @aggregate_class = options[:aggregate_class]  # Custom aggregates
  end
end

# Usage in models:
class Student < ApplicationRecord
  monitor_with_lyra privacy_policy: :university_system
end
```

---

## 11. Event Sourcing with Disabled Projections (Sixth Mode)

### Overview

The **sixth mode** (`event_sourcing` + `projection_mode: :disabled`) implements pure CQRS where:
- **Writes**: Events stored to event store, no database writes
- **Reads**: State reconstructed from events, cached in Rails.cache/Solid Cache

This mode is useful for:
- Pure event sourcing without relational database dependency
- High-read scenarios where cache serves most queries
- Systems where eventual consistency is acceptable

### Configuration

```ruby
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :disabled  # No database writes
end
```

### CachedRelation

**Location:** `/lib/lyra/projections/cached_relation.rb`

An ActiveRecord::Relation-like wrapper that operates on in-memory cached data:

```ruby
# Returns CachedRelation instead of AR::Relation
users = User.where(status: "active")

# Full query interface
users.where(role: "admin")
     .order(created_at: :desc)
     .limit(10)
     .offset(5)

# Finders
User.find(123)                    # By ID
User.find_by(email: "foo@bar.com") # By attributes
User.first                        # Ordered by primary key ASC
User.last                         # Ordered by primary key DESC

# Aggregations
User.where(active: true).count
User.sum(:balance)
User.average(:age)
User.pluck(:email, :name)

# Pagination (Kaminari-compatible)
User.page(2).per(25)
```

#### Type Coercion

CachedRelation automatically handles type mismatches common with controller params:

```ruby
# String "2" matches integer 2
User.where(id: "2")         # Works!
User.where(id: ["1", "3"])  # Works!

# String "true"/"false" matches booleans
User.where(active: "true")  # Works!
User.where(active: "false") # Works!
```

### EventStoreReader

**Location:** `/lib/lyra/projections/event_store_reader.rb`

Reconstructs entity state from event streams with caching:

```ruby
# Find by ID (checks cache, falls back to event replay)
user = Lyra::Projections::EventStoreReader.find(User, 123)

# Find by attributes
user = Lyra::Projections::EventStoreReader.find_by(User, email: "foo@bar.com")

# Get relation for queries
relation = Lyra::Projections::EventStoreReader.relation(User)
relation.where(status: "active").order(:name).to_a

# Cache operations
Lyra::Projections::EventStoreReader.warm(User, 123)      # Pre-load into cache
Lyra::Projections::EventStoreReader.invalidate(User, 123) # Remove from cache
```

### AssociationInterceptor

**Location:** `/lib/lyra/interceptors/association_interceptor.rb`

Patches ActiveRecord associations to load from cache when in sixth mode:

```ruby
# These work transparently with cached data:
order.customer          # belongs_to - loads from cache
user.profile            # has_one - loads from cache
user.orders             # has_many - returns CachedRelation
user.orders.count       # Count without loading all records
user.orders.empty?      # Check existence efficiently

# Polymorphic associations supported
comment.commentable     # Resolves type from cache
```

#### Installation

Installed automatically by Lyra engine:

```ruby
# In lib/lyra/engine.rb
initializer "lyra.install_association_interceptor" do
  ActiveSupport.on_load(:active_record) do
    Lyra::Interceptors::AssociationInterceptor.install!
  end
end
```

### Data Flow in Sixth Mode

```
Write Path:
  User.create! → before_create → CreateCommand → Event stored
                                              ↓
                               Cache warmed with new data
                                              ↓
                               SQL INSERT skipped (projection_mode: :disabled)

Read Path:
  User.find(id) → Check cache → Hit? Return cached record
                            ↓
                     Miss? Replay events → Build state → Cache it → Return
```

### Cache Strategy

Uses Rails.cache (Solid Cache in Rails 8):

```ruby
# Cache keys follow pattern:
"lyra/User/123"           # Individual record
"lyra/User/all"           # All records for Model.all

# Cache is warmed on writes
def lyra_warm_cache(operation, result)
  case operation
  when :create, :update
    EventStoreReader.warm(self.class, model_id)
  when :destroy
    EventStoreReader.invalidate(self.class, model_id)
  end
end
```

---

## 12. Data Access Monitoring Flow

### Flow Diagram

```
User Action → CRUD Operation → CrudInterceptor
                                      ↓
                            (Monitor/Hijack Mode)
                                      ↓
                    ┌──────────────────┼──────────────────┐
                    ↓                  ↓                  ↓
              Event Creation    Policy Integration    Privacy Check
                    ↓                  ↓                  ↓
            Event Enrichment   PII Detection/Masking  Consent Validation
                    ↓                  ↓                  ↓
              Event Store Publishing & Logging
                    ↓
        ┌───────────────────────────────────────┐
        ↓           ↓           ↓           ↓    ↓
    Projections:
    - StateProjection (current state)
    - AuditProjection (access history)
    - EventFlow (correlations & lineage)
    - DualView (verification)
    - GDPRCompliance (rights)
```

---

## 13. Working Examples

### Example 1: Creating an Audit Trail

```ruby
# Model setup
class Student < ApplicationRecord
  monitor_with_lyra privacy_policy: :university_system
end

# Creating a student triggers event creation
student = Student.create!(
  name: "John Doe",
  email: "john@example.com",
  ssn: "123-45-6789"
)

# Get complete audit trail
audit = AuditProjection.audit_trail(Student, student.id)
# Returns:
# [
#   {
#     operation: :created,
#     timestamp: "2025-11-05 10:30:00",
#     user_id: 123,
#     changes: {},
#     attributes: {
#       name: "John Doe",
#       email: "john@example.com",
#       ssn: "123-45-6789"
#     }
#   }
# ]
```

### Example 2: Data Lineage Tracking

```ruby
# Track how an email address changed over time
flow = Lyra::EventFlow.new(model_class: Student, model_id: student.id)
lineage = flow.data_lineage(:email)

# Returns:
# [
#   {
#     timestamp: "2025-11-05 10:30:00",
#     event_id: "abc123",
#     model: "Student",
#     record_id: 1,
#     operation: :created,
#     old_value: nil,
#     new_value: "john@example.com",
#     user_id: 123,
#     action: "students#create"
#   },
#   {
#     timestamp: "2025-11-05 14:20:00",
#     event_id: "def456",
#     model: "Student",
#     record_id: 1,
#     operation: :updated,
#     old_value: "john@example.com",
#     new_value: "john.doe@university.edu",
#     user_id: 123,
#     action: "students#update"
#   }
# ]
```

### Example 3: Privacy Impact Analysis

```ruby
# Analyze privacy impact of events
flow = Lyra::EventFlow.new(model_class: Student, model_id: student.id)
impact = flow.privacy_impact_analysis

# Returns:
# {
#   total_events: 5,
#   events_with_pii: 4,
#   pii_categories: [:email, :ssn, :name, :address],
#   sensitive_data_present: true  # SSN is considered sensitive
# }
```

### Example 4: Dual-View Verification

```ruby
# Compare database state with event-sourced state
dual_view = Lyra::DualView.new(Student, student.id)
comparison = dual_view.compare

# Returns:
# {
#   crud_view: {
#     exists: true,
#     state: { id: 1, name: "John Doe", email: "john@example.com", ... }
#   },
#   event_sourced_view: {
#     exists: true,
#     state: { id: 1, name: "John Doe", email: "john@example.com", ... },
#     events_count: 5,
#     events_summary: [...]
#   },
#   differences: [],
#   metadata: { ... }
# }
```

### Example 5: GDPR Data Export

```ruby
# Exercise GDPR Article 15: Right to Access
gdpr = Lyra::Privacy::GDPRCompliance.new(subject_type: 'Student', subject_id: student.id)
export = gdpr.data_export

# Returns comprehensive data package:
# {
#   subject: { id: 1, type: "Student" },
#   generated_at: "2025-11-05 15:00:00",
#   events: [...],  # All events involving this student
#   pii_inventory: { ... },  # All PII fields collected
#   data_lineage: { ... },  # How data changed over time
#   processing_activities: [ ... ]  # What processing occurred
# }
```

### Example 6: Privacy Policy Integration

```ruby
# Validate access before operation
policy_integration = Lyra::Privacy::PolicyIntegration.new(:university_system)

# Check if we can access email for marketing
begin
  policy_integration.validate_access!(
    [:email],
    :marketing,
    { granted: true, granted_at: 1.year.ago }
  )
  # Access granted
rescue PamDsl::PolicyViolationError => e
  # Access denied - consent expired or not granted
  puts e.message
end

# Mask PII for display
masked_ssn = policy_integration.mask_pii(:ssn, "123-45-6789", :display)
# Returns: "***-**-6789"

masked_email = policy_integration.mask_pii(:email, "john@example.com", :display)
# Returns: "j***@example.com"
```

---

## 14. File Locations Summary

| Component | File Path |
|-----------|-----------|
| Base Projection | `/lib/lyra/projection.rb` |
| CRUD Interception | `/lib/lyra/interceptors/crud_interceptor.rb` |
| Association Interception | `/lib/lyra/interceptors/association_interceptor.rb` |
| CachedRelation | `/lib/lyra/projections/cached_relation.rb` |
| EventStoreReader | `/lib/lyra/projections/event_store_reader.rb` |
| Model Projection | `/lib/lyra/projections/model_projection.rb` |
| Event Flow Analysis | `/lib/lyra/event_flow.rb` |
| Dual-View Comparison | `/lib/lyra/dual_view.rb` |
| Privacy Integration | `/lib/lyra/privacy/policy_integration.rb` |
| PII Detection | `/lib/lyra/privacy/pii_detector.rb` |
| GDPR Compliance | `/lib/lyra/privacy/gdpr_compliance.rb` |
| PAM DSL Core | `/gems/pam_dsl/lib/pam_dsl/policy.rb` |
| Field Definition | `/gems/pam_dsl/lib/pam_dsl/field.rb` |
| Configuration | `/lib/lyra/configuration.rb` |
| Privacy Policies | `/config/privacy_policies.rb` |
| Event Class Registrar | `/lib/lyra/schema/event_class_registrar.rb` |
| Integration Guide | `/gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md` |

---

## 15. Key Takeaways

1. **Projections are Read Models**: Reconstruct state from immutable events for auditing and compliance
2. **Privacy-First Design**: All projections integrate with PAM DSL for field-level privacy policies
3. **Comprehensive Monitoring**: Every CRUD operation tracked with user, request, and correlation context
4. **Dual Verification**: Compare database state vs. event-sourced projections to ensure consistency
5. **GDPR Ready**: Complete support for Articles 15-20 with data lineage and processing activities
6. **Flexible Masking**: Context-aware PII transformation for display, logging, and API usage
7. **Access Control**: Purpose-based validation with consent and retention enforcement
8. **Audit Trails**: Complete who-what-when-why tracking for all data operations
9. **Immutable History**: Append-only event store prevents tampering with audit records
10. **Data Lineage**: Track complete history of field changes across all operations

---

## 16. Benefits

✓ **Complete audit trails** - Every data access tracked with full context
✓ **GDPR compliance** - Built-in support for right to access, rectification, erasure
✓ **Privacy-first** - Field-level policies integrated at projection level
✓ **Data lineage** - Track how data flows and changes over time
✓ **Dual verification** - Ensure database consistency with event-sourced state
✓ **Purpose validation** - Enforce that data access matches declared purposes
✓ **Tamper-proof** - Immutable, append-only monitoring that can't be altered
✓ **Accountability** - Complete who-what-when-why for all data operations
