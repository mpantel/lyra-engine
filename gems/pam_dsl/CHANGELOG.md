# Changelog

All notable changes to PAM DSL will be documented in this file.

## [Unreleased]

## [1.0.0] - 2026-11-17

### Breaking
- **`GDPRCompliance#data_export` no longer has `processing_activities`.** The key listed, per
  event, a purpose guessed from keywords in its source (`registration`, `payment`, `email`,
  `analytics`, else "Application functionality"), whatever the policy declared. The copy's
  purposes are `processing_context`: per purpose that admits the records' declared fields, its
  basis, recipients, transfers, retention and sources, from the policy. Read `processing_context`
  instead. The per-subject Art. 30 method `processing_activities`, and `full_report`'s key of that
  name, are unchanged.

### Added
- **Restriction of processing (Art. 18) and the right to object (Art. 21).**
  - Declarations on a purpose: `allowed_when_restricted(*exceptions, reference: nil)` with the
    Art. 18(2) grounds `:consent`, `:legal_claims`, `:protection_of_rights` and
    `:important_public_interest` (which needs `reference:` naming the law; anything else raises
    at load); `direct_marketing!`; `research_or_statistics!(public_interest_task:)`; and the
    derived `objectable` (`"Art. 21(2)"` for direct marketing, `"Art. 21(1)"` for `:public_task`
    and `:legitimate_interests`, research or not, `"Art. 21(6)"` for research on another basis
    that is not on a public-interest task, else nil). `Policy#to_h`, the comparator, the Article
    30 report (`Right to Object:` and `Under Restriction:` lines) and its export (`objectable`,
    `direct_marketing`, `research_or_statistics`, `allowed_when_restricted`,
    `important_public_interest_reference`) include them, as does
    `GDPRCompliance#processing_activities` (`objectable`, `allowed_when_restricted`); neither is
    an Art. 30(1) gap.
  - `PamDsl.rights`, per data subject and independent of any policy: `restrict!` (grounds
    18(1)(a)-(c), optional `fields:` that a registered policy declares, `requested_at:` kept
    apart from `recorded_at`), `notify_lift!` then `lift!` (`RightsTransitionError` without the
    Art. 18(3) notice), `object!` (direct marketing upheld at once, and then stopping every
    `direct_marketing!` purpose of every policy for that subject; Art. 21(1) and 21(6) pending,
    restricting that purpose only under 18(1)(d); otherwise recorded as rejected and raised as
    `ObjectionNotApplicableError`; objecting again while an objection is in force returns it),
    `decide!` (`:upheld`, or for Art. 21(1) `:overridden` with grounds, a reason and the notice),
    `withdraw_objection!`, `find`, `state`, `open_requests` (a pending objection listed once).
    Times are `Time` or `DateTime` and run forwards (no request in the future, no lift before its
    notice, no notice after the decision), else `ArgumentError`. Each step is a `Rights::Event`;
    `PamDsl.on_rights_event` handlers all receive every event of a transition, then the first
    handler error is raised.
  - Condition 6 in `validate_access!` and `access_violations`, after every other condition:
    `ObjectedProcessingError` for an upheld objection that covers the purpose,
    `RestrictedProcessingError` for a restriction in force that covers the access when the
    purpose declares no exception that applies (`:consent` only with a consent granted after the
    restriction was requested). Not on the subject-less path (`validate_fields!`,
    `field_violations`). `PamDsl.subject_keys` and `PamDsl.subject_key_resolver` map a subject
    to its keys; without a resolver a subject is a non-empty String, Symbol or Integer
    (`ArgumentError` for anything else), and `nil` and `"Model$*"` have none.
  - The store protocol, `PamDsl.rights_store` (`append(events, expected_version:)`, checked with
    `Rights.project`, which refuses a transition the rights do not allow; `events_for`, whose
    times are `Time`; `subject_key_for`; `active`; `RightsStore::Base` adds `active_for`,
    `any_active?`, `durable?`), and one store, `RightsStore::Memory`, the default. `PamDsl.rights`
    refuses to record in a store that is not durable (`RightsStoreNotDurableError`) while
    `PamDsl.require_durable_rights_store` is on, which the railtie sets outside development and
    test (`config.pam_dsl.require_durable_rights_store` overrides it). A durable store comes from
    the host. `PamDsl.reset!` replaces the default memory store and keeps an installed one.
