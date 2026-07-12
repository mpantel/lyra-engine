# PAM DSL - Privacy Attribute Matrix DSL

A declarative Domain-Specific Language (DSL) for defining privacy policies, PII fields, consent requirements, and retention rules using the Privacy Attribute Matrix (PAM) model for privacy-aware event monitoring.

## Overview

PAM DSL provides a fluent, expressive way to define privacy policies using the Privacy Attribute Matrix (PAM) model. It can be used by privacy-aware monitoring systems like Lyra and helps you:

- **Define PII fields** with type and sensitivity classification
- **Specify processing purposes** with legal bases (GDPR compliant)
- **Configure retention policies** with field-level granularity
- **Manage consent requirements** with expiration and granular control
- **Validate data access** against defined policies

## Installation

Add to your Gemfile:

```ruby
gem 'pam_dsl', path: 'gems/pam_dsl'  # For monorepo
```

## Quick Start

```ruby
require 'pam_dsl'

# Define a privacy policy
PamDsl.define_policy :user_data do
  # Define PII fields
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication, :marketing
    transform :display do |value|
      "#{value[0]}***@#{value.split('@').last}"
    end
  end

  field :ssn, type: :ssn, sensitivity: :restricted do
    allow_for :identity_verification
    transform :display do |value|
      "***-**-#{value[-4..]}"
    end
  end

  # Define processing purposes
  purpose :authentication do
    describe "User authentication and session management"
    basis :contract
    requires :email
  end

  purpose :marketing do
    describe "Marketing communications and newsletters"
    basis :consent
    requires :email
    optionally :name, :preferences
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
      granular!
      withdrawable!
      expires_in 1.year
      describe "We'll send you product updates and offers"
    end
  end
end
```

## Detailed Usage

### Defining Fields

Fields represent PII data with type classification and sensitivity levels:

```ruby
PamDsl.define_policy :my_policy do
  # Basic field definition
  field :email, type: :email, sensitivity: :internal

  # Field with allowed purposes
  field :phone, type: :phone, sensitivity: :confidential do
    allow_for :contact, :verification
  end

  # Field with transformations
  field :credit_card, type: :credit_card, sensitivity: :restricted do
    allow_for :payment_processing

    # Transform for display
    transform :display do |value|
      "****-****-****-#{value[-4..]}"
    end

    # Transform for logging
    transform :log do |value|
      "***REDACTED***"
    end

    # Add metadata
    meta :encryption_required, true
    meta :pci_dss_scope, true
  end
end
```

**Sensitivity Levels:**
- `:public` - Publicly accessible
- `:internal` - Internal use only
- `:confidential` - Sensitive, requires protection
- `:restricted` - Highly restricted access

