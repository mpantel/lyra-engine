# PAM DSL Integration Guide

This guide explains how to use PAM DSL (Privacy Attribute Matrix DSL) with Lyra for comprehensive privacy policy management.

## Overview

PAM DSL is a declarative Domain-Specific Language for defining privacy policies using the Privacy Attribute Matrix (PAM) model. It integrates seamlessly with Lyra's event sourcing monitoring and provides:

- **Field-level PII classification** with sensitivity levels
- **Purpose-based access control** aligned with GDPR
- **Retention policies** with field-level granularity
- **Consent management** with expiration tracking
- **Data transformation** for different contexts (display, logging, API)

Lyra does not depend on PAM directly. It defines a privacy provider interface
(`Lyra::Privacy::Policy`, `Lyra::Privacy::Detector` and `Lyra::Privacy::Provider`
in `lib/lyra/privacy/interface.rb`), whose base classes are null
implementations: no attribute is declared personal, every access is allowed and
the detector finds nothing. PAM plugs in as the adapter
`Lyra::Privacy::Adapters::Pam` (`lib/lyra/privacy/adapters/pam.rb`), which
becomes the provider when the pam_dsl gem is loaded. `Lyra::Privacy.provider`
returns the active provider and can be replaced with `Lyra::Privacy.provider =`.
Everything below goes through this interface.

## Quick Start

### 1. Define a Privacy Policy

Create or edit `config/privacy_policies.rb`:

```ruby
PamDsl.define_policy :my_app do
  # Define PII fields
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication, :marketing
    transform :display do |value|
      "#{value[0]}***@#{value.split('@').last}"
    end
  end

  field :ssn, type: :ssn, sensitivity: :restricted do
    allow_for :legal_compliance
    transform(:display) { |_| "***REDACTED***" }
  end

  # Define purposes
  purpose :authentication do
    describe "User login and session management"
    basis :contract  # GDPR Article 6(1)(b)
    requires :email
  end

  purpose :marketing do
    describe "Marketing communications"
    basis :consent  # GDPR Article 6(1)(a)
    requires :email
  end

  # Configure retention
  retention do
    default 7.years

    for_model 'User' do
      keep_for 10.years
      field :email, duration: 2.years
      on_expiry :anonymize
    end
  end

  # Configure consent
  consent do
    for_purpose :marketing do
      required!
      expires_in 1.year
      withdrawable!
    end
  end
end
```

### 2. Use Policy with ActiveRecord Models

```ruby
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_app
end
```

A model without `privacy_policy:` uses the default policy,
`config.privacy_policy`, if one is set.

### 3. Load Policies in Your Application

In `config/initializers/lyra.rb`:

```ruby
require_relative '../privacy_policies'

Lyra.configure do |config|
  config.mode = :monitor
  config.event_store = RailsEventStore::Client.new
  config.privacy_policy = :my_app   # optional: default policy for monitored models
end
```

## Policy Components

### Fields

Fields represent PII data with classification and allowed uses:

```ruby
field :credit_card, type: :credit_card, sensitivity: :restricted do
  # Allow only for payment processing
  allow_for :payment_processing

  # Transform for display (last 4 digits only)
  transform :display do |value|
    "****-****-****-#{value[-4..]}"
  end

  # Transform for logging (fully redacted)
  transform :log do |value|
    "***REDACTED***"
  end

  # Transform for API responses
  transform :api do |value|
    { last4: value[-4..], type: 'credit_card' }
  end

  # Add metadata
  meta :encryption_required, true
  meta :pci_dss_scope, true
end
```

**Sensitivity Levels:**
- `:public` - Publicly accessible data
- `:internal` - Internal use only
- `:confidential` - Sensitive data requiring protection
- `:restricted` - Highly restricted access (SSN, credit cards, health data)

**Available PII Types:**
`:email`, `:name`, `:phone`, `:address`, `:ssn`, `:date_of_birth`, `:ip_address`, `:online_identifier`, `:credit_card`, `:financial`, `:health`, `:biometric`, `:location`, `:identifier`, `:credential`, `:token`, `:payment_token`, `:custom`