- **A type for every Art. 9(1) special category, and for Art. 10 data.** `:genetic`,
  `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief` (religious or philosophical
  beliefs), `:trade_union_membership` and `:sex_life_orientation` join `:health` and `:biometric`
  in `Field::SPECIAL_CATEGORY_TYPES` (an `art9_basis` is required, else
  `SpecialCategoryViolationError`). `:criminal_offence` (`Field::CRIMINAL_DATA_TYPES`,
  `Field#criminal_data?`) holds Art. 10 data and has its own condition: a purpose that reads it
  declares the official authority or the Union or Member State law that authorises it with
  `Purpose#art10_authorisation`, else `CriminalDataViolationError`. Neither condition satisfies
  the other. The Article 30 report and its export show both, `article_30_gaps` lists a missing
  one, and `PIIDetector` (so the generator) proposes the new types from unambiguous column names.
  25 field types (18 before).
- **`Policy#validate_fields!(fields, purpose, subject: nil)` and `Policy#field_violations(fields,
  purpose)`:** Def. 1 for a use whose subjects are not known yet, such as a query before it runs.
  Every condition of `validate_access!` is checked except consent, which is decided per subject:
  the purpose is declared, its basis determined, each field declared and allowed for it, and an
  Article 9 type has an Art. 9(2) basis. `validate_fields!` is enforced and recorded as
  `validate_access!` is; `subject:` only labels the record. Lyra checks a record load's query with
  it before the query runs, then each record returned with `validate_access!`.
