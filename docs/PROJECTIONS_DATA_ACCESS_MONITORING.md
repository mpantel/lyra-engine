# Projections and Data Access Monitoring in Lyra

## Overview

A projection is a read model built from events. Lyra uses projections in
three ways:

- **Replay**: rebuild one record's state from its stream (`StateProjection`),
  or list what happened to it (`AuditProjection`).
- **Table projections**: in the event-sourcing configurations the events are
  authoritative and the model's table is a projection of them, kept up to
  date synchronously, by a background job, lazily before each read, or not at
  all (reads then come from the events themselves).
- **Analysis**: event flows and data lineage (`EventFlow`), row-versus-events
  comparison (`DualView`), and GDPR reports (`GDPRCompliance`).

Data access monitoring has a write side and a read side. Every write to a
monitored model is recorded as an event with who made it and in which causal
chain. Reads of models covered by a privacy policy can be bound to a declared
purpose, checked against the policy, and recorded in an access log.

This document explains how these parts work. The exact API is in
[API_REFERENCE.md](API_REFERENCE.md); the layers are described in
[ARCHITECTURE.md](ARCHITECTURE.md); GDPR workflows are in
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

---

## 1. Streams and Replay

Each record has one stream, `"#{Model.name}$#{id}"` (`"Student$1"`,
`"Spree::Price$7"`). Its events carry a data envelope with `model_class`,
`model_id`, `operation`, `attributes`, `changes` and `timestamp` (see
[API_REFERENCE.md](API_REFERENCE.md#lyraevent)).

Replay dispatches on the operation each event recorded, read by
`Lyra::Event.operation_of(event)`:

| Operation | Effect on the replayed state |
|---|---|
| `:created` | the event's attributes become the state |
| `:imported` | the same; written by Genesis for a row that predates Lyra, and by repair |
| `:updated` | the new value of each change is applied |
| `:destroyed` | the record is marked destroyed |
| `nil` | not replayed (an additional domain event declared with `also: true`, for example) |

`operation_of` reads the operation from the event's data and falls back to the
event name's suffix only for events that carry none, so a domain event that
replaces a CRUD event (`PaymentCompleted` for an update) replays as the
operation it stands for. The same rule is used by every replay in Lyra:
`StateProjection`, the ES-NoProj reader, rebuilds, DualView and the mode
check.

---

## 2. Projection Classes

**Location:** `lib/lyra/projection.rb`

### `Lyra::Projection`

The base class for custom read models. `handle(event)` calls
`apply_<event class name, demodulized and underscored>` if the projection
defines it, so `Lyra::Events::StudentCreated` goes to `apply_student_created`.
`Projection.handle(event)` does the same on a new instance.

`Projection.subscribe_to(*event_types)` passes the class to the event store's
`subscribe`. RubyEventStore 3 accepts only handlers that respond to `call`,
and `Lyra::Projection` defines `handle`, not `call`, so a subclass that
subscribes this way needs a class-level `call`:

```ruby
class EnrollmentStats < Lyra::Projection
  def self.call(event) = handle(event)

  private

  def apply_student_created(event)
    # update your read model
  end
end

EnrollmentStats.subscribe_to(Lyra::Events::StudentCreated)
```

### `Lyra::StateProjection`

`StateProjection.rebuild_state(model_class, id)` reads the record's stream and
returns the replayed attributes, following the table in section 1. A destroyed
record's state keeps its last attributes and gains `deleted: true` and
`deleted_at`.

### `Lyra::AuditProjection`

`AuditProjection.audit_trail(model_class, id)` returns one hash per event of
the record's stream: `operation`, `timestamp`, `user_id` (from the event's
metadata), `changes` and `attributes`. Which write paths record a `user_id`
is listed under [Metadata](API_REFERENCE.md#metadata).

---

## 3. Write-Side Monitoring

**Location:** `lib/lyra/interceptors/crud_interceptor.rb`

The engine includes `Lyra::Interceptors::CrudInterceptor` in every
ActiveRecord model; `monitor_with_lyra` (or `config.models`) turns it on for a
model. What a write does depends on the configuration:

- **Monitor**: the row is written, then `build_event_data` assembles the
  envelope (attributes without `created_at` and `updated_at`, the write's
  `previous_changes`, a timestamp) and the event is appended to the record's
  stream in the same transaction.
- **Hijack and event sourcing**: the write becomes a command
  (`Lyra::Commands::CreateCommand`, `UpdateCommand`, `DestroyCommand`) run by
  `Lyra::CommandHandler`; the event is stored first, and then the row is
  written, projected, or skipped, as section 4 describes.

Both paths attach attribution metadata to the event: the correlation and
causation ids in scope (`Lyra::Correlation.with_id`,
`Lyra::Causation.with_id`), and on the Monitor path the user, the request and
the user action in scope (`Lyra::UserActionContext`). The keys each path
writes are listed under [Metadata](API_REFERENCE.md#metadata).

Writes that skip callbacks (`update_all`, `delete_all`, `update_columns`,
`insert_all`, ...) are recorded as bypass events, one per affected record;
with `config.strict_data_access` they raise
`Lyra::StrictDataAccessViolation` instead (see
[API_REFERENCE.md](API_REFERENCE.md#callback-bypassing-writes)). Raw SQL,
triggers and other applications writing the same tables are not seen.

### Privacy stamps (opt-in)

With `config.annotate_privacy = true`, each event of a model whose policy is
loaded carries `metadata[:privacy]`: the policy name and, for every declared
attribute the event touches, its type, sensitivity, purposes, retention and
transformations, as the policy stood when the data was written. Values are
never copied into the stamp. `Lyra::Privacy.stamp_of(event)` reads it back
(`nil` for an unstamped event).

---

## 4. Table Projections in Each Configuration

Event sourcing (`config.mode = :event_sourcing`) has four projection modes.
Together with Disabled, Monitor and Hijack they make seven configurations;
the full table is in [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#the-modes-at-a-glance).

| Configuration | `projection_mode` | How the table follows the events |
|---|---|---|
| ES-Sync | `:sync` (default) | `Lyra::Projections::ModelProjection` writes the row in the write's transaction |
| ES-Async | `:async` | `Lyra::Projections::AsyncProjectionJob` (queue `lyra_projections`, enqueued after commit) replays the record's stream onto the row |
| ES-NoProj | `:disabled` | no row is written; reads are answered from the events |
| ES-Lazy | `:lazy` | no row at write time; pending events are applied before each read |

In ES-Sync and ES-Async a failed projection is logged and passed to
`config.projection_error_handler`, or re-raised with
`config.strict_projections = true`.

### ES-NoProj: reads from the event store

**Locations:** `lib/lyra/projections/event_store_reader.rb`,
`cached_projection.rb`, `cached_relation.rb`,
`lib/lyra/interceptors/association_interceptor.rb`

```ruby
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :disabled
end
```

**Write path.** The command stores the event, the record's cache entry is
rebuilt (or dropped, for a destroy), and the SQL statement is skipped.

**Read path.** On a monitored model, `find`, `find_by`, `find_by!`,
`exists?` with an id, `where`, `all`, `first` and `last` go to
`Lyra::Projections::EventStoreReader`. It rebuilds each record by replaying
its stream, through `Lyra::Projections::CachedProjection`:

- One `Rails.cache` entry per record, under
  `lyra_projections/<Model>/records/<id>/v2`, holding the attributes and the
  id of the last event they were built from. An entry is used only while that
  is still the stream's last event, so a stale entry is detected rather than
  served. Entries expire after an hour. There is no cache entry for a whole
  collection.
- A collection (`all`, `where`, `count`, `find_by` on other attributes) is
  assembled from the record entries: one query for the last event of every
  stream of the model, one bulk cache read, and a replay of the streams whose
  entry is missing or out of date.

Collections are `Lyra::Projections::CachedRelation` objects, evaluated in
Ruby. They support hash conditions (values, arrays, ranges, `nil`, records),
`where.not`, `or`, simple SQL fragments of `"column OP ?"` terms, ordering,
`limit`/`offset`, `page`/`per`, `joins` on direct associations (evaluated in
memory), `count`, `sum`, `average`, `minimum`, `maximum`, `group`, `pluck`,
batches, and scopes that reduce to hash conditions; the complete list is in
[API_REFERENCE.md](API_REFERENCE.md#es-noproj-projection_mode-disabled).
Query values are compared as controller parameters arrive: the string `"2"`
matches the integer `2`, and `"true"`/`"false"` match booleans.

Anything it cannot answer exactly raises
`Lyra::Projections::UnsupportedQuery` rather than returning an unfiltered or
partly filtered answer: other SQL fragments, string, nested, `:through`,
polymorphic or scoped joins, conditions on tables not joined, and scopes it
cannot reduce. Use ES-Lazy or a projected configuration for such queries.

**Associations.** The engine installs
`Lyra::Interceptors::AssociationInterceptor`, so `belongs_to`, `has_one` and
`has_many` associations whose target is a monitored model are read the same
way; a `has_many` returns a `CachedRelation`, and a polymorphic `belongs_to`
resolves its class from the type column.

**Genesis.** In ES-NoProj a model's first read in a process, as well as its
first write, imports rows that predate Lyra, so they have streams to read.

### ES-Lazy: tables brought up to date before each read

**Location:** `lib/lyra/projections/lazy_projection.rb`

Writes store events only. Before any ActiveRecord read on any model (record
loads, associations, calculations, `pluck`, `exists?`),
`Lyra::Projections::LazyProjection` applies the events not yet in the tables,
in the log's global order, under a PostgreSQL advisory lock; the read then runs
as real SQL. The checkpoint is kept in `lyra_projection_checkpoints`. SQL sent
directly through the connection does not trigger a catch-up. Because event ids
are assigned before commit, ES-Lazy tracks gaps in the log; a gap still empty
after `LazyProjection::GAP_TTL` (300 seconds) is treated as a rollback, so a
single transaction open longer than that has its events skipped by the tables.

### Rebuild

**Location:** `lib/lyra/projections/rebuild.rb`

`Lyra::Projections::Rebuild.rebuild(Model)` clears the table (unless
`truncate: false`) and replays every stream through the same projection code
live writes use; `rebuild_all` does every monitored model, and
`replay_record(Model, id)` one record. `bin/rails lyra:projections:rebuild
[MODEL=A,B] [TRUNCATE=false]` runs it from the command line. Rows without a
stream are lost by a truncating rebuild, so run Genesis first; see
[MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#recovery).

---

## 5. Read-Side Monitoring

### Purpose-bound reads

**Location:** `lib/lyra/purpose_bound_reads.rb`

A read of a monitored model whose privacy policy is loaded, made within a
declared purpose, is checked with the policy's
`validate_access!(field_names, purpose, subject:)`: every declared attribute
the query loaded must be allowed for the purpose, with the record as the
subject. No setting turns this on; declaring a purpose does:

```ruby
Lyra.with_purpose(:enrollment) { Student.select(:id, :email, :name).find(id) }

class EnrollmentsController < ApplicationController
  lyra_purpose :enrollment                      # around every action
  lyra_purpose :payment_processing, only: :pay  # around_action options
end

class ExportJob < ApplicationJob
  lyra_purpose :legal_compliance
end
```

- Loading a declared attribute the purpose does not allow is a violation, so
  select what the purpose needs.
- `pluck` and `pick` are checked by the declared attributes they name, with
  `"Model$*"` as the subject. Under a purpose whose consent the policy
  requires they are refused, since no single person's consent can be checked.
- In ES-NoProj the check is made on the records a query returns.
- The policy's enforcement mode decides a violation: strict raises the PAM
  error from the read, audit logs it and lets the read through.
- A read with no purpose follows `config.reads_without_purpose`: `:allow`
  (default), `:audit` (logged, and recorded when the access log is on), or
  `:deny` (raises `Lyra::PurposeBoundReads::PurposeRequiredError`).
- Not checked: Lyra's own reads (projections, Genesis, DualView, mode checks,
  repair, erasure), Disabled mode, and SQL sent through the connection.

### The access log (opt-in, needs pam_dsl)

**Location:** `lib/lyra/access_log.rb`

With `config.record_access_events = true`, `Lyra::AccessLog` records every
call of a policy's `validate_access!` (from purpose-bound reads or from your
own code) as an event:

- `Lyra::Events::DataAccessed`, outcome `granted`, or `audited` when audit
  mode let the access through despite violations;
- `Lyra::Events::DataAccessDenied` when strict mode refused it.

Each goes to the subject's access stream, `"Lyra::DataAccess$<subject>"`
(`"Lyra::DataAccess$Student$1"` for a record), never to the record's own
stream, so replay, DualView and mode checks do not see it. The data holds the
policy, purpose, legal basis, field names (never values), subject, outcome,
time and any violations. The metadata holds `user_id` and `ip_address` when
the application keeps them in `Current`, the request, correlation and
causation ids, and the hash returned by `config.access_metadata_proc`
(`->(access) { Hash }`). An access that cannot be recorded does not go ahead.
Nothing is recorded in Disabled mode.

```ruby
config.record_access_events = true
config.access_metadata_proc = ->(access) { { api_token: Current.api_token&.id } }

Lyra::AccessLog.for(student)   # its recorded accesses, oldest first
```

---

## 6. Privacy Policy Integration

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
`UndeclaredPurposeError`, `PurposeFieldMismatchError`, `ConsentRequiredError`
and `SensitivityViolationError`.

### PII detection and masking

**Locations:** `lib/lyra/privacy/pii_detector.rb`, `pii_masker.rb`

`Lyra::Privacy::PIIDetector` has no patterns of its own: `detect`,
`contains_pii?`, `mask`, `sensitive?` and `extract_from_event_stream` delegate
to the provider's detector. With PAM that is `PamDsl::PIIDetector`, which
classifies a field by its name (partial matching by default, so
`billing_phone` is a phone; names that look like timestamps, counters, flags
or amounts are excluded first). Without PAM nothing is detected. The detected
types are listed in [API_REFERENCE.md](API_REFERENCE.md#pii-detection-and-masking).

Name-based detection is a fallback. Purpose-bound reads, the access log,
privacy stamps and erasure use the attributes the policy declares.

---

## 7. Analysis Projections

### `Lyra::EventFlow`

**Location:** `lib/lyra/event_flow.rb`

`Lyra::EventFlow.new(subject_id: nil, subject_type: nil, time_range: nil)`
reads events from the whole store, keeps those of the subject (by `user_id` in
the metadata, or by model and id) when both subject arguments are given, and
those in the time range (default: the last 30 days).

| Method | Returns |
|---|---|
| `flow_data` | `{ timeline:, flows:, statistics:, privacy_impact: }`, events grouped by correlation id |
| `data_lineage(field_name, model_name = nil)` | `{ field:, model_class:, total_modifications:, first_seen:, last_modified:, lineage: }`; each lineage entry has `timestamp`, `event_id`, `model`, `record_id`, `operation`, `old_value`, `new_value`, `source`, `user_id`, `action` |
| `privacy_impact_analysis` | `{ total_events:, events_with_pii:, pii_categories:, pii_fields_count:, sensitive_operations:, data_flows:, risk_assessment: }` |
| `crud_to_event_mapping(model_name, operation, model_id = nil)` | the events of one operation |
| `reconstruct_state_chain(model, id)` | the state after each event of a record's stream |

### `Lyra::DualView`

**Location:** `lib/lyra/dual_view.rb`

Compares a record's row with the state replayed from its stream.
`DualView.new(model, id).compare` returns `crud_view`, `event_sourced_view`,
`differences` and `metadata`; `differences` is `{ no_differences: true }`,
`{ exists_mismatch: true }`, or one entry per differing column
(`{ "name" => { crud: ..., event_sourced: ... } }`). `created_at` and
`updated_at` are not compared. `DualView.find_discrepancies(model)` runs the
comparison for every row; `config.dual_view_sample_rate` compares a share of
committed writes after commit. Details:
[API_REFERENCE.md](API_REFERENCE.md#dualview-and-verification).

### `Lyra::Privacy::GDPRCompliance` (needs pam_dsl)

**Location:** `lib/lyra/privacy/gdpr_compliance.rb`

`GDPRCompliance.new(subject_id:, subject_type: "User")` wraps PAM's report
builder (`PamDsl::GDPRCompliance`) over Lyra's event store. It selects the
events whose metadata or data name the subject as `user_id`, or whose
`model_class` and `model_id` are the subject. Reports: `data_export`
(Art. 15), `rectification_history` (Art. 16), `right_to_be_forgotten_report`
(Art. 17, a plan of affected streams and models; it deletes nothing),
`portable_export(format: :json)` (Art. 20), `processing_activities`,
`retention_compliance_check`, `consent_audit` and `full_report`. See
[PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md).

---

## 8. Working Examples

The examples assume the `:university_system` policy and the `Student` model
above, in Monitor mode.

### Audit trail

```ruby
student = Student.create!(name: "John Doe", email: "john@example.com", student_id: "S1")
student.update!(email: "john.doe@university.edu")

Lyra::AuditProjection.audit_trail(Student, student.id).map { _1[:operation] }
# => [:created, :updated]
```

### Data lineage

```ruby
flow = Lyra::EventFlow.new(subject_type: "Student", subject_id: student.id)
lineage = flow.data_lineage(:email, "Student")
lineage[:total_modifications]                    # => 2
lineage[:lineage].map { _1[:new_value] }         # => ["john@example.com", "john.doe@university.edu"]
```

### Row versus events

```ruby
Lyra::DualView.new(Student, student.id).compare[:differences]
# => { no_differences: true }
```

### A purpose-bound read, recorded

```ruby
Lyra.config.record_access_events = true

Lyra.with_purpose(:enrollment) { Student.select(:id, :email, :name).find(student.id) }
Lyra::AccessLog.for(student).last.event_type   # => "Lyra::Events::DataAccessed"
```

### Checking access and masking in your own code

```ruby
integration = Lyra::Privacy::PolicyIntegration.new(:university_system)

begin
  integration.validate_access!([:email], :marketing, subject: student)
rescue PamDsl::Error => e
  e.class   # e.g. PamDsl::ConsentRequiredError while no consent is recorded (strict mode)
end

integration.mask_pii(:email, "john@example.com", :display)   # => "j***@example.com"
```

### GDPR data export

```ruby
gdpr = Lyra::Privacy::GDPRCompliance.new(subject_type: "Student", subject_id: student.id)
gdpr.data_export.keys
# => [:subject, :generated_at, :events, :pii_inventory, :data_lineage, :processing_activities]
```

---

## 9. File Locations

| Component | File |
|---|---|
| Projection, StateProjection, AuditProjection | `lib/lyra/projection.rb` |
| Event envelope, `operation_of` | `lib/lyra/event.rb` |
| CRUD interception | `lib/lyra/interceptors/crud_interceptor.rb` |
| Association interception (ES-NoProj) | `lib/lyra/interceptors/association_interceptor.rb` |
| Read hooks (ES-Lazy) | `lib/lyra/interceptors/lazy_reads.rb` |
| Table projection (ES-Sync) | `lib/lyra/projections/model_projection.rb` |
| Async projection job (ES-Async) | `lib/lyra/projections/async_projection_job.rb` |
| EventStoreReader, CachedProjection, CachedRelation (ES-NoProj) | `lib/lyra/projections/event_store_reader.rb`, `cached_projection.rb`, `cached_relation.rb` |
| LazyProjection (ES-Lazy) | `lib/lyra/projections/lazy_projection.rb` |
| Rebuild | `lib/lyra/projections/rebuild.rb` |
| Purpose-bound reads | `lib/lyra/purpose_bound_reads.rb` |
| Access log | `lib/lyra/access_log.rb` |
| Privacy provider interface, stamps | `lib/lyra/privacy/interface.rb` |
| PolicyIntegration | `lib/lyra/privacy/policy_integration.rb` |
| PII detection and masking | `lib/lyra/privacy/pii_detector.rb`, `pii_masker.rb` |
| GDPR reports | `lib/lyra/privacy/gdpr_compliance.rb` |
| Event flow analysis | `lib/lyra/event_flow.rb` |
| DualView | `lib/lyra/dual_view.rb` |
| Erasure | `lib/lyra/erasure.rb` |
| Configuration | `lib/lyra/configuration.rb` |
| Example policies | `config/privacy_policies.rb` |
| PAM DSL core and errors | `gems/pam_dsl/lib/pam_dsl.rb`, `gems/pam_dsl/lib/pam_dsl/policy.rb` |
| PAM integration guide | `gems/pam_dsl/docs/PAM_DSL_INTEGRATION.md` |

---

## 10. Scope and Limits

- **What is recorded.** Writes through ActiveRecord to monitored models, in
  every mode but Disabled; reads only when a purpose is declared (or
  `reads_without_purpose` is `:audit` or `:deny`), and recorded only with
  `config.record_access_events`. Raw SQL, triggers and other applications are
  not seen.
- **The log is append-only, with one exception.** `Lyra::Erasure.erase!`
  (Art. 17) overwrites a record's events in place (same event id, position
  and time) to remove personal values, and records an
  `Lyra::Events::ErasureApplied` event naming the fields, the reason and who
  erased them. The event log therefore is not tamper-evident by itself:
  anyone with write access to the event store tables can change it.
- **Monitor can lose events.** In Monitor a failed append is logged and the
  write stands; `bin/rails lyra:repair` brings the streams back in line, but
  the detail of the lost changes is not recovered. Hijack and the
  event-sourcing modes fail the write instead.
- **Privacy features need PAM.** Without the pam_dsl gem no policy loads,
  nothing is detected as PII, and purpose checks and the access log do
  nothing.
