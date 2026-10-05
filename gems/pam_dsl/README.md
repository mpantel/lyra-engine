# PAM DSL - Privacy Attribute Matrix DSL

A declarative Domain-Specific Language (DSL) for defining privacy policies, PII fields, consent requirements, and retention rules using the Privacy Attribute Matrix (PAM) model for privacy-aware event monitoring.

## Overview

PAM DSL provides a fluent, expressive way to define privacy policies using the Privacy Attribute Matrix (PAM) model. It can be used by privacy-aware monitoring systems like Lyra and helps you:

- **Define PII fields** with type and sensitivity classification
- **Specify processing purposes** with legal bases (GDPR compliant)
- **Configure retention policies** with field-level granularity
- **Manage consent requirements** with expiration and granular control
- **Validate data access** against defined policies, blocking violations (strict mode) or recording them (audit mode)
- **Declare the Article 30 record of processing**: data subjects, recipients, international transfers and security measures

## Installation

The gem is published as `orfeas_pam_dsl`; the library it loads is `pam_dsl`. Add to your Gemfile:

```ruby
gem 'orfeas_pam_dsl', require: 'pam_dsl'

# Inside the Lyra monorepo
gem 'orfeas_pam_dsl', path: 'gems/pam_dsl', require: 'pam_dsl'
```

Ruby 4.0 or later is required. There are no runtime dependencies: ActiveSupport is used when it is loaded (as in a Rails app), and otherwise a small standard-library polyfill provides the duration helpers (`7.years`, `2.days.ago`) with a fixed 30-day month and 365-day year.

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
`:email`, `:name`, `:phone`, `:address`, `:ssn`, `:date_of_birth`, `:ip_address`, `:online_identifier`, `:credit_card`, `:financial`, `:health`, `:biometric`, `:location`, `:identifier`, `:credential`, `:token`, `:payment_token`, `:custom`

Any other type, or a sensitivity outside the four levels, raises `PamDsl::InvalidFieldError` when the field is declared. A field's sensitivity defaults to `:internal`.

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

#### Article 30 Declarations

The record of processing activities (GDPR Art. 30(1)) needs facts that access control does not: who the data is about, who receives it, whether it leaves the EEA, and how it is protected. A purpose declares the first three; the policy declares the security measures.

```ruby
PamDsl.define_policy :shop do
  security_measures "TLS in transit", "role-based access", "encrypted backups"  # Art. 30(1)(g)

  purpose :payment_processing do
    basis :contract
    requires :email, :billing_address
    data_subjects "customers"                                      # Art. 30(1)(c)
    recipients "card payment processor", "tax authority"           # Art. 30(1)(d)
    transfer to: "US", safeguard: :standard_contractual_clauses    # Art. 30(1)(e)
  end

  purpose :order_fulfillment do
    basis :contract
    requires :email
    data_subjects "customers"
    recipients "shipping partner"
    no_transfers!                                                  # declares that there are none
  end
end

policy = PamDsl.policy(:shop)
policy.article_30_gaps   # => [] when every item is declared
```

`data_subjects`, `recipients` and `security_measures` accumulate across calls and store strings; called with no arguments they return what has been declared. Each `transfer` call adds `{ to:, safeguard: }` (both stored as strings). A purpose's transfers are undeclared until it calls `transfer` or `no_transfers!`, so "none" must be stated rather than assumed.

`policy.article_30_gaps` returns what the record cannot state because the policy does not declare it, as `[purpose_name, clause]` pairs (`purpose_name` is nil for the policy-wide security measures), for example `[:order_fulfillment, "Art. 30(1)(d) categories of recipients"]`. The Article 30 report prints these gaps in its completeness section.

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

    # Conditional retention (`when` is a Ruby keyword: call it on self)
    for_model 'Transaction' do
      keep_for 10.years
      self.when do |context|
        context[:transaction_type] == 'financial'
      end
    end
  end
end
```

The default retention is 7 years and the default deletion strategy `:soft_delete`. Conditions given with `self.when` are stored on the rule and evaluated by `RetentionRule#applies_to?(context)` (true when every condition holds, or there are none); `retention_for` returns the rule's duration without evaluating them.