### Purposes

Purposes define why you process data, aligned with GDPR requirements:

```ruby
purpose :order_fulfillment do
  describe "Processing and shipping customer orders"
  basis :contract  # GDPR legal basis
  requires :email, :shipping_address, :phone
  optionally :delivery_instructions

  meta :department, "Operations"

  # Article 30 declarations, used by the Article 30 report
  data_subjects "customers"
  recipients "Shipping Partner", "Payment Processor"
  no_transfers!
end
```

**GDPR Legal Bases:**
- `:consent` - User has given explicit consent
- `:contract` - Necessary for contract performance
- `:legal_obligation` - Required by law
- `:vital_interests` - Protecting someone's life
- `:public_task` - Task in the public interest
- `:legitimate_interests` - Legitimate business interests

### Retention

Define how long data should be retained:

```ruby
retention do
  # Default retention for all models
  default 5.years

  # Model-specific retention
  for_model 'Order' do
    keep_for 7.years

    # Field-level overrides
    field :credit_card_info, duration: 0.days  # Delete immediately after processing
    field :order_history, duration: 10.years

    # What to do when retention expires
    on_expiry :anonymize  # Options: :hard_delete, :soft_delete, :anonymize, :archive
  end

  # Conditional retention
  for_model 'SupportTicket' do
    keep_for 3.years

    # `when` is a Ruby keyword, so call it with an explicit receiver
    self.when do |record|
      !record[:escalated]  # the rule applies to non-escalated tickets
    end
  end
end
```

Conditions are stored on the rule and checked with `RetentionRule#applies_to?`;
Lyra's adapter passes them on as the `applies` predicate of the retention rule.
`retention_for` returns the rule's duration without evaluating them.

### Consent

Manage consent requirements:

```ruby
consent do
  for_purpose :marketing do
    required!        # Consent is mandatory
    granular!        # Allow fine-grained control
    withdrawable!    # Can be withdrawn anytime
    expires_in 2.years
    describe "We'll send you product updates and special offers"
  end

  for_purpose :analytics do
    required! false  # Consent is optional
    granular!
    describe "Help us improve by sharing anonymous usage data"
  end
end
```

## Using Policies in Code

### Basic Policy Access

```ruby
# Get a policy
policy = PamDsl.policy(:my_app)

# Check if field is allowed for purpose
if policy.allowed?(:email, :marketing)
  # Send marketing email
end

# Get field and apply transformation
field = policy.get_field(:email)
masked = field.apply_transformation(:display, "user@example.com")
# => "u***@example.com"

# Get retention duration
duration = policy.retention_for('User', field_name: :email)
# => 2.years
```

### Integration Layer

Use `Lyra::Privacy::PolicyIntegration` for seamless integration:

```ruby
# Create integration (use_detector: true by default)
integration = Lyra::Privacy::PolicyIntegration.new(:my_app)

# Or policy-only mode (no PIIDetector fallback)
integration = Lyra::Privacy::PolicyIntegration.new(:my_app, use_detector: false)

# Check availability
integration.pam_dsl_available?  # => true if PAM DSL is loaded
integration.policy_loaded?       # => true if policy was found

# Detect PII using policy + detector fallback
user_data = {
  email: "user@example.com",
  name: "John Doe",
  ssn: "123-45-6789",
  phone: "555-1234"   # Not in policy, detected by PIIDetector
}

pii = integration.detect_pii(user_data)
# => {
#   email: { type: :email, sensitive: false, source: :policy, ... },
#   name: { type: :name, sensitive: false, source: :detector, ... },  # not declared in :my_app
#   ssn: { type: :ssn, sensitive: true, source: :policy, ... },
#   phone: { type: :phone, sensitive: false, source: :detector, ... }
# }

# Mask PII for display (uses policy transformations, falls back to detector)
masked = integration.mask_pii(:ssn, "123-45-6789", :display)
# => "***REDACTED***"

# Get retention duration (nil = infinite/manual retention)
retention = integration.retention_duration('User')
# => 10.years (the policy's User rule) or nil (no policy)

# Check whether the purpose's legal basis is consent
if integration.consent_required?(:marketing)
  # Verify user consent before proceeding
end

# Validate access for a data subject. Consent is looked up in the policy's
# runtime consent store, so record it there first.
PamDsl.policy(:my_app).consent_policy.grant_consent(purpose: :marketing, subject: user.id)

begin
  integration.validate_access!([:email], :marketing, subject: user.id)
  # Access granted (returns true; false in audit mode when there are violations)
rescue PamDsl::ConsentRequiredError => e
  # Handle consent error
end
```

