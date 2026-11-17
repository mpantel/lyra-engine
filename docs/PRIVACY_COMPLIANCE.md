# Privacy Compliance and GDPR in Lyra

## Contents

- [Overview](#overview)
- [Privacy Policies](#privacy-policies)
- [Core Privacy Features](#core-privacy-features)
- [Read-Side Monitoring](#read-side-monitoring)
- [Working Examples](#working-examples)
- [Integration Patterns](#integration-patterns)
- [Compliance Workflows](#compliance-workflows)
- [Best Practices](#best-practices)
- [Compliance Checklist](#compliance-checklist)
- [File Locations](#file-locations)
- [Legal Disclaimer](#legal-disclaimer)
- [Support](#support)

## Overview

Lyra uses its event log to support GDPR compliance: data lineage, data
subject reports, erasure, retention, and a record of who read personal data
and for which purpose.

Data access monitoring has a write side and a read side. Every write to a
monitored model is recorded as an event with who made it and in which causal
chain; that side, with privacy stamps on events, is described in
[ARCHITECTURE.md](ARCHITECTURE.md#write-side-monitoring). Reads of models
covered by a privacy policy can be bound to a declared purpose, checked
against the policy, and recorded in an access log ([Read-Side
Monitoring](#read-side-monitoring)).

The privacy features need the PAM DSL gem (`orfeas_pam_dsl`). Without it no
policy loads, nothing is detected as PII, and purpose checks and the access
log do nothing. The exact API is in [API_REFERENCE.md](API_REFERENCE.md#privacy).

## Privacy Policies

### Policies

Policies are written in the PAM DSL (`gems/pam_dsl`). `config/privacy_policies.rb`
holds two example policies, `:university_system` and `:ecommerce`. An excerpt:

```ruby
PamDsl.define_policy :university_system do
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication, :enrollment, :payment_processing
    transform :display do |value|
      local, domain = value.split('@')
      "#{local[0]}***@#{domain}"
    end
  end

  purpose :enrollment do
    describe "Student enrollment and registration"
    basis :contract
    requires :email, :name, :student_id, :date_of_birth
    optionally :phone, :address
  end

  retention do
    for_model 'Student' do
      keep_for 10.years
      field :email, duration: 2.years
      on_expiry :archive
    end
  end
end

class Student < ApplicationRecord
  monitor_with_lyra privacy_policy: :university_system
end
```

A field may be used for a purpose when the field's `allow_for` names the purpose
**or** the purpose's `requires`/`optionally` names the field: `allow_for` widens
the purposes a field is allowed for, it does not restrict them. Above, `:email`
is allowed for `:enrollment` from both sides, and for `:authentication` from
its `allow_for` alone, whatever that purpose lists; to keep a field from a
purpose, leave it out of both.

A model's policy is its `privacy_policy` option, else `config.privacy_policy`
(`Lyra::Privacy.policy_for(Student)`). The DSL is summarised in
[API_REFERENCE.md](API_REFERENCE.md#pam-dsl-essentials) and documented in
[gems/pam_dsl/README.md](../gems/pam_dsl/README.md).

### `Lyra::Privacy::PolicyIntegration`

**Location:** `lib/lyra/privacy/policy_integration.rb`

Combines a named policy with the provider's PII detector, through the
`Lyra::Privacy` provider interface:

| Method | Description |
|---|---|
| `new(policy_name, use_detector: true)` | Wrap the named policy. |
| `validate_access!(field_names, purpose, subject:)` | The policy's access check: `true`, or the first violation raised (strict) / `false` (audit). |
| `detect_pii(attributes)` | Declared fields first (`source: :policy`), then fields the detector finds (`source: :detector`) when `use_detector`. |
| `mask_pii(field, value, context = :display)` | The policy's transformation for a declared field, else the detector's masking, else the value unchanged. |
| `allowed?(field, purpose)`, `allowed_purposes(field)`, `consent_required?(purpose)` | Policy queries. |
| `retention_duration(model_class, field_name: nil)` | Retention from the policy; `nil` without one. |
| `sensitive_fields`, `restricted_fields`, `metadata`, `to_h` | Policy information. |

PAM's errors are defined in `gems/pam_dsl/lib/pam_dsl.rb`, all subclasses of
`PamDsl::Error`: `PolicyNotFoundError`, `InvalidFieldError`,
`UndeclaredPurposeError`, `PurposeFieldMismatchError`, `ConsentRequiredError`,
`SpecialCategoryViolationError` (Condition 5; `SensitivityViolationError` is
its deprecated alias, removed in 2.0) and, from 1.0.0,
`CriminalDataViolationError` (a purpose reads Art. 10 data, a field of type
`criminal_offence`, without an `art10_authorisation` naming the official
authority or the Union or Member State law that authorises it; an Art. 9(2)
basis does not satisfy it).

## Core Privacy Features

### 1. PII Detection

**Locations:** `lib/lyra/privacy/pii_detector.rb`, `pii_masker.rb`

`Lyra::Privacy::PIIDetector` has no patterns of its own: `detect`,
`contains_pii?`, `mask`, `sensitive?` and `extract_from_event_stream` delegate
to the provider's detector. With PAM that is `PamDsl::PIIDetector`, which
classifies a field by its name, not its value (partial matching by default,
so `billing_phone` is a phone; names that look like timestamps, counters,
flags or amounts are excluded first). Without PAM nothing is detected.

Name-based detection is a fallback. Purpose-bound reads, the access log,
privacy stamps and erasure use the attributes the policy declares.

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

The full list of types is in [API_REFERENCE.md](API_REFERENCE.md#pii-detection-and-masking).

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

See [PAM DSL README](../gems/pam_dsl/README.md#piidetector-configuration) for configuration options and [Sensitivity Levels](../gems/pam_dsl/README.md#sensitivity-levels-and-legislative-background) for regulatory mapping.

### 2. GDPR Rights Implementation

#### Right to Access (Article 15)

Export all data about a subject:

```ruby
compliance = Lyra::Privacy::GDPRCompliance.new(
  subject_id: user.id,
  subject_type: 'User'
)

export = compliance.data_export
# Returns, as before 1.0.0:
# - events, pii_inventory, data_lineage (event summaries and detected PII)
# and, from 1.0.0, the copy of the data (Art. 15(3)) and the information of Art. 15(1)-(2):
# - records, accesses, processing_context, notice, gaps
```

`GDPRCompliance` selects the events of the subject's own record (`model_class` and `model_id`
are the subject), of records that refer to the subject by foreign key (`user_id` for subject type
`User`), and of events that name the subject explicitly (`subject_id`, `subject_type`). It does not
select events by their actor: what a staff member edited is other people's data (before 0.9.3 it
did). The keys of the export are shown under [GDPR Data Export](#gdpr-data-export).

##### The copy of the data (from 1.0.0)

**Which records.** A record is the subject's by what it is, not by which of its events repeat the
foreign key: the subject's own row (the model the subject type names), the rows of each monitored
model that link to the subject (indexed queries, read as Lyra), and every record the subject's
events touch (one batched pass over the log), so that a destroyed record, a record of an
events-only model (ES-NoProj) and a row that pre-dates monitoring are all found. A model links to
the subject through each `belongs_to` whose class is the subject's model
(`belongs_to :owner, class_name: "Person"`), each polymorphic `belongs_to` whose type column names
the subject's class, and the `<type>_id` column by convention; the subject's own model is not linked
to itself (a person's manager is another person).

**Records that move between people.** A record belongs to each person for the periods in which its
links named them: its `history` holds those periods' events only, and `periods` lists them. The
event that moves it gives each person only their side: the previous one sees the old values, with
the link's new value given as `"moved to another person"`; the new one sees only the new values.
A record that no longer names the subject is `:reassigned`, with its state just before the move. A
value last set while the record was another person's is not given: its field is listed under
`withheld` with the basis `"set while the record was another person's"`. The access log's entries
for a moved record are the subject's only within their periods.

**`records`**, one per record:

```ruby
{ model: "Registration", id: 42,
  state: :current,          # the row; :replayed (no row: ES-NoProj, ES-Async), :destroyed (the last
                            # state before the destroy), :reassigned (the state when it last named the subject)
  as_of: <time>,
  attributes: { "firstname" => "...", "amount" => 500, "status" => "paid", ... },   # every column
  withheld: [{ field: "password_digest", basis: "<the controller's stated basis>" }],
  review:   [{ field: "payer_name", about: :payer, value: "...", history: [...] }],
  history_from: <time>,     # the first event; for a row imported by Genesis, the import
  periods: nil,             # or [{ from:, to: }] when the foreign key moved
  history: [{ at:, operation: :updated, field: "status", from: "pending", to: "paid", by: "staff" }] }
```

Every attribute is in the copy, not only those a detector flags: nothing is left out unless the
policy says so. Encrypted columns (`encrypts`) appear in plaintext, from the row and from the log.
`history` gives every stored value: a create or an import each attribute (from `nil`), an update
each change (`from`/`to`), a destroy one entry, and any other event in the record's stream
(`ErasureApplied`, a domain event) one entry that names it with no values. Storing is processing
(Art. 4(2)), so past values the event store still holds are part of the data undergoing processing
when the request arrives.

**Withheld fields.** A field is left out of the copy only where the controller declares it in the
policy with its basis:

```ruby
field :password_digest, type: :credential,
      withheld_from_access: "Art. 15(4): <the controller's assessment>"
```

The copy then names the field and that basis under `withheld`, and gives no value, neither in
`attributes` nor in `history`. A field without the declaration is exported. Lyra picks no legal
basis: examples a controller might rely on are Art. 15(4) (the rights and freedoms of others) and a
restriction of the right of access in national law under Art. 23 (in Greece, for instance, the
restrictions of Law 4624/2019). Whether either applies is for the controller to decide with the
DPO; these are examples, not a statement of the law.

**Other people's data.** A field declared `about:` another person (`field :payer_name, type: :name,
about: :payer`) goes to `review`, with its value and history, not to `attributes`: the controller
weighs the other person's rights (Art. 15(4)) before handing the copy over. Free-text fields are
not covered: Lyra does not read them.

**`accesses`** are the access log's entries (`Lyra::AccessLog`) for the subject's records (within
their periods), for the subject's own key and for the keys the application passed as the subject
(`GDPRCompliance.new(access_log_subjects: [...])`; by default the bare subject id, which
`validate_access!(..., subject: 7)` writes; `[]` when bare ids of several types share the log):
when, which record, purpose, legal basis, field names and outcome. Earlier exports appear with
outcome `"exported"`. With `config.record_access_events` off, `accesses` lists only the earlier
exports and `gaps` says the log is not enabled.

**Who acted** is a role label in `history` and `accesses`: `"you"` when the event records the
subject's id and class, `"staff or you"` when it records the subject's id but no class (an event
written before 1.0.0, or by a `metadata_proc` that sets none), `"staff"` for anyone else, and
`"system"` when no user is recorded. From 1.0.0 every event records the acting user's class beside
its id (`user_type`, from `Current.user`). An actor of another class that is the subject's own login
(a `User` account of a `Person` subject) reads `"staff"`; map it with
`GDPRCompliance.new(actor_label: ->(actor, subject) { ... })`. Ids and IP addresses are added
(`actor: { user_id:, ip_address: }`) only with `data_export(disclose_actors: true)`, after the
controller has weighed its staff's rights.

**`processing_context`** comes from the declared policy of each record's model (a subject's
records may span models with different policies): one entry per purpose that admits the record's
declared fields, with its legal basis, data categories (the fields' types), `recipients`,
`transfers`, `retention` (the model's period and the fields' own periods, as the policy declares
them: `nil` where it declares none, rather than PAM's 7-year fallback) and `sources`
(`collected_from`, Art. 15(1)(g)). It is the copy's only statement of purposes: the per-event
`processing_activities` key, whose purposes were guessed from keywords in the event's source, was
removed in 1.0.0 (the Art. 30 method `processing_activities` is unchanged).

**The older keys** (`events`, `pii_inventory`, `data_lineage`) follow the same rules from 1.0.0:
fields declared `withheld_from_access:` or `about:` another person are left out (the copy's
`withheld` and `review` name them), encrypted values are opened, and an event that moves a record
between people carries the subject's side only.

**`notice`** is the controller's notice, declared once in the policy (`access_notice`):
`controller`, `rights`, `complaint` and `automated_decisions`.

**`gaps`** lists, as `[purpose or nil, item]`, every item the policy does not declare: a purpose's
recipients, transfers or undetermined basis, a field's source, a field admitted by no purpose, a
model's retention period, the columns no declaration covers (no purpose, basis or retention
stated), a notice item, and the access log when it is off. An incomplete policy yields an honest, incomplete
copy rather than empty values.

**Narrowing.** `data_export(history: false)` and `data_export(accesses: false)` are for a request
the subject has narrowed (recital 63); the copy says in `gaps` what it leaves out. They are not the
default.

**Recording.** Each explicit export is recorded as a `SubjectAccessExported` event in the stream
`Lyra::SubjectAccessExports$<Type>$<id>`: when, which sections, how many records, who verified the
subject (`data_export(verified_by: "registry desk")`) and who exported (the metadata, as for any
access), never a value. It is the controller's evidence that the request was answered (Arts. 5(2),
12(3)), so it is kept apart from the access log: erasing the subject's access log
(`Lyra::AccessLog.erase!`, or `Lyra::Erasure.erase!` with `access_log: true`) leaves it, as it
leaves the record of the erasure itself. The copy's `accesses` lists earlier exports with outcome
`"exported"`.

The rule is that an explicit `data_export` call answers a request and is recorded; a view of the
data is not. `data_export(record: false)` is that view: `full_report` and the dashboard's subject
and GDPR routes use it, so looking at a subject's data in the dashboard does not put an answered
request on record. Recording is on by default; `config.record_subject_access_exports = false`
turns it off. Nothing is recorded in disabled mode. Identity verification (Art. 12(6)) is the
controller's procedure, not Lyra's.

**Limits.** The copy covers what Lyra can see: the event store and the monitored models' tables
(and the subject's own model). Other systems, backups and files are outside it. A subject with no
row and no events has nothing to export, and `gaps` says so. History starts at a record's first
event; for rows imported by Genesis the earlier history was never recorded. A `pluck` is recorded in
the access log against the model, not a record, so it cannot be attributed to a subject. Values
removed by `Lyra::Erasure` are gone from the history too; the history shows the `ErasureApplied`
event. Selection follows the monitored models' `belongs_to` associations to the subject's model and
the `<type>_id` convention; a link of another kind (a join table, a `has_one` from the subject's
side, a column with another name and no association) is not followed. A record whose stream has no
create or import and whose link never changes is taken to have named its current owner throughout.

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
bin/rails lyra:erase MODEL=Registration ID=5 REASON="Art. 17 request #12" OPERATOR=jdoe [FIELDS=email,phone] [EVERYWHERE=1] [DRY_RUN=1] [MAX_COPIES=12] [ACCESS_LOG=1|0] [ACCESS_LOG_SUBJECTS=user-7]
bin/rails lyra:erase_access_log SUBJECT=user-7 REASON="Art. 17 request #12" OPERATOR=jdoe
```

- Erases the personal attributes (declared by the policy, or listed by the events' privacy
  stamps, or exactly `fields:`, which must be among those unless `any_fields: true`,
  `ANY_FIELDS=1`, since 0.9.3) from the row and from every event in the record's stream,
  overwriting each event in place (same id, position and time): attributes, both sides of each
  change, and payload keys with the attribute's name, plus any copy of an erased value under
  another name (matched by value: a payload's `payer_email`).
- `everywhere: true` (`EVERYWHERE=1`) also searches the whole log for the erased values: events
  of other records that copied them are scrubbed, those records' rows get the value replaced
  where they hold it, and each gets an `ErasureApplied`; `result.copies` lists them. The search
  is a text match on the stored events, then an exact match on each candidate. Since 1.0.0 the
  tables of monitored models with a policy are searched too (below). Only direct identifiers
  (fields the policy types as email, phone, identifier, card, payment token, IP address,
  credential) are searched for in other records: a name, city or postal code can belong to
  another customer by coincidence, so those are erased in the person's own record only. And only
  the person's own values are: those in the row's personal fields and at the top of a personal
  field in the record's own CRUD events (an attribute, either side of a change, a payload entry),
  and the strings inside a structure declared personal that are identifying for its type
  (below). A value the person's data holds for someone else is erased in the person's record, as
  its events are, but is not searched for elsewhere, where it is that person's own: a manager's
  email nested in `{"manager" => {"email" => …}}`, or a friend's email at the top of another event
  in the person's stream (an invitation the application recorded there). Before 1.0.0 both were
  searched for, and the third party's own record was erased.
- **Choose the threshold with a dry run first.** `dry_run: true` (`DRY_RUN=1`, since 1.0.0) runs
  the whole erasure in a transaction and rolls it back: the result (and the task's output) says
  what would be erased, the records reached, the rows without events, what would be left behind
  and each value that would be left as shared with its number of holders, and nothing is
  written. Do this before an erasure with `everywhere`: once the person's own values are erased,
  a later run cannot find the copies left as shared, and raising `MAX_COPIES` then does nothing.
  Check the holders the dry run counts, and erase with `MAX_COPIES=<holders>` if they are this
  person's.
- **The threshold.** A value held by more than `max_copies` other records is shared by many
  people (a city, a placeholder), not a copy of this person's, and is left everywhere. The
  threshold is `config.erasure_max_copies` (default 10), and `max_copies:` (`MAX_COPIES=`)
  overrides it for one call; it must be a positive integer (`ArgumentError` otherwise, before
  anything is written). Holders are counted by record (since 1.0.0; before, by stream, so a
  record's reference links counted too): through their events, each confirmed by an exact match,
  and through their rows, by the table search's match (so a row holding the value only as a JSON
  key, or in another case in a `citext` column, counts). The person's linked records do not
  count. They are found by the rule of the subject-access copy (`Lyra::Privacy::SubjectLinks`):
  a record of a monitored model with a `belongs_to` to the erased record's model whose foreign key
  holds the erased record's id (or, for `belongs_to … primary_key: :col`, the value of that
  column), a polymorphic `belongs_to` whose type column names that model, or a `<model>_id`
  column no association owns. Any such association counts: an assignee, a manager or a referrer
  is taken as linked as much as an owner. That is for the threshold only: a linked record is
  erased only where it holds a copy, as any other holder. Records of the erased record's own
  model, records linked through more than one `belongs_to`, and records not linked at all (one
  person's several registrations with no person table) count. In ES-NoProj, where the tables are
  absent, linked records are found only where Lyra's reads can answer the lookup. Each value left
  as shared is reported in `result.shared` as `{ field: "email", type: :email, holders: 12 }`,
  never the value, and `result.shared_values` is their count. Values above the threshold are
  reported and the erasure goes on; it is never refused.
- **Rows whose events lack the value** (since 1.0.0). A row can hold a value its events do not:
  written by raw SQL, before monitoring and never imported by Genesis, or by a write Lyra could
  not intercept. With `everywhere`, each table of a monitored model with a policy is searched
  once for the erased values: string and text columns by equality (`citext` without case), `json`
  and `jsonb` as text by a `LIKE` on the value as a JSON string, a text column the model reads as
  a structure (serialized, `attribute :x, :json`) by a `LIKE` on the bare value, string arrays
  with `= ANY`, `hstore` values. Encrypted columns are not searched (`not_searched`). Rows found
  this way count toward the threshold. Every record reached, through its events or its row, is
  locked, its stream read again, its events rewritten and its row scrubbed with the value rule
  only, keys never rewritten; the erasure matches whole values and reports the rest in
  `left_behind`. If only the row held the value (its events did not, or held it only inside a
  longer string), its `ErasureApplied` says `row_only: true` and it is listed in
  `result.rows_without_events` (and in `copies`): its row already differed from its replay
  before the erasure. In Monitor and Disabled, where the tables are authoritative, run
  `bin/rails lyra:repair` afterwards to record the rows' state in the log. In Hijack and the
  event-sourcing modes the events are authoritative and `lyra:repair` refuses to run: rebuild
  those tables from the events (`bin/rails lyra:projections:rebuild MODEL=…`), which also drops
  whatever else the raw write put in those rows. If the record has no stream, the row is erased
  first and then imported the Genesis way, under the table's Genesis lock, so its `Imported`
  event holds the replacement, never the value, and an `ErasureApplied` with `imported: true`
  follows; Genesis, DualView and ES-NoProj then see it as any imported record. If a Genesis run
  the lock could not hold back imported the row first, that stream is rewritten instead and no
  import is claimed. The search covers monitored models with a policy only: the tables of other
  models, unmonitored tables, other databases, files, caches, search indexes and external
  systems are not searched. It is skipped in ES-NoProj, where the tables are absent or stale. Its
  cost is one sequential scan per searched table per erasure (about 0.1 s for two values on a
  100,000-row table with string, text, `jsonb` and array columns on a development machine), which
  returns keys only; no row is loaded until it is erased, and no index is added. The log is
  searched once for all the values, and the candidate events are read in batches.
- Lyra's own record streams are never rewritten by `everywhere`, nor counted as holders, even
  when an event there, or its stream's name, holds an erased value (a consent recorded under an
  email as its subject key): restrictions and objections (`Lyra::Rights`), consent
  (`Lyra::Consent`), access logs (`Lyra::DataAccess`) and their erasures, and subject-access
  exports, each with its per-subject streams. They are the evidence that a right was handled
  (Art. 5(2); for consent, Art. 7(1)), and the consent store is rebuilt from them. Keep personal
  values out of their free-text reasons.
- Each row gets the rule its own events get, so it still replays to its events. The record's own
  row is scrubbed column by column with the record's rule: a value under a personal field's name
  is replaced (the key rule), and so is a copy of an erased value under any name (the value rule).
  The rows of other records reached by `everywhere` get the value rule only, as their events do. A
  third party's email under an `email` key in another record's JSON is not this person's, and is
  kept. Since 1.0.0 this reaches inside structured columns: a `json` or `jsonb` column, a
  PostgreSQL array, an `hstore`, a serialized attribute, or any attribute whose type gives a hash
  or an array (`attribute :notes, :json` on a text column) is recursed into, as its events are, and
  is written back whole in the same `UPDATE`. A column declared personal that holds a hash or an array is replaced whole, by
  `nil` or, when it is NOT NULL, by its own default (`[]`, `{}`). Inside a hash, only the strings
  that are identifying for the field's type count as the person's values (an email address for
  `:email`, a phone number for `:phone`, a string with a digit and no space for `:identifier` and
  the token types), and those under a nested key that is itself a personal field (those are
  erased in the record but, since 1.0.0, not searched for elsewhere, see above); labels such as
  `"home"` or `"active"` do not, and are not erased elsewhere. A structure declared personal is
  taken to be the person's: a third party's email inside an `:email` structure of the person
  (`{"work" => …, "manager" => "boss@example.com"}`) is identifying for its type and is searched
  for. Keep third parties' values out of personal structures, or erase without `everywhere`. The strings of an array (an array
  column) all count. An earlier erasure's replacement (`"erased:<id>"`) is no one's value. Before 1.0.0
  the events lost a value inside such a column while the row kept it, and the row no longer
  replayed to its events (DualView and the mode checks reported a discrepancy). With
  `everywhere`, the record was listed in `result.copies` all the same. A `text` column that
  happens to hold JSON is a string in its events too, so it is compared as one string: an email
  inside it is not a copy, as with a derived value below. Encrypted attributes (`encrypts`) are
  compared in clear in the events as in the row. The erasure moves the row's optimistic-lock
  column (`lock_version`), as any write does, so a copy loaded before it fails with
  `StaleObjectError` rather than saving the erased values back. The move is recorded in the
  record's stream as an update of that column alone (metadata `source: "lyra_erasure"`), so the
  row still equals its replay. In ES-Async the move starts from the version the log last
  recorded, which the row can trail. Lyra builds no process-mining export from the log; one built
  outside Lyra should leave out events whose metadata has `lock_moved_by_erasure: true`, or it
  will see an extra update.
- A primary key or a foreign key is never rewritten: the record's stream is named after its key,
  and a foreign key is another record's. A personal value used as a primary key cannot be erased by
  Lyra. The record is listed in `result.left_behind` as `"Model <key withheld>"` with the key
  column, and `result.key_withheld` is true when it is the erased record's own key. A key that
  holds an erased value is never printed in `copies`, `left_behind`, the `ErasureApplied` reason of
  another record, or by `lyra:erase`.
- A value held as a JSON key, or inside a longer string (a `text` column holding JSON), is not
  erased: a key is part of the document's structure, and a value is matched whole. After the
  erasure the record's own row (its replayed state in ES-NoProj) is checked for the erased values,
  and so, with `everywhere`, is each other record reached. Each that still holds one is listed
  in `result.left_behind` as `{ record:, columns: }`, never with the value, and `lyra:erase`
  prints it; erase those by hand. A record is listed in `result.copies` only if its row, when it
  has one, no longer holds the value anywhere. The check matches substrings, so a short value (a
  first name) may be reported for an unrelated word that contains it. A `citext` column compares
  without case, so a copy there that differs in case is reported too (the erasure matches exactly).
- With `everywhere`, other records holding a copy are found by a text search of the stored events,
  without case. An encrypted column (`encrypts`) is stored as ciphertext and cannot be searched;
  `result.not_searched` names the encrypted columns of the monitored models (`"Model.column"`),
  and `lyra:erase` prints them. Each record found is locked, and its stream read again, before it
  is erased, so a copy written during the search is erased with the rest.
- The record's access log (`Lyra::DataAccess$<Model>$<id>`, see below) records who read it, never
  a value. It is kept by default: it may be evidence the controller must keep (Art. 5(2), a
  security investigation). Since 1.0.0, `config.erase_access_log = true` or `access_log: true`
  (`ACCESS_LOG=1`) deletes its events instead, from the events table and every stream they are
  in. The configuration acts only once the record is fully erased (every personal field, by this
  erasure or earlier ones): a field's own retention period erases that field from a record still in
  use, and its log stays. Retention's `:hard_delete` of a record erased earlier deletes the log with
  the record when the configuration is on; `access_log: false` (`ACCESS_LOG=0`) keeps it whatever the configuration says. Either way
  `ErasureApplied` records `access_log` (`"erased"` or `"kept"`) and `access_log_entries`.
  Where the application passes its own id as the subject (`validate_access!(…, subject: "user-7")`),
  that id has a log of its own: name it in `access_log_subjects:` (`ACCESS_LOG_SUBJECTS=`) and it is
  erased, or kept and counted, with the record's; `ErasureApplied` records how many (never which).
  `Lyra::AccessLog.erase!(subject, reason:)` (`lyra:erase_access_log`) deletes one subject's log on
  its own, and records an `AccessLogErased` event (subject, entries, reason, who: the label, and
  the OS user, host and pid beside it) in `Lyra::AccessLogErasures`.
  A model-wide entry (`Lyra::DataAccess$<Model>$*`, written by a `pluck`) names no subject: it is
  the record of a read of everyone's data, and both calls refuse it. Access logs of other records
  reached by `everywhere` are not touched. The access log has no retention period of its own.
- Rows are written with one `UPDATE` by id, so records the application marks read-only (Solidus
  freezes an address once an order uses it) are erased too.
- Locks first, reads second: the record's row, then its aggregate's advisory lock, are taken before the
  stream is read, so a write in flight (a Monitor update appends its event in the transaction that writes
  the row) finishes before the erasure sees the stream. Before 1.0.0 the stream was read first, and an event
  committed in between kept the value. A write that starts after the erasure waits for it, and is new data.
- Appends `Lyra::Events::ErasureApplied` (fields, reason, `erased_by`, never a value). The task
  records `OPERATOR=` as `erased_by`, else `LYRA_OPERATOR`, else the operating-system user and
  process (since 0.9.3; before, it recorded no one). That label is whatever the caller says, so
  since 1.0.0 the event also records what the operating system says, `os_user`, `host` and `pid` in its
  metadata, and in its data whether `ANY_FIELDS` was used (`any_fields`), the columns the request
  named (`requested_fields`) and those erased only because of it (`beyond_policy`). Match `host` and
  the time against your OS and SSH audit logs: attribution to a person is theirs, not Lyra's. It is not
  replayed; the stream still replays to the anonymized row.
- Replacement: `nil` where the column allows it, `"erased:<id>"` for a NOT NULL string column,
  the column default otherwise.
- The log is append-only except for this; the erasure itself is recorded. Crypto-shredding,
  which would leave the log untouched, is not implemented.
- Without `everywhere`, other records holding the same person's data are not touched (erase each,
  or use `everywhere`; the report above lists them). A value derived from the original (an
  uppercased email, a substring, a hash of it) is not a copy and is not found. Both searches are
  text matches: a value stored in a form they cannot see (encrypted, compressed, base64) is not
  found.
- **The database keeps old versions.** PostgreSQL does not overwrite a row in place: a rewritten
  event or row leaves its old version in the table (a dead tuple, and its TOAST chunks for long
  values) until `VACUUM` reclaims it, and in the write-ahead log (WAL), WAL archives, replicas'
  logs and backups until those expire. Lyra cannot reach any of these. The operator's procedure
  after an erasure should therefore run `VACUUM` on `event_store_events` and the touched tables
  (those of the erased record and of the records in `copies` and `rows_without_events`), and the
  controller should state the retention of its WAL archives and backups (and that a restore
  re-applies erasures made since the backup was taken):

  ```bash
  bin/rails lyra:erase MODEL=Registration ID=5 REASON="Art. 17 request #12" OPERATOR=jdoe EVERYWHERE=1 DRY_RUN=1
  bin/rails lyra:erase MODEL=Registration ID=5 REASON="Art. 17 request #12" OPERATOR=jdoe EVERYWHERE=1 MAX_COPIES=12
  bin/rails lyra:repair MODELS=PaymentTransaction   # Monitor: if rows_without_events listed any
  psql "$DATABASE_URL" -c 'VACUUM (VERBOSE) event_store_events, registrations, payment_transactions'
  ```

  A plain `VACUUM` marks the space reusable but does not scrub it at once; `VACUUM FULL` rewrites
  the table (and takes an exclusive lock on it while it runs).
- **Database error text in logs.** Lyra logs the message of a database error it catches and does
  not re-raise, for example when a bypass event (`update_all`, `insert_all`) cannot be published
  in Monitor (`lib/lyra/bypass_events.rb`, `publish_failed!`). PostgreSQL's message can include the
  failing row (`DETAIL: Failing row contains (...)`), so a personal value can reach the
  application log. Lyra does not filter it: cover the application log in your retention rules, or
  filter such lines in your logger.
- **A narrow wait.** Erasing a row with no stream holds its table's Genesis lock until the
  erasure commits. An application transaction that, at the same time, makes the first use of
  that model in its process runs Genesis on a connection of its own and waits for that lock; the
  erasure may in turn wait for a row that transaction has locked. Neither PostgreSQL nor Lyra
  sees this as a deadlock (the two waits are on different connections of one process), so both
  wait until a lock or statement timeout ends one. It needs a model's first use in a process to
  coincide with an `everywhere` erasure reaching a row of it with no stream; run `lyra:genesis`
  before enabling a mode, and set a `lock_timeout` for erasures, to rule it out.

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
It works in every mode: in ES-NoProj the records and their anchor column are read from the event
store (no default scope applied, so a soft-deleted record is still due), and a deletion is an event.

Only models with a rule of their own are acted on: the policy's `default` period is not
executed. A rule that names no `on_expiry` gets `:soft_delete`, which keeps the data and needs a
`deleted_at` or `discarded_at` column; on a table without one, nothing past the period is touched.
Lyra warns about such a rule (`Rails.logger.warn`), naming the model, its policy and rule, and
the fix (add the column, or `on_expiry :anonymize` or `:hard_delete`): at boot for the models
enrolled by then (`Lyra::Retention.check_rules!`), and in each run that skips records for it,
once per model.

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

#### Restriction of Processing (Article 18) and the Right to Object (Article 21)

The policy declares which purposes may continue while a subject's processing is restricted, and which purposes a
subject can object to. The runtime records each request, notice, decision and lift, and refuses the accesses they
cover. A person (the controller, usually the DPO's office) verifies accuracy and weighs grounds: PAM records the
decision, it never takes it.

```ruby
PamDsl.define_policy :shop do
  purpose :analytics do
    basis :legitimate_interests              # Art. 21(1): the subject can object
    lia_documented!
  end
  purpose :newsletter do
    basis :consent
    direct_marketing!                        # Art. 21(2)-(3): an objection stops it at once
  end
  purpose :defence_of_claims do
    basis :legitimate_interests
    allowed_when_restricted :legal_claims    # Art. 18(2): continues under a restriction
  end
end

rights = PamDsl.rights
r = rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, fields: [:lastname])  # Art. 18(1)(a)
rights.notify_lift!(r.id)                    # Art. 18(3): the subject is told before the lift
rights.lift!(r.id, reason: :verified_accurate)

o = rights.object!(subject: "Payer$7", policy: :shop, purpose: :analytics)  # pending; the purpose is restricted
rights.decide!(o.id, outcome: :upheld)       # the purpose stops for this subject
```

- **Condition 6.** `validate_access!` checks, after every other condition, that no upheld objection to the purpose
  (`PamDsl::ObjectedProcessingError`) and no restriction covering the access (`PamDsl::RestrictedProcessingError`)
  applies, unless the purpose declares an Art. 18(2) exception. Strict mode raises; audit mode logs; the access log
  records the refusal with its class.
- **Who can object.** `Purpose#objectable` is derived: Art. 21(1) for the bases public task and legitimate
  interests (research or not), Art. 21(2) for direct marketing, Art. 21(6) for research or statistics on another
  basis that is not on a public-interest task (such an objection is upheld or stays pending: it cannot be
  overridden). An upheld objection to direct marketing stops every direct-marketing purpose of every policy for
  that subject (Art. 21(3); the DPO should confirm the reading). Objecting again while an objection is in force
  returns it rather than recording a second.
  An objection to any other purpose (contract, legal obligation, consent, vital interests) is recorded as rejected
  and raises `PamDsl::ObjectionNotApplicableError`, whose message is the reason to give the subject; for a consent
  purpose it points to withdrawal.
- **The cost of a restriction.** A whole-subject restriction stops contract and legal-obligation processing for that
  person too, unless the purpose declares an exception the DPO accepts. No exception is implied for legal
  obligations: declare `allowed_when_restricted :important_public_interest, reference: "..."` where the DPO agrees.
- **The Art. 30 register** prints each purpose's right to object and its Art. 18(2) exceptions.
- **Storage.** Rights are kept in `PamDsl.rights_store`. PAM DSL alone ships only an in-memory store, which refuses
  to record outside development and test (`PamDsl::RightsStoreNotDurableError`), so a right cannot be lost on
  restart. With Lyra, Lyra's durable store is installed instead (`Lyra::Rights`): each request, notice, decision and
  lift is an event in `Lyra::Rights$<subject key>` (for example `Lyra::Rights$Payer$7`), appended with an expected
  version so that two processes cannot both lift or decide one request (the second gets
  `PamDsl::RightsConcurrencyError`), and the `lyra_rights` table holds each request's current state, written in the
  same transaction (`bin/rails lyra:rights:rebuild` rebuilds it). These streams are never erased, by
  `Lyra::Erasure` or with the access log: they hold the ground, field and purpose names and the controller's reasons,
  never values, and are the evidence that the right was handled (Art. 5(2)). Keep personal data out of the free-text
  reasons. How long to keep them is the DPO's to decide.
- **Whom a restriction names.** With Lyra, a record's keys are its own (`Invoice$12`) and those of the people it
  names, by the subject-access copy's selection rule: a `belongs_to` names a record of its class
  (`belongs_to :payer, class_name: "Person"` gives `Person$7` for `payer_id = 7`), a polymorphic `belongs_to` the
  class its type column holds, and a `<type>_id` column that no association owns the monitored model of that name
  (none if there is no such model). A restriction recorded against a person covers each of their records; one
  recorded against a record covers that record. A record loaded without one of its link columns (a `select` that
  leaves out `payer_id`) has them read from its row, in one query Lyra makes as its own, when a right is in force
  or consent is checked; if they cannot be read, the access fails with `Lyra::Rights::UnresolvedSubjectError`
  rather than go ahead unmatched.
- **When another process sees it.** Each process answers Condition 6 from a snapshot of the committed requests in
  force, shared by its threads, read again at most every `config.rights_refresh_interval` seconds (default 1), on
  `Lyra::Rights.refresh!`, and at the first check of each checking scope: a `Lyra.with_purpose` block (and so a
  controller action or job with `lyra_purpose`), a web request (`Lyra::Rights::Middleware`, which the engine
  installs), an Active Job (`Lyra::Rights::Job`), and each batch of `in_batches`, `find_each` and
  `find_in_batches`. A right recorded in another process therefore applies from this process's next scope, not in
  the middle of one. Consent lookups follow the same rule. A transaction that records a right sees it at once, and
  no other thread does until it commits. The first check in a scope makes one indexed query on `lyra_rights`; after
  it, with nothing in force, a check costs a clock read. Code that checks nothing (no purpose and
  `reads_without_purpose :allow`, as in every benchmark) makes no query at all. That is `config.rights_refresh =
  :scope`, the default. With `:interval`, a scope does not force a read: the snapshot and the consent lookups are
  read again only after `rights_refresh_interval`, so a right or a withdrawal recorded in another process may apply
  up to that long later, in the middle of a request or a batch loop, and a request under a purpose saves one
  indexed query (about half a millisecond on a local database). Choose `:interval` only where that delay is
  acceptable, and keep the interval short.
- **Opting out.** Lyra installs its stores and resolver when it loads, and again at boot only where the application
  has not installed its own in an initializer (`PamDsl.rights_store = ...`, `PamDsl.consent_store = ...`,
  `PamDsl.subject_key_resolver = ...`).
- **In Lyra's reads** (under a purpose, or with `reads_without_purpose` `:audit` or `:deny`; Condition 6 needs a
  purpose):
  - **A record is refused.** Each record a load returns is checked, as consent is: a restricted person's record in
    the result raises `PamDsl::RestrictedProcessingError` (`ObjectedProcessingError` for an upheld objection), in
    Active Record and in ES-NoProj alike. A load that names no declared field (`select(:id, :payer_id)`) is checked
    too, for a restriction of all of the subject's data, a pending objection's restriction of the purpose and an
    upheld objection; a restriction of some fields covers only reads that name one of them.
  - **A population is filtered.** A query over many people (`count` and the other aggregates, `pluck`, `pick`,
    `ids`, `exists?`, `cache_version`) leaves the restricted subjects out rather than fail: the record's own key
    column `NOT IN` the restricted records, and each link column `IS NULL OR NOT IN` the restricted people (for a
    polymorphic link, unless its type column names another class or one of its STI subclasses: the subclasses
    loaded, as with eager loading in production), so rows that name no one are kept. ES-NoProj
    filters its in-memory records the same way, by each record's keys; a record whose links cannot be read raises
    `Lyra::Rights::UnresolvedSubjectError`. A field-scoped restriction applies only to a query that names one of
    its fields. With no right in force for the query, its SQL is unchanged.
  - **A join, subquery or CTE that reaches a model with such a subject is refused** (`RestrictedProcessingError`),
    since only the queried model's own rows can be left out. SQL written as a string counts: the tables a fragment
    reads `FROM` or `JOIN` (with their aliases: `JOIN articles a` makes `a.body` the articles' `body`) are the models
    it reaches, a `joins("INNER JOIN …")` string joins its table, and the words of a subquery written as SQL that are
    columns of the tables it reads belong to those tables (and are checked against their policy, whole: this also
    changes the purpose check, which used to give them to the queried model). A fragment that reads `FROM` or `JOIN`
    something Lyra cannot name (`FROM (VALUES …)`) is refused while a right is in force for the purpose (fail
    closed); name the tables plainly, or use Active Record's joins and subqueries.
  - **Keys are read only when they matter.** A subject's people are resolved (their link columns read, for a
    record loaded without them) only when a request in force could cover the access: an upheld objection to the
    purpose, or a restriction that covers it and that the purpose declares no exception for (other than
    `:consent`). A row of an aggregate (`select("status, count(*) AS n").group(:status)`, `find_by_sql` with a
    `GROUP BY`: no key, columns the table does not have, or a grouped load) is not one person's record and is not a
    subject. A row loaded without its key (`select(:title)`) while such a request is in force cannot be matched to
    its person and fails closed (`UnresolvedSubjectError`); ES-NoProj reads the keys from the whole record before it
    narrows it to the columns selected. `Model.exists?(id)` answers `false` for a record left out, in both read
    paths. A purpose the policy does not declare has no Art. 18(2) exception.
  - **Batch jobs** use `Model.lyra_processable` (or `lyra_processable(fields: [...])`, naming the fields the job
    reads): a scope without the records the purpose in scope may not process, so a loop skips them instead of
    stopping at the first. It chains (`Registration.where(...).lyra_processable.find_each`) and returns every
    record when no purpose is in scope.
  - **Audit mode** excludes nothing: the query runs whole and the log says how many restricted subjects it may
    include.
  - **Writes are not checked under a restriction in 1.0.0**: `update`, `destroy` and bulk writes go ahead, and bulk
    writes are not filtered. Lyra's own work (projections, replay, mode transitions, repair) is storage and exempt.
- **Erasure and retention.** `Lyra::Erasure.erase!` refuses a record that a restriction in force covers (the
  record's own, a person's it names, or one under a key passed as `access_log_subjects:`; of all the data or of a
  field being erased) with `RestrictedProcessingError` naming each restriction: the subject asked for the data to
  be kept (Art. 18(1)(b), (c)). When the controller decides to erase all the same, it records the Art. 18(3)
  notice and passes `lifting: restriction_id`: the restriction is lifted and the record erased in one transaction,
  so a failed erasure leaves the restriction in force. Only a restriction of the record being erased can be lifted
  this way: a person-wide restriction is lifted by erasing that person's own record with `lifting:`, or explicitly
  with `PamDsl.rights.lift!`; erasing one of their other records with it is refused. Under ES-NoProj, or for a
  destroyed record, the people a record names are read from its events; a record with neither row nor events is
  refused while a right is in force (fail closed). With `everywhere: true`, another record holding a copy that a
  restriction covers is left as it is and listed in `Result#restricted_copies` (record and columns, never the
  value; `lyra:erase` prints them): the copy stays until that restriction is lifted, and an erasure then takes it.
  An objection's 18(1)(d) restriction does not refuse an
  erasure. A dry run (`dry_run: true`) is refused the same way; with `lifting:` it lifts nothing and
  reports in `Result#lifting` what it would lift.
  `Lyra::Retention` skips a restricted record and reports it (outcome `:restricted`, the restrictions in
  `detail`, `Result#restricted`, listed by `bin/rails lyra:retention:apply`); it acts on it at the first run after
  the lift. **(DPO)** These readings of Art. 17 against Art. 18 should be confirmed.
- **The subject's copy (Art. 15)** gains `restrictions` and `objections`: the subject's own requests (under their
  key, and under the key of one of their records that names no one else), with ground, fields, state, dates and
  the controller's decisions and reasons; never another person's, nor who on the staff recorded them. Lyra reads
  them as its own: the copy of a restricted subject is not refused.
- **The dashboard** lists the open requests at `privacy/rights` (HTML and JSON), oldest first, each with its age.
  An objection awaiting the controller's decision has a deadline one month from its receipt (Art. 12(3); an
  extension is the controller's to record) and is marked overdue after it. A restriction listed is in force:
  recording it was the controller's action on the request, so it has no deadline and lasts until it is lifted. The
  policy page shows each purpose's right to object and Art. 18(2) exceptions. Under the dashboard's purpose, a route
  about one record (`flow/event_chain`, `flow/visualization`, `flow/timeline` for a subject,
  `visualizations/entity_graph`, `privacy/pii_inventory`, and the model routes, which read the record) answers 403
  when a restriction or upheld objection covers it, and the routes over many records (`flow/timeline`,
  `flow/correlation`, `flow/crud_mapping`, `flow/user_actions`, the event graph and event list, `privacy/pii_detection`,
  `privacy/data_lineage`) leave out the events of the records it covers, with their number in the
  `X-Lyra-Rights-Withheld` header. With no dashboard purpose, they show everything, as reads with no purpose do.
- **By design.** The purpose is per thread: a thread started inside `Lyra.with_purpose` reads with no purpose (and
  so, under `:allow`, unchecked) unless it declares its own. A rake task or console with no purpose block, request
  or job opens no checking scope, so it reads the rights afresh only after `rights_refresh_interval`.
- **Not done.** PAM does not notify recipients (Art. 19; use `PamDsl.on_rights_event`) or tell the subject, and
  objections arriving by automated means (Art. 21(5)) come through the application's own channel. The reading that
  a pending objection restricts only the objected purpose (Art. 18(1)(d)) should be confirmed by the DPO.

See the PAM DSL README, "Restriction of Processing and the Right to Object", for the API and the store protocol.
From 1.0.0 an update is listed when it changed a field the model's policy declares, or one the
detector flags; before, the detector alone decided.

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

From 1.0.0 these come from the policy of each event's model where one is declared (the purpose
the source names, else the purposes that admit the declared fields the events carry); without a
policy they are guessed from `metadata[:source]` and the detector, and the basis reads "Not
specified".

The organization-wide register comes from the declared policy:
`PamDsl.reporter(:my_policy).article_30_report` (or `bin/rails pam_dsl:report:article_30`)
lists each purpose with its legal basis, data categories, consent requirement and retention.

Reads are not in this register; the access log records them (see [The Access Log](#the-access-log)).

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
- Implement field-level encryption (Active Record `encrypts`: Lyra stores
  those attributes in the event log as ciphertext too, see the API reference)
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

From 1.0.0 consent is durable with Lyra. Lyra installs its consent store as `PamDsl.consent_store`, which every
policy's `consent_policy` then uses: each `request_consent`, `grant_consent` and `withdraw_consent` is an event
(`ConsentRequested`, `ConsentGranted`, `ConsentWithdrawn`) in `Lyra::Consent$<subject key>`, and the `lyra_consents`
table holds each (subject key, purpose)'s current record, written in the same transaction. A grant or withdrawal is
therefore kept across restarts and seen by every process and every policy, so the consent that `validate_access!`
checks (Condition 4) and the `:consent` exception of Art. 18(2) read the same record. Expiry is derived, as in PAM:
the grant records `expires_at` from the requirement's `expires_in`, and the record is expired once it has passed.

- A consent is recorded under the subject's first key (a record's own, or the subject given as a string). A record
  that names one person (by the rule under "Whom a restriction names") uses that person's consent, so a person's
  consent (`"Customer$5"`) covers each of their records; a record that names no one uses a consent recorded for
  itself. Before 1.0.0 consent was per record object.
- **Limit: a record that names more than one person.** Whose consent such a record needs (a transfer between a
  payer and a payee) is not decided in 1.0.0. A consent check on it, for a purpose whose basis is consent or for the
  `:consent` exception of Art. 18(2), is refused with `Lyra::Rights::ConsentStore::SharedRecordConsentError` (a
  `PamDsl::ConsentRequiredError`), and recorded like any other consent refusal, whatever each person consented to.
  Future work: the consent of all of them, or of each for the fields about them (the `about:` markers).
- A lookup is remembered for `config.rights_refresh_interval` seconds (default 1), as is whether any consent at all
  is recorded for a subject type and purpose, so reading many records costs a query or two, not one per record. A
  withdrawal made in another process applies here within that interval; a grant or withdrawal made in a
  transaction is seen by that transaction at once and by other threads once it commits.
- Granting a consent already granted with the same times records nothing, so an application that used to load
  its consent decisions into PAM DSL at boot or per request no longer needs to, and calling it anyway adds no
  events.
- `consent_audit` lists the store's records for the subject (`recorded_consents`, with each record's history), and
  they take precedence in `current_consents` over consent found in the application's own events.
- Without Lyra, PAM DSL keeps consent in memory, per process and per policy, as before.

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

`PolicyIntegration#mask_pii` prefers the policy's own transformation for a
declared field (see [Working Examples](#working-examples)).

## Read-Side Monitoring

### Purpose-Bound Reads

**Location:** `lib/lyra/purpose_bound_reads.rb`

A read of a monitored model whose privacy policy is loaded, made within a
declared purpose, is checked with the policy's
`validate_access!(field_names, purpose, subject:)`: every declared attribute
the query loaded must be allowed for the purpose, with the record as the
subject. No setting turns this on; declaring a purpose does:

```ruby
Lyra.with_purpose(:enrollment) { Student.select(:id, :email, :name).find(id) }

class PaymentsController < ApplicationController
  lyra_purpose :payment_processing             # around every action
  lyra_purpose :invoicing, only: :invoice      # around_action options
end

class ExportJob < ApplicationJob
  lyra_purpose :legal_compliance
end
```

- **Data minimisation:** loading a declared attribute the purpose does not
  allow is a violation, so a `SELECT *` under a narrow purpose fails; select
  what the purpose uses.
- **A query uses every declared attribute it names** (from 1.0.0), whatever
  it returns: its `select` or `pluck` list, the aggregated column, `group`,
  `where`, `having` and `order`, the conditions of `find_by` and `exists?`,
  the filter of a bulk write (`update_all`, `delete_all`, `touch_all`,
  `delete_by`, `destroy_by`), and a subquery inside any of them. A filter is
  a use: `Student.where(name: "Ann").exists?` tells whether a student is
  called Ann, and `find_by(name: "Ann")` answered the same question by
  raising for Ann and returning `nil` for anyone else. A `count` with no
  column (`count`, `count(:all)`, `size`) names nothing and is not checked;
  `count(:name)` uses `name`. The values a write sets are not reads.
- **The check is split by what can be known.** A record load (`where(...).first`,
  `find_by`, `to_a`) has the attributes its query names checked before it
  runs, without the consent step (PAM's `validate_fields!`), and then each
  record returned checked as before, consent included, for what it holds and
  what the query named. Everything else (aggregates, `exists?`, `ids`,
  `pluck`, `pick`, bulk writes) reads many people at once: its subject is
  the model (`"Student$*"`), and under a purpose whose basis is consent it is
  refused, since no single person's consent can be checked. Load the records
  instead.
- **Joins:** a declared attribute of a joined model
  (`Enrollment.joins(:student).where(students: { name: "Ann" })`) is checked
  against that model's own policy, with subject `"Student$*"`.
- **Once per query:** the batches of `find_each` and `in_batches`, and the
  queries Active Record runs inside another, are checked and recorded once.
- **On a violation** the policy's enforcement mode decides: strict raises the
  PAM error before the query runs, audit logs it and lets the query run. With
  the access log on, every checked read is recorded.
- **Reads with no purpose** follow `config.reads_without_purpose`: `:allow`
  (default; nothing breaks when a policy is added, and the hooks return
  before looking at the query), `:audit` (logged, and recorded as audited
  when the access log is on), or `:deny` (raises
  `Lyra::PurposeBoundReads::PurposeRequiredError`).
- **ES-NoProj** rebuilds whole records from events; what a query returns is
  narrowed to its `select` and checked, and what its query named is kept on
  the relation and checked the same way, so the rule is the same in every
  mode.
- **Not checked:** Lyra's own reads (projections, bypass snapshots, Genesis,
  DualView's comparisons for Lyra, mode checks, repair, erasure, ES-NoProj's
  join partners), Rails' uniqueness validation and an association's
  `dependent:` handling when a record is destroyed (`:delete_all`, `:nullify`,
  `:delete`, the restrict options, and the lookup of the dependents
  `:destroy` destroys; each is then destroyed as the application destroys a
  record), which are part of the write (`find_or_create_by` and the
  application's own `where(fk: id).delete_all` are checked), and Disabled
  mode.
- **Blocks over records** (`select { }`, `find { }`, `count { }`, `map`,
  `group_by` and the rest of Enumerable) see the records the relation loads,
  each checked first, in ES-NoProj as in Active Record.
- **Limits.** Attributes are found by walking the query's Arel; an SQL string
  fragment is matched by the queried model's declared names, as words, with
  quoted literals left out. So SQL written by hand (`connection.select_*`,
  `execute`, Arel handed to the connection) names no model and is not checked
  (`find_by_sql` returns records, which are); a fragment naming another
  table's column (a raw `JOIN` string) is not mapped to that table's model,
  and string joins are not read; database views, functions and triggers are
  outside the ORM; a form the walk does not reach (a custom Arel node) is not
  checked. A `table.column` inside a fragment is that table's model's. A
  subquery or CTE (`with`) reads other people: what it names is checked
  whole, with subject `"Model$*"`, even on the queried model; a `from`
  string that names a CTE is matched as a fragment.
- **Uniqueness answers membership.** Rails runs a uniqueness check on
  `valid?`, and it is exempt as part of the write, so
  `Student.new(name: "Ann").valid?` tells whether a student called Ann
  exists under a purpose that may not use `name`. Declare uniqueness on
  attributes that are not personal, or validate it in a purpose that may
  use them.
- **Collection writes are the application's.** Only `dependent:` handling
  on destroy is exempt; `user.enrollments.delete(enrollment)` is a filtered
  write on the foreign key, checked as the application's.
- **The purpose follows Enumerators.** It is kept in Ruby's fiber storage,
  tied to its thread: an Enumerator's fiber (`relation.to_enum.next`) has
  it, a thread started inside the block does not. A load under a consent purpose that finds nothing
  tells that no matching record exists; the attributes it filtered on are
  ones the purpose may use.

### The Access Log

**Location:** `lib/lyra/access_log.rb` (opt-in, needs pam_dsl)

The Article 30 register says what may be processed and the event stream shows
what was written; neither records reads. With
`config.record_access_events = true` (default false), `Lyra::AccessLog`
records every call of a policy's `validate_access!`, from purpose-bound reads
or from your own code, as an event:

```ruby
Lyra.configure do |config|
  config.record_access_events = true
  config.access_metadata_proc = ->(access) { { actor: Current.api_token&.name || "console" } }
end

PamDsl.policy(:my_policy).validate_access!(%i[email], :contact, subject: user)
Lyra::AccessLog.for(user)   # its recorded accesses, oldest first
# => [#<Lyra::Events::DataAccessed data: { policy: "my_policy", purpose: "contact",
#       legal_basis: "contract", fields: ["email"], subject: "User$5", outcome: "granted", ... }>]
```

- `Lyra::Events::DataAccessed`: the access went ahead (`outcome` `"granted"`,
  or `"audited"` when audit mode let it through; then `violations` lists
  them).
- `Lyra::Events::DataAccessDenied`: strict mode refused it (`violations`
  lists why).
- Each goes to the subject's access stream, `"Lyra::DataAccess$<subject>"`
  (`"Lyra::DataAccess$Student$1"` for a record), never to the record's own
  stream, so replay, DualView and mode transitions do not see it.
- The data holds the policy, purpose, legal basis, field names (never
  values), subject, outcome, time and any violations.
- Who accessed is in the metadata: `user_id` (`Current.user.id`) and
  `ip_address` (`Current.ip_address`) when your app sets them in `Current`,
  plus the request, correlation and causation ids. Where `Current` does not
  know (a console, a job, an API token), `config.access_metadata_proc`
  (`->(access) { Hash }`) adds your own keys (string, number, boolean or nil
  values; a failing proc is logged and the access recorded without it). With
  neither, an access carries no user.
- Every access is recorded (no sampling). If the event store cannot record
  it, the store's error propagates and the access does not go ahead. Nothing
  is recorded in Disabled mode.
- Since 1.0.0 an access is recorded on a connection of its own, so the entry
  stays when the reader's transaction rolls back. Inside a transaction that
  takes a thread and a second database connection per access. **Size the
  connection pool for it** (`pool:` in `database.yml`): about twice the
  application's threads (Puma's, Sidekiq's). If every connection is in use, a
  read waits the pool's `checkout_timeout` (5 s by default) and is then
  recorded in the reader's own transaction, so a rollback takes the entry
  with it. Outside a transaction nothing changes. Rails' transactional tests
  pin one connection, so there the entry is always recorded inline.
- The log is personal data about the users who read records: cover it in
  your retention rules.
- Erasing a record keeps its access log unless `config.erase_access_log` or
  the call (`access_log: true`, `ACCESS_LOG=1`) says to delete it (1.0.0; see
  Right to Erasure above). `Lyra::AccessLog.erase!` deletes one subject's log on its own, a bare id
  included; model-wide (`pluck`) logs name no subject and are not erasable per person.
- Off by default because reads can outnumber writes by orders of magnitude;
  the Aegean testbed measures it separately with `LYRA_RECORD_ACCESS=1`
  ([PERFORMANCE.md](PERFORMANCE.md)).

### Scope and Limits

- **What is recorded.** Reads are checked only when a purpose is declared (or
  `reads_without_purpose` is `:audit` or `:deny`), and recorded only with
  `config.record_access_events`. Raw SQL, triggers and other applications are
  not seen. Writes are covered in
  [ARCHITECTURE.md](ARCHITECTURE.md#scope-and-limits).
- **Erasure rewrites events.** `Lyra::Erasure.erase!` overwrites a record's
  events in place and records an `ErasureApplied` event; the log is
  append-only otherwise, and not tamper-evident by itself. The old versions
  stay on disk until `VACUUM`, and in WAL and backups until they expire, and a
  database error's text in the application log can hold a value (see Right to
  Erasure above).
- **Privacy features need PAM.** Without the pam_dsl gem no policy loads,
  nothing is detected as PII, and purpose checks and the access log do
  nothing.

## Working Examples

The examples assume the `:university_system` policy and the `Student` model
above, in Monitor mode. Write-side examples (audit trail, data lineage, row
versus events) are in [ARCHITECTURE.md](ARCHITECTURE.md#working-examples).

### A Purpose-Bound Read, Recorded

```ruby
Lyra.config.record_access_events = true

Lyra.with_purpose(:enrollment) { Student.select(:id, :email, :name).find(student.id) }
Lyra::AccessLog.for(student).last.event_type   # => "Lyra::Events::DataAccessed"
```

### Checking Access and Masking in Your Own Code

```ruby
integration = Lyra::Privacy::PolicyIntegration.new(:university_system)

begin
  integration.validate_access!([:email], :marketing, subject: student)
rescue PamDsl::Error => e
  e.class   # e.g. PamDsl::ConsentRequiredError while no consent is recorded (strict mode)
end

integration.mask_pii(:email, "john@example.com", :display)   # => "j***@example.com"
```

### GDPR Data Export

```ruby
gdpr = Lyra::Privacy::GDPRCompliance.new(subject_type: "Student", subject_id: student.id)
gdpr.data_export.keys
# => [:subject, :generated_at, :events, :pii_inventory, :data_lineage,
#     :records, :accesses, :processing_context, :notice, :gaps, :restrictions, :objections]
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

  # 2. Generate the copy (recorded as an answered request); review its
  #    `review` fields and `gaps` before handing it over
  report = compliance.data_export(verified_by: "registry desk")

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
# Good
Lyra::UserActionContext.with_context(...) do
  user.update!(...)
end

# Avoid: no context
user.update!(...)
```

### 2. Group Related Operations

```ruby
# Good: operations are correlated
Lyra::Correlation.with_id do
  order = Order.create!(...)
  payment = Payment.create!(order: order, ...)
  invoice = Invoice.create!(order: order, ...)
end

# Avoid: operations not linked
order = Order.create!(...)
payment = Payment.create!(order: order, ...)
invoice = Invoice.create!(order: order, ...)
```

### 3. Configure Appropriate Retention Policies

```ruby
# Good: specific policies per data type
config.retention_policy = {
  'User' => { duration: 7.years },
  'Payment' => { duration: 10.years },
  'HealthRecord' => { duration: 25.years }
}

# Avoid: one-size-fits-all
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

- [ ] A privacy policy declares the personal attributes of each monitored model
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

## File Locations

| Component | File |
|---|---|
| Purpose-bound reads | `lib/lyra/purpose_bound_reads.rb` |
| Access log | `lib/lyra/access_log.rb` |
| Privacy provider interface, stamps | `lib/lyra/privacy/interface.rb` |
| PolicyIntegration | `lib/lyra/privacy/policy_integration.rb` |
| PII detection and masking | `lib/lyra/privacy/pii_detector.rb`, `pii_masker.rb` |
| GDPR reports | `lib/lyra/privacy/gdpr_compliance.rb` |
| Erasure | `lib/lyra/erasure.rb` |
| Retention | `lib/lyra/retention.rb` |
| Event flow analysis | `lib/lyra/event_flow.rb` |
| Example policies | `config/privacy_policies.rb` |
| PAM DSL core and errors | `gems/pam_dsl/lib/pam_dsl.rb`, `gems/pam_dsl/lib/pam_dsl/policy.rb` |
| PAM integration guide | `gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md` |

Projection and interception components are listed in
[ARCHITECTURE.md](ARCHITECTURE.md#file-locations).

## Legal Disclaimer

This tool provides technical capabilities to assist with GDPR compliance. However:

- **Legal advice**: This is not legal advice. Consult legal counsel for compliance requirements.
- **Completeness**: This may not cover all aspects of GDPR compliance.
- **Verification**: Always verify that the implementation meets your specific legal requirements.
- **Responsibility**: Ultimate compliance responsibility rests with the data controller.

## Support

For questions about privacy compliance features:
- Review the examples in [`examples/privacy_examples.rb`](../examples/privacy_examples.rb)
- Check the API documentation in [API_REFERENCE.md](API_REFERENCE.md)