**Deletion Strategies:**
- `:hard_delete` - Permanently delete data
- `:soft_delete` - Mark as deleted but keep data
- `:anonymize` - Remove PII while keeping aggregated data
- `:archive` - Move to long-term storage

### Consent Management

Consent has two distinct layers in PAM:

1. **Policy-time spec** (`consent` DSL block) — declares *what* consent is required per purpose
2. **Runtime consent store** — records each data subject's consent and where it stands: pending, granted, expired or withdrawn

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

Each `(purpose, subject)` pair has a `ConsentRecord` in one of four states:

- `:pending` - consent requested (`request_consent`), not yet granted
- `:granted` - consent active; the only state in which access is allowed
- `:expired` - the record's `expires_at` has passed (derived when the state is read)
- `:withdrawn` - the subject revoked consent

Expired and withdrawn are final for that record. A new `request_consent` or `grant_consent` starts a fresh record (re-consent). `grant_consent` sets `expires_at` from the requirement's `expires_in`, counted from `granted_at`.

```ruby
policy = PamDsl.policy(:my_policy)

# Optionally record that consent was requested (state :pending)
policy.consent_policy.request_consent(purpose: :marketing, subject: 42)

# Subject 42 grants marketing consent (pending -> granted)
policy.consent_policy.grant_consent(purpose: :marketing, subject: 42)

# Subject 43 grants with a backdated timestamp (e.g. loaded from DB)
policy.consent_policy.grant_consent(
  purpose: :marketing,
  subject: 43,
  granted_at: 6.months.ago
)

# Subject 43 withdraws consent
policy.consent_policy.withdraw_consent(purpose: :marketing, subject: 43)
```

`validate_access!` then looks up the store automatically — no need to pass a boolean. The check applies when the purpose's basis is `:consent` and its consent requirement is `required!` (the default once `for_purpose` declares one):

```ruby
# Passes: the record's state is :granted
policy.validate_access!([:email], :marketing, subject: 42)

# Raises ConsentRequiredError: no record for subject 99
policy.validate_access!([:email], :marketing, subject: 99)

# Raises ConsentRequiredError: the record is withdrawn
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
  meta :organization, "Example University"
  meta :dpo_email, "dpo@example.com"
  meta :policy_version, "2.1"
  meta :gdpr_compliant, true
  meta :last_review_date, "2026-06-02"
  meta :next_review_date, "2027-06-02"

  # ... fields, purposes, etc.
end

# Access policy metadata
policy = PamDsl.policy(:my_app)
policy.metadata[:organization]      # => "Example University"
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
purpose.lia_documented?           # => true
purpose.metadata[:lia_date]       # => "2026-06-02"
purpose.metadata[:dpia_reference] # => nil (not set on :analytics)
```

#### Common Use Cases for Metadata

| Use Case | Level | Example Keys |
|----------|-------|--------------|
| Compliance tracking | Policy | `:gdpr_compliant`, `:ccpa_compliant`, `:last_audit_date` |
| Encryption requirements | Field | `:encryption_required`, `:encryption_algorithm`, `:key_rotation` |
| Data categorization | Field | `:pii_category`, `:special_category_data`, `:children_data` |
| Cross-border transfers | Field | `:cross_border_transfer`, `:adequacy_decision`, `:sccs_required` |
| Third-party sharing | Field | `:third_party_sharing`, `:processors`, `:joint_controllers` |
| LIA documentation | Purpose | `:lia_date`, `:lia_outcome`, `:balancing_test` |
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