- **The Art. 15 copy.** `GDPRCompliance#data_export` adds five keys to those it returned:
  `records` (each of the subject's records whole, with its history), `accesses` (the access log),
  `processing_context` (purposes, bases, recipients, transfers, retention and sources, from the
  policy of each record's model), `notice` and `gaps` (what the policy does not declare). It takes
  `history:`, `accesses:` (false only for a narrowed request), `disclose_actors:` (who acted is a
  role label otherwise), `verified_by:` and `record:` (an explicit call is passed to the
  `export_recorder`; `record: false`, which `full_report` uses, is a view and is not). New
  constructor options: `policy_resolver:`,
  `records_reader:`, `access_reader:`, `export_recorder:`, `actor_label:`. See
  `PamDsl::SubjectAccess`.
- **Field options for the copy:** `withheld_from_access: "<basis>"` (the field is named with the
  controller's stated basis instead of its value; PAM picks no basis), `about: :payer` (another
  person's data, set aside for review) and `collected_from` (the source, Art. 15(1)(g)), as
  keywords or in the field's block.
- **`access_notice`**, a policy-level declaration of the controller's notice: `controller`,
  `rights`, `complaint`, `automated_decisions`. A missing item is a gap in the copy. An empty or
  nil item raises `PamDsl::Error`, as an empty or nil `about` or `collected_from` raises
  `InvalidFieldError`: an empty declaration would read as declared.
- **`Policy#declared_retention_for(model, field_name:)`** and
  `RetentionPolicy#declared_duration_for` / `#default_declared?`: the period the policy itself
  declares, or nil; `retention_for` still falls back to PAM's 7 years. The copy reports the
  declared period and lists a missing one as "Art. 15(1)(d) retention not declared"; it also
  lists the columns no declaration covers.
- `PolicyComparator`'s field details include the three field options.

### Changed
- **The gems' MIT-LICENSE copyright line no longer names the University of the Aegean**, which is
  the author's affiliation, not a copyright holder.
- **The generator counts the models with personal data as such.** Its draft's header and summary
  said "Models scanned:" for the number of models in which it found personal data. They now say
  "Models with PII fields: N (of M scanned)" after a scan (on the Aegean testbed, 11 of 32: its 28
  models and 4 of its gems').
- **Condition 6 alone, the rights in the Art. 15 copy, and per-purpose declarations in the
  per-subject register.** `Policy#validate_rights!(fields, purpose, subject:)` checks only the
  subject's restrictions and upheld objections (no purpose declaration, no consent), records only
  a refusal and is free when nothing is in force; `Policy#rights_violations` returns the same
  without enforcing (a host decides with it whom a model-wide query leaves out). `data_export` has
  `restrictions` and `objections`, the subject's own requests (`PamDsl.rights.export(keys)`; the
  keys are `"<type>$<id>"` or the new `rights_keys:` option's), without who on the staff recorded
  them. `processing_activities` gives each activity's `rights_by_purpose` for its declared
  purposes, read from each model's policy, and `objectable`/`allowed_when_restricted` when there
  is exactly one; they read only the `policy_name:` policy before, so with a `policy_resolver:`
  they were always empty.
- **Condition 6 resolves a subject only when a request in force could cover the access**
  (`Rights.could_apply?`, `applicable`, `violations_among`): with requests in force that cannot
  cover this purpose and these fields (an exception the purpose declares, another purpose's
  objection), the host is not asked for the subject's keys. An undeclared purpose declares no
  Art. 18(2) exception (`validate_rights!`, `rights_violations`). `Rights.project` refuses a decision
  on, or withdrawal of, an objection whose Art. 18(1)(d) restriction is not recorded.
- **A shared consent store (`PamDsl.consent_store`).** When set, every policy's
  `consent_policy.store` is that store (it answers `request`, `grant`, `withdraw`, `record_for`,
  `granted?`, `durable?`), so consent is kept once per (purpose, subject) for every policy and
  survives `PamDsl.reset!`; unset, each policy keeps its own in-memory store, as before. Lyra
  installs a durable one. `ConsentRecord.restore` rebuilds a record in a recorded state, and
  `consent_audit` lists the store's records for the subject (`recorded_consents`, from a store that
  answers `consents_for`), which take precedence in `current_consents`. Under the `:consent`
  exception of Art. 18(2), a `ConsentRequiredError` the store raises (Lyra's, for a record shared by
  several people) is reported with the restriction instead of escaping `validate_access!`.
- **`processing_activities` reads the declared policy** where one governs the events' model
  (`policy_name:` or `policy_resolver:`): the purpose the source names, else the purposes that
  admit the declared fields the events carry, with their legal bases, recipients and the model's
  retention period; the detector's categories are joined by the declared fields' types. Without a
  policy it guesses as before.
- **`data_export`'s `pii_inventory` and `data_lineage` leave out the fields the policy declares
  `withheld_from_access:` or `about:` another person** (the copy's `withheld` and `review` name
  them), so the old keys no longer give what the copy withholds.
- **Actor labels:** "you" only when the actor's id and class (`user_type`) are the subject's;
  "staff or you" for an actor with the subject's id and no recorded class; "staff" otherwise.
  An `access_reader` may return `{ entries:, gap: }` for a partial log.
- **`rectification_history` lists an update that changed a declared field,** as well as one whose
  changed field the detector flags; `corrected_fields` are those fields. Before, the detector
  alone decided, on the whole event.

### Fixed
- **A retention period given in plain seconds prints correctly.** Under ActiveSupport an Integer
  number of seconds (`keep_for 86400`, `default 7 * 365 * 86400`, or an Integer from
  configuration) was read as years by `Reporter#format_duration`: 86400 printed "0 years" in the
  Article 30 register, the policy summary and the retention check. `PolicyComparator` printed
  365 days of seconds as "365 days" and seven years of seconds as "6 years". Plain seconds are
  now worded by `PamDsl::DurationFormat`, the same in both modes, with the polyfill's
  fixed-length units (1 month = 30 days, 1 year = 365 days) rounded down to the largest whole
  unit: 3600 is "1 hour", 86400 "1 day", 30 days "1 month", 365 days "1 year".
  `ActiveSupport::Duration` values print as before. Enforcement (`RetentionRule#expired?`, the
  retention checks) already read plain seconds as seconds in both modes.
- **Works without ActiveSupport again.** With the standard-library polyfill, the Article 30
  register raised `NoMethodError` on `String#presence`, and JSON export
  (`Reporter#export_json`, `GDPRCompliance#portable_export`) relied on ActiveSupport having loaded
  `json`. The polyfill now provides `Object#presence` and treats a whitespace-only string as blank,
  as ActiveSupport does; both files require `json`. Nothing changes under ActiveSupport. A
  reporter test expected "1 months" where the formatter writes "1 month"; `rake test:polyfill`
  passes again.

### Documented
- **`allow_for` widens, it does not restrict.** `Policy#allowed?(field, purpose)` holds when the
  field's `allow_for` names the purpose or the purpose's `requires`/`optionally` names the field;
  a field is not kept from a purpose by an `allow_for` that leaves it out. `Field#allowed_for?`
  checks the field's side only. The README and the comments say so; no behaviour change.
- **`:soft_delete`, the default deletion strategy, keeps the data.** The README says that a rule
  that should remove data names `:anonymize` or `:hard_delete`, and that Lyra's executor acts only
  on `for_model` rules.

## [0.9.3] - 2026-11-04

### Changed
- **The policy generator no longer chooses legal bases.** Each purpose it drafts, from models or
  as a template, reads `basis :undetermined` with the usual candidate and its caveats as a comment;
  it used to write one (contract for billing, which tax law often makes a legal obligation;
  legitimate interests for analytics, not available to a public authority for its tasks; consent
  with no consent block). The basis is the controller's decision.

### Added
- **`basis :undetermined`**, not a legal basis but a marker: access under such a purpose raises
  `PamDsl::UndeterminedBasisError`, and `article_30_gaps` lists the purpose, until a basis is
  declared.

### Documented
- The runtime consent store is held in memory, per process, and not persisted (README, "Runtime
  consent store"; `ConsentStore`). Persistent, event-backed consent is future work.

## [0.9.1] - 2026-11-02

### Changed
- **The gem's description expands ORFEAS as the words its letters stand for**:
  Object-Relational Framework for Event-Aware Systems. It read "Object-Relational to
  Event-Sourcing Architecture", which has no F. No code changed since 0.9.0.

## [0.9.0] - 2026-10-25

### Added
- **`online_identifier` is a declarable field type** — the detector had a pattern by that name
  but `Field::PII_TYPES` lacked it, so a policy could not declare such a field. It is a
  non-special, non-sensitive type. (The detector still reports login-name columns as
  `identifier`.)
- **The policy generators keep an existing policy file** — `generate:policy` and
  `generate:from_models` raise `PolicyGenerator::FileExistsError` instead of overwriting
  `config/initializers/pam_dsl_policy.rb`; `FORCE=1` on the rake tasks (`force: true` in Ruby)
  replaces it.
- **Article 30 register from declarations, not placeholders** — `article_30_report` printed
  "Internal staff" as every purpose's recipients, "No international transfers", a list of
  asserted security measures (TLS, role-based access, PaperTrail), a per-purpose retention that
  was always the default (it passed a field where a model name belongs), and a data-subject
  rights section of "[Configure implementation path]" that Article 30 does not ask for. Purposes
  now declare `data_subjects`, `recipients` and `transfer to:, safeguard:` (or `no_transfers!`),
  and policies `security_measures` (Art. 30(1)(c), (d), (e), (g)); the register prints them, a
  retention schedule from the policy's rules (Art. 30(1)(f)), and a completeness section listing
  each undeclared item with its clause (`Policy#article_30_gaps`). The JSON export carries the
  same, under `not_declared` for the gaps. Durations read "1 year", not "1 years".
- **One PII dictionary; detection fixed on a foreign codebase** — `PolicyGenerator` kept its own
  exact-name patterns and exclusions, separate from `PIIDetector`'s; on Solidus 4.7 the
  generator found 6 of 26 personal columns and flagged an order's state machine as an address.
  The generator now detects with `PIIDetector` (its `PII_PATTERNS` and `EXCLUDE_PATTERNS` are
  gone), scans each table's real columns (a column the model ignores is reported, and the
  generated policy says the application cannot see or erase it), and counts a bare `name` only
  in a model that holds other personal data (a product's or a payment plan's name is not a
  person's). The detector gained `address1`/`address2`, `zipcode`/`postcode`, `state_name`, any
  `*_ip`, `last_digits`/`last4`, `login`/`username` (an `:identifier`), `bic`/`swift`/account
  numbers, `birth_date`, and a person's account and session tokens and credentials (password
  hashes and salts, remember/confirmation/reset/unlock/guest tokens), which the `encrypted_` and
  `_token` exclusions used to drop; names match name forms and the names of people in a role
  (`debtor_name`, `approver_name`), not every `*_name`. New exclusions: foreign keys (`*_id`,
  except identifiers such as `vat_id`, `customer_national_id`), `*_iso`, `*_message`, `*_reason`,
  `*_notes`; a bare `state` and `rest_income_budget` are no longer personal. On Solidus: 24 of
  26; on the Aegean testbed: 29 fields (27 personal) where the old generator reported 18; on the
  labelled evaluation dataset: recall 99.1% (was 97.4%), precision 98.3% (was 98.2%).
- **Access recorder** (`PamDsl.access_recorder`, `Enforcement::Access`): every
  `validate_access!` call, whatever its outcome, is passed to the recorder before it returns or
  raises, as an `Access` (policy, purpose, legal basis, fields, subject, outcome `:granted`,
  `:audited` or `:denied`, the violations found, time). The recorder answers `record?(policy)`
  and `call(access)`; an error it raises propagates, so an access it cannot record does not go
  ahead. One per process, set by the host (Lyra's access log); `PamDsl.reset!` leaves it in place.
- **Enforcement modes** (`PamDsl.enforcement_mode`, `PamDsl::Enforcement`): `:strict`, the
  default and the behaviour so far, blocks an invalid access by raising its typed exception;
  `:audit` lets it through, records **every** violation found (not only the first), logs each
  (`PamDsl.logger`: `Rails.logger` under Rails, standard error otherwise), passes each to the
  `PamDsl.on_violation { |violation| ... }` handlers as an `Enforcement::Violation` (policy,
  purpose, fields, subject, error class, message, time), and makes `validate_access!` return
  `false`. A policy can override the global mode (`enforcement :audit` in its definition). In
  strict mode the first violation raised is the same, in the same order, as before.
  `Policy#access_violations` returns them all without raising. `PamDsl.reset!` also resets the
  mode and the handlers.
### Changed
- **Ruby 4.0 or later is required** (`required_ruby_version >= 4.0`; none was declared before).
### Fixed
- `PamDsl.reporter` dropped the `output:` option, so reports always went to standard output.

## [0.8.0] - 2026-06-15

The first release to RubyGems since 0.6.0, and the version the PAM article (Requirements
Engineering, 2026) cites. It also contains 0.7.0 (below), which was never published.

### Changed
- **ActiveSupport is now optional.** `pam_dsl` previously declared a hard runtime dependency on `activesupport` and unconditionally `require`d it. It now loads ActiveSupport only if present and otherwise falls back to a minimal standard-library polyfill (`lib/pam_dsl/core_ext.rb`), so the gem is self-contained when used standalone (outside Rails). `activesupport` moved from a runtime to a development dependency (still exercised by the test suite). The ActiveSupport surface the gem uses is small: `Numeric` duration helpers (`.years`/`.months`/`.weeks`/`.days`, `.ago`/`.from_now`), `Time.current`, `String#underscore`/`#titleize`, and `Object#present?`.
- The polyfill durations use a **fixed-length approximation** (30-day month, 365-day year), matching the gem's report tooling. When ActiveSupport is present its calendar-aware durations are used instead, unchanged.
- `Reporter#format_duration` now matches `PamDsl::DURATION_CLASS` (`ActiveSupport::Duration` when available, else `Numeric`) instead of referencing `ActiveSupport::Duration` directly, so it works under both paths.

### Added
- `PAM_DSL_FORCE_POLYFILL` environment variable forces the stdlib polyfill even when ActiveSupport is installed, so both code paths can be tested.
- Rake tasks `test:polyfill` (run the suite forcing the polyfill) and `test:both` (run it under both ActiveSupport and the polyfill). The same 425 tests pass under both paths; `test_duration_formatting` was made tolerant of the 30-day month boundary (the only assertion that differs between the calendar and fixed-length duration models).

## [0.7.0] - 2026-06-02 (never published; part of 0.8.0)

### Added
- `ConsentRecord` class: full four-state lifecycle (P0 Pending, P1 Granted, P2 Expired, P3 Withdrawn) matching the formal consent state diagram (paper §4.2). `expires_at` is stored on the record at grant time so `state` derives `:expired` autonomously without external requirement lookup. `grant!` (P0→P1) and `withdraw!` (P1→P3) enforce valid transitions; P2 and P3 are absorbing.
- `ConsentStore#request` creates a Pending record (P0); replaces absorbing records to support re-consent flow
- `ConsentPolicy#request_consent` exposes the Pending flow at the policy level
- `ConsentStore` class: runtime consent state store (the $CS$ component of the formal runtime context); indexed by `[purpose, subject]` pairs; supports `grant`, `withdraw`, `record_for`, `granted?`
- `ConsentPolicy#grant_consent(purpose:, subject:, granted_at:)` and `#withdraw_consent(purpose:, subject:)` for populating the consent store
- `ConsentPolicy#validate!(purpose, subject:)` now performs per-subject consent lookup against the store, implementing `consent_active(u, s, C)` from Definition 5
- `Policy#validate_access!` signature changed to `(field_names, purpose_name, subject:)` — subject identifier is now required, eliminating the caller-supplied boolean anti-pattern
- `UndeclaredPurposeError` and `PurposeFieldMismatchError` exception classes — completes the five-class violation taxonomy from Definition 4 (`InvalidFieldError`, `UndeclaredPurposeError`, `PurposeFieldMismatchError`, `ConsentRequiredError`, `SensitivityViolationError`)
- `Policy#validate_access!` now calls `get_field` before `allowed?` so undeclared fields raise `InvalidFieldError` and purpose-field mismatches raise `PurposeFieldMismatchError`, making violation classes unambiguous
- `Purpose#lia_documented!` DSL method and `lia_documented?` predicate — records that a Legitimate Interests Assessment has been conducted for an Art. 6(1)(f) purpose
- `Policy#lia_compliance_gaps` — returns all `:legitimate_interests` purposes lacking a documented LIA; surfaces Definition 2's basis_ok condition as a compliance query rather than an enforcement gate (per paper §3.2: LIA is a human-judgment obligation, not automatable)
- `Purpose#art9_basis(*bases)` DSL method for declaring GDPR Art. 9(2) sub-clauses on a purpose; multiple calls accumulate
- `Purpose#art9_basis?` predicate returning true when at least one Art. 9(2) basis is declared
- `SensitivityViolationError` exception class (Definition 4, Sensitivity Violation class)
- `Field::SPECIAL_CATEGORY_TYPES` constant (`:health`, `:biometric`) and `Field#special_category?` predicate — identify GDPR Article 9 special-category data by **type**, independently of the `:restricted` sensitivity (Article 32 risk) level
- `Policy#validate_access!` enforces Definition 1 Condition 5 by **data type**: raises `SensitivityViolationError` when any requested field is an Article 9 special-category type (`special_category?`) and the purpose declares no Art. 9(2) basis. This deliberately decouples the Art. 9(2) requirement from the `:restricted` risk tier, so high-risk-but-ordinary data (e.g. financial or national-identifier fields marked `:restricted`) no longer spuriously requires an Art. 9(2) basis, while a special-category type triggers the check at any sensitivity level.

## [0.6.0] - 2026-01-05

### Added
- `country_code` and `locale` as identifier PII types
- Health PII patterns: `diagnosis`, `prescription`, `condition`

### Changed
- Improved policy generator formatting and edge case handling
- Fixed field DSL method chain return value

### Fixed
- Field DSL now returns `self` for proper method chaining

#### PIIDetector Enhancements
- `extract_pii_from_records` method for scanning any record collection
- Generic extractor interface (`attribute_extractor`, `metadata_extractor`)
- Works with any event store (Lyra, RubyEventStore, ActiveRecord, plain hashes)
- PII inventory grouped by type with source tracing

#### PIIMasker Class (NEW)
- Batch masking of PII in data structures
- Three masking strategies: `:partial`, `:full`, `:redact_sensitive`
- `mask(attributes, strategy:)` for hash masking
- `mask_field(value, field_name, strategy:)` for individual fields
- `mask_by_type(value, pii_type, strategy:)` for type-based masking
- `mask_records(records, attribute_extractor:, attribute_setter:, strategy:)` for collections

#### GDPRCompliance Class (NEW)
- Comprehensive GDPR data subject rights implementation
- Article 15 (Access): `data_export` with full PII inventory
- Article 16 (Rectification): `rectification_history` tracking corrections
- Article 17 (Erasure): `right_to_be_forgotten_report` with deletion strategy
- Article 20 (Portability): `portable_export` in JSON/CSV/XML formats
- Article 30 (Processing Records): `processing_activities` documentation
- `retention_compliance_check` for policy enforcement
- `consent_audit` for consent tracking and legitimacy verification
- `full_report` combining all GDPR aspects
- Generic extractor interface for any event source

#### Core DSL
- Field definitions with PII types and sensitivity levels
- Purpose definitions with GDPR legal bases
- Retention policies with field-level granularity
- Consent management with expiration and granular control
- Policy validation and access control
- Transformation support for different contexts
- Metadata support for all entities

#### Reporter Class
- Policy summary with field types, sensitivity levels, and transformations
- GDPR Article 30 Records of Processing Activities report
- PII analysis with event store integration
- Retention compliance checking
- Access pattern analysis by operation type and time
- JSON export for machine processing

#### PolicyGenerator Class
- Generate template policies with sensible defaults
- Scan ActiveRecord models to detect PII fields
- Pattern-based field detection (email, phone, name, address, financial, etc.)
- Exclusion patterns to reduce false positives (timestamps, amounts, foreign keys)
- Auto-generate purposes based on detected field types
- Model-specific retention rules for financial data

#### PolicyComparator Class
- Compare two PAM DSL policies programmatically
- Field comparison: common fields, unique to each policy, type/sensitivity matching
- Purpose comparison with legal basis and required fields
- Retention comparison with default durations and rule counts
- Generate markdown comparison reports with `generate_report(output_path:)`
- Export comparison data as hash via `to_h` for JSON serialization
- `pam_dsl:report:compare[policy1,policy2,output_path]` rake task

#### Rails Integration
- Rake tasks under `pam_dsl:report:*` namespace
- Rake tasks under `pam_dsl:generate:*` namespace
- Convenience aliases under `privacy:*` namespace
- Configuration via `Rails.application.config.pam_dsl`
