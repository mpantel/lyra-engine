# PAM DSL - Privacy Attribute Matrix DSL

A declarative Domain-Specific Language (DSL) for defining privacy policies, PII fields, consent requirements, and retention rules using the Privacy Attribute Matrix (PAM) model for privacy-aware event monitoring.

## Overview

PAM DSL provides a fluent, expressive way to define privacy policies using the Privacy Attribute Matrix (PAM) model. It can be used by privacy-aware monitoring systems like Lyra and helps you:

- **Define PII fields** with type and sensitivity classification
- **Specify processing purposes** with legal bases (GDPR compliant)
- **Configure retention policies** with field-level granularity
- **Manage consent requirements** with expiration and withdrawal
- **Validate data access** against defined policies, blocking violations (strict mode) or recording them (audit mode)
- **Declare the Article 30 record of processing**: data subjects, recipients, international transfers and security measures

## Installation

The gem is published as `orfeas_pam_dsl`; the library it loads is `pam_dsl`. Add to your Gemfile:

```ruby
gem 'orfeas_pam_dsl', require: 'pam_dsl'

# From a checkout of lyra-engine
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

**`allow_for` widens, it does not restrict.** A field may be used for a declared purpose when the field lists that purpose in `allow_for` *or* the purpose lists the field in `requires`/`optionally`; either side suffices (`Policy#allowed?` takes the union). So a field listed in `allow_for(:contact)` is allowed for `:contact` even if `:contact`'s own field lists do not name it, and a purpose that lists the field may use it even if the field's `allow_for` does not name that purpose. `allow_for` is not a whitelist that keeps other purposes out: to keep a field from a purpose, leave it out of both.

```ruby
field :phone, type: :phone do
  allow_for :contact
end
purpose(:contact)   { basis :contract }                  # no field lists
purpose(:shipping)  { basis :contract; requires :phone }  # not in allow_for

policy.allowed?(:phone, :contact)   # => true (field side)
policy.allowed?(:phone, :shipping)  # => true (purpose side)
policy.allowed?(:phone, :marketing) # => false (neither side; or :marketing undeclared)
```

**Sensitivity Levels:**
- `:public` - Publicly accessible
- `:internal` - Internal use only
- `:confidential` - Sensitive, requires protection
- `:restricted` - Highly restricted access