`validate_access!(field_names, purpose, subject:)` delegates to the policy's
`validate_access!`. In strict mode (the default) the first violation is raised
as its typed error; in audit mode (`PamDsl.enforcement_mode = :audit`, or
`enforcement :audit` in the policy) every violation is logged and passed to the
`PamDsl.on_violation` handlers, and the call returns false. With no provider
installed it always returns true.

#### Fallback Behavior

| Condition | `detect_pii` | `mask_pii` | `retention_duration` |
|-----------|--------------|------------|----------------------|
| PAM DSL available + policy loaded | Policy fields + detector fallback | Policy transform + detector fallback | Policy duration |
| PAM DSL available + no policy | Detector only (if enabled) | Detector masking (if enabled) | `nil` (infinite) |
| PAM DSL not available | `{}` (empty) | Value unchanged | `nil` (infinite) |
| `use_detector: false` | Policy fields only | Policy transform only | Policy duration |

### GDPR Compliance Integration

```ruby
# Use policy with GDPR compliance
compliance = Lyra::Privacy::GDPRCompliance.new(
  subject_id: user.id,
  subject_type: 'User'
)

# Detect PII with policy
pii = compliance.detect_pii_with_policy(user_attributes, :my_app)

# Check retention compliance with policy
retention_status = compliance.retention_compliance_with_policy(:my_app)
```

## Advanced Usage

### Multiple Policies

Define different policies for different parts of your system:

```ruby
# In config/privacy_policies.rb

# Customer-facing policy
PamDsl.define_policy :customer_portal do
  # ... customer-specific fields and purposes
end

# Admin policy
PamDsl.define_policy :admin_panel do
  # ... admin-specific fields and purposes with different access rules
end

# Internal analytics policy
PamDsl.define_policy :analytics do
  # ... analytics-specific anonymization and retention
end
```

Use different policies for different models:

```ruby
class Customer < ApplicationRecord
  monitor_with_lyra privacy_policy: :customer_portal
end

class AdminUser < ApplicationRecord
  monitor_with_lyra privacy_policy: :admin_panel
end
```

### Dynamic Policy Selection

```ruby
class DataProcessor
  def initialize(user_type)
    @policy_name = user_type == :admin ? :admin_panel : :customer_portal
    @integration = Lyra::Privacy::PolicyIntegration.new(@policy_name)
  end

  def process_data(data, purpose, subject:)
    @integration.validate_access!(data.keys, purpose, subject: subject)
    # Process data...
  end
end
```

### Custom Transformations

```ruby
field :location, type: :location, sensitivity: :confidential do
  allow_for :service_delivery, :analytics

  # Different transformations for different contexts
  transform :display do |value|
    # Show city/state only
    "#{value[:city]}, #{value[:state]}"
  end

  transform :analytics do |value|
    # Anonymize for analytics
    { country: value[:country], city: value[:city] }
  end

  transform :api do |value|
    # Structured API response
    {
      latitude: value[:lat].round(2),  # Reduce precision
      longitude: value[:lng].round(2),
      accuracy: '~1km'
    }
  end
end
```

### Conditional Access

```ruby
# In your application
def can_access_field?(user, field_name, purpose)
  policy = PamDsl.policy(:my_app)

  # Check policy allows it
  return false unless policy.allowed?(field_name, purpose)

  # Check user has appropriate role
  field = policy.get_field(field_name)
  if field.restricted?
    return user.has_role?(:admin)
  end

  # Check consent if required
  purpose_obj = policy.get_purpose(purpose)
  if purpose_obj.requires_consent?
    return user.consents.active.exists?(purpose: purpose)
  end

  true
end
```

