# Changelog

All notable changes to PAM DSL will be documented in this file.

## [Unreleased]

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