See [Sensitivity Levels and Legislative Background](#sensitivity-levels-and-legislative-background) for detailed regulatory mapping.

**PII Types:**
`:email`, `:name`, `:phone`, `:address`, `:ssn`, `:date_of_birth`, `:ip_address`, `:online_identifier`, `:credit_card`, `:financial`, `:health`, `:biometric`, `:location`, `:identifier`, `:credential`, `:token`, `:payment_token`, `:custom`, and from 1.0.0 the other GDPR Art. 9(1) special categories and Art. 10 data:

| Type | Holds | GDPR |
|------|-------|------|
| `:health` | data concerning health | Art. 9(1) |
| `:biometric` | biometric data for uniquely identifying a person | Art. 9(1) |
| `:genetic` | genetic data | Art. 9(1) |
| `:racial_ethnic_origin` | racial or ethnic origin | Art. 9(1) |
| `:political_opinion` | political opinions | Art. 9(1) |
| `:religious_belief` | religious or philosophical beliefs | Art. 9(1) |
| `:trade_union_membership` | trade-union membership | Art. 9(1) |
| `:sex_life_orientation` | sex life or sexual orientation | Art. 9(1) |
| `:criminal_offence` | criminal convictions and offences, or related security measures | Art. 10 |

The eight Art. 9(1) types are the special categories (`Field::SPECIAL_CATEGORY_TYPES`, `special_category?`): a purpose that reads one needs an Art. 9(2) basis (`art9_basis`). `:criminal_offence` is not a special category (`Field::CRIMINAL_DATA_TYPES`, `criminal_data?`): a purpose that reads it needs an Art. 10 authorisation (`art10_authorisation`). See [Art. 9(2) Basis for Special-Category Data](#art-92-basis-for-special-category-data) and [Art. 10 Authorisation for Criminal-Offence Data](#art-10-authorisation-for-criminal-offence-data).

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
- `:undetermined` - Not a legal basis: what the policy generator writes until the controller decides one, and what a purpose has when it declares no `basis` (before 1.0.0 that defaulted to `:consent`). Access under it is refused (`PamDsl::UndeterminedBasisError`) and the Article 30 register lists it as a gap.

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

When a purpose accesses **special-category fields** — those whose `type` is a GDPR Article 9(1) category (`:health`, `:biometric`, `:genetic`, `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief`, `:trade_union_membership`, `:sex_life_orientation`) — you **must** also declare an Art. 9(2) basis. Without it, `validate_access!` raises `SpecialCategoryViolationError` (before 1.0.0 named `SensitivityViolationError`, which stays as a deprecated alias until 2.0). Multiple bases are accepted. Note that this is driven by the field **type**, not by the `:restricted` sensitivity level: `:restricted` is an Article 32 *risk* tier (used for high-risk-but-ordinary data such as financial or national-identifier fields), so a `:restricted` field of a non-Article-9 type does **not** require an Art. 9(2) basis, while an Article-9-type field requires one even below `:restricted`.

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

#### Art. 10 Authorisation for Criminal-Offence Data

A field of type `:criminal_offence` holds Art. 10 data: criminal convictions and offences, or related security measures. Art. 10 does not make it a special category, and its rule is different: the data may be processed only under the control of official authority, or when Union or Member State law authorises the processing with appropriate safeguards. There is no list of grounds to choose from as in Art. 9(2), so a purpose that reads such a field names what authorises it, as text, with `art10_authorisation`. Without one, `validate_access!` (and `validate_fields!`) raises `PamDsl::CriminalDataViolationError`; in audit mode the violation is recorded like the others.

The two conditions are separate: an Art. 9(2) basis does not satisfy Art. 10, and an Art. 10 authorisation does not satisfy Art. 9. A purpose that reads both kinds of data declares both.

```ruby
PamDsl.define_policy :staff_vetting do
  field :conviction_record, type: :criminal_offence, sensitivity: :restricted
  field :union_member, type: :trade_union_membership

  purpose :vetting do
    basis :legal_obligation
    art10_authorisation "the act and article that require the check"  # Art. 10
    requires :conviction_record
  end

  purpose :payroll_deductions do
    basis :contract
    art9_basis :employment_law                                        # Art. 9(2)(b)
    requires :union_member
  end
end
```

`art10_authorisation` accepts one or more non-blank strings and accumulates across calls; `art10_authorisations` returns them and `art10_authorised?` is true when there is at least one. The Article 30 report prints them on an `Art. 10:` line for each purpose that reads Art. 10 data (and the Art. 9(2) bases on an `Art. 9(2) Basis:` line for each purpose that reads special-category data), and `article_30_gaps` lists a purpose that reads such data without them.

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

`policy.article_30_gaps` returns what the record cannot state because the policy does not declare it, as `[purpose_name, clause]` pairs (`purpose_name` is nil for the policy-wide security measures), for example `[:order_fulfillment, "Art. 30(1)(d) categories of recipients"]`. It also lists a purpose whose basis is `:undetermined`, a purpose that reads special-category data without an Art. 9(2) basis (`"Art. 9(2) basis for special-category data"`), and one that reads Art. 10 data without an Art. 10 authorisation (`"Art. 10 authorisation for criminal-offence data"`). The Article 30 report prints these gaps in its completeness section.

#### Restriction and Objection Declarations (Arts. 18 and 21)

A purpose declares what happens to it when a data subject exercises one of two rights: restriction of processing (Art. 18) and the right to object (Art. 21). The runtime side is in [Restriction of Processing and the Right to Object](#restriction-of-processing-and-the-right-to-object-arts-18-and-21).

```ruby
PamDsl.define_policy :shop do
  purpose :analytics do
    basis :legitimate_interests            # objectable by its basis (Art. 21(1)); nothing to declare
    lia_documented!
  end

  purpose :newsletter do
    basis :consent
    direct_marketing!                      # Art. 21(2)-(3): objectable whatever the basis; an objection stops it at once
  end

  purpose :usage_statistics do
    basis :public_task
    research_or_statistics! public_interest_task: false   # Art. 89(1); on public task Art. 21(1) applies
  end

  purpose :defence_of_claims do
    basis :legitimate_interests
    lia_documented!
    allowed_when_restricted :legal_claims  # Art. 18(2): continues while the subject's processing is restricted
  end

  purpose :invoicing do
    basis :legal_obligation
    allowed_when_restricted :important_public_interest, reference: "the act and article that impose the duty"
  end
end
```

- `allowed_when_restricted(*exceptions, reference: nil)` takes one or more of the Art. 18(2) grounds: `:consent`, `:legal_claims`, `:protection_of_rights` (of another natural or legal person) and `:important_public_interest` (of the Union or a Member State), which needs `reference:` naming the law. Any other symbol raises `PamDsl::Error` when the policy loads. Calls accumulate. Storage needs no declaration: it is not a purpose, and Art. 18(2) excepts it. A purpose with no exception stops for a restricted subject, whatever its basis: a restriction stops contract and legal-obligation processing too unless the policy declares an exception the DPO accepts. No exception is implied for `:legal_obligation`. The `:consent` exception holds only with an active consent for (purpose, subject) granted at or after the time the restriction was requested, since a consent given before it was not given in view of it.
- `direct_marketing!` marks the purpose as direct marketing (Art. 21(2)). The subject can object whatever the basis, and the objection is upheld at once (Art. 21(3)).
- `research_or_statistics!(public_interest_task:)` marks the purpose as research or statistics under Art. 89(1). On the bases `:public_task` and `:legitimate_interests` the right to object is Art. 21(1) whatever this marker says (Art. 21(1) covers all processing on Art. 6(1)(e) or (f), and Art. 21(6) does not take it away). On any other basis, `public_interest_task: true` (necessary for a task carried out in the public interest) leaves no right to object (Art. 21(6), last clause), and with `false` the subject can object under Art. 21(6). A purpose cannot be both direct marketing and research.
- `objectable` is derived, never declared: `"Art. 21(2)"` for direct marketing, `"Art. 21(1)"` for the bases `:public_task` and `:legitimate_interests` (research or not), `"Art. 21(6)"` for research on another basis that is not on a public-interest task, and `nil` otherwise (`:consent`, `:contract`, `:legal_obligation`, `:vital_interests` or an undetermined basis, outside research, or research on a public-interest task on one of those bases).

`to_h` and the policy comparator include the declarations. The Article 30 report prints, for each purpose, a `Right to Object:` line (the article, or `none` with the reason) and an `Under Restriction:` line (the exceptions, or `stops`), and its JSON export carries `objectable`, `direct_marketing`, `research_or_statistics`, `allowed_when_restricted` and `important_public_interest_reference` (the same names as `to_h`). `GDPRCompliance#processing_activities` adds `objectable` and `allowed_when_restricted` for the policy purpose each source matches. Neither is an Art. 30(1) item, so neither adds a gap. The policy generator never writes these declarations: they are the controller's decisions.
#### Right of Access Declarations (Art. 15)

`GDPRCompliance#data_export` gives the data subject a copy of their data (Art. 15(3)) and the information of Art. 15(1)-(2). Most of it comes from the declarations above (purposes, bases, recipients, transfers, retention). Four more are the controller's to make, as field options (keywords, or calls in the field's block) and one policy-level declaration:

```ruby
PamDsl.define_policy :epay do
  field :email, type: :email, collected_from: :data_subject      # Art. 15(1)(g): the source
  field :vat_number, type: :identifier do
    collected_from "the tax registry"
  end
  field :payer_name, type: :name, about: :payer                  # another person's data: for review
  field :password_digest, type: :credential,
        withheld_from_access: "Art. 15(4): <the controller's assessment>"

  access_notice controller: "University of X, Registry, dpo@x.example",            # who the controller is
                rights: "rectification, erasure, restriction, objection: ...",     # Art. 15(1)(e)
                complaint: "the national supervisory authority, www.example.org",  # Art. 15(1)(f)
                automated_decisions: "No decision is based solely on automated processing."  # Art. 15(1)(h)
end
```

- `withheld_from_access:` takes the basis the controller relies on, as text, and the copy names the field and that basis under `withheld` instead of giving its value. A field without it is exported: PAM picks no basis. Art. 15(4) and a national restriction of the right of access under Art. 23 (for instance Greece's Law 4624/2019) are examples a controller might rely on; whether one applies is for the controller and its DPO to decide.
- `about:` names whose data the field is when it is not the data subject's (`:payer`, `:guardian`); `:data_subject` (or nothing) is the subject's own. Such a field goes to the copy's `review`, with its value and history, for the controller to weigh the other person's rights before the copy is handed over.
- `collected_from` is `:data_subject` or text naming the source. A declared field without it is listed in the copy's `gaps`. An empty or nil `collected_from` or `about` raises `InvalidFieldError`, and an empty or nil `access_notice` item `PamDsl::Error`: an empty declaration would read as declared.
- `access_notice` accepts `controller`, `rights`, `complaint` and `automated_decisions`, as text; repeated calls add items, and `policy.access_notice` returns them. An item no policy of the subject's records declares is listed in the copy's `gaps`.

`field_to_h` (and so `policy.to_h`) includes the three field options, and `policy.to_h[:access_notice]` the notice.

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

The default retention is 7 years and the default deletion strategy `:soft_delete`, which keeps the data: a rule that should remove it names `:anonymize` or `:hard_delete`. PAM only declares the rules; Lyra's retention executor carries them out for the models with a `for_model` rule (it does not execute `default`), and warns about a `:soft_delete` rule on a table with no `deleted_at` or `discarded_at` column, where it can never act. Conditions given with `self.when` are stored on the rule and evaluated by `RetentionRule#applies_to?(context)` (true when every condition holds, or there are none); `retention_for` returns the rule's duration without evaluating them.

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
      withdrawable!       # Can be withdrawn anytime
      expires_in 2.years  # Consent expires after 2 years
      describe "We'll send you marketing emails about new products"
    end

    for_purpose :analytics do
      required! false     # Optional consent (not allowed where the purpose's basis is :consent)
      describe "Help us improve by sharing anonymous usage data"
    end
  end
end
```

#### Runtime consent store

Before calling `validate_access!` for a consent-based purpose, populate the store with the subject's actual consent decision. The store is the runtime $CS$ component from the formal model — indexed by `(purpose, subject)` pairs.

> **Without a shared store, the store is held in memory, per process.** `ConsentStore` keeps its
> records in a hash inside the policy object and does not persist them. A restart or deploy loses
> every record, so the store alone cannot demonstrate that a consent was given (GDPR Art. 7(1)). A
> grant or withdrawal made in one process (a Puma worker, a job worker) is not seen by the others,
> so it alone cannot make a withdrawal take effect everywhere (Art. 7(3)). `withdrawable!` is
> recorded with the requirement but not enforced.
>
> **A shared store** (from 1.0.0): when `PamDsl.consent_store` is set, every policy's
> `consent_policy.store` is that store, so consent is kept once per (purpose, subject), whichever
> policy records or checks it, and survives `PamDsl.reset!`. It answers `request`, `grant`,
> `withdraw`, `record_for`, `granted?` and `durable?` (and, optionally, `consents_for(subject_key)`,
> which `GDPRCompliance#consent_audit` then lists as `recorded_consents`). Lyra installs a durable
> one that keeps consent as events in its event store, seen by every process: an application
> using Lyra no longer loads its consent decisions into PAM DSL at start-up or per request (a
> repeated grant records nothing).
> `ConsentRecord.restore` rebuilds a record in a state a store recorded.

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
rescue PamDsl::SpecialCategoryViolationError => e
  puts "Art. 9 violation: #{e.message}"
rescue PamDsl::CriminalDataViolationError => e
  puts "Art. 10 violation: #{e.message}"
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

`validate_access!` checks, in order: the purpose is declared (`UndeclaredPurposeError`), consent is active when the purpose needs it (`ConsentRequiredError`), each field is declared (`InvalidFieldError`) and allowed for the purpose (`PurposeFieldMismatchError`), a purpose touching an Article 9 type has an Art. 9(2) basis (`SpecialCategoryViolationError`), a purpose touching an Art. 10 type has an Art. 10 authorisation (`CriminalDataViolationError`), and, last, the subject has no restriction or upheld objection that covers the access (Condition 6: `RestrictedProcessingError`, `ObjectedProcessingError`; see [below](#restriction-of-processing-and-the-right-to-object-arts-18-and-21)). All errors inherit from `PamDsl::Error`. `policy.access_violations(fields, purpose, subject:)` returns every violation found, in that order, without raising or recording anything.

#### Fields Without a Subject

Consent is decided per data subject, and some uses do not know their subjects yet: a query, before it runs, names the fields it will select, filter or sort on, but not the people it will find. `validate_fields!(fields, purpose, subject: nil)` checks every condition of `validate_access!` except consent and the subject's restrictions and objections (Condition 6), which are per subject: the purpose is declared, its basis is determined (not `:undetermined`), each field is declared and allowed for the purpose, an Article 9 type has an Art. 9(2) basis, and an Art. 10 type has an Art. 10 authorisation. It is enforced as `validate_access!` is (strict raises the first violation, audit reports every one and returns `false`) and goes to the access recorder. `subject:` is optional and only labels the record and the reported violations. `field_violations(fields, purpose)` returns the violations without raising or recording.

```ruby
policy.validate_fields!([:email], :marketing)               # => true, whatever anyone's consent
policy.validate_fields!([:ssn], :marketing)                 # raises PurposeFieldMismatchError
policy.field_violations([:ssn], :marketing)                 # => [#<PamDsl::PurposeFieldMismatchError ...>]
policy.validate_access!([:email], :marketing, subject: 42)  # consent checked for subject 42
```

A purpose whose basis is `:consent` needs an active consent for every subject `validate_access!` is called with, whether or not the policy declares a consent block for it (Art. 6(1)(a)). `validate_fields!` does not replace that check: it is the part that can be made before the subjects are known. Lyra uses it to check a record load's query before it runs, and then checks each record returned with `validate_access!`.

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

`PamDsl.reset!` clears the registered policies, the global enforcement mode (back to `:strict`), the violation handlers, the rights event handlers and the default in-memory rights store (a rights store installed with `PamDsl.rights_store=`, memory or durable, stays).

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

### Restriction of Processing and the Right to Object (Arts. 18 and 21)

The rights belong to the data subject, not to a policy. `PamDsl.rights` records each request, notice, decision and lift as an event in `PamDsl.rights_store`, and computes each request's state from its events. A restriction applies to the subject's data under every policy; an objection concerns one purpose of one policy. Redefining a policy (a code reload) does not touch them. PAM records the controller's decisions: it does not weigh grounds, verify accuracy, or tell the subject or the recipients anything.

```ruby
rights = PamDsl.rights

# Art. 18(1)(a)-(c): all of the subject's data, or only some fields
r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested,   # 18(1)(a)
                     fields: [:lastname, :address],                      # optional; none = all of the data
                     requested_at: asked_at, recorded_by: "dpo-office")
rights.notify_lift!(r.id, at: told_at, by: "dpo-office")   # Art. 18(3): the subject is told first
rights.lift!(r.id, reason: :verified_accurate)             # raises RightsTransitionError without that notice

# Art. 21(1): pending, and the purpose is restricted for this subject (Art. 18(1)(d)) until decided
o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics, grounds: "the subject's words")
rights.decide!(o.id, outcome: :overridden, grounds: :compelling_legitimate_grounds,
               reason: "the controller's reasons", by: "dpo-office", notified_at: told_at)
# or: rights.decide!(o.id, outcome: :upheld, by: "dpo-office")   # the purpose stops for this subject
rights.withdraw_objection!(o.id)                           # the subject's own withdrawal, pending or upheld

rights.state("Payer$7")    # => restrictions and objections with their history, and the events
rights.open_requests       # => restrictions not lifted and objections not decided, oldest first; each answers age
rights.find(r.id)          # => the Restriction or Objection, or nil

PamDsl.on_rights_event { |event| Notifier.rights_event(event) }   # e.g. tell the recipients (Art. 19)
```

**Restrictions.** The grounds are `:accuracy_contested` (Art. 18(1)(a)), `:unlawful_erasure_opposed` (b) and `:needed_for_legal_claims` (c). The fourth, `:objection_pending` (d), is created only by `object!`. A restriction is `:active`, then `:lift_notified` (still restricting), then `:lifted`; `lift!` before `notify_lift!` raises `RightsTransitionError`. `requested_at` (when the subject asked; the month of Art. 12(3) runs from it) is kept apart from `recorded_at`. `fields:` are names a registered policy declares (others raise `ArgumentError`).

**Times.** `requested_at:`, `at:` and `notified_at:` take a `Time` (an `ActiveSupport::TimeWithZone` is one) or a `DateTime`, which is converted; a `Date`, a `String` or a number raises `ArgumentError`. They run forwards: a request is not in the future, a notice is not before its request, a lift is not before its notice, a decision or withdrawal is not before its request, and an override's `notified_at` lies between the request and the decision (`at:`, default now). Otherwise `ArgumentError`, and nothing is recorded. A restriction records the recipients the registered policies declare for the purposes that use its fields, so the controller sees whom Art. 19 says to tell.

**Objections.** What `object!` does depends on the purpose's `objectable` (see the declarations above):

| Purpose | `objectable` | What `object!` does |
|---|---|---|
| `direct_marketing!` (any basis) | `"Art. 21(2)"` | upheld at once (Art. 21(3)); it then stops every `direct_marketing!` purpose of every policy for that subject |
| basis `:public_task` or `:legitimate_interests` (research or not) | `"Art. 21(1)"` | pending, with an Art. 18(1)(d) restriction of that purpose; then `decide!` |
| `research_or_statistics! public_interest_task: false`, on another basis | `"Art. 21(6)"` | pending, with an Art. 18(1)(d) restriction of that purpose; then `decide!(outcome: :upheld)` (it cannot be overridden) |
| anything else | `nil` | records the rejection with its reason, then raises `ObjectionNotApplicableError`, whose message is that reason (for a consent purpose it points to withdrawal, Art. 7(3)) |

A pending objection restricts the objected purpose only (a reading of Art. 18(1)(d) and 18(2) the DPO should confirm), and that restriction ends with the decision, never by `lift!`. `decide!` takes `outcome: :upheld` or `:overridden`. An override needs `grounds:` (`:compelling_legitimate_grounds` or `:legal_claims`; only an Art. 21(1) objection can be overridden), a `reason:` in text, and `notified_at:` (it lifts the 18(1)(d) restriction, so Art. 18(3) applies). An Art. 21(6) objection has no ground to override on: the article yields only to a task in the public interest, and the policy declares the purpose not to be one; uphold it, or correct the declaration. An upheld objection stays in force until the subject withdraws it: a later consent does not lift it (Art. 21(3)). An upheld objection to direct marketing stops every purpose marked `direct_marketing!`, in every policy, for that subject; the objection records the purpose objected to (a reading of Art. 21(3) the DPO should confirm).

**One objection at a time.** While an objection to a purpose of a policy is in force (pending or upheld), `object!` for the same purpose returns it and records nothing, and once direct marketing is objected to, so does `object!` for any direct-marketing purpose. A retry (after a hook failed, say) is therefore safe, and two processes objecting at once end with one objection. After a decision that ended it (overridden, withdrawn), a new `object!` records a new objection.

Event types: `ProcessingRestricted`, `RestrictionLiftNotified`, `RestrictionLifted`, `ObjectionReceived`, `ObjectionUpheld`, `ObjectionOverridden`, `ObjectionRejected` and `ObjectionWithdrawn`. Each `PamDsl::Rights::Event` has `type`, `request_id`, `subject_key`, `data` (grounds, field and purpose names and the controller's reasons; never personal data values), `at` (when it happened), `recorded_at` and `recorded_by`. Keep personal data out of the free-text grounds and reasons: the records are evidence that the right was handled (Art. 5(2)) and are kept when the subject's data is erased.

**Hooks.** Every `on_rights_event` handler is called with every event of a transition, even when one raises; then the first error is raised (the others are logged) and the events stay recorded. A rejected objection still raises `ObjectionNotApplicableError`, with the handler's error as its `cause`.

`open_requests` lists restrictions not lifted and objections not decided, oldest first. A pending objection appears once: its 18(1)(d) restriction is its `restriction_id`.

#### Condition 6

`validate_access!` (and `access_violations`) checks Condition 6 after every other condition, so an access refused for another reason reports the same error as before. With a subject:

- an **upheld objection** to this purpose of this policy, or an upheld objection to direct marketing when this purpose is `direct_marketing!`, gives `ObjectedProcessingError`, whatever the purpose declares;
- a **restriction in force** (active or lift-notified) gives `RestrictedProcessingError` when it covers the access (it names no fields, or names one of the fields accessed; an 18(1)(d) restriction covers only the objected purpose) and the purpose declares no `allowed_when_restricted` exception that applies.

Strict mode raises the first violation; audit mode reports each one and returns `false`; the access recorder receives the refusal with its class, like any other. `validate_fields!` and `field_violations` have no subject and do not check Condition 6: deciding which of many subjects a query may reach is the host's job (Lyra leaves restricted subjects out of model-wide queries).

`validate_rights!(field_names, purpose, subject:)` checks Condition 6 alone (from 1.0.0), for an access whose other conditions are checked elsewhere or that names no declared field: a host calls it for a record loaded by undeclared columns, which a restriction of all of the subject's data, a pending objection's restriction of the purpose, or an upheld objection still covers. It neither checks the purpose's declaration nor consent, records only a refusal, and is free when nothing is in force. `rights_violations(field_names, purpose, subject:)` gives the same violations without enforcing them. A purpose the policy does not declare declares no exception. Condition 6 asks the host for a subject's keys only when a request in force could cover the access (`PamDsl::Rights.could_apply?`: an upheld objection to the purpose, or a restriction that covers it and that no exception other than `:consent` admits); `Rights.applicable(requests, policy, purpose, fields)` and `Rights.violations_among(requests, policy, purpose, fields, subject)` let a host decide many subjects in one pass (Lyra does, for model-wide queries). `Rights.project` refuses a decision on, or the withdrawal of, an objection whose Art. 18(1)(d) restriction is not recorded.

**Subject keys.** A right is recorded under a subject key. `PamDsl.subject_keys(subject)` gives the keys Condition 6 looks up: by default, a non-empty String, Symbol or Integer is its own key (`7` and `"7"` are one key), `nil` and a model-wide subject such as `"Payer$*"` have none, and any other object (a model instance, a Struct, an Array) raises `ArgumentError`, in `restrict!`/`object!` and in `validate_access!` alike, so that a right is never recorded under, or looked up by, a key that matches nothing. A host sets `PamDsl.subject_key_resolver` (an object answering `call(subject)` with the keys, or `nil` for the default) to map, for example, a record to its own key and to the keys of the people it names; `restrict!` and `object!` given such an object record under its first key. With no rights recorded, Condition 6 returns at once, without resolving the subject.

#### The Rights Store

`PamDsl.rights_store` is a protocol, so the host decides where rights are kept. A store keeps the events, append-only, one stream per subject key, and answers:

- `append(events, expected_version:)`: append one or more events for one subject key, atomically, if the subject's stream holds exactly `expected_version` events; otherwise raise `PamDsl::RightsConcurrencyError` and append nothing (two processes cannot both lift, or both decide, one request). Before storing, check the stream with `PamDsl::Rights.project(existing + events)`, which raises `PamDsl::RightsTransitionError` for a step the rights do not allow (a lift without the Art. 18(3) notice, a decision on a decided objection, an unknown request or event type), and store nothing if it raises.
- `events_for(subject_key)`: the subject's events, in order, as `PamDsl::Rights::Event` values whose `at` and `recorded_at` are `Time` objects (a store that serialises events returns Times) and whose `data` has symbol keys, symbols kept as symbols.
- `subject_key_for(request_id)`: the key of the stream holding a request, or `nil`.
- `active`: every request in force (`PamDsl::Rights::Restriction` not lifted, `PamDsl::Rights::Objection` pending or upheld). `PamDsl::Rights.project(events)` folds events into these.

Including `PamDsl::RightsStore::Base` adds `active_for(keys)` and `any_active?` (which Condition 6 calls on every access with a subject; override them when they can be answered more cheaply) and `durable?` (false; a store whose records outlive the process and are shared by every process returns true).

PAM DSL ships one store, `PamDsl::RightsStore::Memory`, the default: in memory, per process, lost on restart. It is for tests, development and scripts. While `PamDsl.require_durable_rights_store` is on, `PamDsl.rights` refuses to record in a store whose `durable?` is false (`RightsStoreNotDurableError`), this one or a host's, so that a right a subject exercised cannot be lost silently; reading still works and finds nothing, so an application that records no rights is unaffected. The flag is off by default. Under Rails, PAM's railtie turns it on outside the development and test environments; `config.pam_dsl.require_durable_rights_store = true` or `false` sets it for every environment. A durable store comes from the host: Lyra installs one that keeps the events in its event store. Without Lyra, an application implements the four methods above over its own durable storage.

#### Reports

- **The Art. 15 copy** (`GDPRCompliance#data_export`, from 1.0.0) has `restrictions` and `objections`: the subject's own requests (`PamDsl.rights.export(keys)`), each with its ground or article, fields, purpose, state, dates and the controller's decisions and reasons, oldest first; an objection's 18(1)(d) restriction is part of the objection. Who on the staff recorded or decided a request is left out. The keys read are `"<subject_type>$<subject_id>"`, or what the `rights_keys:` option (`->(records) { [key, ...] }`) gives: Lyra adds the keys of the subject's records that name no one else.
- **The register** prints each purpose's right to object and Art. 18(2) exceptions (Art. 30 report, its JSON, `to_h`). The per-subject `GDPRCompliance#processing_activities` gives, for each activity, `rights_by_purpose` (`{ purpose => { objectable:, allowed_when_restricted: } }` for its declared purposes, read from each model's policy) and, when there is exactly one such purpose, its `objectable` and `allowed_when_restricted`. Before 1.0.0's rights work these read only the `policy_name:` policy, so with a `policy_resolver:` (Lyra's) they were always empty.

#### With Lyra

Lyra applies the rights where it checks reads (see Lyra's PRIVACY_COMPLIANCE.md): a record a restriction or upheld objection covers is refused when loaded, even by undeclared columns; model-wide queries leave the restricted subjects out (a join or subquery reaching one is refused); `Model.lyra_processable` gives batch jobs the records they may process; `Lyra::Erasure.erase!` refuses a restricted record unless it lifts a notified restriction (`lifting:`); retention skips restricted records and reports them; the rights are read afresh at the first check of each purpose block, request, job and batch. Writes are not checked in 1.0.0. The lifecycle of a restriction and of an objection is also a pair of PetriFlow nets in Lyra's verification tests, matched against `PamDsl::Rights.project`.

What PAM does not do: it does not send the Art. 19 notifications or the subject's replies (use `on_rights_event`), it does not provide the channel through which objections arrive (Art. 21(5)), and it checks only the accesses that reach `validate_access!` or `validate_rights!`.

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
- Processing activities, one per declared purpose (Art. 30(1)(b)-(e)): description, legal basis with its Art. 6(1) citation, the Art. 9(2) bases and Art. 10 authorisations of a purpose that reads such data, data subjects, data categories (required and optional fields), whether consent is required, recipients, and transfers with their safeguards
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

The generator drafts purposes but does not choose their legal bases, which are the controller's decision: each drafted purpose reads `basis :undetermined`, with the usual candidate and its caveats as a comment (from 0.9.3; it used to write a basis). Until each is replaced, access under it is refused.

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
| `:health` | `medical`, `health`, `diagnosis`, `prescription`, and names containing them (`medical_record`) |
| `:biometric` | `fingerprint`, `face`, `retina`, `biometric` |
| `:genetic` | `genetic`, `genome`, `genomic`, `genotype`, `dna`, and names containing them (`genetic_test_result`, `dna_sample`) |
| `:racial_ethnic_origin` | `ethnicity`, `ethnic_origin`, `ethnic_group`, `racial_origin`; `race` only as the whole name or its end (`applicant_race`) |
| `:political_opinion` | `political_opinion`, `political_views`, `political_affiliation`, `political_party`, `party_affiliation`, `party_membership` |
| `:religious_belief` | `religion`, `religious_belief`, `religious_affiliation`, `religious_denomination`, `philosophical_belief` |
| `:trade_union_membership` | `trade_union`, `labour_union`/`labor_union`, `union_member`, `union_membership` |
| `:sex_life_orientation` | `sexual_orientation`, `sexual_preference`, `sexual_life`, `sex_life` |
| `:criminal_offence` | `criminal_record`, `criminal_conviction`, `criminal_offence`/`criminal_offense`, `criminal_history`, `criminal_background_check`, `conviction` |

The special-category and Art. 10 names are matched conservatively: a word that often means something else is not enough on its own (`party` is often a counterparty, `union` a set operation, `orientation` a page's, `denomination` a banknote's, `offence` a sport's), and neither is `gender`, which Art. 9(1) does not list. The generator marks each such field in its draft with the condition a purpose reading it must meet (`art9_basis` or `art10_authorisation`).

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

# Redact only sensitive PII (ssn, credit_card, financial, identifier, credential,
# token, payment_token, the Art. 9 special categories and Art. 10 data)
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

#### The Art. 15 copy

Beside the keys above, `data_export` returns the copy of the data and the information of Art. 15(1)-(2) (`PamDsl::SubjectAccess`):

```ruby
report = compliance.data_export   # history: true, accesses: true, disclose_actors: false, verified_by: nil, record: true
report[:records]             # each record whole: attributes (every field), withheld, review, history (from/to per change)
report[:accesses]            # the access log's entries; nil when the store keeps none
report[:processing_context]  # per purpose admitting the records' declared fields: basis, recipients, transfers, retention, sources
                             # (the copy's purposes; the per-event processing_activities, guessed from keywords, is gone from 1.0.0)
report[:notice]              # the policy's access_notice
report[:gaps]                # [purpose or nil, item] for what the policy does not declare
```

The store supplies what only it knows through the constructor's options; without them the records are rebuilt from the subject's events and `accesses` is `nil`:

| Option | Signature |
|---|---|
| `policy_resolver:` | `->(model_name) { PamDsl::Policy or nil }`: each model's policy, for subjects whose records span policies (falls back to `policy_name:`) |
| `records_reader:` | `->(subject_id, subject_type, events, history:) { [{ model:, id:, state:, as_of:, attributes:, history_from:, periods:, history: [{ at:, operation:, field:, from:, to:, actor: }] }] }` |
| `access_reader:` | `->(subject_id, subject_type, records) { [{ at:, record:, purpose:, legal_basis:, fields:, outcome:, actor: }] or nil }`; `{ entries: [...], gap: "..." }` for a partial log, whose gap the copy lists |
| `export_recorder:` | `->(export) { ... }`: called after each explicit export with its sections, record count and `verified_by`, never values; not for `data_export(record: false)` or `full_report`, which are views rather than answered requests |
| `actor_label:` | `->(actor, subject) { label }`: default `"you"` (the actor's `user_id` and `user_type` are the subject's), `"staff or you"` (the subject's id, no `user_type`), `"staff"`, `"system"` (no user) |

A records reader's record may also carry `set_outside_periods: [field, ...]`, values set while the record was another person's: the copy lists them under `withheld` with the basis "set while the record was another person's" instead of giving them. Retention in `processing_context` is what the policy declares (`Policy#declared_retention_for`), `nil` and a gap where it declares nothing; columns no declaration covers are a gap too. `pii_inventory` and `data_lineage` leave out fields declared `withheld_from_access:` or `about:` another person.

Who acted is a role label unless `disclose_actors: true`. `history: false` and `accesses: false` are for a request the subject narrowed, and the copy lists what it leaves out in `gaps`. Where a policy governs a model, `processing_activities` reads its purposes, bases, categories, recipients and retention, and `rectification_history` lists updates of declared fields as well as detected ones.

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
- `PamDsl.rights` - The rights API (`restrict!`, `notify_lift!`, `lift!`, `object!`, `decide!`, `withdraw_objection!`, `find`, `state`, `open_requests`, `active_for`); see [Restriction of Processing and the Right to Object](#restriction-of-processing-and-the-right-to-object-arts-18-and-21)
- `PamDsl.rights_store` / `PamDsl.rights_store=` - Where rights are recorded (the store protocol); a `RightsStore::Memory` created on first use by default; `= nil` returns to it
- `PamDsl.require_durable_rights_store` / `=` - When true, a store that is not durable refuses to record; set by the railtie outside development and test
- `PamDsl.subject_key_resolver` / `=` - Maps a subject to its rights keys (`call(subject)`); `PamDsl.subject_keys(subject)` applies it
- `PamDsl.on_rights_event { |event| ... }` - Register a handler called with each recorded `Rights::Event`
- `PamDsl.reset!` - Clear all policies, the enforcement mode, the violation and rights event handlers, and the default in-memory rights store (not the access recorder, the subject key resolver or an installed rights store)

### Policy

- `field(name, type:, sensitivity:, &block)` - Define a field
- `purpose(name, &block)` - Define a purpose
- `retention(&block)` - Configure retention
- `consent(&block)` - Configure consent
- `meta(key, value)` - Add custom metadata to policy
- `enforcement(mode)` - Set this policy's enforcement mode, overriding the global one
- `enforcement_mode` - The mode this policy enforces with (its own, or the global one)
- `security_measures(*measures)` - Declare technical and organisational measures (Art. 30(1)(g)); with no arguments, return them
- `article_30_gaps` - `[purpose_name or nil, clause]` pairs for every Article 30(1) item not declared, an undetermined basis, and a missing Art. 9(2) basis or Art. 10 authorisation
- `purpose_reads?(purpose, predicate)` - True when the purpose reads (lists, or is allowed) a field for which the `Field` predicate (`:special_category?`, `:criminal_data?`) holds
- `get_field(name)` / `get_purpose(name)` - Look up a field or purpose; raise `InvalidFieldError` / `UndeclaredPurposeError`
- `allowed?(field, purpose)` - Check if field is allowed for purpose: true when the field's `allow_for` names the purpose or the purpose's `requires`/`optionally` names the field (the union; see [Defining Fields](#defining-fields))
- `validate_access!(fields, purpose, subject:)` - Validate access for a data subject. Returns `true` when valid. In strict mode raises the first violation: `UndeclaredPurposeError`, `ConsentRequiredError`, `InvalidFieldError`, `PurposeFieldMismatchError`, `SpecialCategoryViolationError`, `CriminalDataViolationError`, `ObjectedProcessingError` or `RestrictedProcessingError` (Condition 6); in audit mode records every violation and returns `false`. Every call goes to the access recorder, if one is set
- `access_violations(fields, purpose, subject:)` - Every violation for the access, as error objects, without raising or recording
- `validate_fields!(fields, purpose, subject: nil)` - `validate_access!` without the consent step and Condition 6, for a use whose subjects are not known yet (a query before it runs). Enforced and recorded as `validate_access!` is; `subject:` only labels the record
- `field_violations(fields, purpose)` - Every violation `validate_fields!` would find, without raising or recording
- `validate_rights!(fields, purpose, subject:)` - Condition 6 alone (from 1.0.0): the subject's restrictions and upheld objections that cover the access; no purpose or consent check. Enforced as `validate_access!` is; only a refusal is recorded. `rights_violations(fields, purpose, subject:)` returns them without enforcing
- `consent_policy` - Access the `ConsentPolicy` to populate the runtime consent store
- `lia_compliance_gaps` - Returns purposes with `:legitimate_interests` basis that have not called `lia_documented!`
- `sensitive_fields` - Get all fields with confidential/restricted sensitivity
- `restricted_fields` - Get all fields with restricted sensitivity
- `retention_for(model_class, field_name: nil)` - Retention duration for a model (and field), falling back to the default
- `fields`, `purposes`, `retention_policy` - The declared fields and purposes (hashes by name) and the `RetentionPolicy`
- `metadata` - Access policy metadata hash
- `to_h` - Export policy as hash (includes all metadata)

### Field

- `allow_for(*purposes)` - Allow field for purposes. Widens, does not restrict: the field is allowed for these purposes in addition to every purpose that lists it in `requires`/`optionally`
- `transform(context, &block)` - Define transformation
- `meta(key, value)` - Add custom metadata
- `metadata` - Access field metadata hash
- `sensitive?` - Check if field is confidential or restricted
- `restricted?` - Check if field is restricted
- `special_category?` - True for an Article 9 type (`Field::SPECIAL_CATEGORY_TYPES`: `:health`, `:biometric`, `:genetic`, `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief`, `:trade_union_membership`, `:sex_life_orientation`)
- `criminal_data?` - True for an Article 10 type (`Field::CRIMINAL_DATA_TYPES`: `:criminal_offence`)
- `allowed_for?(purpose)` - Whether the field's own `allow_for` list admits the purpose (true when the list is empty); `Policy#allowed?` is the full check
- `apply_transformation(context, value)` - Apply defined transformation

### Purpose

- `describe(text)` - Set description
- `basis(legal_basis)` - Set legal basis (GDPR Art. 6)
- `lia_documented!(value = true)` - Record that a Legitimate Interests Assessment has been conducted for this `:legitimate_interests` purpose; pass `false` to unset
- `lia_documented?` - True when LIA has been recorded
- `art9_basis(*bases)` - Declare one or more Art. 9(2) bases; required when the purpose accesses Article-9 special-category-**type** fields (e.g. `:health`, `:trade_union_membership`), independently of the `:restricted` risk level; multiple calls accumulate
- `art10_authorisation(*authorisations)` - Name the official authority or the Union or Member State law that authorises processing Art. 10 data (non-blank strings); required when the purpose accesses a `:criminal_offence` field; an Art. 9(2) basis does not stand in for it; multiple calls accumulate
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
- `art10_authorised?` - True when at least one Art. 10 authorisation is declared
- `art10_authorisations` - Array of declared Art. 10 authorisations
- `allowed_when_restricted(*exceptions, reference: nil)` - Declare the Art. 18(2) grounds on which the purpose continues while a subject's processing is restricted (`:consent`, `:legal_claims`, `:protection_of_rights`, `:important_public_interest` with `reference:` naming the law); multiple calls accumulate
- `restriction_exceptions` / `important_public_interest_reference` / `continues_under_restriction?(exception)` - The declared Art. 18(2) exceptions
- `direct_marketing!` / `direct_marketing?` - Mark the purpose as direct marketing (Art. 21(2))
- `research_or_statistics!(public_interest_task:)` / `research_or_statistics?` / `public_interest_task?` - Mark the purpose as research or statistics (Art. 89(1), Art. 21(6))
- `objectable` - The article that gives the right to object (`"Art. 21(1)"`, `"Art. 21(2)"`, `"Art. 21(6)"`), or nil
- `all_fields` - Get all fields (required + optional)
- `requires_field?(field)` - Check if field is required
- `allows_field?(field)` - Check if field is allowed

### Rights (`PamDsl.rights`)

- `restrict!(subject:, ground:, fields: nil, requested_at: nil, recorded_by: nil)` - Record an Art. 18(1)(a)-(c) restriction; returns a `Rights::Restriction`
- `notify_lift!(id, at: nil, by: nil)` - Record the Art. 18(3) notice
- `lift!(id, reason:, at: nil, by: nil)` - Lift; raises `RightsTransitionError` without a recorded notice
- `object!(subject:, policy:, purpose:, grounds: nil, requested_at: nil, recorded_by: nil)` - Record an objection; returns a `Rights::Objection` (pending, or upheld for direct marketing), or records the rejection and raises `ObjectionNotApplicableError`; returns the objection in force instead of recording a second (same purpose, or any direct-marketing purpose once direct marketing is objected to)
- `decide!(id, outcome:, grounds: nil, reason: nil, by: nil, at: nil, notified_at: nil)` - `:upheld`, or `:overridden` with grounds, reason and notice
- `withdraw_objection!(id, at: nil, by: nil)` - The subject withdraws a pending or upheld objection
- `find(id)`, `state(subject)`, `open_requests`, `active_for(keys)` - Read the requests
- `export(keys)` - The requests under these keys as the Art. 15 copy gives them: `{ restrictions: [...], objections: [...] }`

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
- `withdrawable!(value)` - Set if withdrawable. For a purpose whose basis is `:consent`, `withdrawable!(false)` and `required!(false)` raise `PamDsl::ConsentGrammarError` when the policy is defined (Arts. 6(1)(a), 7(3)). `granular!` was removed in 1.0.0: it was recorded and never enforced; declare one consent block per purpose.
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
| `genetic` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |
| `racial_ethnic_origin` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |
| `political_opinion` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |
| `religious_belief` | `:restricted` | Special (Art. 9) | Religious or philosophical beliefs |
| `trade_union_membership` | `:restricted` | Special (Art. 9) | GDPR explicit prohibition |
| `sex_life_orientation` | `:restricted` | Special (Art. 9) | Sex life or sexual orientation |
| `criminal_offence` | `:restricted` | Criminal (Art. 10) | Official authority or Union/Member State law |
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

**Article 9 special categories** (independent of the table above): a field whose **type** is one of the eight Art. 9(1) types (`:health`, `:biometric`, `:genetic`, `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief`, `:trade_union_membership`, `:sex_life_orientation`) additionally requires an `art9_basis` on every purpose that accesses it — at any sensitivity level — under Art. 9(2)(a)–(j).

**Article 10 data** (independent of both): a field whose **type** is `:criminal_offence` requires an `art10_authorisation` on every purpose that accesses it, naming the official authority or the Union or Member State law that authorises the processing. An Art. 9(2) basis does not satisfy it.

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
    art9_basis :health_care        # Art. 9(2)(h) — mandatory for Art. 9 type fields (:health, :genetic, ...)
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
