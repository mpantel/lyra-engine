# Privacy Compliance and GDPR in Lyra

## Overview

Lyra provides comprehensive GDPR compliance tools by leveraging event sourcing to maintain complete data lineage and enable all data subject rights.

## Core Privacy Features

### 1. Automatic PII Detection

Lyra automatically detects personally identifiable information (PII) in all events using pattern matching. The detection is powered by `PamDsl::PIIDetector`, providing a unified implementation across both Lyra and PAM DSL.

**Detected PII categories:**
- Email addresses
- Names (first, last, full)
- Phone numbers
- Physical addresses
- Social Security Numbers
- Credit card numbers
- Date of birth
- IP addresses
- Financial information (IBAN, bank accounts, salary)
- Health data
- Biometric data
- Location data
- Government IDs and tax identifiers (VAT, TIN, AFM, passport)

```ruby
# Usage
attributes = { email: "john@example.com", name: "John Doe", vat_number: "EL123456789" }
pii = Lyra::Privacy::PIIDetector.detect(attributes)
# => {
#      email: { type: :email, value: "...", sensitive: false, sensitivity: :confidential },
#      name: { type: :name, value: "...", sensitive: false, sensitivity: :internal },
#      vat_number: { type: :identifier, value: "...", sensitive: true, sensitivity: :restricted }
#    }

# Partial matching (default) detects prefixed/suffixed field names
Lyra::Privacy::PIIDetector.contains_pii?(:customer_email)  # => true
Lyra::Privacy::PIIDetector.contains_pii?(:billing_phone)   # => true
```