## Event Integration

### What Lyra does with a policy

A monitored model's policy (its `privacy_policy:` option, or
`config.privacy_policy`) is used in three places. None of them changes the
attribute values Lyra records in events.

1. **Privacy stamp (opt-in).** With `config.annotate_privacy = true` (off by
   default), each event Lyra builds for a model with a loaded policy gets a
   `metadata[:privacy]` entry naming the policy and annotating every declared
   attribute the event carries: its type, sensitivity, allowed purposes (the
   field's `allow_for` list), retention period (ISO 8601) and the contexts it has a transformation for.
   Never a value. A create annotates the attributes it carries, an update the
   ones it changed (and, in Monitor mode, the full row it also carries). An
   event with no declared attribute is left unstamped.
2. **Purpose-bound reads.** A read made for a declared purpose
   (`Lyra.with_purpose(:invoicing) { ... }`, or `lyra_purpose` in a controller
   or job) is checked against the policy with `validate_access!`, with the
   record as the subject.
3. **Access log (opt-in).** With `config.record_access_events = true`, every
   call to `validate_access!` is recorded as a `DataAccessed` or
   `DataAccessDenied` event in the subject's access stream, through
   `PamDsl.access_recorder`. Field names only, never values.

```ruby
class Order < ApplicationRecord
  monitor_with_lyra privacy_policy: :ecommerce
end

Lyra.configure { |config| config.annotate_privacy = true }

Order.create!(email: "customer@example.com", credit_card: "4111111111111111")
```

### The privacy stamp

With the policy declaring `email` and `credit_card`, the event's metadata
includes (string keys; values illustrative):

```ruby
{
  # ... metadata Lyra already records ...
  privacy: {
    "policy" => "ecommerce",
    "fields" => {
      "email" => {
        "type" => "email", "sensitivity" => "internal",
        "purposes" => ["order_fulfillment"], "retention" => "P7Y"
      },
      "credit_card" => {
        "type" => "credit_card", "sensitivity" => "restricted",
        "purposes" => ["payment_processing"], "retention" => "P7Y",
        "transformations" => ["display", "log"]
      }
    }
  }
}
```

`Lyra::Privacy.stamp_of(event)` reads the stamp of a stored event back with
string keys, or nil if it was not stamped. Because the stamp records the
policy as it was when the event was written, reclassifying a field later does
not rewrite the history.

## Best Practices

### 1. Policy Organization

```ruby
# Keep related fields together
PamDsl.define_policy :my_app do
  # Identity fields
  field :email, type: :email, sensitivity: :internal do
    # ...
  end
  field :username, type: :identifier, sensitivity: :internal do
    # ...
  end

  # Financial fields
  field :credit_card, type: :credit_card, sensitivity: :restricted do
    # ...
  end
  field :bank_account, type: :financial, sensitivity: :restricted do
    # ...
  end

  # Personal fields
  field :name, type: :name, sensitivity: :internal do
    # ...
  end
  field :dob, type: :date_of_birth, sensitivity: :confidential do
    # ...
  end
end
```

### 2. Principle of Least Privilege

```ruby
# Only allow fields for purposes that truly need them
field :ssn, type: :ssn, sensitivity: :restricted do
  allow_for :legal_compliance, :tax_reporting
  # Don't allow for :marketing, :analytics, etc.
end
```

### 3. Document Legal Bases

```ruby
purpose :data_retention do
  describe "Retaining customer data for legal compliance"
  basis :legal_obligation
  meta :regulations, ["SOX", "GDPR Article 6(1)(c)"]
  meta :retention_laws, ["7 years for financial records"]
end
```

### 4. Regular Policy Audits

```ruby
# Create a script to audit policies
def audit_policy(policy_name)
  policy = PamDsl.policy(policy_name)

  puts "Auditing policy: #{policy_name}"
  puts "Restricted fields: #{policy.restricted_fields.map(&:name)}"
  puts "Purposes requiring consent: #{
    policy.purposes.values.select(&:requires_consent?).map(&:name)
  }"
  puts "Retention periods: #{
    policy.retention_policy.rules.map { |r|
      "#{r.model_class}: #{r.duration ? r.duration.inspect : 'default'}"
    }
  }"
end
```

### 5. Version Your Policies

```ruby
PamDsl.define_policy :my_app do
  meta :version, "2.1.0"
  meta :effective_date, "2025-01-01"
  meta :last_reviewed, "2025-01-01"
  meta :next_review, "2026-01-01"

  # ... policy definition
end
```

## Testing

### Testing Policies

```ruby
# spec/privacy/policies_spec.rb
RSpec.describe "Privacy Policies" do
  before do
    require Rails.root.join('config/privacy_policies')
  end

  describe "university_system policy" do
    let(:policy) { PamDsl.policy(:university_system) }

    it "restricts SSN to legal compliance only" do
      expect(policy.allowed?(:ssn, :legal_compliance)).to be true
      expect(policy.allowed?(:ssn, :marketing)).to be false
    end

    it "requires consent for marketing" do
      purpose = policy.get_purpose(:marketing)
      expect(purpose.requires_consent?).to be true
    end

    it "retains student records for 10 years" do
      duration = policy.retention_for('Student')
      expect(duration).to eq(10.years)
    end
  end
end
```

### Testing Integration

```ruby
RSpec.describe Lyra::Privacy::PolicyIntegration do
  let(:integration) { described_class.new(:my_app) }

  describe "#detect_pii" do
    it "detects PII based on policy" do
      data = { email: "test@example.com", age: 25 }
      pii = integration.detect_pii(data)

      expect(pii).to have_key(:email)
      expect(pii[:email][:type]).to eq(:email)
    end
  end

  describe "#validate_access!" do
    it "raises error when consent required but not given" do
      # :marketing has basis :consent and a required consent requirement;
      # subject 99 has no consent record
      expect {
        integration.validate_access!([:email], :marketing, subject: 99)
      }.to raise_error(PamDsl::ConsentRequiredError)
    end
  end
end
```

## Troubleshooting

### Policy Not Found

```ruby
# Error: PamDsl::PolicyNotFoundError

# Solution: Ensure policy is defined and loaded
require_relative 'config/privacy_policies'
PamDsl.registry.names  # See all loaded policies
```

### Field Not Defined

```ruby
# Error: PamDsl::InvalidFieldError

# Solution 1: Define the field in your policy
# Solution 2: Use detector fallback (default behavior)
integration = Lyra::Privacy::PolicyIntegration.new(:my_app, use_detector: true)
# Fields not in policy are detected by PIIDetector pattern matching
# Result includes source: :detector for these fields

# To use policy-only mode (no fallback):
integration = Lyra::Privacy::PolicyIntegration.new(:my_app, use_detector: false)
# Fields not in policy are ignored
```

### Consent Validation Fails

```ruby
# Error: PamDsl::ConsentRequiredError

# Solution: record the subject's consent in the runtime consent store, then
# validate for that subject
policy = PamDsl.policy(:my_app)
policy.consent_policy.grant_consent(purpose: :marketing, subject: user.id)
integration.validate_access!([:email], :marketing, subject: user.id)
```

The error message gives the reason: no consent record, consent requested but
not yet granted, expired, or withdrawn. The check applies to purposes whose
basis is `:consent` and that have a required consent requirement
(`consent { for_purpose(:marketing) { required! } }`).

## Further Reading

- [PAM DSL README](../README.md) - Complete PAM DSL documentation
- [Privacy Compliance Guide](../../../docs/PRIVACY_COMPLIANCE.md) - GDPR compliance with Lyra
- [Privacy Policy Examples](../../../config/privacy_policies.rb) - Example policy definitions
- [Usage Examples](../../../examples/privacy_policy_usage.rb) - Code examples
- [Privacy provider interface](../../../lib/lyra/privacy/interface.rb) and [PAM adapter](../../../lib/lyra/privacy/adapters/pam.rb)

## Support

For questions or issues:
- Open a GitHub issue
- Contact the research team
- Review the examples and test suite
