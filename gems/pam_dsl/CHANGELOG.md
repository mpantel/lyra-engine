# Changelog

All notable changes to PAM DSL will be documented in this file.

## [Unreleased]

### Added
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

## [0.8.0] - 2026-06-15

### Changed
- **ActiveSupport is now optional.** `pam_dsl` previously declared a hard runtime dependency on `activesupport` and unconditionally `require`d it. It now loads ActiveSupport only if present and otherwise falls back to a minimal standard-library polyfill (`lib/pam_dsl/core_ext.rb`), so the gem is self-contained when used standalone (outside Rails). `activesupport` moved from a runtime to a development dependency (still exercised by the test suite). The ActiveSupport surface the gem uses is small: `Numeric` duration helpers (`.years`/`.months`/`.weeks`/`.days`, `.ago`/`.from_now`), `Time.current`, `String#underscore`/`#titleize`, and `Object#present?`.
- The polyfill durations use a **fixed-length approximation** (30-day month, 365-day year), matching the gem's report tooling. When ActiveSupport is present its calendar-aware durations are used instead, unchanged.
- `Reporter#format_duration` now matches `PamDsl::DURATION_CLASS` (`ActiveSupport::Duration` when available, else `Numeric`) instead of referencing `ActiveSupport::Duration` directly, so it works under both paths.

### Added
- `PAM_DSL_FORCE_POLYFILL` environment variable forces the stdlib polyfill even when ActiveSupport is installed, so both code paths can be tested.
- Rake tasks `test:polyfill` (run the suite forcing the polyfill) and `test:both` (run it under both ActiveSupport and the polyfill). The same 425 tests pass under both paths; `test_duration_formatting` was made tolerant of the 30-day month boundary (the only assertion that differs between the calendar and fixed-length duration models).

## [0.7.0] - 2026-06-02

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