See [PAM DSL README](gems/pam_dsl/README.md#piidetector-configuration) for configuration options and [Sensitivity Levels](gems/pam_dsl/README.md#sensitivity-levels-and-legislative-background) for regulatory mapping.

### 2. GDPR Rights Implementation

#### Right to Access (Article 15)

Export all data about a subject:

```ruby
compliance = Lyra::Privacy::GDPRCompliance.new(
  subject_id: user.id,
  subject_type: 'User'
)

export = compliance.data_export
# Returns:
# - All events related to the subject
# - Complete PII inventory
# - Data lineage for all PII fields
# - Processing activities record
```

**API Endpoint**:
```
GET /lyra/privacy/subject/User/123
```

#### Right to Erasure / Right to be Forgotten (Article 17)

Identify all data that needs to be deleted:

```ruby
report = compliance.right_to_be_forgotten_report
# Returns:
# - Total events containing subject data
# - Events with PII
# - Affected database streams
# - Affected models
# - Dependencies and foreign key references
# - Recommended deletion strategy
```

**API Endpoint**:
```
GET /lyra/privacy/gdpr_report/User/123
```

Then erase, one record at a time:

```ruby
Lyra::Erasure.erase!(Registration, 5, reason: "Art. 17 request #12")
# => #<Result fields: ["email", "firstname", ...], events_rewritten: 4, row_erased: true>
```
```bash
bin/rails lyra:erase MODEL=Registration ID=5 REASON="Art. 17 request #12" [FIELDS=email,phone] [EVERYWHERE=1]
```

- Erases the personal attributes (declared by the policy, or listed by the events' privacy
  stamps, or exactly `fields:`) from the row and from every event in the record's stream,
  overwriting each event in place (same id, position and time): attributes, both sides of each
  change, and payload keys with the attribute's name, plus any copy of an erased value under
  another name (matched by value: a payload's `payer_email`).
- `everywhere: true` (`EVERYWHERE=1`) also searches the whole log for the erased values: events
  of other records that copied them are scrubbed, those records' rows get the value replaced
  where they hold it, and each gets an `ErasureApplied`; `result.copies` lists them. The search
  is a text match on the stored events, then an exact match on each candidate. A value held by
  more than `max_copies:` other records (default 10) is shared by many people (a city, a
  placeholder), not a copy of this person's, and is left; `result.shared_values` counts them.
  Only direct identifiers (fields the policy types as email, phone, identifier, card, payment
  token, IP address, credential) are searched for in other records: a name, city or postal code
  can belong to another customer by coincidence, so those are erased in the person's own record
  only.
- Rows are written with one `UPDATE` by id, so records the application marks read-only (Solidus
  freezes an address once an order uses it) are erased too.
- Appends `Lyra::Events::ErasureApplied` (fields, reason, `erased_by`, never a value). It is not
  replayed; the stream still replays to the anonymized row.
- Replacement: `nil` where the column allows it, `"erased:<id>"` for a NOT NULL string column,
  the column default otherwise.
- The log is append-only except for this; the erasure itself is recorded. Crypto-shredding,
  which would leave the log untouched, is not implemented.
- Without `everywhere`, other records holding the same person's data are not touched (erase each,
  or use `everywhere`; the report above lists them). A value derived from the original (an
  uppercased email, a substring) is not a copy and is not found.

#### Erasure driven by the policy (opt-in)

`Lyra::Retention` applies the policy's retention rules. Off by default:

```ruby
Lyra.configure do |config|
  config.retention_executor = true
  config.retention_anchors = { "Registration" => :registered_at } # default: created_at
end
```
```bash
bin/rails lyra:retention:apply DRY_RUN=1   # what would happen (works with the executor off)
bin/rails lyra:retention:apply             # or enqueue Lyra::RetentionJob on a schedule
```

For each monitored model with a `retention { for_model(...) }` rule, a record past `keep_for`
gets the rule's `on_expiry`:

| Strategy | What happens |
|---|---|
| `:anonymize` | personal attributes erased from row and events (`Lyra::Erasure`), `ErasureApplied` |
| `:hard_delete` | the same, then the record is destroyed through the normal write path |
| `:soft_delete` | `deleted_at` / `discarded_at` set through the normal write path (skipped if neither exists) |
| `:archive` | skipped: the policy names no archive |

An attribute with its own, shorter period (`field :email, duration: 30.days`) is erased when that
passes. Rule conditions (`when { |record| ... }`) get the record. Already-erased attributes are
not erased again, so runs are idempotent; erasures are recorded with `erased_by: "lyra_retention"`.

#### Right to Data Portability (Article 20)

Export data in machine-readable formats:

```ruby
# JSON format
json_export = compliance.portable_export(format: :json)

# CSV format
csv_export = compliance.portable_export(format: :csv)

# XML format
xml_export = compliance.portable_export(format: :xml)
```

**API Endpoints**:
```
GET /lyra/privacy/portable_export/User/123?format=json
GET /lyra/privacy/portable_export/User/123?format=csv
GET /lyra/privacy/portable_export/User/123?format=xml
```

#### Right to Rectification (Article 16)

Track all corrections made to subject data:

```ruby
history = compliance.rectification_history
# Returns chronological list of all data corrections with:
# - Timestamp of correction
# - Fields that were corrected
# - Old and new values
# - User who made the correction
# - Reason for correction (if available)
```

### 3. Processing Activities Record (Article 30)

Automatically maintain a record of processing activities:

```ruby
activities = compliance.processing_activities
# Returns for each processing activity:
# - Purpose of processing
# - Legal basis (consent, contract, legal obligation, etc.)
# - Data categories processed
# - Recipients of the data
# - Retention period
# - Number of events
```

The organization-wide register comes from the declared policy:
`PamDsl.reporter(:my_policy).article_30_report` (or `bin/rails pam_dsl:report:article_30`)
lists each purpose with its legal basis, data categories, consent requirement and retention.

#### Access log (opt-in)

The register says what may be processed and the event stream shows what was written; neither
records reads. With the access log on, every `validate_access!` call is recorded:

```ruby
Lyra.configure { |config| config.record_access_events = true } # default false

PamDsl.policy(:my_policy).validate_access!(%i[email], :contact, subject: user)
Lyra::AccessLog.for(user)
# => [#<Lyra::Events::DataAccessed data: { policy: "my_policy", purpose: "contact",
#       legal_basis: "contract", fields: ["email"], subject: "User$5", outcome: "granted", ... }>]
```

- `DataAccessed`: the access went ahead (`outcome` `"granted"`, or `"audited"` when audit
  mode let it through; then `violations` lists them).
- `DataAccessDenied`: strict mode refused it (`violations` lists why).
- Stream `Lyra::DataAccess$<Model>$<id>` per subject record, never the record's own stream,
  so replay, DualView and mode transitions are unaffected. Field names only, never values.
- Who accessed is in the metadata: `user_id` (`Current.user.id`) and `ip_address`
  (`Current.ip_address`) when your app sets them in `Current`, plus request and correlation
  ids. Where `Current` does not know (a console, a job, an API token), add your own:
  `config.access_metadata_proc = ->(access) { { actor: Current.api_token&.name || "console" } }` (string,
  number, boolean or nil values; a failing proc is logged and the access recorded without it).
  With neither, an access carries no user.
- Every access is recorded (no sampling). If the event store cannot record it, the store's
  error propagates and the access does not go ahead. Nothing is recorded in disabled mode.
- The log is personal data about the users who read records: cover it in your retention rules.
- Off by default because reads can outnumber writes by orders of magnitude; the Aegean
  testbed measures it separately with `LYRA_RECORD_ACCESS=1` (see `BENCHMARKING.md`).

### 3a. Purpose-bound reads

A model with a privacy policy is checked on every read made for a declared purpose: each declared
attribute the query loaded must be allowed for that purpose (the policy's `validate_access!`, the
record as subject). No setting turns it on; the purpose does:

```ruby
class PaymentsController < ApplicationController
  lyra_purpose :payment_processing             # around every action
  lyra_purpose :invoicing, only: :invoice
end

class ExportJob < ApplicationJob
  lyra_purpose :audit_trail
end

Lyra.with_purpose(:invoicing) { Registration.select(:id, :vat_number, :address).find(id) }
```

- **Data minimisation:** loading a declared attribute the purpose does not need is refused, so a
  `SELECT *` under a narrow purpose fails; select what the purpose uses.
- **On a violation** the policy's enforcement mode decides: strict raises from the read, audit
  logs and lets it through. With the access log on, every checked read is recorded.
- **Reads with no purpose:** `config.reads_without_purpose = :allow` (default; nothing breaks when
  a policy is added), `:audit` (logged, recorded as audited), or `:deny`
  (`Lyra::PurposeBoundReads::PurposeRequiredError`).
- **`pluck` and `pick`** are checked by the declared attributes they name (also inside an SQL
  fragment). A pluck reads many people at once, so its subject is the model
  (`"Registration$*"`): under a purpose whose consent the policy requires, it is refused.
- **ES-NoProj** rebuilds whole records from events; what a query returns is narrowed to its
  `select` and checked, so the rule is the same in every mode.
- **Not checked:** Lyra's own reads (projections, bypass snapshots, Genesis, DualView, mode
  checks, repair, erasure), and SQL written by hand (`connection.select_*`, `execute`): it names
  no model. `find_by_sql` returns records, which are checked.