Metadata is free-form and PAM does not interpret it. Facts the Article 30 report needs (data subjects, recipients, transfers, security measures) have their own declarations (see [Article 30 Declarations](#article-30-declarations)), and so does a completed LIA (`lia_documented!`); the report and `lia_compliance_gaps` read those, not metadata.

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
  policy.validate_access!([:email], :marketing, subject: current_user.id)
rescue PamDsl::ConsentRequiredError => e
  puts "Consent error: #{e.message}"
rescue PamDsl::SensitivityViolationError => e
  puts "Art. 9 violation: #{e.message}"
rescue PamDsl::Error => e
  # UndeclaredPurposeError, InvalidFieldError, PurposeFieldMismatchError
  puts "Access refused: #{e.message}"
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

`validate_access!` checks, in order: the purpose is declared (`UndeclaredPurposeError`), consent is active when the purpose needs it (`ConsentRequiredError`), each field is declared (`InvalidFieldError`) and allowed for the purpose (`PurposeFieldMismatchError`), and a purpose touching an Article 9 type has an Art. 9(2) basis (`SensitivityViolationError`). All errors inherit from `PamDsl::Error`. `policy.access_violations(fields, purpose, subject:)` returns every violation found, in that order, without raising or recording anything.

### Enforcement Modes

What happens when an access fails validation depends on the enforcement mode:

- `:strict` (the default) blocks it: `validate_access!` raises the first violation as its typed error.
- `:audit` lets it through and records every violation found, not only the first: each is logged as a warning (to `Rails.logger` under Rails, standard error otherwise; set another with `PamDsl.logger =`) and passed to the `on_violation` handlers, and `validate_access!` returns `false`. Use it to introduce a policy to a running system and see what it would block before it blocks anything.

`validate_access!` returns `true` for a valid access in either mode.

```ruby
# Globally
PamDsl.enforcement_mode = :audit   # or :strict; anything else raises ArgumentError

# Or per policy, overriding the global mode
PamDsl.define_policy :legacy_crm do
  enforcement :audit
  # ...
end

PamDsl.policy(:legacy_crm).enforcement_mode   # => :audit

# Handle each violation recorded in audit mode
PamDsl.on_violation do |violation|
  # violation is a PamDsl::Enforcement::Violation with
  # policy, purpose, fields, subject, error_class, message, at
  ViolationLog.create!(policy: violation.policy, message: violation.to_s)
end
```

`PamDsl.reset!` clears the registered policies, the global enforcement mode (back to `:strict`) and the violation handlers.

### Access Recorder

`PamDsl.access_recorder` receives every `validate_access!` call, whatever its outcome. It is an object answering `record?(policy)` and `call(access)`; `access` is a `PamDsl::Enforcement::Access` with `policy`, `purpose`, `legal_basis`, `fields`, `subject`, `outcome` (`:granted`, `:audited` or `:denied`), `violations` and `at`. The recorder runs before `validate_access!` returns or raises, and an error it raises propagates, so an access that cannot be recorded does not go ahead.

```ruby
class AccessAudit
  def self.record?(_policy) = true
  def self.call(access) = Rails.logger.info("#{access.outcome}: #{access.purpose} #{access.fields}")
end

PamDsl.access_recorder = AccessAudit
```

There is one recorder per process, set by the host application; Lyra installs its access log (`Lyra::AccessLog`, active when `config.record_access_events` is on). `PamDsl.reset!` leaves the recorder in place.

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

    # The rule applies to active contracts
    self.when do |context|
      context[:status] == 'active'
    end

    on_expiry :archive
  end

  for_model 'SupportTicket' do
    keep_for 3.years

    # The rule applies to tickets that were not escalated
    self.when do |context|
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

# Export to JSON (default path: tmp/privacy_report_<timestamp>.json)
bundle exec rake "pam_dsl:report:export[reports/privacy_report.json]"

# Compare two policies (Markdown report, default reports/policy_comparison.md)
bundle exec rake "pam_dsl:report:compare[policy_v1,policy_v2,reports/comparison.md]"

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

**Article 30 Report** (generated from the declared policy):
- Controller and DPO contact
- Processing activities, one per declared purpose (Art. 30(1)(b)-(e)): description, legal basis with its Art. 6(1) citation, data subjects, data categories (required and optional fields), whether consent is required, recipients, and transfers with their safeguards
- Retention schedule (Art. 30(1)(f)): the default and each model rule, with its deletion strategy and field overrides
- Technical and organisational measures (Art. 30(1)(g)) declared with `security_measures`
- Completeness: every Article 30(1) item the policy does not declare (`article_30_gaps`); undeclared items are also marked NOT DECLARED where they would appear

**Event Store Analysis (requires an event store; the rake tasks use Lyra's):**
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

# Replace an existing config/initializers/pam_dsl_policy.rb
FORCE=1 bundle exec rake "pam_dsl:generate:from_models[my_app_policy]"
```

Both tasks write `config/initializers/pam_dsl_policy.rb` and refuse to overwrite an existing file there unless `FORCE=1` is set, so a reviewed policy is not replaced by a fresh draft. The policy name defaults to `application`.

### PolicyGenerator Class

```ruby
generator = PamDsl::PolicyGenerator.new(
  :my_app,
  output_path: "config/initializers/pam_dsl_policy.rb",
  force: false   # true replaces an existing file
)

# Generate from template
generator.generate

# Scan models for PII fields
generator.generate_from_models
```

If the output file already exists and `force:` is false, both methods raise `PamDsl::PolicyGenerator::FileExistsError` before scanning or writing anything (the rake tasks turn this into an abort with the message).

### Detection

`generate_from_models` scans every concrete ActiveRecord model with a table and classifies each column with `PIIDetector` (the same dictionary as the rest of PAM, in its current matching mode; see below). On top of the detector it applies one rule: a bare `name` column counts only in a model that holds other personal data (an address's name does, a product's does not). Columns listed in a model's `ignored_columns` are kept and marked with a comment, since the application cannot see or erase them.

In the default (partial) mode, for example:

| Type | Detected |
|------|----------|
| `:email` | `email`, `email_address`, `customer_email`, `emailAddress` |
| `:phone` | `phone`, `mobile`, `telephone`, `cell`, and names containing them (`billing_phone`) |
| `:name` | `first_name`, `last_name`, `full_name`, `surname`, role names such as `customer_name` or `card_holder_name`, and a bare `name` |
| `:address` | `address`, `address1`, `street`, `city`, `zipcode`, `postal_code`, `country`, `state_name` |
| `:identifier` | `passport`, `tax_id`, `vat_number`, `vat_id`, `license`; also `login`, `username`, `nickname` |
| `:financial` | `iban`, `bic`, `swift`, `account_number`, `routing_number`, `salary`, `income` |
| `:credit_card` | `card_number`, `credit_card`, `cvv`, `cvc`, `last4`, `last_digits` |
| `:location` | `latitude`, `longitude`, `location`, `gps` |
| `:ip_address` | `ip`, `ip_address`, any `*_ip` such as `current_sign_in_ip` |
| `:date_of_birth` | `dob`, `birthday`, `birth_date`, `date_of_birth` |
| `:credential` | `password`, `encrypted_password`, `password_digest`, `api_key`, `secret` |
| `:token` | a person's account and session tokens: `reset_password_token`, `remember_token`, `confirmation_token`, `authentication_token`, `session_token`, `guest_token` |
| `:payment_token` | `stripe_customer_id`, `paypal_account_id`, `gateway_customer_profile_id` (a column named `payment_token` falls under the `*_token` exclusion) |

Not detected by default: `fax` and `coordinates` (the exact mode does match `fax`), and login names are reported as `:identifier`, not `:online_identifier`.

**Exclusions** (checked first, to avoid false positives): timestamps and dates (`*_at`, `*_on`, `*_date`, `*_time`, and `created_*`, `updated_*`, ...), counters and amounts (`*_count`, `*_amount`, `*_total`), flags (`is_*`, `has_*`, `*_enabled`, `*_verified`, `*_confirmed`, `*_sent`, `*_notified`), `*_status`, `*_type`, `*_code`, `*_uuid`, primary keys, foreign keys (`*_id`, `*_ids`), ISO codes (`*_iso`, `*_iso3`), `*_message`, `*_reason`, `*_note`/`*_notes`, hashes and tokens (`*_digest`, `*_hash`, `*_token`) and `encrypted_*`.

Some personal columns would fall under an exclusion and are carved out of it: `postal_code`, `zip_code`, `birth_date`, `health_status`, identifier columns such as `vat_id`, `tax_id`, `national_id`, `passport_id` and `face_id`, the payment-provider ids above, the credentials `encrypted_password`, `password_digest`, `password_hash`, `password_salt`, and the account and session tokens listed above. A generic `csrf_token` or `user_id` stays excluded.

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

The method returns a hash grouped by PII type; each entry also carries the
metadata the `metadata_extractor` returned (here `event_id`):

```ruby
{
  email: [
    { field: :email, value: "alice@example.com", pii_type: :email,
      sensitivity: :confidential, event_id: "evt-1" },
    { field: :contact_email, value: "bob@example.com", pii_type: :email,
      sensitivity: :confidential, event_id: "evt-2" }
  ],
  name: [
    { field: :name, value: "Alice", pii_type: :name, sensitivity: :internal,
      event_id: "evt-1" }
  ],
  phone: [
    { field: :phone, value: "+30 210 1234567", pii_type: :phone,
      sensitivity: :confidential, event_id: "evt-1" }
  ]
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

# Redact only sensitive PII (ssn, credit_card, financial, health, biometric,
# identifier, credential, token, payment_token)
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
#      deletion_strategy: :direct_deletion }

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

`generate_from_models` creates a draft policy file with:
- Field definitions with the detected type and sensitivity, each commented with the models it was found in
- A `:log` transformation for confidential and restricted fields, and a `:display` one as well for emails, phones, identifiers, SSNs, card numbers, credentials and tokens
- Suggested processing purposes, chosen by the detected types, with `lia_documented!` left commented out for legitimate-interests purposes
- A 7-year default retention, and 10 years for models whose names contain payment, transaction, invoice or order
- Rails configuration boilerplate (`default_policy`, `organization`, `dpo_contact`)

The draft declares no data subjects, recipients, transfers or security measures, so its Article 30 report lists those as gaps until you add them. `generate` writes a basic template instead. Neither overwrites an existing output file unless forced (`FORCE=1` for the rake tasks, `force: true` for the class).

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
rake pam_dsl:report:compare[policy1,policy2,path]  # Compare two policies (Markdown)

# Generation (refuse to overwrite config/initializers/pam_dsl_policy.rb unless FORCE=1)
rake pam_dsl:generate:policy[name]       # Generate template policy
rake pam_dsl:generate:from_models[name]  # Generate from model scan

# Aliases
rake privacy:report                 # Same as pam_dsl:report:full
rake privacy:policy                 # Same as pam_dsl:report:policy
rake privacy:retention              # Same as pam_dsl:report:retention
rake privacy:article_30             # Same as pam_dsl:report:article_30
rake privacy:export[path]           # Same as pam_dsl:report:export
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

Lyra reaches PAM through its privacy provider interface, with PAM as the adapter (`Lyra::Privacy::Adapters::Pam`). See the [integration guide](docs/PAM_DSL_INTEGRATION.md) for the privacy stamp on events, purpose-bound reads and the access log.

## API Reference

### PamDsl Module

- `PamDsl.define_policy(name, &block)` - Define a new policy
- `PamDsl.policy(name)` - Get a defined policy; raises `PolicyNotFoundError` if there is none
- `PamDsl.registry` - The policy registry (`names`, `get`, `exists?`, `count`, ...)
- `PamDsl.enforcement_mode` / `PamDsl.enforcement_mode=(mode)` - Global enforcement mode, `:strict` (default) or `:audit`
- `PamDsl.on_violation { |violation| ... }` - Register a handler for each violation recorded in audit mode
- `PamDsl.logger` / `PamDsl.logger=` - Where audit-mode violations are logged
- `PamDsl.access_recorder` / `PamDsl.access_recorder=` - Object receiving every `validate_access!` call (`record?(policy)`, `call(access)`)
- `PamDsl.reporter(policy_name = nil, **options)` - Build a `Reporter`, defaulting to the Rails-configured policy, organization and DPO contact
- `PamDsl.reset!` - Clear all policies, the enforcement mode and the violation handlers (not the access recorder)

### Policy

- `field(name, type:, sensitivity:, &block)` - Define a field
- `purpose(name, &block)` - Define a purpose
- `retention(&block)` - Configure retention
- `consent(&block)` - Configure consent
- `meta(key, value)` - Add custom metadata to policy
- `enforcement(mode)` - Set this policy's enforcement mode, overriding the global one
- `enforcement_mode` - The mode this policy enforces with (its own, or the global one)
- `security_measures(*measures)` - Declare technical and organisational measures (Art. 30(1)(g)); with no arguments, return them
- `article_30_gaps` - `[purpose_name or nil, clause]` pairs for every Article 30(1) item not declared
- `get_field(name)` / `get_purpose(name)` - Look up a field or purpose; raise `InvalidFieldError` / `UndeclaredPurposeError`
- `allowed?(field, purpose)` - Check if field is allowed for purpose
- `validate_access!(fields, purpose, subject:)` - Validate access for a data subject. Returns `true` when valid. In strict mode raises the first violation: `UndeclaredPurposeError`, `ConsentRequiredError`, `InvalidFieldError`, `PurposeFieldMismatchError` or `SensitivityViolationError`; in audit mode records every violation and returns `false`. Every call goes to the access recorder, if one is set
- `access_violations(fields, purpose, subject:)` - Every violation for the access, as error objects, without raising or recording
- `consent_policy` - Access the `ConsentPolicy` to populate the runtime consent store
- `lia_compliance_gaps` - Returns purposes with `:legitimate_interests` basis that have not called `lia_documented!`
- `sensitive_fields` - Get all fields with confidential/restricted sensitivity
- `restricted_fields` - Get all fields with restricted sensitivity
- `retention_for(model_class, field_name: nil)` - Retention duration for a model (and field), falling back to the default
- `fields`, `purposes`, `retention_policy` - The declared fields and purposes (hashes by name) and the `RetentionPolicy`
- `metadata` - Access policy metadata hash
- `to_h` - Export policy as hash (includes all metadata)

### Field

- `allow_for(*purposes)` - Allow field for purposes
- `transform(context, &block)` - Define transformation
- `meta(key, value)` - Add custom metadata
- `metadata` - Access field metadata hash
- `sensitive?` - Check if field is confidential or restricted
- `restricted?` - Check if field is restricted
- `special_category?` - True for an Article 9 type (`:health`, `:biometric`)
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
- `data_subjects(*categories)` - Declare categories of data subjects (Art. 30(1)(c)); with no arguments, return them
- `recipients(*names)` - Declare categories of recipients, including processors (Art. 30(1)(d)); with no arguments, return them
- `transfer(to:, safeguard:)` - Declare a transfer to a third country or international organisation and its safeguard (Art. 30(1)(e))
- `no_transfers!` - Declare that the purpose involves no international transfer
- `transfers` - Declared transfers (`[{ to:, safeguard: }]`), `[]` after `no_transfers!`, nil when undeclared
- `transfers_declared?` - True after `transfer` or `no_transfers!`
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
- `on_expiry(strategy)` - Set deletion strategy (`:hard_delete`, `:soft_delete` (default), `:anonymize`, `:archive`)
- `self.when { |context| ... }` - Add a condition to the rule; `applies_to?(context)` evaluates them

### ConsentPolicy

DSL configuration (policy-time):
- `for_purpose(purpose, &block)` - Declare a consent requirement for a purpose
- `required!(value)` - Set if required
- `granular!(value)` - Enable granular consent
- `withdrawable!(value)` - Set if withdrawable
- `expires_in(duration)` - Set expiration window
- `describe(text)` - Describe the consent request

Runtime consent store (per-subject, accessed via `policy.consent_policy`):
- `request_consent(purpose:, subject:)` - Create a pending record (consent requested, not yet granted)
- `grant_consent(purpose:, subject:, granted_at: Time.current)` - Record that subject granted consent; `expires_at` is computed from the requirement's `expires_in`
- `withdraw_consent(purpose:, subject:)` - Record that subject withdrew consent (no-op when there is no record; raises `PamDsl::Error` unless the record is granted)
- `validate!(purpose, subject:)` - Raise `ConsentRequiredError` unless consent is required-and-granted or not required
- `requirement_for(purpose)` - Look up the `ConsentRequirement` for a purpose
- `required_for?(purpose)` - True if consent is required for the purpose
- `store` - The underlying `ConsentStore`

### ConsentStore

- `request(purpose:, subject:)` - Create a pending record; replaces an expired or withdrawn one, raises `PamDsl::Error` if a pending or granted record exists
- `grant(purpose:, subject:, granted_at: Time.current, expires_at: nil)` - Grant a pending record, or create a new granted record
- `withdraw(purpose:, subject:)` - Withdraw the record (no-op when there is none)
- `record_for(purpose, subject)` - Returns the `ConsentRecord` or nil
- `granted?(purpose, subject)` - True only when the record's state is `:granted`

### ConsentRecord

- `purpose` - Purpose symbol
- `subject` - Subject identifier
- `granted_at` - Time consent was granted, or nil
- `expires_at` - Time consent expires, or nil (no expiry)
- `withdrawn_at` - Time consent was withdrawn, or nil
- `state` - `:pending`, `:granted`, `:expired` (granted and `expires_at` has passed) or `:withdrawn`
- `pending?`, `granted?`, `expired?`, `withdrawn?` - State predicates
- `grant!(granted_at:, expires_at:)` / `withdraw!(at:)` - Transitions; raise `PamDsl::Error` from the wrong state

### Reporter

- `Reporter.new(policy_name, organization:, dpo_contact:, event_store:, output:)` - Create reporter
- `policy_summary` - Print policy summary
- `article_30_report` - Print GDPR Article 30 report (activities, retention schedule, declared measures, gaps)
- `pii_analysis` - Analyze PII in event store
- `retention_check` - Check retention compliance
- `access_patterns` - Show access patterns
- `full_report` - Print complete report
- `export_json(path)` - Export to JSON file
- `to_h` - Export as hash

### PolicyGenerator

- `PolicyGenerator.new(name, output_path: nil, force: false)` - Create generator (default path `config/initializers/pam_dsl_policy.rb` under Rails, `pam_dsl_policy.rb` otherwise)
- `generate` - Generate template policy file
- `generate_from_models` - Scan ActiveRecord models with `PIIDetector` and generate a policy
- Both raise `PolicyGenerator::FileExistsError` when the output file exists and `force` is false

### PIIDetector

- `PIIDetector.detect(attributes)` - Detect PII in a hash, returns `{ field: { type:, value:, sensitive:, sensitivity: } }`
- `PIIDetector.contains_pii?(field_name)` - Check if a field name is PII
- `PIIDetector.pii_type(field_name)` - Get PII type for a field (`:email`, `:phone`, etc.)
- `PIIDetector.sensitivity(field_name)` - Get sensitivity level for a field
- `PIIDetector.sensitive?(pii_type)` - Check if PII type requires special protection
- `PIIDetector.mask(value, pii_type)` - Mask a PII value for safe display
- `PIIDetector.extract_pii_from_records(records, attribute_extractor:, metadata_extractor: nil)` - Extract PII from any record collection
- `PIIDetector.partial_match=(bool)` - Enable/disable partial matching mode
- `PIIDetector.reset!` - Reset to default settings

### PIIMasker

- `PIIMasker.mask(attributes, strategy:)` - Mask all PII in a hash
- `PIIMasker.mask_field(value, field_name, strategy:)` - Mask a value by field name
- `PIIMasker.mask_by_type(value, pii_type, strategy:)` - Mask a value by PII type
- `PIIMasker.mask_records(records, attribute_extractor:, attribute_setter:, strategy:)` - Mask PII in a collection

### GDPRCompliance

- `GDPRCompliance.new(subject_id:, record_reader:, subject_type: 'User', **options)` - Create compliance handler (options: extractors, `retention_policy:`, `policy_name:`)
- `data_export` - Right to Access (Art. 15) - Full data export
- `right_to_be_forgotten_report` - Right to Erasure (Art. 17) - Deletion analysis
- `portable_export(format: :json)` - Right to Portability (Art. 20) - Export as JSON, CSV, XML or a Hash (`:hash`)
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

A declared field's sensitivity is whatever the policy states (default `:internal`). The table shows the sensitivity `PIIDetector` assigns to each type it detects, which the policy generator writes into its draft:

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
| `credential` | `:restricted` | Regular (Art. 6) | Passwords, password hashes, API keys |
| `token` | `:restricted` | Regular (Art. 6) | A person's account and session tokens |
| `payment_token` | `:restricted` | Financial | Payment-provider customer and profile ids |

Login names (`login`, `username`, `nickname`) are detected as `identifier` with `:internal` sensitivity, not as `identifier`'s usual `:restricted`. The `:online_identifier` and `:custom` types can be declared but the detector never assigns them.

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

MIT License - see MIT-LICENSE

## Contributing

This is part of the ORFEAS PhD thesis research. Contributions welcome.