See [Sensitivity Levels and Legislative Background](#sensitivity-levels-and-legislative-background) for detailed regulatory mapping.

**PII Types:**
`:email`, `:name`, `:phone`, `:address`, `:ssn`, `:date_of_birth`, `:ip_address`, `:credit_card`, `:financial`, `:health`, `:biometric`, `:location`, `:identifier`, `:custom`

### Defining Purposes

Purposes represent why you process personal data, aligned with GDPR requirements:

```ruby
PamDsl.define_policy :my_policy do
  purpose :account_management do
    describe "Creating and managing user accounts"
    basis :contract  # GDPR Article 6(1)(b)
    requires :email, :password_hash
    optionally :phone, :preferences
  end

  purpose :analytics do
    describe "Improving service quality and user experience"
    basis :legitimate_interests  # GDPR Article 6(1)(f)
    lia_documented!              # balancing test conducted and on record
    requires :user_id
    optionally :session_data, :interaction_events
    meta :data_minimization, true
  end

  purpose :legal_compliance do
    describe "Complying with tax and financial regulations"
    basis :legal_obligation  # GDPR Article 6(1)(c)
    requires :transaction_history, :financial_records
  end
end
```

**Legal Bases (GDPR Article 6):**
- `:consent` - Data subject has given consent
- `:contract` - Processing necessary for contract
- `:legal_obligation` - Compliance with legal obligation
- `:vital_interests` - Protection of vital interests
- `:public_task` - Task in public interest
- `:legitimate_interests` - Legitimate interests

#### Legitimate Interests Assessment (LIA)

When the basis is `:legitimate_interests`, GDPR Art. 6(1)(f) requires a balancing test — a human-judgment obligation PAM cannot automate. Instead, PAM verifies that one has been recorded. Use `lia_documented!` to mark the assessment as done; `lia_compliance_gaps` surfaces any `:legitimate_interests` purposes where it is missing.

```ruby
purpose :analytics do
  basis :legitimate_interests
  lia_documented!   # records that the LIA balancing test has been conducted
  requires :user_id
end

# Check which purposes still need an LIA
policy.lia_compliance_gaps.each do |p|
  puts "#{p.name}: LIA not documented"
end
```

`lia_compliance_gaps` is a compliance query, not an enforcement gate — access is not blocked when `lia_documented!` is absent, because the balancing test is an organizational process, not a runtime condition.

#### Art. 9(2) Basis for Special-Category Data

When a purpose accesses **special-category fields** — those whose `type` is a GDPR Article 9 category (`:health`, `:biometric`) — you **must** also declare an Art. 9(2) basis. Without it, `validate_access!` raises `SensitivityViolationError`. Multiple bases are accepted. Note that this is driven by the field **type**, not by the `:restricted` sensitivity level: `:restricted` is an Article 32 *risk* tier (used for high-risk-but-ordinary data such as financial or national-identifier fields), so a `:restricted` field of a non-Article-9 type does **not** require an Art. 9(2) basis, while an Article-9-type field requires one even below `:restricted`.

```ruby
purpose :medical_diagnosis do
  describe "Processing health data for treatment"
  basis :contract
  art9_basis :health_care               # Art. 9(2)(h)
  art9_basis :explicit_consent          # Art. 9(2)(a) — multiple allowed
  requires :diagnosis, :prescription
end

# Or pass multiple in one call
purpose :health_research do
  basis :public_task
  art9_basis :health_care, :research_archiving
  requires :diagnosis
end
```

**Art. 9(2) Bases:**
- `:explicit_consent` - 9(2)(a): explicit consent from the data subject
- `:employment_law` - 9(2)(b): employment / social security law obligation
- `:vital_interests` - 9(2)(c): vital interests, subject incapable of consenting
- `:non_profit` - 9(2)(d): legitimate non-profit body, members only
- `:made_public` - 9(2)(e): data manifestly made public by the subject
- `:legal_claims` - 9(2)(f): legal claims or judicial acts
- `:substantial_public_interest` - 9(2)(g): substantial public interest (Union/Member State law)
- `:health_care` - 9(2)(h): medical diagnosis, health or social care
- `:public_health` - 9(2)(i): public health
- `:research_archiving` - 9(2)(j): scientific/historical research or statistics

### Retention Policies

Define how long data should be retained:

```ruby
PamDsl.define_policy :my_policy do
  retention do
    # Set default retention
    default 5.years

    # Model-specific retention
    for_model 'User' do
      keep_for 7.years

      # Field-level overrides
      field :email, duration: 2.years
      field :payment_info, duration: 10.years

      # Deletion strategy
      on_expiry :anonymize  # or :hard_delete, :soft_delete, :archive
    end

    # Conditional retention
    for_model 'Transaction' do
      keep_for 10.years
      when do |context|
        context[:transaction_type] == 'financial'
      end
    end
  end
end
```

**Deletion Strategies:**
- `:hard_delete` - Permanently delete data
- `:soft_delete` - Mark as deleted but keep data
- `:anonymize` - Remove PII while keeping aggregated data
- `:archive` - Move to long-term storage

### Consent Management

Consent has two distinct layers in PAM:

1. **Policy-time spec** (`consent` DSL block) — declares *what* consent is required per purpose
2. **Runtime consent store** — records *whether* each data subject has actually granted or withdrawn consent

#### Policy-time spec

```ruby
PamDsl.define_policy :my_policy do
  consent do
    for_purpose :marketing do
      required!           # Must have consent
      granular!           # Allow fine-grained consent
      withdrawable!       # Can be withdrawn anytime
      expires_in 2.years  # Consent expires after 2 years
      describe "We'll send you marketing emails about new products"
    end

    for_purpose :analytics do
      required! false     # Optional consent
      granular!
      describe "Help us improve by sharing anonymous usage data"
    end
  end
end
```

#### Runtime consent store

Before calling `validate_access!` for a consent-based purpose, populate the store with the subject's actual consent decision. The store is the runtime $CS$ component from the formal model — indexed by `(purpose, subject)` pairs.

```ruby
policy = PamDsl.policy(:my_policy)

# Subject 42 grants marketing consent
policy.consent_policy.grant_consent(purpose: :marketing, subject: 42)

# Subject 42 grants with a backdated timestamp (e.g. loaded from DB)
policy.consent_policy.grant_consent(
  purpose: :marketing,
  subject: 42,
  granted_at: 6.months.ago
)

# Subject 42 withdraws consent
policy.consent_policy.withdraw_consent(purpose: :marketing, subject: 42)
```

`validate_access!` then looks up the store automatically — no need to pass a boolean:

```ruby
# Passes: record exists and is not withdrawn/expired
policy.validate_access!([:email], :marketing, subject: 42)

# Raises ConsentRequiredError: no record for subject 99
policy.validate_access!([:email], :marketing, subject: 99)

# Raises ConsentRequiredError: record is withdrawn
policy.consent_policy.withdraw_consent(purpose: :marketing, subject: 42)
policy.validate_access!([:email], :marketing, subject: 42)
```

### Custom Attributes (Metadata)

PAM DSL supports custom attributes via the `meta(key, value)` method at three levels: **policy**, **field**, and **purpose**. This allows you to extend policies with application-specific data without modifying the DSL core.

#### Policy-Level Metadata

Add organization-wide or policy-specific attributes:

```ruby
PamDsl.define_policy :my_app do
  # Policy-level custom attributes
  meta :organization, "University of the Aegean"
  meta :dpo_email, "dpo@aegean.gr"
  meta :policy_version, "2.1"
  meta :gdpr_compliant, true
  meta :last_review_date, "2026-06-02"
  meta :next_review_date, "2027-06-02"

  # ... fields, purposes, etc.
end

# Access policy metadata
policy = PamDsl.policy(:my_app)
policy.metadata[:organization]      # => "University of the Aegean"
policy.metadata[:gdpr_compliant]    # => true
```

#### Field-Level Metadata

Add field-specific attributes for compliance, encryption requirements, or custom categorization:

```ruby
field :email, type: :email, sensitivity: :confidential do
  allow_for :authentication, :marketing

  # Custom attributes
  meta :pii_category, "direct_identifier"
  meta :encryption_required, true
  meta :encryption_algorithm, "AES-256"
  meta :anonymization_method, "hash_prefix"
  meta :data_controller, "IT Department"
  meta :cross_border_transfer, false
  meta :third_party_sharing, ["analytics_provider"]
end

field :credit_card, type: :credit_card, sensitivity: :restricted do
  allow_for :payment_processing

  meta :pci_dss_scope, true
  meta :tokenization_required, true
  meta :storage_allowed, false  # Store token only, not actual card
  meta :processor, "Stripe"
end

# Access field metadata
field = policy.get_field(:email)
field.metadata[:encryption_required]  # => true
field.metadata[:pii_category]         # => "direct_identifier"
```

#### Purpose-Level Metadata

Document compliance details for each processing purpose:

```ruby
purpose :analytics do
  describe "Aggregated analytics for service improvement"
  basis :legitimate_interests
  requires :usage_data
  optionally :device_info

  # Legitimate Interest Assessment (LIA) — use lia_documented! to record completion
  lia_documented!
  meta :lia_date, "2026-06-02"
  meta :lia_outcome, "Approved - minimal privacy impact"
  meta :balancing_test, "User benefit outweighs minimal data use"

  # Data minimization
  meta :data_minimization_review, "quarterly"
  meta :aggregation_level, "daily"
  meta :individual_identification, false
end

purpose :fraud_detection do
  describe "Detecting and preventing fraudulent transactions"
  basis :legitimate_interests
  requires :transaction_data, :device_fingerprint

  meta :automated_decision_making, true
  meta :human_review_available, true
  meta :profiling, true
  meta :impact_assessment_required, true
  meta :dpia_reference, "DPIA-2024-003"
end

# Access purpose metadata
purpose = policy.get_purpose(:analytics)
purpose.metadata[:lia_conducted]  # => true
purpose.metadata[:dpia_reference] # => nil (not set)
```

#### Common Use Cases for Metadata

| Use Case | Level | Example Keys |
|----------|-------|--------------|
| Compliance tracking | Policy | `:gdpr_compliant`, `:ccpa_compliant`, `:last_audit_date` |
| Encryption requirements | Field | `:encryption_required`, `:encryption_algorithm`, `:key_rotation` |
| Data categorization | Field | `:pii_category`, `:special_category_data`, `:children_data` |
| Cross-border transfers | Field | `:cross_border_transfer`, `:adequacy_decision`, `:sccs_required` |
| Third-party sharing | Field | `:third_party_sharing`, `:processors`, `:joint_controllers` |
| LIA documentation | Purpose | `:lia_conducted`, `:lia_date`, `:balancing_test` |
| DPIA references | Purpose | `:dpia_required`, `:dpia_reference`, `:impact_assessment_date` |
| Automated decisions | Purpose | `:automated_decision_making`, `:profiling`, `:human_review` |

#### Metadata in Exports

All metadata is preserved when exporting policies:

```ruby
policy = PamDsl.policy(:my_app)
export = policy.to_h

# Metadata is included at each level
export[:metadata]                           # Policy metadata
export[:fields][:email][:metadata]          # Field metadata
export[:purposes][:analytics][:metadata]    # Purpose metadata
```

This makes metadata available for compliance reporting, auditing, and integration with external systems.

### Using Policies

```ruby
# Get a defined policy
policy = PamDsl.policy(:user_data)

# Check if field is allowed for purpose
policy.allowed?(:email, :marketing)  # => true
policy.allowed?(:ssn, :marketing)    # => false

# Record consent for subject before validating (required for consent-based purposes)
policy.consent_policy.grant_consent(purpose: :marketing, subject: current_user.id)

# Validate data access — subject: is always required
begin
  policy.validate_access!([:email, :name], :marketing, subject: current_user.id)
rescue PamDsl::ConsentRequiredError => e
  puts "Consent error: #{e.message}"
rescue PamDsl::SensitivityViolationError => e
  puts "Art. 9 violation: #{e.message}"
end

# Get field and apply transformation
field = policy.get_field(:email)
masked = field.apply_transformation(:display, "john@example.com")
# => "j***@example.com"

# Get sensitive fields
policy.sensitive_fields.each do |field|
  puts "#{field.name} is #{field.sensitivity}"
end

# Get retention duration
duration = policy.retention_for('User', field_name: :email)
# => 2.years

# Export policy as hash
policy_hash = policy.to_h
```

### Advanced Examples

#### Multi-Purpose Field

```ruby
field :email, type: :email, sensitivity: :internal do
  allow_for :authentication, :communication, :account_recovery

  transform :display do |value|
    local, domain = value.split('@')
    "#{local[0]}***@#{domain}"
  end

  transform :api_response do |value|
    { email: value, verified: true }
  end

  meta :required, true
  meta :unique, true
end
```

#### Purpose with Complex Requirements

```ruby
purpose :payment_processing do
  describe "Processing customer payments securely"
  basis :contract

  requires :billing_address, :payment_method
  optionally :billing_email, :invoice_preferences

  meta :pci_dss_compliant, true
  meta :encryption_required, true
  meta :audit_logging, true
end
```

#### Conditional Retention

```ruby
retention do
  for_model 'Contract' do
    keep_for 10.years

    when do |context|
      # Keep active contracts longer
      context[:status] == 'active'
    end

    on_expiry :archive
  end

  for_model 'SupportTicket' do
    keep_for 3.years

    when do |context|
      # Keep escalated tickets longer
      !context[:escalated]
    end
  end
end
```

## Privacy Reporting

PAM DSL includes a comprehensive reporting system for GDPR compliance documentation.

### Quick Reports via Rake Tasks

```bash
# Policy summary
bundle exec rake pam_dsl:report:policy

# GDPR Article 30 Records of Processing Activities
bundle exec rake pam_dsl:report:article_30

# Full compliance report
bundle exec rake pam_dsl:report:full

# Export to JSON
bundle exec rake "pam_dsl:report:export[reports/privacy_report.json]"

# PII analysis from event store (requires Lyra)
bundle exec rake pam_dsl:report:pii
bundle exec rake pam_dsl:report:retention
bundle exec rake pam_dsl:report:access_patterns
```

### Reporter Class

```ruby
# Create a reporter
reporter = PamDsl::Reporter.new(
  :my_policy,
  organization: "My Company",
  dpo_contact: "dpo@example.com",
  event_store: Rails.configuration.event_store  # Optional
)

# Generate reports (output to stdout)
reporter.policy_summary
reporter.article_30_report
reporter.full_report

# With event store integration
reporter.pii_analysis       # Analyze PII in events
reporter.retention_check    # Check retention compliance
reporter.access_patterns    # Show access patterns by hour/operation

# Export
reporter.export_json("reports/privacy.json")
report_hash = reporter.to_h
```

### Report Contents

**Policy Summary:**
- PII fields with types, sensitivity levels, and transformations
- Processing purposes with legal bases
- Retention rules per model
- Sensitivity breakdown chart

**Article 30 Report:**
- Controller and DPO information
- Processing activities with legal basis citations (GDPR Art. 6(1)(a-f))
- Data categories and retention periods
- Data subject rights implementation status
- Technical and organizational measures

**Event Store Analysis (requires Lyra):**
- PII field occurrence counts
- Retention compliance status per model
- Access patterns by operation type and time

## Policy Generation

Generate PAM DSL policies automatically from your codebase.

### Generate from ActiveRecord Models

```bash
# Scan models and generate policy
bundle exec rake "pam_dsl:generate:from_models[my_app_policy]"

# Generate basic template
bundle exec rake "pam_dsl:generate:policy[my_app_policy]"
```

### PolicyGenerator Class

```ruby
generator = PamDsl::PolicyGenerator.new(
  :my_app,
  output_path: "config/initializers/pam_dsl_policy.rb"
)

# Generate from template
generator.generate

# Scan models for PII fields
generator.generate_from_models
```

### Detection Patterns

The generator detects PII fields by name patterns:

| Type | Patterns Detected |
|------|-------------------|
| Email | `email`, `email_address`, `user_email` |
| Phone | `phone`, `mobile`, `telephone`, `fax` |
| Name | `name`, `firstname`, `lastname`, `full_name` |
| Address | `address`, `street`, `city`, `postal_code`, `zip` |
| Financial | `iban`, `bic`, `account_number`, `routing_number` |
| Credit Card | `card_number`, `credit_card`, `cvv`, `card_` |
| Identifiers | `ssn`, `vat_number`, `tax_id`, `passport` |
| Location | `latitude`, `longitude`, `location`, `coordinates` |
| IP Address | `ip_address`, `ip`, `remote_ip` |
| Date of Birth | `dob`, `date_of_birth`, `birth_date`, `birthday` |

**Exclusion Patterns** (to reduce false positives):
- Timestamps: `*_at` (e.g., `created_at`, `email_sent_at`)
- Amounts: `*_amount` (e.g., `vat_amount`, `total_amount`)
- Foreign keys: `*_id` (e.g., `user_id`)
- Status fields: `*_status`, `*_reason`
- Boolean flags: `is_*`, `has_*`, `*_enabled`
- Security fields: `*_digest`, `*_token`, `encrypted_*`
- Code fields: `*_code` (e.g., `country_code`, but `postal_code` is whitelisted)

### PIIDetector Configuration

The `PIIDetector` class provides automatic PII field detection with configurable matching behavior.

#### Matching Modes

PAM DSL supports two matching modes for PII detection:

| Mode | Setting | Behavior |
|------|---------|----------|
| **Partial** (default) | `partial_match = true` | Matches field names *containing* PII keywords with word boundaries |
| **Exact** | `partial_match = false` | Only matches specific known field names |

#### Partial Matching (Default)

Partial matching uses word boundary patterns to detect PII in compound field names:

```ruby
# These are all detected as PII with partial matching enabled (default)
PamDsl::PIIDetector.contains_pii?(:email)           # => true
PamDsl::PIIDetector.contains_pii?(:customer_email)  # => true
PamDsl::PIIDetector.contains_pii?(:billing_phone)   # => true
PamDsl::PIIDetector.contains_pii?(:user_name)       # => true
PamDsl::PIIDetector.contains_pii?(:home_address)    # => true
```

Word boundaries are detected at:
- Start of string or after underscore (`_`)
- End of string, before underscore, or before uppercase (camelCase suffix)

**Important**: snake_case naming is preferred for reliable detection. camelCase prefix detection (e.g., `customerEmail`) is not supported—use `customer_email` instead. camelCase suffix detection works (e.g., `emailAddress` is detected).

#### Exact Matching

For stricter control, switch to exact matching mode:

```ruby
# Configure exact matching
PamDsl::PIIDetector.partial_match = false

# Now only exact field names are detected
PamDsl::PIIDetector.contains_pii?(:email)           # => true (exact match)
PamDsl::PIIDetector.contains_pii?(:user_email)      # => true (in exact patterns)
PamDsl::PIIDetector.contains_pii?(:customer_email)  # => false (not in exact patterns)
PamDsl::PIIDetector.contains_pii?(:billing_phone)   # => false (not in exact patterns)

# Reset to default (partial matching)
PamDsl::PIIDetector.reset!
```

#### When to Use Each Mode

| Use Case | Recommended Mode |
|----------|------------------|
| New applications with varied naming conventions | Partial (default) |
| Legacy databases with unpredictable field names | Partial (default) |
| Applications with strict naming conventions | Exact |
| Minimizing false positives in large schemas | Exact |
| GDPR compliance scanning | Partial (default) |

#### Configuration in Rails Initializer

```ruby
# config/initializers/pam_dsl.rb

# Option 1: Use partial matching (default, recommended for most cases)
PamDsl::PIIDetector.partial_match = true

# Option 2: Use exact matching (stricter, fewer false positives)
PamDsl::PIIDetector.partial_match = false
```

#### Direct PIIDetector Usage

```ruby
# Check if a field contains PII
PamDsl::PIIDetector.contains_pii?(:customer_email)  # => true

# Get the PII type
PamDsl::PIIDetector.pii_type(:customer_email)       # => :email

# Get sensitivity level
PamDsl::PIIDetector.sensitivity(:customer_email)   # => :confidential

# Detect PII in a hash of attributes
data = { customer_email: "test@example.com", order_id: 123 }
pii_fields = PamDsl::PIIDetector.detect(data)
# => { customer_email: { type: :email, value: "...", sensitive: false, sensitivity: :confidential } }

# Mask PII for display
PamDsl::PIIDetector.mask("test@example.com", :email)  # => "t***@example.com"
```

#### Extracting PII from Record Collections

The `extract_pii_from_records` method scans any collection of records for PII fields. It uses a generic interface with extractors, making it compatible with any data source—Lyra events, RubyEventStore events, ActiveRecord models, or plain hashes.

```ruby
# Basic usage with hash records
records = [
  { id: 1, email: "alice@example.com", name: "Alice", status: "active" },
  { id: 2, email: "bob@example.com", name: "Bob", status: "inactive" }
]

inventory = PamDsl::PIIDetector.extract_pii_from_records(
  records,
  attribute_extractor: ->(r) { r }
)
# => { email: [{ field: :email, value: "alice@...", pii_type: :email, sensitivity: :confidential }, ...],
#      name: [{ field: :name, value: "Alice", pii_type: :name, sensitivity: :internal }, ...] }
```

**With Metadata Extraction** (for tracing PII back to source records):

```ruby
# Extract PII with record metadata for audit trails
inventory = PamDsl::PIIDetector.extract_pii_from_records(
  records,
  attribute_extractor: ->(r) { r },
  metadata_extractor: ->(r) { { record_id: r[:id], source: "import" } }
)
# Each entry includes: { field:, value:, pii_type:, sensitivity:, record_id:, source: }
```

**With Event Store Events** (RubyEventStore, Lyra, or custom):

```ruby
# RubyEventStore events
inventory = PamDsl::PIIDetector.extract_pii_from_records(
  event_store.read.to_a,
  attribute_extractor: ->(e) { e.data[:attributes] || {} },
  metadata_extractor: ->(e) {
    { event_id: e.event_id, timestamp: e.metadata[:timestamp] }
  }
)

# Lyra events (Lyra provides a convenience wrapper)
inventory = Lyra::Privacy::PIIDetector.extract_from_event_stream(events)
```

**With ActiveRecord Models**:

```ruby
# Scan database records for PII
inventory = PamDsl::PIIDetector.extract_pii_from_records(
  User.where(created_at: 1.month.ago..),
  attribute_extractor: ->(u) { u.attributes },
  metadata_extractor: ->(u) { { id: u.id, type: u.class.name } }
)
```

**Return Value Structure**:

The method returns a hash grouped by PII type:

```ruby
{
  email: [
    { field: :email, value: "alice@example.com", pii_type: :email,
      sensitivity: :confidential, event_id: "evt-1", ... },
    { field: :contact_email, value: "bob@example.com", ... }
  ],
  name: [
    { field: :name, value: "Alice", pii_type: :name, sensitivity: :internal, ... }
  ],
  phone: [...]
}
```

This structure enables:
- PII inventory reports for GDPR compliance
- Data lineage tracking
- Retention policy enforcement
- Audit trail generation

### PIIMasker

The `PIIMasker` class provides batch masking of PII fields in data structures. It uses `PIIDetector` for field detection and applies type-specific masking strategies.

#### Basic Usage

```ruby
# Mask all PII in a hash (default: partial masking)
data = { email: "alice@example.com", name: "Alice Smith", status: "active" }
masked = PamDsl::PIIMasker.mask(data)
# => { email: "a***@example.com", name: "Alice ***", status: "active" }

# Full redaction mode
masked = PamDsl::PIIMasker.mask(data, strategy: :full)
# => { email: "[REDACTED]", name: "[REDACTED]", status: "active" }

# Redact only sensitive PII (ssn, credit_card, financial, health, biometric)
data = { email: "alice@example.com", ssn: "123-45-6789" }
masked = PamDsl::PIIMasker.mask(data, strategy: :redact_sensitive)
# => { email: "a***@example.com", ssn: "[REDACTED]" }
```

#### Masking Strategies

| Strategy | Behavior |
|----------|----------|
| `:partial` (default) | Type-specific partial masking (e.g., `a***@example.com`) |
| `:full` | Complete redaction with `[REDACTED]` |
| `:redact_sensitive` | Full redaction for sensitive types, partial for others |

#### Masking Individual Fields

```ruby
# Mask a value by field name
PamDsl::PIIMasker.mask_field("alice@example.com", :email)
# => "a***@example.com"

# Works with compound field names (partial matching)
PamDsl::PIIMasker.mask_field("alice@example.com", :customer_email)
# => "a***@example.com"

# Non-PII fields return original value
PamDsl::PIIMasker.mask_field("active", :status)
# => "active"

# Mask by known PII type
PamDsl::PIIMasker.mask_by_type("123-45-6789", :ssn)
# => "***REDACTED***"
```

#### Masking Record Collections

The `mask_records` method masks PII in any collection using extractors, similar to `extract_pii_from_records`:

```ruby
# With hash records
records = [
  { id: 1, email: "alice@example.com" },
  { id: 2, email: "bob@example.com" }
]

masked = PamDsl::PIIMasker.mask_records(
  records,
  attribute_extractor: ->(r) { r },
  attribute_setter: ->(r, masked_attrs) { masked_attrs }
)
# => [{ id: 1, email: "a***@example.com" }, { id: 2, email: "b***@example.com" }]

# With custom objects
masked = PamDsl::PIIMasker.mask_records(
  events,
  attribute_extractor: ->(e) { e.data },
  attribute_setter: ->(e, masked_data) { e.class.new(e.id, masked_data) },
  strategy: :full
)
```

#### Integration with Lyra

Lyra provides a convenience wrapper for masking events:

```ruby
# Mask all events in a collection
masked_events = Lyra::Privacy::PIIMasker.mask_events(events)

# With full redaction
masked_events = Lyra::Privacy::PIIMasker.mask_events(events, strategy: :full)
```

### GDPRCompliance

The `GDPRCompliance` class provides comprehensive GDPR data subject rights functionality. It works with any event source through configurable extractors.

#### GDPR Rights Supported

| Right | Article | Method |
|-------|---------|--------|
| Access | Art. 15 | `data_export` |
| Erasure ("Right to be Forgotten") | Art. 17 | `right_to_be_forgotten_report` |
| Portability | Art. 20 | `portable_export` |
| Rectification | Art. 16 | `rectification_history` |
| Processing Records | Art. 30 | `processing_activities` |

#### Basic Usage

```ruby
# With any event source (using extractors)
compliance = PamDsl::GDPRCompliance.new(
  subject_id: user.id,
  subject_type: 'User',
  record_reader: ->(subject_id, subject_type) {
    # Return events for this subject from your event store
    EventStore.events_for_user(subject_id)
  }
)

# Generate Subject Access Request (SAR) report
report = compliance.data_export
# => { subject: { id: 123, type: 'User' },
#      events: [...],
#      pii_inventory: { email: [...], name: [...] },
#      data_lineage: { email: [{ timestamp: ..., operation: :created }, ...] } }

# Right to be forgotten analysis
erasure = compliance.right_to_be_forgotten_report
# => { total_events: 47, events_with_pii: 23, affected_models: ['User', 'Order'],
#      deletion_strategy: :batch_deletion }

# Data portability export
json = compliance.portable_export(format: :json)
csv = compliance.portable_export(format: :csv)
xml = compliance.portable_export(format: :xml)
```

#### Custom Extractors

For non-standard event formats, provide custom extractors:

```ruby
# RubyEventStore example
compliance = PamDsl::GDPRCompliance.new(
  subject_id: user.id,
  record_reader: ->(sid, stype) {
    event_store.read.stream("User$#{sid}").to_a
  },
  attribute_extractor: ->(e) { e.data[:attributes] || {} },
  timestamp_extractor: ->(e) { e.metadata[:timestamp] },
  operation_extractor: ->(e) { e.data[:operation]&.to_sym },
  model_class_extractor: ->(e) { e.data[:model_class] },
  model_id_extractor: ->(e) { e.data[:model_id] },
  changes_extractor: ->(e) { e.data[:changes] || {} },
  retention_policy: {
    default: { duration: 7.years },
    'Invoice' => { duration: 10.years }
  }
)
```

#### Retention Compliance

Check if data retention policies are being followed:

```ruby
compliance.retention_compliance_check
# => [
#   { model_class: 'User', total_events: 5, expired_events: 0, compliance_status: :compliant },
#   { model_class: 'Log', total_events: 100, expired_events: 45, compliance_status: :requires_action }
# ]
```

#### Consent Audit

Track and verify consent for data processing:

```ruby
compliance.consent_audit
# => {
#   current_consents: { marketing: { granted: true, timestamp: ... } },
#   consent_history: [...],
#   processing_legitimacy: [{ event_id: 'evt-1', has_consent: true, legitimate: true }, ...]
# }
```

#### Full Compliance Report

Generate a comprehensive report covering all GDPR aspects:

```ruby
compliance.full_report
# => {
#   data_export: { ... },
#   erasure_report: { ... },
#   rectification_history: [...],
#   processing_activities: [...],
#   retention_compliance: [...],
#   consent_audit: { ... }
# }
```

#### Integration with Lyra

Lyra provides a convenience wrapper that auto-configures GDPRCompliance:

```ruby
# Lyra automatically uses its event store and extractors
compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: user.id)
report = compliance.data_export
```

### Generated Output

The generator creates a complete policy file with:
- Field definitions with appropriate types and sensitivity
- Auto-generated transformations for masking
- Suggested processing purposes based on field types
- Model-specific retention rules (10 years for financial models)
- Rails configuration boilerplate

## Rails Integration

### Configuration

```ruby
# config/initializers/lyra.rb or pam_dsl.rb

# Define your policy
PamDsl.define_policy :my_app do
  field :email, type: :email, sensitivity: :confidential
  # ...
end

# Configure reporting defaults
Rails.application.config.pam_dsl.default_policy = :my_app
Rails.application.config.pam_dsl.organization = "My Company Inc."
Rails.application.config.pam_dsl.dpo_contact = "privacy@mycompany.com"
```

### Available Rake Tasks

```bash
# Reporting
rake pam_dsl:report:policy          # Policy summary
rake pam_dsl:report:article_30      # GDPR Article 30 report
rake pam_dsl:report:full            # Full compliance report
rake pam_dsl:report:pii             # PII analysis (requires Lyra)
rake pam_dsl:report:retention       # Retention compliance (requires Lyra)
rake pam_dsl:report:access_patterns # Access patterns (requires Lyra)
rake pam_dsl:report:export[path]    # Export to JSON

# Generation
rake pam_dsl:generate:policy[name]       # Generate template policy
rake pam_dsl:generate:from_models[name]  # Generate from model scan

# Aliases
rake privacy:report                 # Same as pam_dsl:report:full
rake privacy:policy                 # Same as pam_dsl:report:policy
rake privacy:article_30             # Same as pam_dsl:report:article_30
```

## Integration with Lyra

PAM DSL is designed to integrate seamlessly with Lyra:

```ruby
# Define policy
PamDsl.define_policy :university_system do
  field :student_id, type: :identifier, sensitivity: :internal
  field :email, type: :email, sensitivity: :internal
  field :ssn, type: :ssn, sensitivity: :restricted

  purpose :enrollment do
    basis :contract
    requires :student_id, :email
  end

  retention do
    for_model 'Student' do
      keep_for 10.years
      on_expiry :anonymize
    end
  end
end

# Use in Lyra
class Student < ApplicationRecord
  monitor_with_lyra privacy_policy: :university_system
end
```

## API Reference

### PamDsl Module

- `PamDsl.define_policy(name, &block)` - Define a new policy
- `PamDsl.policy(name)` - Get a defined policy
- `PamDsl.reset!` - Clear all policies

### Policy

- `field(name, type:, sensitivity:, &block)` - Define a field
- `purpose(name, &block)` - Define a purpose
- `retention(&block)` - Configure retention
- `consent(&block)` - Configure consent
- `meta(key, value)` - Add custom metadata to policy
- `allowed?(field, purpose)` - Check if field is allowed for purpose
- `validate_access!(fields, purpose, subject:)` - Validate access for a data subject; raises `ConsentRequiredError`, `SensitivityViolationError`, or `InvalidFieldError`
- `consent_policy` - Access the `ConsentPolicy` to populate the runtime consent store
- `lia_compliance_gaps` - Returns purposes with `:legitimate_interests` basis that have not called `lia_documented!`
- `sensitive_fields` - Get all fields with confidential/restricted sensitivity
- `restricted_fields` - Get all fields with restricted sensitivity
- `metadata` - Access policy metadata hash
- `to_h` - Export policy as hash (includes all metadata)

### Field

- `allow_for(*purposes)` - Allow field for purposes
- `transform(context, &block)` - Define transformation
- `meta(key, value)` - Add custom metadata
- `metadata` - Access field metadata hash
- `sensitive?` - Check if field is confidential or restricted
- `restricted?` - Check if field is restricted
- `allowed_for?(purpose)` - Check if allowed for specific purpose
- `apply_transformation(context, value)` - Apply defined transformation

### Purpose

- `describe(text)` - Set description
- `basis(legal_basis)` - Set legal basis (GDPR Art. 6)
- `lia_documented!(value = true)` - Record that a Legitimate Interests Assessment has been conducted for this `:legitimate_interests` purpose; pass `false` to unset
- `lia_documented?` - True when LIA has been recorded
- `art9_basis(*bases)` - Declare one or more Art. 9(2) bases; required when the purpose accesses Article-9 special-category-**type** fields (e.g. `:health`, `:biometric`), independently of the `:restricted` risk level; multiple calls accumulate
- `requires(*fields)` - Define required fields
- `optionally(*fields)` - Define optional fields
- `meta(key, value)` - Add custom metadata
- `metadata` - Access purpose metadata hash
- `requires_consent?` - Check if purpose requires consent (basis is :consent)
- `art9_basis?` - True when at least one Art. 9(2) basis is declared
- `art9_bases` - Array of declared Art. 9(2) bases
- `all_fields` - Get all fields (required + optional)
- `requires_field?(field)` - Check if field is required
- `allows_field?(field)` - Check if field is allowed

### Retention

- `default(duration)` - Set default retention
- `for_model(model_class, &block)` - Define model retention
- `keep_for(duration)` - Set retention duration
- `field(name, duration:)` - Set field retention
- `on_expiry(strategy)` - Set deletion strategy

### ConsentPolicy

DSL configuration (policy-time):
- `for_purpose(purpose, &block)` - Declare a consent requirement for a purpose
- `required!(value)` - Set if required
- `granular!(value)` - Enable granular consent
- `withdrawable!(value)` - Set if withdrawable
- `expires_in(duration)` - Set expiration window

Runtime consent store (per-subject, accessed via `policy.consent_policy`):
- `grant_consent(purpose:, subject:, granted_at: Time.current)` - Record that subject granted consent
- `withdraw_consent(purpose:, subject:)` - Record that subject withdrew consent
- `requirement_for(purpose)` - Look up the `ConsentRequirement` for a purpose
- `required_for?(purpose)` - True if consent is required for the purpose
- `store` - The underlying `ConsentStore`

### ConsentStore

- `grant(purpose:, subject:, granted_at:)` - Add a consent record to CS
- `withdraw(purpose:, subject:)` - Mark a record as withdrawn
- `record_for(purpose, subject)` - Returns the `ConsentRecord` or nil
- `granted?(purpose, subject)` - True when a non-withdrawn record exists

### ConsentRecord

- `purpose` - Purpose symbol
- `subject` - Subject identifier
- `granted_at` - Time consent was granted
- `withdrawn_at` - Time consent was withdrawn, or nil
- `withdrawn?` - True if consent has been withdrawn
- `state` - `:granted` or `:withdrawn`

### Reporter

- `Reporter.new(policy_name, organization:, dpo_contact:, event_store:, output:)` - Create reporter
- `policy_summary` - Print policy summary
- `article_30_report` - Print GDPR Article 30 report
- `pii_analysis` - Analyze PII in event store
- `retention_check` - Check retention compliance
- `access_patterns` - Show access patterns
- `full_report` - Print complete report
- `export_json(path)` - Export to JSON file
- `to_h` - Export as hash

### PolicyGenerator

- `PolicyGenerator.new(name, output_path:)` - Create generator
- `generate` - Generate template policy file
- `generate_from_models` - Scan models and generate policy
- `scan_models` - Detect PII fields in ActiveRecord models

### PIIDetector

- `PIIDetector.detect(attributes)` - Detect PII in a hash, returns `{ field: { type:, value:, sensitivity: } }`
- `PIIDetector.contains_pii?(field_name)` - Check if a field name is PII
- `PIIDetector.pii_type(field_name)` - Get PII type for a field (`:email`, `:phone`, etc.)
- `PIIDetector.sensitivity(field_name)` - Get sensitivity level for a field
- `PIIDetector.sensitive?(pii_type)` - Check if PII type requires special protection
- `PIIDetector.mask(value, pii_type)` - Mask a PII value for safe display
- `PIIDetector.extract_pii_from_records(records, attribute_extractor:, metadata_extractor:)` - Extract PII from any record collection
- `PIIDetector.partial_match=(bool)` - Enable/disable partial matching mode
- `PIIDetector.reset!` - Reset to default settings

### PIIMasker

- `PIIMasker.mask(attributes, strategy:)` - Mask all PII in a hash
- `PIIMasker.mask_field(value, field_name, strategy:)` - Mask a value by field name
- `PIIMasker.mask_by_type(value, pii_type, strategy:)` - Mask a value by PII type
- `PIIMasker.mask_records(records, attribute_extractor:, attribute_setter:, strategy:)` - Mask PII in a collection

### GDPRCompliance

- `GDPRCompliance.new(subject_id:, subject_type:, record_reader:, **extractors)` - Create compliance handler
- `data_export` - Right to Access (Art. 15) - Full data export
- `right_to_be_forgotten_report` - Right to Erasure (Art. 17) - Deletion analysis
- `portable_export(format:)` - Right to Portability (Art. 20) - Export as JSON/CSV/XML
- `rectification_history` - Right to Rectification (Art. 16) - Correction history
- `processing_activities` - Processing Records (Art. 30) - Activity documentation
- `retention_compliance_check` - Check retention policy compliance
- `consent_audit` - Audit consent records and legitimacy
- `full_report` - Complete GDPR compliance report

## Sensitivity Levels and Legislative Background

PAM DSL uses a four-tier sensitivity classification system that combines regulatory requirements from multiple frameworks. This section explains the legislative basis and practical implications of each level.

### Regulatory Framework Alignment

The sensitivity levels are derived from three primary sources:

| Framework | Relevance | Key Articles/Sections |
|-----------|-----------|----------------------|
| **GDPR** (EU 2016/679) | Primary regulation for EU personal data | Art. 5, 6, 9, 32 |
| **ISO/IEC 27001:2022** | Information security management | Annex A.5.12, A.5.13 |
| **NIST SP 800-122** | US guidance on PII protection | Section 2.2 |

### Sensitivity Level Definitions

#### `:public` - Publicly Accessible Data

**Definition**: Information that is intended for public disclosure or has no privacy implications.

**Regulatory Basis**:
- GDPR Art. 9(2)(e): Data "manifestly made public by the data subject"
- ISO 27001: Public classification level

**Examples**: Published company addresses, public social media handles, product catalogs

**Requirements**: No special handling required

---

#### `:internal` - Internal Use Only

**Definition**: Personal data that requires basic protection but poses low risk if disclosed.

**Regulatory Basis**:
- GDPR Art. 5(1)(f): "Integrity and confidentiality" principle
- GDPR Art. 32: Appropriate security measures
- ISO 27001 A.5.12: Classification of information

**Examples**: Names, business email addresses, IP addresses, user preferences

**GDPR Category**: Regular personal data (Art. 6)

**Requirements**:
- Access control (need-to-know basis)
- Basic audit logging
- Standard encryption in transit

---

#### `:confidential` - Requires Protection

**Definition**: Personal data that could cause harm or distress if disclosed, requiring enhanced protection measures.

**Regulatory Basis**:
- GDPR Art. 5(1)(f): Enhanced integrity and confidentiality
- GDPR Art. 32(1)(a): Pseudonymization and encryption
- GDPR Art. 35: May require Data Protection Impact Assessment (DPIA)
- ISO 27001 A.5.13: Labeling of information
- NIST SP 800-122: Moderate confidentiality impact

**Examples**: Personal email, phone numbers, physical addresses, date of birth, location data, financial transactions

**GDPR Category**: Regular personal data requiring enhanced protection (Art. 6)

**Requirements**:
- Encryption at rest and in transit
- Enhanced access controls with approval workflows
- Comprehensive audit logging
- Data minimization practices
- Defined retention periods
- Breach notification within 72 hours (Art. 33)

---

#### `:restricted` - Highly Restricted Access

**Definition**: Sensitive personal data that could cause significant harm if disclosed, subject to the strictest regulatory requirements.

**Regulatory Basis**:
- GDPR Art. 9: Special categories of personal data (prohibited unless exception applies)
- GDPR Art. 10: Criminal conviction data
- GDPR Art. 35: DPIA mandatory
- PCI DSS: Payment card data requirements
- HIPAA: Health information (US)
- ISO 27001: Confidential/Restricted classification
- NIST SP 800-122: High confidentiality impact

**GDPR Special Categories (Art. 9)**:
- Racial or ethnic origin
- Political opinions
- Religious or philosophical beliefs
- Trade union membership
- Genetic data
- Biometric data (for identification)
- Health data
- Sex life or sexual orientation

**Additional Restricted Data**:
- Social Security Numbers (SSN) / National IDs
- Credit card numbers (PCI DSS scope)
- Bank account details (IBAN, account numbers)
- Tax identifiers (VAT numbers, TIN)
- Passport numbers
- Driver's license numbers

**Requirements**:
- Encryption mandatory (at rest and in transit)
- Strict access controls with multi-factor authentication
- Detailed audit trails with tamper protection
- Data Protection Impact Assessment (DPIA) required
- Explicit consent or legal exception documented (Art. 9(2))
- Breach notification within 72 hours with enhanced detail
- Appointed Data Protection Officer (DPO) oversight
- Regular security assessments
- Data retention strictly limited

### PII Type to Sensitivity Mapping

The following table shows the default sensitivity assignments in PAM DSL:

| PII Type | Default Sensitivity | GDPR Category | Regulatory Notes |
|----------|---------------------|---------------|------------------|
| `name` | `:internal` | Regular (Art. 6) | Low risk in isolation |
| `email` | `:confidential` | Regular (Art. 6) | Contact data, spam risk |
| `phone` | `:confidential` | Regular (Art. 6) | Contact data, spam risk |
| `address` | `:confidential` | Regular (Art. 6) | Physical location risk |
| `ip_address` | `:internal` | Regular (Art. 6) | CJEU: Personal data when linkable |
| `date_of_birth` | `:confidential` | Regular (Art. 6) | Age discrimination risk |
| `location` | `:confidential` | Regular (Art. 6) | Movement tracking risk |
| `ssn` | `:restricted` | National ID (Art. 87) | High identity theft risk |
| `credit_card` | `:restricted` | Financial | PCI DSS requirements |
| `financial` | `:restricted` | Financial | Bank account data |
| `identifier` | `:restricted` | National ID | VAT, tax IDs, passports |
| `health` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |
| `biometric` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |

### Legal Bases by Sensitivity

`sensitivity` is an Article 32 **risk** tier; it determines the strength of protection, not the legal basis. The Article 9(2) requirement is driven separately by a field's **type** (see below), not by its sensitivity level.

| Sensitivity (risk tier) | Typical Article 6 Legal Bases | GDPR Articles |
|-------------|---------------------|---------------|
| `:public` | Not applicable | N/A |
| `:internal` | Contract, Legitimate Interest | Art. 6(1)(b), (f) |
| `:confidential` | Contract, Consent, Legal Obligation | Art. 6(1)(a), (b), (c) |
| `:restricted` | Contract, Legal Obligation, Consent (highest-risk ordinary data, e.g. financial/national-ID) | Art. 6(1)(a), (b), (c) |

**Article 9 special categories** (independent of the table above): a field whose **type** is `:health` or `:biometric` additionally requires an `art9_basis` on every purpose that accesses it — at any sensitivity level — under Art. 9(2)(a)–(j).

### Practical Implementation

```ruby
PamDsl.define_policy :gdpr_compliant do
  # Internal - basic personal data
  field :display_name, type: :name, sensitivity: :internal do
    allow_for :personalization, :communication
    meta :gdpr_basis, "Art. 6(1)(b) - Contract performance"
  end

  # Confidential - requires enhanced protection
  field :email, type: :email, sensitivity: :confidential do
    allow_for :authentication, :account_recovery
    meta :gdpr_basis, "Art. 6(1)(b) - Contract performance"
    meta :encryption_required, true
    meta :retention_period, "Account lifetime + 2 years"
  end

  # Special-category TYPE (Art. 9) at the restricted risk tier
  field :health_status, type: :health, sensitivity: :restricted do
    allow_for :medical_services
    meta :dpia_required, true
    meta :encryption_algorithm, "AES-256"
    meta :access_approval_required, true
  end

  purpose :medical_services do
    describe "Health data processing for care provision"
    basis :contract
    art9_basis :health_care        # Art. 9(2)(h) — mandatory for Art. 9 type fields (:health/:biometric)
    art9_basis :explicit_consent   # Art. 9(2)(a) — additional basis
    requires :health_status
  end

  # Restricted - financial identifier
  field :vat_number, type: :identifier, sensitivity: :restricted do
    allow_for :invoicing, :tax_compliance
    meta :gdpr_basis, "Art. 6(1)(c) - Legal obligation"
    meta :retention_period, "10 years (tax law)"
  end
end
```

### References

- **GDPR Full Text**: [EUR-Lex 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj)
- **ISO/IEC 27001:2022**: Information Security Management Systems
- **NIST SP 800-122**: Guide to Protecting the Confidentiality of PII
- **Article 29 Working Party Guidelines**: [EDPB Guidelines](https://edpb.europa.eu/our-work-tools/general-guidance/guidelines-recommendations-best-practices_en)
- **PCI DSS v4.0**: Payment Card Industry Data Security Standard
- **CJEU Breyer Case (C-582/14)**: IP addresses as personal data

## License

MIT License - see LICENSE file

## Contributing

This is part of the ORFEAS PhD thesis research. Contributions welcome.