### 4. Data Lineage Tracking

Track how personal data flows and changes over time:

```ruby
flow = Lyra::EventFlow.new
lineage = flow.data_lineage('email', 'User')
# Returns complete history:
# - When the field was first created
# - All modifications with old/new values
# - Who made each change
# - What action triggered the change
# - Source system/component
```

**API Endpoint**:
```
GET /lyra/privacy/data_lineage/email?model_class=User
```

**Example Output**:
```json
{
  "field": "email",
  "model_class": "User",
  "total_modifications": 3,
  "first_seen": "2024-01-15T10:00:00Z",
  "last_modified": "2024-06-20T15:30:00Z",
  "lineage": [
    {
      "timestamp": "2024-01-15T10:00:00Z",
      "operation": "created",
      "old_value": null,
      "new_value": "john@example.com",
      "user_id": null,
      "action": "registration"
    },
    {
      "timestamp": "2024-03-10T14:20:00Z",
      "operation": "updated",
      "old_value": "john@example.com",
      "new_value": "john.doe@example.com",
      "user_id": 123,
      "action": "profile_update"
    }
  ]
}
```

### 5. Event Flow Visualization

#### User Action Tracking

Link all events back to the user action that triggered them:

```ruby
# In controllers, wrap actions in context
Lyra::UserActionContext.with_context(
  action_type: :web_request,
  user_id: current_user.id,
  controller: 'users',
  action_name: 'update',
  params: params.except(:password)
) do
  @user.update!(user_params)
  # All CRUD operations tracked with user action context
end
```

#### Correlation Groups

Group related operations using correlation IDs:

```ruby
Lyra::Correlation.with_id do |correlation_id|
  # All operations share the same correlation ID
  user = User.create!(...)
  profile = Profile.create!(user: user, ...)
  preferences = Preferences.create!(user: user, ...)

  # Later, retrieve all events from this group
  # GET /lyra/flow/correlation/#{correlation_id}
end
```

#### Timeline Visualization

View event timeline with PII tracking:

```ruby
flow = Lyra::EventFlow.new(subject_id: user.id, subject_type: 'User')
timeline = flow.build_timeline(events)
# => Chronological view showing:
#    - What happened
#    - When it happened
#    - Who did it
#    - What PII was affected
#    - What other events were part of same action
```

**API Endpoints**:
```
GET /lyra/flow/timeline?subject_id=123&subject_type=User
GET /lyra/flow/timeline?subject_id=123&subject_type=User&format=html
```

**Visualization Formats**:
- JSON (for programmatic access)
- HTML (web-based timeline)
- Mermaid (diagram generation)
- ASCII (command-line viewing)
- D3.js (interactive visualization)

### 6. CRUD to Event Mapping

Understand how CRUD operations map to events:

```ruby
mapping = flow.crud_to_event_mapping('User', :updated, user_id)
# Shows:
# - The CRUD operation details
# - All events generated from this operation
# - Side effects (notifications, audit logs, etc.)
# - PII affected
```

**API Endpoint**:
```
GET /lyra/flow/crud_mapping?model_class=User&operation=updated&model_id=123
```

### 7. Privacy Impact Analysis

Assess privacy impact of your system:

```ruby
analysis = flow.privacy_impact_analysis
# Returns:
# - Total events analyzed
# - Events containing PII
# - PII categories present
# - Sensitive operations (updates/deletes of PII)
# - Data flows between models
# - Risk assessment with recommendations
```

**API Endpoint**:
```
GET /lyra/privacy/pii_detection
```

**Risk Levels**:
- **High**: Sensitive PII (SSN, credit cards, health data)
- **Medium**: Large amount of PII or frequent modifications
- **Low**: Minimal PII exposure

**Recommendations**:
- Implement field-level encryption
- Enable audit logging
- Review retention policies
- Implement change approval workflows

### 8. Consent Management

Track user consent for processing:

```ruby
audit = compliance.consent_audit
# Returns:
# - Current active consents
# - Consent history (granted/withdrawn)
# - Processing legitimacy verification
# - Expired consents
```

### 9. Data Retention Compliance

Check compliance with retention policies:

```ruby
retention_check = compliance.retention_compliance_check
# Returns for each model:
# - Total events
# - Expired events (past retention period)
# - Compliance status
# - Events requiring action
```

**Configure Retention Policies**:
```ruby
Lyra.configure do |config|
  config.retention_policy = {
    'User' => { duration: 7.years },
    'Payment' => { duration: 10.years },  # Financial records
    'MedicalRecord' => { duration: 20.years },  # Health records
    default: { duration: 5.years }
  }
end
```

### 10. PII Masking

Safely display PII in logs and UIs:

```ruby
# Mask email
masked = Lyra::Privacy::PIIDetector.mask("john.doe@example.com", :email)
# => "j***@example.com"

# Mask phone
masked = Lyra::Privacy::PIIDetector.mask("555-123-4567", :phone)
# => "***-***-4567"

# Mask SSN
masked = Lyra::Privacy::PIIDetector.mask("123-45-6789", :ssn)
# => "***REDACTED***"
```

## Integration Patterns

### Pattern 1: Controller Integration

```ruby
class UsersController < ApplicationController
  def update
    Lyra::UserActionContext.with_context(
      action_type: :web_request,
      user_id: current_user.id,
      controller: controller_name,
      action_name: action_name,
      params: safe_params
    ) do
      if @user.update(user_params)
        redirect_to @user, notice: 'User updated successfully.'
      else
        render :edit
      end
    end
  end

  private

  def safe_params
    params.except(:password, :password_confirmation, :authenticity_token)
  end
end
```

### Pattern 2: Background Job Integration

```ruby
class UserEmailJob < ApplicationJob
  def perform(user_id)
    Lyra::UserActionContext.with_context(
      action_type: :background_job,
      params: { job: self.class.name, user_id: user_id }
    ) do
      user = User.find(user_id)
      UserMailer.welcome(user).deliver_now
      user.update!(welcome_email_sent: true)
    end
  end
end
```

### Pattern 3: API Integration

```ruby
class Api::V1::UsersController < Api::BaseController
  def create
    Lyra::UserActionContext.with_context(
      action_type: :api_call,
      user_id: current_api_user&.id,
      controller: controller_name,
      action_name: action_name,
      params: params.except(:api_key)
    ) do
      @user = User.create!(user_params)
      render json: @user, status: :created
    end
  end
end
```

## Compliance Workflows

### Workflow 1: Data Subject Access Request (DSAR)

```ruby
# 1. Receive DSAR from user
def handle_dsar(subject_id)
  compliance = Lyra::Privacy::GDPRCompliance.new(
    subject_id: subject_id,
    subject_type: 'User'
  )

  # 2. Generate report
  report = compliance.data_export

  # 3. Export in requested format
  export = compliance.portable_export(format: :json)

  # 4. Deliver to user
  deliver_dsar_response(subject_id, export)
end
```

### Workflow 2: Right to be Forgotten Request

```ruby
def handle_erasure_request(subject_id)
  compliance = Lyra::Privacy::GDPRCompliance.new(
    subject_id: subject_id,
    subject_type: 'User'
  )

  # 1. Generate deletion report
  report = compliance.right_to_be_forgotten_report

  # 2. Review dependencies
  if report[:dependencies].any?
    # Handle dependencies first
    handle_dependencies(report[:dependencies])
  end

  # 3. Delete or anonymize data
  execute_deletion_strategy(report[:deletion_strategy])

  # 4. Confirm deletion
  confirm_erasure(subject_id)
end
```

### Workflow 3: Privacy Audit

```ruby
def perform_privacy_audit
  # 1. Detect all PII
  # GET /lyra/privacy/pii_detection

  # 2. Assess risk
  flow = Lyra::EventFlow.new
  analysis = flow.privacy_impact_analysis

  # 3. Check retention compliance
  User.find_each do |user|
    compliance = Lyra::Privacy::GDPRCompliance.new(
      subject_id: user.id,
      subject_type: 'User'
    )
    retention_check = compliance.retention_compliance_check

    # Handle non-compliant records
    handle_retention_issues(retention_check)
  end

  # 4. Generate audit report
  generate_audit_report(analysis)
end
```

## Best Practices

### 1. Always Use User Action Context

```ruby
# ✅ Good
Lyra::UserActionContext.with_context(...) do
  user.update!(...)
end

# ❌ Bad - no context
user.update!(...)
```

### 2. Group Related Operations

```ruby
# ✅ Good - operations are correlated
Lyra::Correlation.with_id do
  order = Order.create!(...)
  payment = Payment.create!(order: order, ...)
  invoice = Invoice.create!(order: order, ...)
end

# ❌ Bad - operations not linked
order = Order.create!(...)
payment = Payment.create!(order: order, ...)
invoice = Invoice.create!(order: order, ...)
```

### 3. Configure Appropriate Retention Policies

```ruby
# ✅ Good - specific policies per data type
config.retention_policy = {
  'User' => { duration: 7.years },
  'Payment' => { duration: 10.years },
  'HealthRecord' => { duration: 25.years }
}

# ❌ Bad - one-size-fits-all
config.retention_policy = {
  default: { duration: 1.year }
}
```

### 4. Regular Privacy Audits

Schedule regular audits:
```ruby
# In cron or scheduled job
class PrivacyAuditJob < ApplicationJob
  def perform
    # Check PII exposure
    # Verify retention compliance
    # Generate compliance report
    # Alert on issues
  end
end
```

## Compliance Checklist

- [ ] PII is automatically detected in all events
- [ ] User action context is set for all operations
- [ ] Retention policies are configured
- [ ] DSAR workflow is implemented
- [ ] Right to erasure workflow is implemented
- [ ] Data portability is tested
- [ ] Privacy impact analysis is performed regularly
- [ ] Consent tracking is implemented
- [ ] Processing activities are documented
- [ ] Data lineage is traceable for all PII
- [ ] Regular privacy audits are scheduled

## Legal Disclaimer

This tool provides technical capabilities to assist with GDPR compliance. However:

- **Legal advice**: This is not legal advice. Consult legal counsel for compliance requirements.
- **Completeness**: While comprehensive, this may not cover all aspects of GDPR compliance.
- **Verification**: Always verify that the implementation meets your specific legal requirements.
- **Responsibility**: Ultimate compliance responsibility rests with the data controller.

## Support

For questions about privacy compliance features:
- Review the examples in `examples/privacy_examples.rb`
- Check the API documentation in `API_REFERENCE.md`
