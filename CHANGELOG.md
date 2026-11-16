# Changelog

All notable changes to the Lyra project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking
- **A query uses every declared field it names, whatever it returns.** Purpose-bound reads checked
  record loads and `pluck`; aggregates, filters and `exists?` were not checked, so under a purpose
  that does not allow `name`, `Registration.group(:name).count`, `maximum(:name)` and
  `where(name: "Ann").exists?` answered, and `find_by(name: "Ann")` raised for Ann and returned
  `nil` for anyone else: a membership test. Now the declared fields a query names (its select or
  pluck list, the aggregated column, `group`, `where`, `having`, `order`, the conditions of
  `find_by`, class-level too, and `exists?`, a subquery, and the filter of `update_all`,
  `delete_all`, `touch_all`, `delete_by` and `destroy_by`) are checked before it runs, so such code
  under a purpose now raises `PamDsl::PurposeFieldMismatchError` (or, with no purpose under
  `reads_without_purpose :deny`, `PurposeRequiredError`). `count`, `count(:all)` and `size` name
  nothing and are not checked; `count(:name)` uses `name`. The check is split by what can be known:
  a record load has its query's fields checked without the consent step (PAM's new
  `validate_fields!`), then each record returned as before, consent included, for what it holds
  and what the query named; aggregates, `exists?`, `ids`, `pluck` and bulk writes read everyone at
  once (subject `Model$*`) and are refused under a purpose whose basis is consent. A joined
  model's declared fields are checked against its own policy (subject `Other$*`). `find_each` and
  `in_batches` check and record a query once, not per batch. ES-NoProj gives the same answers:
  its relations keep what their query named, and it no longer disagrees with Monitor on
  `exists?(hash)`. Rails' uniqueness validation and an association's `dependent:` handling when a record
  is destroyed (`:delete_all`, `:nullify`, `:delete`, the restrict options, and the lookup of the
  dependents `:destroy` destroys) run as part of the write and are not checked; `find_or_create_by`
  and an application's own `where(author_id: id).delete_all` are. In ES-NoProj a block given to
  `select` (now returning an Array, as in Active Record), `find` or `many?` sees only checked
  records; it saw the cached records unchecked. So do its association readers (`belongs_to`,
  `has_one`), `records`, `each` and `find_each` without a block, and `inspect`, which handed
  records out unchecked. A subquery or CTE reads other people, so what it names is checked whole
  (subject `Model$*`), even on the queried model; a `table.column` inside an SQL fragment belongs
  to that table's model; a column named without its table that the queried model lacks belongs
  to the joined model that has it; a condition on a `belongs_to` association names its foreign
  key; `update_all`'s SET expressions read the columns they name (`"email = name"`); the
  `returning:` columns of `insert_all` and `upsert_all` are read; and `cache_version` and
  `cache_key_with_version` are aggregates. A refused check is never remembered, and the
  application's block inside `find_each` or `in_batches` is checked each time it queries; only the
  loop's own cursor queries are checked once. The purpose and Lyra's internal-read flag are kept
  in Ruby's fiber storage, tied to their thread, so the fiber an Enumerator runs in
  (`relation.to_enum.next`) has them and another thread does not; code that read
  `Thread.current[:lyra_purpose]` uses `Lyra::PurposeBoundReads.current`. With no purpose and `reads_without_purpose :allow` the hooks return before
  looking at the query. Limits: hand-written SQL, string joins, views, functions, triggers, custom
  Arel nodes and CTEs are not seen, and an SQL fragment is matched by the queried model's declared
  names only.
- **Lyra's escape hatches are Lyra's.** `Lyra.projection_write`, `Lyra::PurposeBoundReads.internal`,
  `Lyra::Projections::ModelProjection.project` and `Lyra::Projections::Rebuild.project_events`
  switch off the checks that keep every write in the log and every read under its purpose. They now
  take a token only Lyra's own code can name, and raise `Lyra::InternalApiError` without it;
  `ModelProjection.project_create`, `project_update` and `project_destroy` are private. Application
  code that wrote without events (seeding, fixtures, a wipe whose history is not wanted) uses
  `Lyra.unrecorded_write(reason:) { ... }`. It runs the block the same way and records that it ran
  (reason, who, the caller) in the stream `Lyra::UnrecordedWrites`; `config.unrecorded_writes =
  :deny` refuses it. The token keeps code from calling them by accident; it is no barrier against
  code out to defeat it. A refused call leaves the flags of the block it ran in as they were.
- **`DualView#crud_state` reads the row as its caller does,** so under `reads_without_purpose :deny`
  it needs a purpose that allows the declared fields, as any read does; before, it read as Lyra.
  `compare`, `compare_all` and `find_discrepancies` follow it. Lyra's mode gate, the sampler,
  repair still read as Lyra. The dashboard reads under a purpose, as the application does: the
  request's `?purpose=`, else the new `config.dashboard_purpose`; a read the policy refuses answers
  403 and says how to name one.
- **PAM DSL: a purpose that declares no `basis` is `:undetermined`,** where it was `:consent`.
  The register printed such a purpose as Art. 6(1)(a), and nothing checked it, because no consent
  block asked for one. Access under it now raises `PamDsl::UndeterminedBasisError`, and the
  Article 30 register lists it as a gap, as for a purpose the policy generator writes. A policy
  that relied on the default must declare the basis it means (`basis :consent` included).

- **PAM DSL: the consent grammar refuses what the Regulation does not allow, and a `:consent`
  purpose always needs consent.** On a purpose whose basis is `:consent`, `required! false` (Art.
  6(1)(a)) and `withdrawable! false` (Art. 7(3)) raise `PamDsl::ConsentGrammarError` when the
  purpose or its consent block is declared, in either order, through `define_policy` or the
  methods of `Policy`. `granular!`, recorded and never enforced, is removed: it raises
  `ConsentGrammarError`, and the consent report has no `granular` key. Access under a `:consent`
  purpose now needs an active consent whether or not a consent block is declared for it; with no
  block it passed the legal-basis check unchecked.

- **`created_at` and `updated_at` are ordinary columns, and event logs written before 1.0.0 are
  not supported.** Every event Lyra writes now carries the two timestamps like any other column
  (a create's `attributes`, an update's `changes` when they moved), DualView compares them, and
  nothing treats them specially any more. The compatibility code for older logs is gone:
  `Lyra::Event.created_attributes` no longer recovers a create's timestamps from its `changes`
  (Monitor creates written by 0.9.x left them out of `attributes`), and `ModelProjection` no longer
  stamps `created_at`/`updated_at` with the projection time when an event lacks them. An update
  that left `updated_at` alone (`update_columns`, an `update_all` that does not set it) now leaves
  it alone in the projected row too, where before a rebuild stamped the rebuild time and the row
  differed from its events. An application with a log from Lyra 0.9.x should start a new event
  store at 1.0.0 (Genesis imports the existing rows) rather than replay the old one; the per-mode
  event shapes of 0.9.x are not supported.

- **`DualView#compare` and `#calculate_differences` return `{}` when the row and its replayed
  state agree,** where they returned `{ no_differences: true }`. An agreement is now an empty hash,
  and every entry of a non-empty one has the same shape, `{ crud:, event_sourced: }`: an attribute
  that differs, or `exists: { crud:, event_sourced: }` (`true`/`false` each) when only one view has
  the record, where it was `{ exists_mismatch: true }`. That entry keeps the result non-empty, so a
  check for `{}` cannot take a missing record for agreement. Code that tested
  `differences[:no_differences]` or compared with `{ no_differences: true }` must test
  `differences.empty?`; code that tested `differences[:exists_mismatch]` must test
  `differences.key?(:exists)`. Attribute differences are keyed by column name as a **string**
  (`differences["email"]`, as Active Record keys `attributes`, and as HABTM link differences already
  were), where they were symbols; the existence entry is the symbol `:exists`, so no column, a
  column named `exists` included, can collide with it. Lyra's own callers
  (`ModeTransition`, `Repair`, `DualView.find_discrepancies`, the recommendations) and the replay
  verifiers of the BPI and Olist examples are updated.

### Fixed
- **Retention did nothing in ES-NoProj.** `Lyra::Retention` (and `lyra:retention:apply`) listed
  the model's ids from its streams but loaded each record from its table, which ES-NoProj leaves
  empty or stale: no record was found, a dry run listed nothing and no rule was applied, and
  `:hard_delete` and `:soft_delete` would have failed reloading the record from its table. In
  ES-NoProj retention now finds the records, their anchor column (`created_at` or
  `config.retention_anchors`) included, in the event store, with no default scope applied (a
  soft-deleted record is still due), and acts on them there: `:hard_delete` destroys the record
  rebuilt from its events (a destroy event) and `:soft_delete` updates it (an update event). The
  other modes are unchanged.
- **The Art. 15 copy read a column an association owns as a link to another model too.** The
  `<type>_id` convention of `Lyra::Privacy::SubjectLinks` also read `owner_id` of
  `belongs_to :owner, class_name: "Person"` as a link to a model named `Owner`, and a polymorphic
  `owner_id` as one whatever `owner_type` said, so the export for `Owner` 13 included the note
  of `Person` 13. A column an association owns now links only to that association's class (a
  polymorphic one's, only with its type column naming the subject's class), and the convention
  reads only columns no association owns, for a subject type that is a monitored model or names
  no model at all.
- **ES-NoProj reads apply the model's default scope.** Active Record builds every read of a
  table from the model's `default_scope`; ES-NoProj reads, rebuilt from the event log, left it
  out, so soft-deleted records (`default_scope { where(deleted_at: nil) }`, as paranoia, discard
  and Solidus's `Spree::SoftDeletable` use) were found, counted and returned by associations.
  `find`, `find_by`, `find_by!`, `exists?`, `where`, `all` (and so `count`, `pluck` and the other
  calculations), `first`, `last` and named scopes now read through the default scope, as do
  `belongs_to` and `has_one` readers and `has_many` readers, counts, sizes and collection queries
  (through the target's default scope less what the association's scope unscopes, as Active
  Record's association scope). A default `order` orders the results; on a `CachedRelation` an
  `order` now adds to the existing order and `reorder` replaces it, as in Active Record, and
  `first`/`last` follow the relation's order (`last(n)` returns the last n in that order, no
  longer reversed). `Model.unscoped` read the table, which ES-NoProj leaves empty or stale; in
  application code it now returns every record from the event store, and reads inside
  `Model.unscoped { ... }` (and `reload`) leave the default scope out. Active Record's internals
  and Lyra's own code keep Active Record's relation from `Model.unscoped`, also through a
  model's own `def self.unscoped = super`. Scopes that take the default scope off
  (`with_deleted`, `with_discarded`, `unscope(where: :deleted_at)`) and `rewhere` work after
  `where`, `order` and named scopes, on the model and on an association, as on Active Record
  (the relation replays its conditions without what is taken off); **after a `limit`,
  `where.not` or an SQL fragment they raise `UnsupportedQuery`**, since the records they would
  bring back are no longer in the relation. **A default scope ES-NoProj cannot evaluate (an SQL
  string, a join, an ordering by an expression) now raises `UnsupportedQuery` on every read of
  the model**, rather than answer with the records it leaves out, and
  `Lyra::ModeTransition.to!` refuses the switch into ES-NoProj while a monitored model has one
  (`force: true` overrides). An association's scope is evaluated on each read, so one that
  decides at run time (`-> { Current.admin? ? with_deleted : all }`) is honoured. A find by
  primary key reads one record even under an ordered default scope. Models without a default
  scope read as before.
- **ES-NoProj relations no longer act on records their query did not select.** A
  `CachedRelation` answers exactly or raises `UnsupportedQuery` before anything is written.
  `merge` and `merge!` returned the relation unchanged, so `Model.unscoped.merge(Model.where(...))
  .delete_all` deleted every record; they now evaluate the other relation (its conditions,
  order and limit, or the records of an event-store relation) and refuse another model's, a
  joined or a limited one. `where!` with anything but hash conditions kept every record and now
  raises; `exists?(["title = ?", x])` ignored its condition and now evaluates it as `where`
  does (or refuses it). Relation methods Lyra did not implement ran on a bare relation of the model, past the
  relation's conditions: `update` and `update_counters` changed every record, `first_or_create!`
  and `create_or_find_by!` created records without the conditions, `create_with` was dropped and
  `to_sql` raised `NoMethodError`. `update`, `update!`, `update_counters` (with `touch:`),
  `first_or_initialize`, `first_or_create(!)`, `create_or_find_by(!)` (a record is found instead
  when a unique index of the table would refuse it, as Active Record finds it on the violation)
  and `create_with` now work on the relation's records and conditions, and `sole` and
  `find_sole_by` raise `RecordNotFound` or `SoleRecordExceeded` as Active Record does; `lock`, `annotate`,
  `optimizer_hints` and `strict_loading` are accepted and do nothing (writes take Lyra's
  aggregate lock); `to_sql` and every other Active Record relation method raise
  `UnsupportedQuery` before running. A model's own class methods called on a relation run with
  it as the current scope, as Active Record runs them: their reads and writes act on its
  records.
- **PAM DSL prints a retention period given in plain seconds correctly.** With ActiveSupport
  loaded, as in a Lyra application, an Integer number of seconds (`keep_for 86400`,
  `default 7 * 365 * 86400`, or an Integer from configuration) was read as years: 86400 printed
  "0 years" in the Article 30 register, the policy summary and the retention check, and the
  policy comparator printed 365 days of seconds as "365 days" and seven years of seconds as
  "6 years". Plain seconds are now worded the same with and without ActiveSupport, with the
  polyfill's fixed-length units (1 month = 30 days, 1 year = 365 days), rounded down to the
  largest whole unit: 3600 is "1 hour", 86400 "1 day", 30 days "1 month", 365 days "1 year".
  `ActiveSupport::Duration` values (`1.day`, `7.years`) print as before. Retention enforcement
  was not affected: it already read plain seconds as seconds in both modes.
- **Lyra's GDPR retention check dropped a policy's retention given in plain seconds** and
  applied the configured or default period (7 years) instead; it now keeps a plain number of
  seconds as it keeps an `ActiveSupport::Duration`.
- **An erased record's row kept personal values inside `json`, `jsonb` and array columns that
  its events had lost,** so it no longer replayed to its events. This happened with or without
  `everywhere`. The erasure rewrote the events recursively but replaced only top-level string
  columns in the row. `Lyra::Erasure` now scrubs every column of the row with the rule its events
  get: the record's own row with the key and value rule, another record's row reached by
  `everywhere` with the value rule only, so a third party's email under an `email` key there is
  kept. `json`, `jsonb` and array columns and serialized attributes are recursed into and written
  back whole in the same `UPDATE`. A `text` column holding JSON is still compared as a string, as
  in its events. A column declared personal that holds a hash or an array is replaced whole, in
  the row and in the events alike (each side of a change too): `nil`, or, when it is NOT NULL,
  its own default as the database stores it (`[]`, `{}`); before, the events kept it, or got its
  elements replaced one by one. Inside a hash, the strings that are identifying for the field's type (an
  email for `:email`, a phone number for `:phone`) count as the person's values, and those under a
  nested personal field; their copies elsewhere in the record, and with `everywhere` in other
  records, are erased too. Labels such as `"home"` are not. An earlier erasure's `"erased:<id>"`
  is no one's value, so a second erasure neither reports nor searches for it. The row is scrubbed by
  the attribute's type, as its events are, so `hstore` columns and attributes cast as json are
  recursed into too. An
  encrypted attribute is compared in clear in its events, as in its row, and a replacement is
  encrypted again; before, its ciphertext stayed in the events and replayed back to the value.
  The erasure moves the row's optimistic-lock column, as any write does, so a copy loaded before
  it fails with `StaleObjectError` instead of saving the erased values back; the move is recorded
  as an ordinary update of that column alone (metadata `source: "lyra_erasure"`), so the row still
  equals its replay. Before, the lock moved in the row only, and the row no longer replayed to its
  events. Virtual attributes are no longer written, which made the erasure fail. An
  event that is not a CRUD event (an application's own, in the record's stream) gets the key rule
  at its top level, so a personal field's hash there is replaced whole. With `everywhere`, a
  record is listed in `result.copies` only if its row no longer holds the value anywhere. A value
  held as a JSON key, or inside a longer string, is not erased, and the record is listed in the
  new `result.left_behind` as `{ record:, columns: }`, never with the value; `lyra:erase` prints
  it. Before, such a record was listed as erased. The erased record's own row is checked the same
  way, with or without `everywhere`, and listed first. A primary or foreign key is never rewritten;
  one that holds an erased value is reported in `left_behind` as `"Model <key withheld>"` (and
  `result.key_withheld`), and no result, reason or task output prints it. With `everywhere`, each
  record found is locked and its stream read again before it is erased, so a copy written during
  the search is not missed; candidates are found without case, and a `citext` copy differing in
  case is reported. The new `result.not_searched` names the encrypted columns of monitored
  models, which a text search of the log cannot read. In ES-Async the lock moves from the version
  the log last recorded.
- **`everywhere` erased a third party's own record when the person's data named them.** In the
  person's own record a value under a personal field's name is the person's (the key rule), so a
  manager's email nested inside the person's JSON (`{"manager" => {"email" => …}}`), or a friend's
  email at the top of another event in the person's stream (an invitation), was erased there and
  then searched for in other records, the third party's own included. Now only the person's own
  values drive the search: those of the row's personal fields and at the top of a personal field in
  the record's own CRUD events (an attribute, either side of a change, a payload entry), with the
  strings inside a structure declared personal taken by its type as before. The others are still
  erased in the person's record, as its events are, and no longer anywhere else.
- **`everywhere` missed rows that held a value their events did not.** The search reached rows
  only through events, so a row given the value by raw SQL, written before monitoring, or changed
  by a write Lyra could not intercept kept it, and nothing reported it; and a record reached
  through an event that mentioned the value only inside a longer string kept a whole copy in its
  row. With `everywhere`, the tables of monitored models with a policy are now searched directly,
  one query per table that returns keys only (string and text columns by equality, `json`/`jsonb`
  as text by a `LIKE` on the value as a JSON string, string arrays with `= ANY`, `hstore` values);
  not in ES-NoProj, where the tables are absent or stale. Every record reached has its row scrubbed
  by the value rule, whether or not its events held the value whole. When only the row held it,
  its `ErasureApplied` says `row_only: true` and it is listed in the new
  `result.rows_without_events` (its row already differed from its replay: `lyra:repair` in Monitor
  or Disabled, a rebuild of its table in the other modes; the task says which). A row with no
  stream is erased first and then imported the Genesis way, so its `Imported` event holds the
  replacement, never the value (an `ErasureApplied` alone would have started a stream Genesis never
  imports); if a Genesis run imported it first, that stream is rewritten instead. A key column is
  still never rewritten, and a row holding a value only as a JSON key or in another case in a
  `citext` column is reported in `left_behind`. The log is searched once for all the values (it
  was searched again per value to count holders), and candidate events are read in batches.
- **`everywhere`'s threshold counted streams, not people's records.** A value was taken as shared
  when more than `max_copies` other streams held it, so one person's many records (and a record's
  reference links) counted against it. Holders are now counted by record, through events (each
  confirmed by an exact match) and rows alike, and the person's linked records, found by the rule
  of the subject-access copy (`Lyra::Privacy::SubjectLinks`: any `belongs_to` to the erased
  record's model naming it, by id or by its `primary_key:` column, a polymorphic one, a
  `<model>_id` column), do not count. `max_copies:` must be a positive Integer (`ArgumentError`
  before anything is written; a String failed half-way before).
- **`everywhere` rewrote Lyra's own record streams.** An event in a stream that was not a monitored
  record's was rewritten when it held an erased value, so a consent recorded under an email as its
  subject key (`Lyra::Consent$<email>`) lost it, and the consent store, rebuilt from those events,
  lost the consent. Restrictions and objections (`Lyra::Rights`), consent (`Lyra::Consent`), the
  access log and its erasures and the subject-access exports, with their per-subject streams, are
  now never rewritten by `everywhere`, nor counted as holders.
- **Genesis's lock was per class, not per table.** An import through an STI subclass did not wait
  for one through its base class. The lock is now named after the table's stream owner (the STI
  base class), which the erasure of a row with no stream also takes.
- **PAM DSL works without ActiveSupport again.** Loaded on its own, with its standard-library
  polyfill, the Article 30 register raised `NoMethodError` (`String#presence` is ActiveSupport),
  and JSON export (`Reporter#export_json`, `GDPRCompliance#portable_export`) relied on
  ActiveSupport having loaded `json`. The polyfill now provides `presence` and treats a
  whitespace-only string as blank, as ActiveSupport does, and both files require `json`. Behaviour
  under ActiveSupport is unchanged. `rake test:all` now runs the PAM DSL suite twice, with
  ActiveSupport and with the polyfill (`rake test:both`), so CI covers both.
- **A model whose single primary key is not `id`** (`self.primary_key = "code"`, a string or
  uuid column, no `id` column) is supported in every mode. `Lyra::DualView` looked the row up
  with `find_by(id:)`, so `DualView#compare`, `compare_all`, `find_discrepancies`,
  `Lyra::ModeTransition.discrepancy`, the mode gate's check and `lyra:repair` raised on such a
  model; sync projection and rebuild updated and deleted rows `where(id:)`. Hijack and event
  sourcing ignored the key the application gave, reserved another (a uuid), and put an `id`
  attribute the table does not have into the `Created` event. ES-NoProj's and `as_of`'s
  reconstructed records, the dashboard's record pages and `event_aware_belongs_to` also used
  `id`. All now use the model's primary key. A composite primary key is still not supported, and
  is now refused clearly: `monitor_with_lyra` and `config.models` raise `ArgumentError` naming
  the key, and `verify_mapping!` reports it.
- **ES-NoProj: `has_many ... dependent: :delete_all` left the children alive.** Rails deletes
  them through the association's table scope, which matches no row in the events-only store, so
  no `Destroyed` event was written and the children were still read back after their parent was
  destroyed. A `dependent: :nullify` found its children by foreign key alone, so it also cleared
  those outside a scoped association (`has_many :x, -> { where(...) }`), and a polymorphic one
  (`as:`) wrote no events at all. Both now find the children the association selects in the event
  store, as Active Record's association scope does: the owner's records, narrowed by the child's
  default scopes (less what the association's scope unscopes, so a soft-deleted child is left
  alone) and by the association's scope. Each gets the event `delete_all` or `update_all` writes
  there (`delete_all`, `dependent_association` or `update_all`, as in Monitor); strict mode
  refuses `delete_all` as it does in Monitor. **A dependent association whose scope, or whose
  child's default scope, cannot be evaluated against the event store (an SQL string scope such
  as `-> { where("status = 'x'") }`) now raises `UnsupportedQuery` and the parent's destroy is
  refused**, rather than delete or nullify children the association might not select. The same
  applies to `delete_all`, `delete(record)` and assigning a new set on such an association;
  `delete(record)` and assignment raised `TypeError` before (a condition on a record's query
  constraints, `where(["id"] => [[1]])`, which `CachedRelation` now evaluates). The owner's
  in-memory counter cache is no longer lowered (it went negative): ES-NoProj does not maintain
  counter caches. `has_one` `:delete` and `:nullify` were not affected. Monitor, Hijack and
  ES-Sync are unchanged.
- **ES-NoProj answers `delete_by` and `destroy_by`,** as `where(...).delete_all` and
  `where(...).destroy_all`; they raised `UnsupportedQuery`. The partners of an in-memory join are
  read as Lyra's own read: under a purpose, a join on a model with a policy was refused for the
  partners' fields though no partner is returned; so are the children a `dependent: :nullify`
  rewrites, read for their events.
- **Monitor appended `Updated` after `Destroyed`** when a stale copy was saved after another
  process had destroyed the record. Its UPDATE reached no row, or, when nothing had changed, no
  UPDATE ran; Active Record still ran `after_update`, and the stream became
  `[Created, Destroyed, Updated]`. Monitor now records no update when the UPDATE reached no row or
  nothing changed.
- **`belongs_to ... touch: true` cascades published nothing.** Rails touches the parent through
  `touch_later`, which sets the timestamps and clears their change before `touch` runs at commit,
  so Lyra saw no change. The parent's row moved and its stream did not; with timestamps compared,
  DualView flagged every touched parent and the mode gate refused. Lyra now keeps the row's value
  before the first deferred touch and records the change.
- **An application's `metadata_proc` `source` was overwritten** by Lyra's (`lyra_interceptor`,
  `lyra_command_handler`). Lyra's value is now the default the application's keys override.
- **ES-NoProj: `where(...).touch_all` touched every record** (an unscoped `touch_all` through the
  scope branch, with an event each) and then raised `UnsupportedQuery`. It now touches only the
  selected records, with one time for all, as Rails's `touch_all` does.
- **The GDPR helpers lost a related record's updates and destroy** (Art. 15/17/20 reports):
  they matched the subject's foreign key in each event alone, and an update carries only its
  changes. Each record is now followed through the log, and an event is the subject's when the
  record pointed at them before or after it.
- **A record created in Monitor lost `created_at` and `updated_at` when the log became
  authoritative.** Monitor's event left the two columns out of its `attributes` snapshot (its
  `changes` carried them), and replay and projection read a create's `attributes`. After a switch
  to event sourcing an ES-NoProj read raised `MissingAttributeError` on them, and a rebuild reset
  them to the rebuild time; DualView ignored the two columns, so it reported neither. `attributes`
  now holds every column, timestamps included, in Monitor events and in the events of bypass writes
  that create or delete records (`insert_all`, `delete_all` and the like), as Hijack and the
  event-sourcing modes already did. Logs written before this change are not supported (see
  Breaking).
- **`ModelProjection.project_create` overwrote a string-keyed `created_at` or `updated_at` with
  the projection time.** It defaulted the two with symbol keys, and stringifying the keys let the
  default replace the value the event carried. A rebuild therefore reset the timestamps of every
  record whose event attributes had string keys, as Monitor's do.

### Changed
- **`config.erasure_max_copies`** (default 10) sets `everywhere`'s threshold for the application;
  `erase!(max_copies:)` and `lyra:erase MAX_COPIES=` still override it per call. Each value left
  as shared is reported in the new `result.shared` as `{ field:, type:, holders: }` (never the
  value); `result.shared_values` stays an Integer, their count. **`erase!(dry_run: true)`**
  (`lyra:erase DRY_RUN=1`) runs the erasure and rolls it back, reporting what it would do, the
  shared values and their holders included, and writing nothing: once a person's values are
  erased, a later run cannot find the copies left as shared, so the threshold is chosen with a dry
  run first, and the task's hint says so. `ErasureApplied` gains `row_only` and `imported`
  (above). The documentation now gives the operator's `VACUUM` step after an erasure (old row and
  event versions stay on disk, in WAL and in backups until reclaimed or expired), states that a
  database error logged by a failed bypass publish can contain the failing row, and describes a
  narrow wait between an erasure and a model's first use in another transaction.
- **PAM DSL: restriction of processing (Art. 18) and the right to object (Art. 21).** PAM had no
  construct for either: a restriction could only be approximated by narrowing a purpose for
  everyone or withdrawing a consent, and a purpose on contract or legal obligation could not be
  stopped for one person. A purpose now declares the Art. 18(2) grounds on which it continues
  while a subject's processing is restricted (`allowed_when_restricted :consent`, `:legal_claims`,
  `:protection_of_rights`, or `:important_public_interest, reference: "<the law>"`), and whether
  it is direct marketing (`direct_marketing!`, Art. 21(2)) or research or statistics
  (`research_or_statistics! public_interest_task: true|false`, Art. 21(6)); `Purpose#objectable`
  derives the article that lets a subject object (Art. 21(1) for public task and legitimate
  interests, research or not), or none. `PamDsl.rights` records, per subject and independent of any policy,
  restrictions (`restrict!`, then `notify_lift!` and `lift!`, which raises without the Art. 18(3)
  notice) and objections (`object!`: upheld at once for direct marketing, pending and restricting
  that purpose for Art. 21(1) and 21(6) until `decide!`, recorded as rejected and raised as
  `ObjectionNotApplicableError` for a purpose with no right to object; `withdraw_objection!`), as
  events in `PamDsl.rights_store`, with an `on_rights_event` hook. An upheld objection to direct
  marketing stops every direct-marketing purpose for that subject; objecting again while an
  objection is in force returns it; times must be `Time` values that run forwards. `validate_access!` gains
  Condition 6, checked after every other condition: `RestrictedProcessingError` for a restriction
  that covers the access when the purpose declares no exception that applies, and
  `ObjectedProcessingError` for an upheld objection. The Article 30 report prints each purpose's
  right to object and its exceptions. PAM DSL ships the store protocol and an in-memory store
  only; the in-memory store refuses to record outside development and test
  (`RightsStoreNotDurableError`). Lyra's durable store and its enforcement on reads, erasure and
  retention are not in this change, and writes are not checked under a restriction in 1.0.0.
- **Lyra keeps the data subject's restrictions, objections and consent durably, shared by every
  process.** With PAM DSL loaded, Lyra installs `Lyra::Rights` into it. `PamDsl.rights_store`
  becomes Lyra's: each request, notice, decision and lift is an event in
  `Lyra::Rights$<subject key>` (linked to `Lyra::Rights`), appended with RubyEventStore's expected
  version so that two processes cannot both lift or decide one request (the second gets
  `PamDsl::RightsConcurrencyError` and nothing is stored), and an append that does not replay is
  refused before anything is written. The new table `lyra_rights` (one row per restriction or
  objection: subject key, kind, policy, purpose, fields, ground, state, times) is written in the
  same transaction and created on first use; `bin/rails lyra:rights:rebuild` rebuilds it.
  Condition 6 answers from a per-process snapshot of the committed requests in force, refreshed at
  most every `config.rights_refresh_interval` seconds (default 1, new) and on
  `Lyra::Rights.refresh!`, so a check costs a clock read when nothing is in force; a transaction
  that records a right sees it at once and other threads only after it commits, and a rebuild
  locks the table against transitions. `PamDsl.subject_key_resolver` maps a record to its own key
  and to the keys of the people it names, by the subject-access copy's selection rule (link
  columns a record was loaded without are read from its row, or the access fails with
  `Lyra::Rights::UnresolvedSubjectError`), so a restriction recorded against a person
  (`"Person$7"`) refuses a read of their invoice under a purpose with no Art. 18(2) exception.
  Lyra installs its stores when it loads, and at boot only where the application has not
  installed its own. Consent moves to the same store: PAM DSL's new `PamDsl.consent_store`, when set, is
  the store of every policy's `consent_policy`, and Lyra's keeps each request, grant and withdrawal
  as an event in `Lyra::Consent$<subject key>` with the table `lyra_consents` as its projection.
  Before, consent was held in memory, per process and per policy object: lost on restart, not seen
  by other processes or by another policy, and gone when a policy was defined again. A person's
  consent now covers the records that name them; a grant that repeats a granted consent records
  nothing. Limit: a consent check on a record that names more than one person (a payer and a
  payee) is refused with `Lyra::Rights::ConsentStore::SharedRecordConsentError`, a
  `PamDsl::ConsentRequiredError`, whatever each consented to; whose consent such a record needs
  is future work. Condition 4 and the `:consent` exception of Art. 18(2) read the same record (a
  consent store's refusal under that exception is now reported with the restriction rather than
  raised), and `consent_audit` lists the store's records (`recorded_consents`). Without Lyra, PAM
  DSL keeps consent in memory as before. Neither stream
  is erased by `Lyra::Erasure` or with the access log: they hold names, grounds and reasons, never
  values. Model-wide filtering of restricted subjects, `lyra_processable`, and restriction-aware
  erasure and retention are not in this change.
- **Lyra enforces restriction and objection where it checks reads, in erasure and in retention,
  and reports them.** Under a purpose (or `reads_without_purpose` `:audit`/`:deny`):
  - A record load that names no declared field (`select(:id, :payer_id)`) is checked too, for a
    restriction of all of its subjects' data, a pending objection's restriction of the purpose and
    an upheld objection (PAM DSL's new `validate_rights!`); before, such a load was never checked.
    A loaded restricted record raises, as a non-consenting one does.
  - Aggregates, `pluck`, `pick`, `ids`, `exists?` and `cache_version` (subject `Model$*`) leave the
    restricted subjects out: the record's own key `NOT IN` the restricted records and each link
    column `IS NULL OR NOT IN` the restricted people, so rows that name no one are kept; ES-NoProj
    filters its in-memory records by their keys, and fails closed
    (`Lyra::Rights::UnresolvedSubjectError`) when a record's links cannot be read. A field-scoped
    restriction applies only to queries naming one of its fields. Audit mode leaves no one out and
    logs it. With nothing in force for the query, its SQL is unchanged. Before, these queries
    included the restricted people.
  - A join, subquery or CTE that reaches a model with such a subject raises
    `PamDsl::RestrictedProcessingError` rather than include or silently drop them.
  - `Model.lyra_processable(fields: nil)`, a scope without the records the purpose in scope may not
    process, for batch jobs (Active Record and ES-NoProj).
  - The rights and consent are read afresh at the first check of each checking scope: a
    `Lyra.with_purpose` block, a web request (`Lyra::Rights::Middleware`, installed by the
    engine), an Active Job (`Lyra::Rights::Job`) and each batch of `in_batches`, `find_each` and
    `find_in_batches` (`Lyra::Rights.scope`). A right recorded in another process applies from the
    next scope; before, up to `rights_refresh_interval` later, mid-request included. The first
    check in a scope makes one indexed query; code that checks nothing (no purpose, `:allow`) makes
    none.
    `config.rights_refresh = :interval` (new; the default is `:scope`) keeps scopes but drops the
    forced read: rights and consent are read again only after `rights_refresh_interval`, as before.
  - `Lyra::Erasure.erase!` refuses a record that a restriction in force covers (its own, a person's
    it names, of all the data or of a field being erased) with `PamDsl::RestrictedProcessingError`;
    `lifting: restriction_id`, after the Art. 18(3) notice, lifts it and erases in one transaction.
    A dry run (`dry_run: true`) is refused the same way and, with `lifting:`, lifts nothing and
    lists in `Result#lifting` what it would lift (a real erasure lists what it lifted).
    `Lyra::Retention` skips restricted records with outcome `:restricted` (`Result#restricted`,
    printed by `lyra:retention:apply`). Before, both acted on data the subject had asked to be kept.
  - The subject-access copy (`data_export`) has `restrictions` and `objections`: the subject's own
    requests, never another person's. The per-subject `processing_activities` gives each declared
    purpose's right to object and Art. 18(2) exceptions (`rights_by_purpose`); with Lyra's
    per-model policies it gave none. A dashboard page, `privacy/rights`, lists the open requests
    with their age against the month of Art. 12(3); the policy page shows each purpose's
    declarations; `RestrictedProcessingError` and `ObjectedProcessingError` in a dashboard read
    answer 403.
  - `Lyra::Verification::DataLifecycleWorkflow` (the data lifecycle with a Restricted place,
    restrict, notice and lift) and `ObjectionWorkflow`, PetriFlow nets whose tests check that
    PAM DSL's transitions are exactly theirs and that Deleted is unreachable from Restricted
    without the lift.
  - After review: SQL strings are read for the tables they reach (`FROM`/`JOIN`, with aliases), so a
    string join or subquery reaching a restricted model is refused, and a subquery's words are
    checked against the policy of the table they belong to (a change to the purpose check too); a
    `FROM`/`JOIN` Lyra cannot name is refused while a right is in force (fail closed). A polymorphic
    filter covers STI subclass names. A subject's people are resolved only when a request in force
    could cover the access, and aggregate rows are not subjects (a grouped `select` or `find_by_sql`
    no longer raises `UnresolvedSubjectError` because of an unrelated right); ES-NoProj reads a
    narrowed record's people from the whole record. ES-NoProj's `Model.exists?(id)` and an undeclared
    purpose follow the rights. Erasure reads a record's people from its events when it has no row
    (ES-NoProj), refuses one it cannot resolve, lifts with `lifting:` only a restriction of the record
    erased, and with `everywhere:` leaves another record's restricted copy unmodified
    (`Result#restricted_copies`, printed by `lyra:erase`, which takes `LIFTING=`). The subject-access copy
    lists record restrictions under ES-NoProj too. The dashboard's event routes refuse (403) or leave
    out restricted records (`X-Lyra-Rights-Withheld`). The rights page gives a deadline only to an
    objection awaiting a decision. The excluded subjects are computed once per snapshot (one pass over
    the requests in force), the condition compiled once, and a scope whose rights did not change costs
    one single-row query: a count with 300 restrictions in force went from about 13 ms to about 1 ms.
  Writes (`update`, `destroy`, bulk writes) are not checked under a restriction in 1.0.0.
- **PAM DSL: a type for every Art. 9(1) special category, and for Art. 10 data.** Only `:health`
  and `:biometric` were special-category types, so a column of any other Art. 9(1) category had
  to be declared under another type (`:custom`), and a purpose with only an Art. 6 basis could
  read, say, trade-union membership without PAM raising anything. The new types `:genetic`,
  `:racial_ethnic_origin`, `:political_opinion`, `:religious_belief` (religious or philosophical
  beliefs), `:trade_union_membership` and `:sex_life_orientation` are special categories: a purpose
  that reads one needs an `art9_basis`, else `PamDsl::SpecialCategoryViolationError`. Art. 10 data
  (criminal convictions and offences) gets the type `:criminal_offence` and a condition of its own,
  since Art. 10 permits processing only under official authority or when Union or Member State law
  authorises it, not on an Art. 9(2) ground: a purpose that reads such a field names that
  authorisation with `art10_authorisation "<the authority or the law>"`, else
  `PamDsl::CriminalDataViolationError` (strict raises it, audit records it, in `validate_access!`
  and `validate_fields!`). An Art. 9(2) basis does not satisfy Art. 10, nor an Art. 10
  authorisation Art. 9. The Article 30 report prints a purpose's Art. 9(2) bases and Art. 10
  authorisations where it reads such data, the export carries them, and `article_30_gaps` lists
  a purpose that reads such data without them. The detector, and so the policy generator,
  proposes the new types from names that say what a column holds (`ethnicity`, `political_party`,
  `religion`, `trade_union_member`, `sexual_orientation`, `criminal_record`), never from a bare
  `party`, `union`, `orientation` or `offence`, and the generator marks such fields with the
  condition a purpose reading them must meet. The dashboard refuses a read that raises the new
  error as it refuses the others. PAM now has 25 field types (18 before). No field of the Aegean
  testbed changes type.
- **The Art. 15 export is a copy of the data.** `Lyra::Privacy::GDPRCompliance#data_export` keeps
  its keys and adds five. `records` holds each of the subject's records whole: every attribute (not
  only those a detector flags; encrypted columns in plaintext) and its stored history, `from`/`to`
  per change. A record is the subject's by what it is: the subject's own row, the rows of monitored
  models whose `<type>_id` names them (indexed queries), and the records the subject's events touch,
  so a row that pre-dates monitoring, a destroyed record and an ES-NoProj record are all in it
  (`state` `:current`, `:destroyed`, `:replayed`); a record whose foreign key moved is the
  subject's only for the periods it named them (`:reassigned`, `periods`). `accesses` is the access
  log for those records (`nil` when `record_access_events` is off). `processing_context` takes each
  record's purposes, bases, recipients, transfers, retention (field periods included) and sources
  from its own model's policy; `notice` is the policy's `access_notice`; `gaps` lists what the
  policy does not declare. Who acted is a role label (`"you"`, `"staff"`, `"system"`) unless
  `disclose_actors: true`. History and the access log are included by default; `history: false`
  and `accesses: false` are for a request the subject narrowed. A field the policy declares
  `withheld_from_access: "<basis>"` is named with that basis instead of its value, and one declared
  `about:` another person goes to `review`; Lyra picks no basis. See
  [PRIVACY_COMPLIANCE.md](docs/PRIVACY_COMPLIANCE.md#the-copy-of-the-data-from-100).
  - *Links.* A record refers to the subject through any `belongs_to` whose class is the subject's
    model (`belongs_to :owner, class_name: "Person"`), a polymorphic `belongs_to` whose type
    column names it, or the `<type>_id` column; the subject's own model is not linked to itself.
  - *Moved records.* An event that moves a record between people gives each only their side: the
    previous subject sees the old values and the link's new value as "moved to another person",
    the new one only the new values. A record whose links no longer name the subject is
    `:reassigned` with its state just before the move, whatever comes after. A value last set
    while the record was another person's is not given: the field is listed under `withheld` with
    the basis "set while the record was another person's". Accesses to a moved record are the
    subject's only within their periods.
  - *The old keys follow the copy's rules* (their content changes): `pii_inventory` and
    `data_lineage` leave out fields declared `withheld_from_access:` or `about:` another person,
    give encrypted values in plaintext, and, like `events`, see a moving event with the subject's
    side only.
  - *Retention* is what the policy declares: with no rule and no `default`, the period is `nil`
    and `gaps` lists "Art. 15(1)(d) retention not declared", rather than PAM's silent 7 years.
    Columns the policy does not declare (no purpose, basis or retention) are listed in `gaps`.
  - *Accesses* include those recorded under the bare subject id (`access_log_subjects:` on
    `GDPRCompliance.new` names others, or `[]` for none) and, with the access log off, the
    subject's earlier exports, with a gap saying the log is off.
- **Events record the acting user's class** (`user_type` in the metadata, beside `user_id`, from
  `Current.user`: the table's owner class for an Active Record user), in the write path, bulk
  writes and the access log. The copy's role labels compare id and class: "you" only when both
  are the subject's; "staff or you" when an event records an id equal to the subject's but no
  class (written before 1.0.0, or by a `metadata_proc` that sets none); "staff" otherwise.
- **Each explicit export is recorded,** as `Lyra::Events::SubjectAccessExported` in a stream of
  its own, `Lyra::SubjectAccessExports$<Type>$<id>`: when, which sections, how many records,
  `verified_by:` and who exported, never values. Erasing the subject's access log
  (`AccessLog.erase!`, or `Lyra::Erasure` with `access_log:`) leaves it, so the evidence that a
  request was answered outlives the log; the copy's `accesses` still lists earlier exports. Only an
  explicit `data_export` call is recorded: `data_export(record: false)`, `full_report` and the
  dashboard's subject and GDPR routes are views of the data and record nothing. On by default;
  `config.record_subject_access_exports = false` turns it off. Nothing is recorded in disabled mode.
- **The GDPR reports read each model's policy.** The wrapper passes PAM the policy of each record's
  model (its `privacy_policy`, else `config.privacy_policy`). `processing_activities` takes the
  purpose, legal basis, categories, recipients and retention from it, where it printed "Not
  specified" and guessed the purpose from `metadata[:source]`; `rectification_history` lists an
  update that changed a declared field as well as one the detector flags.
- **The privacy stamp's purposes are those the policy admits the field for,** from either side:
  the field's `allow_for` and every purpose that lists it in `requires` or `optionally`, as
  `Policy#allowed?` decides. A policy that lists its fields on the purpose side stamped every field
  with `"purposes" => []`. `allowed_purposes` on the PAM adapter follows.
- **PAM DSL field options and the notice declaration:** `withheld_from_access:`, `about:` and
  `collected_from` on `field`, and `access_notice` on the policy (see the PAM DSL changelog).
- **ES-Lazy reads cost less, with the same consistency.** The check before every read reads the
  checkpoint and the newest event id in one query instead of two. A reader that finds the log
  ahead of the tables tries the catch-up lock (`pg_try_advisory_xact_lock`); if another reader holds
  it, it waits for that catch-up to end, without holding the lock, and reads the checkpoint again.
  It is done if the checkpoint has reached the newest event it saw and no event the checkpoint
  lists as missing is visible to it; otherwise it catches up itself, as before. Before, it queued
  for the lock to repeat a catch-up that, under a write-heavy mix, had mostly been done already. A
  catch-up that applies nothing no longer rewrites the checkpoint. The three rules hold: only the
  lock's holder applies events or moves the checkpoint, in the log's order and in its own
  transaction, and a read sees every event it saw before (a late commit below the checkpoint
  still within `GAP_RECHECK` on the fast path). In a local profile (30% writes, 70% reads by id,
  one process) the mean read took about 45% less time at 16 threads and 30% less at 4.
- **PAM DSL: a Condition 5 failure raises `PamDsl::SpecialCategoryViolationError`,** where it
  raised `PamDsl::SensitivityViolationError`. The condition is about special categories (Art. 9,
  decided by the field's type); sensitivity is a separate Art. 32 risk tier that gates nothing,
  and the old name mixed the two. `SensitivityViolationError` stays as a deprecated alias of the
  new class until 2.0, so `rescue PamDsl::SensitivityViolationError` still catches it.
- **ModeSync adopts an escalation only if a gated switch recorded it.** It adopted the newest
  `applied` row of `lyra_mode_transitions` and checked nothing, so one `INSERT` moved every process
  from Monitor to ES-NoProj. A switch now records where it came from (`from_config`), whether the
  gate was overridden (`forced`) and the certificate of the clean check that cleared it
  (`certificate_id`). Other processes adopt an escalation only if the row names that certificate
  (for the same `from -> to`, recorded before the row, named by no earlier switch) or is forced;
  the escalation is judged from the row's `from` and from where the previous switch left the
  application, so a row cannot claim a `from` that avoids the gate. No clock is compared, so a
  switch near the end of its certificate's life or under clock skew is adopted. With the gate off,
  switches are adopted as recorded. A refusal is logged once; an error while deciding leaves the
  row to be tried again. Columns Lyra adds to its own tables are added outside the caller's
  transaction and safely when two processes add one at once. This guards against mistakes and
  naive writes, not against anyone who can write the table.

- **The dashboard and `Lyra::EventFlow` read a window of the log, not all of it.** The flow and
  privacy routes read the newest `config.dashboard_max_events` events (10,000 by default; `?limit=`
  may only lower it), leaving out the access log's own entries, which would otherwise fill the
  window as soon as the access log is on, and report `window: { limit:, returned:, truncated:,
  skipped: }`. A subject's timeline reads that record's own stream (its newest events, up to the
  limit), not the log; what a user did to other records is the `flow/user_actions` route, which
  lists at most `?actions=` actions. With `config.record_access_events` on, a dashboard read is
  recorded in `Lyra::DataAccess$Dashboard` (route, scope, how much came back, never a value). The
  GDPR report helpers still read the whole log, a batch of 1,000 at a time.
- **A save that changes nothing records no event, in every mode.** Monitor, Hijack and event
  sourcing each appended an `Updated` with no changes for a `save` that changed no attribute.
  An update carries its changes, and there were none; Hijack and event sourcing still refuse such a
  save on a destroyed record, as for any write.
- **One event shape in every mode**. Monitor, the command handler of Hijack and event
  sourcing, bypass writes, Genesis and repair now build the payload with `Lyra::EventData`: a
  create or an import carries the record's `attributes` and no `changes`; an update carries its
  `changes` as `[old, new]` pairs and no `attributes`; a destroy carries neither. Before, Monitor's
  events carried the record on an update and a destroy and listed every column in a create's
  `changes`, and a Hijack or event-sourcing update stored its delta twice (`attributes: { changes: … }`
  beside `changes`). Every mode now sets `metadata[:source]` (`lyra_interceptor` for Monitor,
  `lyra_command_handler` for the others). Replay reads a create's `attributes` and an update's
  `changes`; events in the old per-mode shapes are not supported (see Breaking).
  The smaller events cost less to serialise and store, and copy less personal data into the log.
- **Personal data is detected in an event's fields.** `Lyra::Event.fields_of(event)` gives a create's
  attributes or an update's new values; the privacy and flow controllers, `EventFlow`, `EventGraph`,
  `Timeline`, Lyra's GDPR helpers and the PAM DSL's compliance reports use it. They read an event's
  `attributes` alone, so an update, which now carries none, would have reported no personal data
  (a Hijack or event-sourcing update already did, because its `attributes` held only `changes`).
- **A destroy no longer keeps the record's final state** in Monitor. It is in the events before it;
  the audit trail view shows no final state for a destroy.
- **DualView compares `created_at` and `updated_at`.** They were left out of the comparison; a row
  whose timestamp differs from its events is now a difference, and `lyra:repair` records it like
  any other.
- **A bare `touch_all` publishes an update per row** whose only change is `updated_at`, as an
  instance `touch` already did. Bulk bypass events (`update_all`, `upsert_all` and the like) now
  list `created_at` and `updated_at` among their changes when those moved, so an upsert's event
  carries `updated_at` beside the columns it set.

## [0.9.3] - 2026-11-04

**Security update.** A thorough review of Lyra's code against the claims made for it found the
defects below. None of them touches the gradual migration itself: the modes, the interception
of writes, the mapping of operations to events, the checked transitions between modes, and the
results that rest on them are unchanged. The defects are in the dashboard, the GDPR helpers, the
hand-over from PaperTrail and the operator tasks. Upgrade if the dashboard is open to anyone, or if
the Art. 15/20 export, the retention check, `lyra:erase` or the policy generator is used. PAM DSL
moves to 0.9.3 for its policy generator, and PetriFlow to 0.9.3 for the way it runs Graphviz
(below).

### Security
- **The dashboard resolves only monitored models.** The routes that take a model
  (`dashboard/compare`, `discrepancies`, `model_overview`, `audit_trail`, `model_heatmap`,
  `event_list`, `flow/event_chain`, `flow/visualization`) called `constantize` on the request
  parameter and returned the record's attributes. Any user the dashboard admitted could therefore
  read the rows of any Active Record model, monitored or not, including password digests and
  tokens. They now answer 404 for a model Lyra does not monitor. List sizes, day ranges and graph
  depth are clamped (`limit` at most 1,000, 500 or 100 by route, `days` at most 90, `depth` at most
  3). As before, the dashboard is closed outside development and test unless
  `config.dashboard_authorization` admits the request.
- **The Art. 15/20 export gathers the subject's data, not the subject's edits.**
  `Lyra::Privacy::GDPRCompliance` selected every event whose metadata named the subject as its
  *actor*. A staff member's export therefore held the records they had edited, which is other
  people's data, while a subject's own records written by staff could be missed. It now gathers
  the events of the subject's own record, of records that refer to the subject by foreign key
  (`<subject_type>_id`, e.g. `user_id`), and of events that name the subject explicitly. The
  dashboard's subject timeline does the same; who did what remains the `user_actions` view.
- **PetriFlow runs Graphviz without a shell.** `VerificationRunner` (its PNG, PDF and SVG
  images) and `Visualization::Graphviz#render` built a shell command from the report directory,
  the workflow's name, the output path and the layout, so a path or name with shell syntax in it
  would have run as a command. They now pass Graphviz its arguments one by one, and `render`
  accepts only Graphviz's layout engines (`Graphviz::LAYOUTS`) and plain format names. The
  values come from the developer, not from a request; a static analysis (Brakeman) flagged both.

### Fixed
- **PaperTrail is switched off per model, not per request.** Where Lyra takes over a write
  (Hijack and the event-sourcing modes), it set `PaperTrail.request.enabled = false`. That turned
  versioning off for every model for the rest of the request or job thread and never turned it
  back on, so writes to versioned models Lyra does not monitor lost their versions, with no event
  in their place. Lyra now calls `PaperTrail.request.disable_model` for the model it takes over.
- **The retention check reads the policies.** `GDPRCompliance#retention_compliance_check` ignored
  the policies' `retention` blocks in favour of hard-coded periods for models named Payment,
  Invoice, Student and Enrollment, and raised `TypeError` when `config.retention_policy` was a
  single duration such as `7.years`. It now takes each monitored model's period from its policy,
  over the configured default. `retention_compliance_with_policy` called a method that did not
  exist.
- **Erasures and mode switches name who made them.** `rake lyra:erase` passes `OPERATOR=` as
  `erased_by`, falling back to `LYRA_OPERATOR`, then the operating-system user and process; before,
  it recorded no one. Every mode switch records the same in a new `actor` column of
  `lyra_mode_transitions`, added on first use to an existing table, and logs it. A switch to
  Disabled turns purpose checks and the access log off, so it is now attributable.
- **Erasure is limited to personal fields.** `Lyra::Erasure.erase!` (and `lyra:erase FIELDS=`)
  erased any column it was named, rewriting history in place under an Art. 17 reason. It now
  refuses a column that neither the record's policy declares personal nor the events' privacy
  stamps list, unless called with `any_fields: true` (`ANY_FIELDS=1`).
- **Bulk writes lock the rows they write.** `update_all` and `delete_all` (and the writes routed
  through them: `update_counters`, `touch_all`, `delete_by`, `dependent: :delete_all`) took their
  snapshot with a plain read, so under READ COMMITTED a row another transaction changed or
  inserted between the snapshot and the write could be written without an event. They now lock
  the matched rows (`FOR UPDATE`, through a subquery of keys so DISTINCT and joins work) and write
  exactly those, inside a transaction in every mode that keeps tables. A failed append rolls back
  only its savepoint, so in Monitor the write still stands.
- **A destroyed record is not written again.** Two writers of one record, a destroy and an
  update, could both pass: the second found no row to lock, fell back to the advisory lock and
  appended after the Destroyed event, leaving a stream that brought the record back
  (`Lyra.state_at`, DualView). An update or destroy of a record whose stream ends in a destroy now
  raises `Lyra::RecordDestroyedError` (a `RecordNotFound`). To check it, ES-NoProj and ES-Lazy now
  take the lock on the aggregate for updates and destroys, as the other event-sourcing modes did.
- **PAM DSL 0.9.3: the policy generator no longer chooses legal bases.** It wrote one for each
  purpose it drafted: contract for billing, which tax law often makes a legal obligation;
  legitimate interests for analytics, which a public authority cannot use for its tasks; consent
  without a consent block. A drafted purpose now reads `basis :undetermined` with the usual
  candidate and its caveats as a comment. Access under it is refused
  (`PamDsl::UndeterminedBasisError`), and the Article 30 register lists it as a gap, until the
  controller decides.

### Documented
- **The dashboard is a development tool.** Opening it in production with
  `config.dashboard_authorization` is at the deployer's risk: whoever the rule admits reads every
  data subject's records and history, with no declared purpose and no access-log entry, and the
  rule covers the whole dashboard. What bringing it to production would take is listed in the
  README (Dashboard) as a future feature.

### Dependencies
- **The development lockfile is updated against published advisories** (bundler-audit,
  2026-11-04): `rack`, `nokogiri`, `loofah`, `rails-html-sanitizer`, `crass` and `sqlite3` (tests
  only). The gems' own dependency declarations are unchanged: none pins a vulnerable version, and
  an application resolves its own.

### Known limitations (unchanged)
- PAM DSL keeps consent records in memory, per process. Persistent consent storage is future
  work; an application that relies on consent must store it. Documented in the PAM DSL README
  ("Runtime consent store"), on `ConsentStore`, and in `docs/PRIVACY_COMPLIANCE.md`.

## [0.9.2] - 2026-11-03

One fix in Lyra; PAM DSL and PetriFlow are unchanged (0.9.1).

### Released
- `orfeas_lyra` on RubyGems, built from tag `v0.9.2` and pushed on 2026-11-03

### Fixed
- **ES-Async read-your-writes no longer races a projection job.** With read-your-writes
  (`each_write: true`), the writer projected its own event without the per-stream lock that
  `AsyncProjectionJob` holds. A job that had read the record's stream before that event
  committed could write the row afterwards, putting it back to the older value until the newer
  event's job ran: a reader in between saw the record step back (an application's suite, run
  with real background projection, read a refund as "approved" just after it was "processed").
  `Lyra::Consistency::ReadYourWrites` now takes the job's lock before projecting, held to the
  end of the writer's transaction. Final states converged before as well. Plain ES-Async (no
  read-your-writes) was not affected. `test/concurrent_same_record_test.rb` reproduces the
  interleaving.

## [0.9.1] - 2026-11-02

Lyra's changes since 0.9.0; PAM DSL and PetriFlow change only in their gem descriptions.

### Released
- The gems on RubyGems (`orfeas_lyra`, `orfeas_petri_flow`, `orfeas_pam_dsl`), built from tag
  `v0.9.1` and pushed on 2026-11-02

### Added
- **Writes are grouped into causal chains by default** (`config.correlate_writes`, on). Before,
  Lyra carried correlation and causation only where the application called
  `Lyra::Correlation.with_id`/`Lyra::Causation.with_id`, which no example did: every event was its
  own chain. Now:
  - every event-producing write runs in a write scope (`around_save`/`around_destroy`, first in
    the chain) that fixes its event id before its callbacks run, so a write made inside them
    records that event as its `causation_id`; a record saving itself inside its own callbacks is
    caused by the outer save;
  - the outermost write opens the correlation when none is in scope, its own event id, as the
    event store does for a root event;
  - `Lyra::Correlation::Middleware`, installed by the engine, gives the writes of one HTTP request
    one correlation, the request id; a correlation already in scope is kept;
  - `Lyra::Correlation::Job`, included into `ActiveJob::Base` by the engine, gives the writes of
    one job the correlation in scope where the job was created, or the job id without one, and a
    write in scope there as their cause. Both are taken when the job is created, so a job deferred
    to after the commit (`enqueue_after_transaction_commit`) keeps them, and travel in its payload
    (`lyra_correlation_id`, `lyra_causation_id`), so a retry does too. A job created inside a
    transaction and sent at once (the Rails default) could outlive a rollback of its cause; its
    cause is kept when it runs only if that event is in the log, so no job names a cause the log
    lacks (one that runs before the enqueuing transaction commits loses the link).
  Monitor, Hijack and event-sourcing events alike (`DomainEvents.build` takes the pre-assigned
  `event_id:`, given once per write). The Olist replay runs each step as one request would
  (`test/write_correlation_test.rb`).

### Changed
- **ORFEAS is expanded as the words its letters stand for**: Object-Relational Framework for
  Event-Aware Systems (README, `docs/ARCHITECTURE.md` and its citation, gem descriptions). It
  read "Object-Relational to Event-Sourcing Architecture", which has no F.

### Fixed
- **Writes that skip callbacks name who made them.** Events of `update_columns`, `touch`,
  `delete`, `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify`, and
  `has_and_belongs_to_many` links, carried correlation and causation but neither `user_id` nor
  `request_id`, so the same request's writes named a user only if they ran callbacks. They now
  take both from `Current`, as the documentation already said. Events written before this keep no
  actor; their correlation still ties them to the request's other writes.
- **`AsyncProjectionJob` warns again when its event is not in the log.** The warning sat in a
  rescue of `RubyEventStore::EventNotFound`, which `read.event` never raises (it returns nil;
  `read.event!` raises), so it was never logged. The job still did nothing for a missing event.

## [0.9.0] - 2026-10-25

Everything since 0.8.0, the version the PAM article describes.

### Released
- The gems on RubyGems (`orfeas_lyra`, `orfeas_petri_flow`, `orfeas_pam_dsl`), built from tag
  `v0.9.0` (2026-10-19); the entries marked *after the tag* are not in them
- The replication package: https://doi.org/10.5281/zenodo.17770613
- The benchmark results: https://doi.org/10.5281/zenodo.23640846

### Added
- **`config.models` takes namespace patterns, `:all` and a denylist** (`Lyra::ModelSelection`):
  `config.models = %w[Spree::* Order]`, `config.models = :all`,
  `config.models = :all, except: %w[Session]`. Patterns and `:all` enrol only eligible models
  (concrete, named, with a table and a single-column primary key, base classes of an STI
  hierarchy), after eager-loading the application's code. The event store's tables, Lyra's own and
  those of Solid Cache/Queue/Cable, Active Storage, Action Text, Action Mailbox and PaperTrail are
  never enrolled; naming one fails the boot. A pattern matching nothing warns; `:all` outside
  Monitor mode warns. On a Solidus application `:all` enrols 90 models, excludes 28 and leaves 48
  abstract classes and STI subclasses to their bases (`test/model_selection_test.rb`).
- **`ReadYourWrites.with_guaranteed_read(each_write: true)`**: each write in the block is projected
  as it is made, so reads later in the same block see it (by default the block projects when it
  ends). For code that writes and reads back in one unit of work, as Solidus's checkout does
  (a replay of 2,000 Olist orders through Solidus under ES-Async matched the oracle for 135 orders,
  and for 1,992, as plain ActiveRecord does, with each step in such a block).
  `test/projections/read_your_writes_async_test.rb`. The controller concern takes it per
  controller, inherited by subclasses, so an application is adapted from an initializer:
  `Spree::BaseController.include Lyra::Consistency::ControllerConcern` and
  `Spree::BaseController.lyra_read_your_writes each_write: true`
  (`test/consistency/controller_concern_test.rb`). `docs/API_REFERENCE.md` named the concern
  `ReadYourWrites::ControllerConcern`, which does not exist; it is `Consistency::ControllerConcern`.
- **`config.lock_aggregate_before_append`** (default `true`): Hijack, ES-Sync and ES-Async lock
  the aggregate before appending. Two writers of one record could append in one order and write the
  row in the other, leaving the row at a value its log does not replay to; seen in the wild, 2
  rounds of 120 with 8 threads on one record, and reproduced deterministically
  (`test/concurrent_same_record_test.rb`). An update or destroy now locks the record's row before
  its event is appended, held to the end of the transaction (assumption L of Theorem 5), in the
  strength the write takes anyway (PostgreSQL `FOR NO KEY UPDATE` for an update, `FOR UPDATE` for
  a destroy), so a write takes the locks plain ActiveRecord takes, in the same order, and adds no
  deadlock. A first version took an advisory lock on the stream before the row lock; it deadlocked
  against a writer that holds the row first (`record.lock!`, `with_lock`) and then updates it,
  where plain ActiveRecord only makes the update wait. The advisory lock remains for a record with
  no row. `test/aggregate_lock_deadlock_test.rb`: writes to several records in one order never
  deadlock, opposite orders deadlock exactly as plain ActiveRecord does, a row lock held first
  does not deadlock a plain writer. SQLite needs no lock: it serialises writers from the first
  write, which is the append (`test/sqlite_same_record_test.rb`). ES-Async writers take the
  advisory lock on the stream (they do not write the row, the projection job does, so they never
  wait for the row's lock); it makes a record's events commit in append order, which the job's
  checkpoint relies on (below). Creates, Monitor, ES-Lazy and ES-NoProj are unchanged
  (`test/aggregate_lock_statements_test.rb`). Cost: an update issues three more SQL statements
  (the lock, then the savepoint pair the append now needs), so Hijack and ES-Sync updates go from
  5 to 8 statements and ES-Async's from 4 to 7, and a destroy one more; on one contended record
  Hijack's throughput falls from about 90 to about 52 ops/s. Set `false` for the previous
  behaviour and its numbers.
- **ES-Async's projection job applies only the events after the stream's checkpoint**
  (`Lyra::Projections::AsyncCheckpoint`, table `lyra_async_checkpoints`, created on first use)
  instead of replaying the record's whole stream, so a record's jobs cost what its history is
  long, not its square. Exact because the lock above makes a record's commits follow its
  appends; with the lock off, or without a usable checkpoint (its event gone), the job replays
  the whole stream. A checkpoint older than the row only re-applies events the row already has,
  which is harmless (`test/projections/async_checkpoint_test.rb`).
- `test/projections/cached_projection_concurrency_test.rb`: readers and writers of one record under
  ES-NoProj see only states the stream had, never go back, and converge.
- **Reference links for ES-NoProj** (`Lyra::Projections::ReferenceLinks`, `config.reference_links`,
  default `:auto`). An event that sets a `belongs_to` foreign key is also linked into the stream
  `Model.foreign_key$value`, the way Rails Event Store links events by metadata. A lookup by that
  key, including the dependent-association lookups Active Record makes on destroy, reads the
  stream for candidates and keeps those whose current state still matches, so moved and destroyed
  children drop out and the answer is exact, without rebuilding every record of the model.
  `:auto` writes links in ES-NoProj only, so no other mode pays; `true` and `false` force it.
  Events stored while linking was off are linked before a model's first lookup in a process, from
  a checkpoint kept in the store (`$lyra_reference_links$Model`). On the Aegean testbed this made
  an ES-NoProj delete about 30 times faster at 16 threads and about 250 times at 64.
- **`config.monitor_append_failure`** (opt-in; default `:log`, unchanged). With `:fail_write`,
  Monitor fails a write whose event cannot be stored, raising `EventStoreUnavailableError` and
  rolling the write back (bulk writes included), as Hijack and the event-sourcing modes always
  do. Row and event already commit together; the setting decides only what a failed append
  does. Validated on assignment.
- **Trace conformance test** (`test/verification/trace_conformance_test.rb`). It records the
  steps Lyra takes on real writes in every mode (event built, applied to the aggregate, stored;
  row written; commit) and replays each trace token by token on a PetriFlow net: the paper's
  core net with the row write placed as each mode places it. Every trace must be a firing
  sequence ending in the net's final place, each operation must build exactly one event of its
  own type, and a trace in another order is rejected. It found that Hijack and the
  event-sourcing modes apply the event to the aggregate before storing it, the order the formal
  model now uses.
- **`LYRA_DISABLE_PETRI_FLOW=true`** — runs Lyra as without petri_flow, as
  `LYRA_DISABLE_PAM_DSL=true` does for PAM DSL.
- **`lyra:workflows:generate OUTPUT_DIR=... REPORTS_DIR=...`** — write the workflow files and
  the reports to other directories than `app/workflows/` and `reports/`.
- **Dashboard authorization** (`config.dashboard_authorization`) — a proc run on the engine's
  controller before every action (`instance_exec`, and given the controller when it takes an
  argument); truthy allows, falsy answers 403. Unset, the dashboard is open in development and
  test only and refused everywhere else with a log line, since its privacy pages show a data
  subject's personal data. Example: `->(controller) { controller.current_user&.admin? }`.
- **`mode=` and `projection_mode=` validate** — one of `Configuration::MODES` and the new
  `Configuration::PROJECTION_MODES`; a string is taken as its symbol, anything else raises
  `ArgumentError` naming the valid values.
- **`lyra:erase MAX_COPIES=n`** — passed to `Lyra::Erasure.erase!` as `max_copies:`; the task
  also prints how many values were left as shared.
- **The blog example runs again** (`examples/blog_app`) — rebuilt for Rails 8.1,
  RailsEventStore 3 and PostgreSQL, with `bin/setup` and a passing test suite.
- **ES-NoProj runs Solidus** — the Olist replay passes under `projection_mode :disabled`
  (6 of 6 orders end as Olist records them). Association queries (`variant.prices.find_by`,
  `.where`, `.find_or_create_by!`) run on the records the event store holds for the owner, and
  `:through`, polymorphic (`as:`) and scoped associations are read correctly: a `:through`
  association was filtered on a foreign key its target does not have. Calculations and plucks on
  an association (`payment.refunds.sum(:amount)`) read the events instead of the empty table.
  Building through an association or a `where` takes its conditions, as ActiveRecord's
  `scope_for_create` does. `CachedRelation` gains `group` with grouped `count`/`sum`/`average`/
  `minimum`/`maximum`, `extending`, class attributes (`discard_column`), records as condition
  values (mapped to their ids) and the relation readers ActiveRecord's calculations ask for.
- **Erasure driven by the policy, opt-in** (`Lyra::Retention`, `config.retention_executor`,
  `config.retention_anchors`, `bin/rails lyra:retention:apply [DRY_RUN=1] [MODELS=]`,
  `Lyra::RetentionJob`) — applies the policy's retention rules: for each monitored model with a
  rule, a record past its period gets the rule's `on_expiry` — `:anonymize` (Lyra::Erasure),
  `:hard_delete` (erase, then destroy through the write path), `:soft_delete` (`deleted_at` /
  `discarded_at` through the write path; skipped without one), `:archive` (skipped: no archive
  is named). Attributes with a shorter period of their own are erased first; rule conditions get
  the record; already-erased attributes are skipped, so runs are idempotent. The period runs
  from `created_at` or the column named per model. Off by default; a dry run works either way.
  The privacy interface gains `Policy#retention_rule`.
- **Erasure finds copies by value, and optionally everywhere** — `Lyra::Erasure` now also
  replaces an erased value wherever the record's events copy it under another name (a payload's
  `payer_email`). `everywhere: true` (`EVERYWHERE=1`) searches the whole log for the values:
  other records' events are scrubbed, their rows get the value replaced where they hold it, and
  each gets an `ErasureApplied`; `Result#copies` lists them. A value held by more than
  `max_copies` other records (default 10) is shared by many people, not a copy, and is left
  (`Result#shared_values` counts them): on the Olist replay a placeholder address shared by
  every customer took all 1,954 addresses with it. Only direct identifiers (the policy's email,
  phone, identifier, card, payment-token, IP, credential types) are searched for in other
  records: a name, city or postal code can be another customer's by coincidence (erasing one
  Olist customer's postal-code prefix took two other customers' addresses). Erasure writes rows with one `UPDATE` by id,
  so a record the application marks read-only (a Solidus address once an order uses it) is
  erased too.
- **Purpose-bound `pluck` and `pick`** — checked by the declared attributes they name (also
  inside SQL fragments), with the model (`"Registration$*"`) as subject, so a purpose whose
  consent the policy requires refuses them.
- **Purpose-bound reads** (`Lyra::PurposeBoundReads`, `Lyra.with_purpose`, `lyra_purpose` for
  controllers and jobs, `config.reads_without_purpose`) — a read of a monitored model with a
  privacy policy, made within a declared purpose, is checked through the policy's
  `validate_access!` with the record as subject: every declared attribute the query loaded must be
  allowed for the purpose, so loading more than the purpose needs is refused (data minimisation).
  No setting turns it on: the purpose does. Reads with no purpose follow
  `config.reads_without_purpose`: `:allow` (default), `:audit` (logged, and recorded as an audited
  access with purpose `none` when the access log is on) or `:deny` (`PurposeRequiredError`).
  Lyra's own reads (projections, bypass snapshots, Genesis, DualView, mode checks, repair,
  erasure) are exempt; reads that load no model are not checked. Every monitored model gains an
  `after_find`, which returns at once when no purpose is in scope and reads without one are
  allowed.
- **Erasure executor** (`Lyra::Erasure.erase!`, `bin/rails lyra:erase MODEL= ID= REASON=
  [FIELDS=]`, `Lyra::Events::ErasureApplied`) — erases one record's personal attributes (declared
  by its policy or listed by its events' privacy stamps, or exactly `fields:`) from the row and
  from every event in its stream, overwriting each event in place (same id, position, time):
  attributes, both sides of each change, and payload keys with the attribute's name. Appends
  `ErasureApplied` (fields, reason, who; never a value), which replay skips; the stream still
  replays to the anonymized row. Replacement is nil where allowed, `"erased:<id>"` for a NOT NULL
  string, else the column default. Works in every mode, with strict data access on and inside a
  purpose. On request only; not policy-driven, and crypto-shredding remains future work.
- **Event store failure policies, named** (`Lyra::EventStoreUnavailableError`, `Lyra.append_events`;
  FEATURE_GAP_PLAN F1) — every event Lyra writes now goes through `Lyra.append_events`, which
  raises `EventStoreUnavailableError` (the store's error as its `cause`, the stream in its message)
  when the store fails. The policy is fixed by the mode: **fail-closed** in Hijack and every
  event-sourcing mode (the write fails with the error and rolls back), **log-and-continue** in
  Monitor (the write stands; the log line names the stream and points to `lyra:repair`). No
  in-memory retry queue: the store shares the application's database, a queue dies with its
  process, and a retried event could land behind a later one in its stream.
- **Repair after lost events** (`Lyra::Repair`, `bin/rails lyra:repair [DRY_RUN=1] [MODELS=...]`) —
  brings the event log back in line with the tables after Monitor lost events: an `Imported` event
  for a row with no events (or one its stream says was destroyed), an `Updated` event with the
  differing columns for a row that differs from its events, a `Destroyed` event for events with no
  row. Each record is re-checked and repaired under a lock on its row; repair events carry
  metadata `source: "lyra_repair"` and the problem repaired. Refused in Hijack and event sourcing,
  where the events are authoritative (rebuild the tables instead). `ModeTransition.record_ids` and
  `ModeTransition.discrepancy` expose the check it uses.
- **Access log** (`config.record_access_events`, default false; `Lyra::AccessLog`,
  `Lyra::Events::DataAccessed`, `Lyra::Events::DataAccessDenied`; FEATURE_GAP_PLAN F6) — when on,
  every access the privacy policy validates (`validate_access!`) is recorded in the subject's
  access stream (`Lyra::DataAccess$<Model>$<id>`): `DataAccessed` when it went ahead (outcome
  `granted`, or `audited` with the violations audit mode let through), `DataAccessDenied` when
  strict mode refused it. Each carries the policy, purpose, legal basis, field names (never
  values) and outcome. Who accessed goes in the metadata: `user_id` and `ip_address` from the
  application's `Current.user` / `Current.ip_address`, request and correlation ids, and whatever
  `config.access_metadata_proc` returns for the access (for consoles, jobs and API tokens that
  `Current` does not know; a failing proc is logged and skipped). Every access is
  recorded, with no sampling; an access the store cannot record does not go ahead. Nothing is
  recorded in disabled mode, and the record's own stream is untouched. `AccessLog.for(subject)`
  reads them back. Off by default because reads can outnumber writes by orders of magnitude; the
  Aegean testbed turns it on with `LYRA_RECORD_ACCESS=1`, which also makes the benchmark's reads
  validate access, and records it in its benchmark reports. The Article 30 register stays
  PAM's `article_30_report`, generated from the declared policy.
- **Privacy stamps on events** (`config.annotate_privacy`, default false; `Lyra::Privacy.stamp`,
  `Lyra::Privacy.stamp_of`; FEATURE_GAP_PLAN F5) — when on, every event that carries an
  attribute the model's privacy policy declares is stamped as it is built with
  `metadata[:privacy]`: the policy's name and, per attribute, its type, sensitivity, allowed
  purposes, retention period (ISO 8601) and the contexts it has a transformation for — never a
  value. Every declared attribute the event carries is annotated: a create's, import's or
  destroy's attributes, and an update's changes together with the whole row Monitor also records
  (annotating only the changes left 28,374 of an Olist replay's events carrying personal data
  unannotated). All four places events are built stamp them: Monitor, the command handler (Hijack,
  event sourcing, and so domain events), bypass events and Genesis imports. The stamp records the
  policy as it was when the data was written, unlike `annotations_for`, which reads today's
  policy; `stamp_of(event)` reads it back with string keys. Off by default because it adds work
  to every write (no SQL statements); the Aegean testbed turns it on with
  `LYRA_ANNOTATE_PRIVACY=1` and records it in its benchmark reports. The privacy `Annotation`
  gains a `transformations` member.
- **ModeSync: one mode per application** (`Lyra::ModeSync`, `config.mode_sync`,
  `config.mode_sync_interval`) — the latest switch recorded in `lyra_mode_transitions` is the
  application's mode; every process adopts a newer one within `mode_sync_interval` seconds
  (default 5), checking before each web request (Rack middleware), each background job and each
  write to a monitored model, never inside an open transaction. A runtime switch
  (`ModeTransition.to!`) used to change only the process that made it. `to!` now logs what the
  switch reaches. On wherever the Mode Transition Safety gate is (not in the test environment);
  the raw `config.mode =` setter is left alone. the migration guide (`docs/MIGRATION_GUIDE.md`, Switching modes) documents the
  deploy-time rule.
- **Mode Transition Safety** (`Lyra::ModeTransition`, `rake lyra:mode:check`; FEATURE_GAP_PLAN F3)
  — a mode switch that changes the authoritative store is allowed only when rows and events
  agree for every monitored record: escalating from Disabled or Monitor to Hijack or event
  sourcing (rows that predate Lyra are imported by Genesis first), and leaving ES-NoProj,
  ES-Lazy or ES-Async for a mode that reads tables (`rebuild: true` rebuilds them first). The
  check compares every row and every stream in batches, reading the real table, then
  re-checks what changed while it ran, and stores a clean result as a certificate.
  `ModeTransition.to!` and the `enable_*!` helpers accept a fresh certificate after
  re-checking only what changed since, else run the full check, and raise `Refused` with the
  discrepancies; `force: true` overrides. At boot, a switch from the mode the application last
  ran in needs a certificate (`LYRA_FORCE_MODE_TRANSITION=1` overrides; rake processes are
  exempt). `config.mode_transition_gate`: nil (default) gates everywhere but the test
  environment; `config.mode = ...` stays the raw, ungated setter.
- **Sampled DualView verification** (`config.dual_view_sample_rate`, default 0.0, off;
  `config.dual_view_discrepancy_handler`) — after a write commits, a sampled share of writes
  is compared with its events; a discrepancy is logged and passed to the handler, and the write
  is never failed. Skipped in ES-NoProj, ES-Lazy and ES-Async, whose tables lag by design.
- **Domain events** (`monitor_with_lyra domain_events: [...]`, `Lyra::DomainEvents`;
  FEATURE_GAP_PLAN F8) — rules name a write's event after what it means instead of the CRUD
  operation: `{ name: "PaymentCompleted", on: %i[create update], if: ->(payment, changes) { ... } }`.
  The first matching rule names the write's own event, which keeps Lyra's envelope (model, id,
  operation, attributes, changes), so replay, projections, DualView and `Lyra.state_at` work
  unchanged; a write no rule matches keeps its CRUD event. `payload:` adds fields for the
  event's consumers under `data[:payload]`; `class:` uses an event class of your own (a
  `RubyEventStore::Event` subclass) instead of a generated `Lyra::Events::<name>`;
  `also: true` emits an additional event from the same write, in the same stream and
  transaction, marked `replay: false` and pointing to the write's own event through its
  `causation_id`. Works in Monitor, Hijack and every event-sourcing mode; writes that skip
  callbacks are still recorded as CRUD bypass events. Generated event classes are registered
  at boot. A rule whose block raises fails the write where events are the record (Hijack,
  event sourcing) and is logged in Monitor. Commands now carry their `record`.
- **Configuration surface** (FEATURE_GAP_PLAN F2): `config.models = %w[Order Payment]` (or a
  hash of name => options) declares the monitored models by name in the initializer; once the
  application's code has loaded, each is given `monitor_with_lyra`, with no model file edited,
  and a name that does not resolve fails the boot. `config.verify_mapping!` verifies the
  CRUD-to-event mapping at boot (`Lyra.verify_mapping!`: the PetriFlow lifecycle, mode and
  bypass nets through `CrudVerifier`, and a table and primary key for every monitored model)
  and stops the boot with `Lyra::MappingVerificationError` naming each failed check; called
  after boot it runs at once. `config.privacy_policy = :name` is the default policy for
  monitored models that name none of their own.
- **Point-in-time reconstruction** (`Lyra.state_at(model, id, time)`, `Model.as_of(time)`,
  `Lyra::Temporal`) — a record's attributes at a given time, rebuilt by replaying its stream up
  to the last event stored at or before then: `nil` if it did not exist yet or had been
  destroyed. `Model.as_of(time).find(id)` / `.find_by_id(id)` return read-only records and
  `.all` every record that existed then. For a row imported by Genesis, a time before its
  import raises `Lyra::Temporal::HistoryNotRecorded` instead of guessing (a time before its own
  `created_at` is `nil`). Works in every mode that records events, Monitor included
  (FEATURE_GAP_PLAN F7).
- **ES-NoProj joins, evaluated in memory** (`Lyra::Projections::CachedJoins`) — `joins`,
  `left_joins`/`left_outer_joins`, `where.missing` and `where.associated` on `belongs_to`,
  `has_many` and `has_one` associations, with hash conditions on the joined table
  (`where(programs: { available: true })`, by table or association name), used to raise
  `UnsupportedQuery`. They are now evaluated as SQL would: a joined relation holds rows of a
  record and its partners; an inner join drops records without a partner; a `has_many` join
  repeats the record per partner (so `count` agrees, and `distinct` removes the repeats); a
  missing left-join partner behaves like NULL, including under `where.not`. Partners come from
  the joined model's streams if it is an ES-NoProj model, otherwise from one SQL query on its
  table. Still refused: SQL-string, nested, `:through`, polymorphic and scoped joins, a
  condition on a table not joined first, and `merge` with an arbitrary relation (so Solidus
  still needs ES-Lazy). `where` with no arguments now returns the where-chain, as in
  ActiveRecord.
- **Privacy provider interface** (`Lyra::Privacy`) — `Policy` (declared attributes and their
  `Annotation`s), `Detector` (name-based PII heuristic) and `Provider`, with null defaults when
  no provider is installed. PAM is an adapter (`Lyra::Privacy::Adapters::Pam`), loaded when
  `pam_dsl` is present. `Lyra::Privacy.annotations_for(event)` returns the annotation of every
  declared attribute an event touched. The foundation for `config.privacy_policy=` and PII
  annotation in event metadata (`FEATURE_GAP_PLAN.md`, F2 and F5). From `thesis-restructure`
  (1adadfe); the testbed binds `Registration` and `PaymentTransaction` to its `:epay_data`
  policy (d0df542), which adds nothing to the write path.
- **`Lyra::IdGenerator.reserves_safely?(model)`** — true for UUID keys and for integer keys
  backed by a PostgreSQL sequence. It uses the cached sequence lookup, so it adds no query per
  write once a table's sequence is known.
- **Bypass events for bulk writes** (`Lyra::BypassEvents`) — `update_all`, `delete_all`,
  `insert`/`insert_all(!)`, `upsert`/`upsert_all` and `dependent: :nullify` on a monitored model
  now publish one event per affected row, whatever the `strict_data_access` setting
  (`update_column(s)`, `touch` and `delete` already did). `update_all` publishes "updated" per
  row that changed; `delete_all` "destroyed" per row; inserts "created" per row; `upsert_all`
  finds existing rows by its conflict key (primary key, `unique_by:` columns or index name) and
  publishes "updated" for those, "created" for the rest. The caller's `returning:` result is
  unchanged. Brought over from the `thesis-restructure` branch (3ba39bb, 975dc6e), keeping
  master's instance methods (events built after the write).
- **`Lyra.projection_write { ... }`** — Lyra's own read-model writes: skips strict data access
  and publishes no bypass events. `ModelProjection` and `Rebuild` use it; use it for writes that
  must not reach the event stream, such as seeding or wiping a table.
- **Genesis: event streams for rows that predate Lyra** (`Lyra::Genesis`,
  `config.genesis`, `rake lyra:genesis`) — a row written before Lyra was enabled had no
  stream, so its first `Updated` event started a stream with no head, and DualView,
  `Rebuild` and ES-NoProj reads saw the record wrongly or not at all. On a model's first
  use in a process (its first write, or in ES-NoProj its first read or aggregate), every
  row without a stream now gets one `Imported` event holding the row as it is. `Imported`
  is replayed like `Created` everywhere state is rebuilt. Later uses cost nothing; when
  every row already has a stream the check is one query and takes no lock. The import
  runs under a per-model advisory lock on a connection of its own, so a long caller
  transaction does not block other first uses and a caller's rollback does not undo it.
  `config.genesis`: `:auto` (default, event-sourcing mode only), `true` (also Monitor and
  Hijack) or `false`. `rake lyra:genesis MODEL=...` imports ahead of time for large tables.
- **ES-NoProj SQL aggregates computed from streams only, with SQL semantics** —
  `count(column)`, `sum`, `average`, `minimum`, `maximum` and `calculate` on an ES-NoProj
  relation run over the records rebuilt from streams (rows that predate Lyra included, via
  Genesis). `sum` used to go through `to_f` (losing decimal precision) and now keeps the
  column's type, returning 0 over no rows; `average` returns a `BigDecimal` for integer and
  decimal columns, as ActiveRecord does; `count(column)` counts non-NULL values, where it
  used `present?` and dropped `""` and `false`. An SQL expression (`sum("price * qty")`)
  raises `UnsupportedQuery` instead of being guessed. Known difference: `average` keeps
  every digit of the quotient, while PostgreSQL rounds a numeric `AVG` to about 16
  significant digits.
- **ES-Lazy: event sourcing that projects on read** (`projection_mode :lazy`, in
  event-sourcing mode; `Lyra::Projections::LazyProjection`, `Lyra::Interceptors::LazyReads`)
  — writes store events only, as in ES-NoProj; before any database read, the tables are
  brought up to date from the event log, and the read runs as real SQL, so joins, merged
  relations, SQL fragments and aggregates all work. The log stays the only source of
  truth; the tables are a cache that `Rebuild` can recreate. Events are applied in the
  log's global order under a PostgreSQL advisory lock, against a checkpoint that also
  tracks ids still in flight (filled by replaying the record when they commit, forgotten
  after 5 minutes). Read-your-writes consistent. Needs no migration: the checkpoint table
  is created on first use. It runs Solidus, which ES-NoProj cannot: on 20 real Olist
  orders it matches plain ActiveRecord with DualView clean. Cost: every read first checks
  the log (about half ES-Sync's throughput in the replays).
- **`Lyra::EventSerializer`** — a JSON serializer for RailsEventStore that keeps time
  precision. Ruby's `JSON` writes `Time` with `Time#to_s`, dropping fractional seconds, so
  apps passing `serializer: JSON` stored `09:51:15.304` as `"09:51:15 UTC"`, and an update
  from `.304` to `.352` as no change at all. `Lyra::EventSerializer` writes times as ISO 8601
  with microseconds and `BigDecimal` as its exact decimal string; `load` is plain
  `JSON.parse`. Opt in with
  `EventRepository.new(serializer: Lyra::EventSerializer)`. Lyra's default client (RES's
  YAML serializer) was not affected. Found by replaying the BPI Challenge 2017 log
  (`examples/bpi2017_loan_app`), whose timestamps carry milliseconds.
### Changed
- **Documentation** (*after the tag*) — `docs/PERFORMANCE.md` gives the 0.9.0 measurement (three runs, with
  controls for PaperTrail and for the lock on the aggregate), the SQL statements per write under the
  lock, and the published runs (https://doi.org/10.5281/zenodo.23640846); the install instructions
  take the gems from RubyGems (`"~> 0.9"`); the case studies, benchmark harness and formal-model
  scripts are referred to as the replication package (https://doi.org/10.5281/zenodo.17770613).
  Comments no longer cite issue numbers; `lib/` changes in comments only.
- **The Rakefile's testbed tasks** (*after the tag*) say where the testbed is when it is absent, and `stats:all`
  skips it.
- **ES-NoProj reads**: a stale cache entry is brought up to date from the events after its stamp
  instead of a full replay; cache entries have a process-local copy in front of the shared cache;
  an association's records are read when first needed, and a reference-link lookup intersects
  every indexed key and takes candidate ids from the stream table; `Model.new` reads no record.
  A replay of 640 Olist orders through Solidus took 855 s where it took 2,229 s, with the same
  end state.
- **`ModeTransition.to!` links before switching into ES-NoProj.** Entering `event_sourcing`
  with `projection_mode: :disabled` first runs a full reference-link pass over the monitored
  models, so lookups are complete from the first one.
- **Documentation regrouped.** `docs/ADOPTION.md` and `docs/MODE_TRANSITIONS.md` are now
  sections of `docs/MIGRATION_GUIDE.md` (Adopting Lyra in an existing application; Switching
  modes); `docs/ORFEAS_FRAMEWORK_OVERVIEW.md` is the opening of `docs/ARCHITECTURE.md` (About
  ORFEAS); `docs/PROJECTIONS_DATA_ACCESS_MONITORING.md` is split between `ARCHITECTURE.md`
  (projections, write-side monitoring) and `docs/PRIVACY_COMPLIANCE.md` (read-side monitoring).
  Claims were checked against the code on the way. `docs/PERFORMANCE.md` no longer presents the
  withdrawn July 2026 figures: it explains each mode's cost in SQL statements per write, and
  the throughput is being re-measured.
- **The workflow generator's mode nets name what Lyra does.** Their steps were labelled with
  methods that do not exist (`CommandHandler.validate`, `CommandHandler.execute`,
  `Projection.apply`, `EventStore.append_to_stream`) or with `Aggregate.apply(command)`, and
  the Monitor net called the event store through `Lyra::Event.publish`. Each step now names the
  method Lyra calls, in the order the trace conformance test observes; the generator no longer
  claims to introspect the implementation (the mode nets are written by hand). The shipped
  `app/workflows/*_mode_workflow.rb` files are regenerated.
- **Ruby 4.0 or later is required** (`required_ruby_version >= 4.0`, was `>= 3.4.5`); CI tests
  Ruby 4.0. The project runs 4.0.7.
- **Article 30 register (PAM)** — `pam_dsl:report:article_30` states only what the policy declares (data subjects, recipients, transfers, security measures) and lists the rest as not declared; see `gems/pam_dsl/CHANGELOG.md`.
- **PII detection (PAM)** — Lyra's detector fallback (`Lyra::Privacy::PIIDetector`, `PolicyIntegration`) uses PAM's merged dictionary: more personal columns found (street, postal code, IP columns, card digits, account tokens), foreign keys and generic `*_name` columns no longer flagged. See `gems/pam_dsl/CHANGELOG.md`.
- **Hijack fails a write whose event cannot be stored with `EventStoreUnavailableError`**, as event
  sourcing does, instead of a refused save (`save` returning false with the store's message on
  `errors[:base]`). A store failure is not a validation error; `save` now raises it, as it raises
  database errors.
- **ES-Async can run out of line in tests** — `async_projections_inline` now decides: unset
  (the new default, `nil`) projects inline in the test environment only, as before; `true`
  always; `false` never, so a test with an `:async` job adapter exercises the real background
  path. The test environment used to force inline projection whatever the setting said, so no
  test could run ES-Async as it runs in production. `Configuration#async_projections_inline?`
  gives the effective value.
- **ES-NoProj cache: entries stamped with their stream's last event** (`CachedProjection`) — each
  record's cached rebuild carries the id of the last event it was built from and is used only
  while that is still the stream's last event, so it is exactly right or detectably out of date.
  Collection reads (`all`, `where`, `find_by` on non-key attributes, `count`) are assembled from
  those entries: one query for every stream's last event, one bulk cache read, and a replay of
  only the streams that changed. They used to be cached as whole collections that every write
  threw away, so after any write the next collection read replayed every stream of the model.
  A `dependent: :nullify` delete, which must find the children by attribute, cost 1.7-3.5 s in
  the Aegean smoke runs; it now costs 0.1-0.4 s (that cell: 10-16 → 49-101 ops/s). ES-NoProj
  SQL statements per write: 12 → 11 per create, 9 → 8 per update (a write no longer deletes
  collection keys; it reads its stream's last event). Cache entries are versioned `v2`; old
  ones are ignored.
- **`Lyra.privacy_features_available?`** asks the installed privacy provider instead of
  checking for `pam_dsl` directly. `PIIDetector` and `PolicyIntegration` load always and work
  through the interface; `PIIMasker` and `GDPRCompliance` stay PAM-only.
- **Hijack creates reserve an id only where it cannot collide** (`reserves_safely?`). Elsewhere
  (an integer key without a PostgreSQL sequence, e.g. SQLite or MySQL) hijack falls back to the
  `pending-<hex>` placeholder with a one-time warning, rather than guessing an id the database
  may also hand out. On PostgreSQL nothing changes, and SQL statements per write are unchanged
  in every mode.
- **Bulk writes on monitored models publish events** (see Added). Code that relied on
  `update_all`/`delete_all`/`insert_all` leaving the event stream untouched should wrap them in
  `Lyra.projection_write`. Bulk-write guards are on `ActiveRecord::Relation`
  (`Lyra::StrictDataAccessRelation`); `Lyra::StrictDataAccessClassMethods` is removed.
- **ES-NoProj bulk writes are events.** With projections disabled the records exist only in
  the stream, so `CachedRelation#delete_all`/`update_all` publish the events that are the write
  (a `delete_all`d record used to reappear on the next read). `upsert_all` raises
  `ArgumentError` there: its `ON CONFLICT` would check the table, not the stream. Cost: a
  `dependent: :nullify` delete must find the children, which in ES-NoProj rebuilds every stream
  of the child model.
- Instance bypass events (`update_column(s)`, `touch`, `delete`) go through
  `BypassEvents.publish`, which also invalidates the ES-NoProj read cache.
- **ES-NoProj answers exactly or raises** (`Lyra::Projections::CachedRelation`, new
  `Lyra::Projections::UnsupportedQuery`) — reading from the event store, `CachedRelation`
  used to answer queries it could not evaluate anyway, with the wrong records: a
  SQL-string `where` kept every record, unrecognised conditions (`!=`, ranges written as
  SQL, ORs) were dropped, `joins` and `where.missing`/`where.associated` were ignored, a
  condition on an unknown column matched nothing, and a scope that failed, carried
  `order`/`limit`/`group` and the like, or was not a scope at all, returned the whole set.
  Each now raises `UnsupportedQuery`, naming the query and the alternatives. Hash
  conditions, ordering, limits, loading hints and scopes made of hash conditions work as
  before. This found the Aegean benchmark's own cleanup, `where("email LIKE ?")` under
  ES-NoProj, silently matching every registration.
- **RailsEventStore 3** — `lyra.gemspec` now requires `rails_event_store ~> 3.0` (3.2.0 in the
  lockfile), on Ruby 4.0.7 and Rails 8.1.4 (8.1.3.1 and RES 3.1.0 until 2026-10-19). RES 3 moved
  the ActiveRecord repository to
  `RubyEventStore::ActiveRecord::EventRepository` and the event base class and errors to
  `RubyEventStore`; `Lyra::Event`, `Lyra::Aggregate` and the default client follow. Apps
  that build their own client must switch from `RailsEventStoreActiveRecord::EventRepository`.
- **`IdGenerator` caches the PostgreSQL sequence name** — `pg_get_serial_sequence` ran on
  every reserved ID, a round trip whose answer never changes. Since hijack mode now reserves
  its IDs here too, that was one extra SQL statement on every hijack-mode create (two
  instead of one). The name is now looked up once per table and cached; only `nextval`
  runs per ID.

### Removed
Dead code, none of it on the write path. Initializers that set `config.event_backend`, or models
that pass `command_handler:`, must drop it: the former now raises `NoMethodError`, the latter is
ignored like any unknown option.
- **`Lyra::EventMapper` and `Lyra::AuditMapper`** (`lib/lyra/event_mapper.rb`). The interceptor
  and the command handler build their events themselves (`CrudInterceptor#publish_event`,
  `CommandHandler#create_event`, both through `Lyra::DomainEvents.build`); nothing called the
  mappers.
- **`Lyra::EventStoreAdapter`, `RailsEventStoreAdapter`, `CustomEventStoreAdapter` and
  `config.event_backend`**, read only by `EventStoreAdapter.build`. Lyra uses the RailsEventStore
  client in `config.event_store` directly; `Lyra.append_events` and `EventStoreUnavailableError`
  stay.
- **The `command_handler` model option** (`monitor_with_lyra command_handler:`,
  `ModelConfiguration#command_handler`) and its dashboard line. It was stored and shown, but the
  write path always uses `Lyra::CommandHandler`.

### Fixed
- **`trace_conformance_test.rb` on a fresh database** (*after the tag*) — the recorder took the commit of Lyra's own
  checkpoint table, created on a connection of its own, for part of the write; it now records only
  the write's connection. Test only.
- **A thread that wrote through Lyra kept a database connection until it ended.** Lyra
  called `Model.connection` (Rails' `lease_connection`) in its write, lock and read paths: the
  aggregate lock, the id generator, Genesis, ES-Async's job, ES-NoProj's cache and reference links,
  ES-Lazy's catch-up, and its maintenance calls (DualView, Rebuild, mode checks, erasure). Since
  Rails 7.2 that keeps the connection for the thread, even inside `with_connection`, which then does
  not return it. So in Hijack and every event-sourcing mode, a thread of the application's own (a
  job runner, a worker pool) ended still holding one, and the pool got it back only by reaping: the
  first thread to find the pool full reset every dead thread's connection, one by one, while the
  others waited. In the benchmark's 64-thread cells such a wait now and then passed the 5 s checkout
  timeout (0.3 to 3 operations per trial of 12,800 in Hijack, Hijack+PT and ES-Sync; part of
  ES-NoProj's 14 to 18), and the contention benchmark reset each round's connections inside its
  timed window. Lyra now uses `with_connection` throughout: inside a transaction it is the
  transaction's own connection, outside one it is returned after use. `OwnConnection`'s thread
  returns whatever its work leased. `test/connection_release_test.rb`: in every mode, a thread that
  writes and reads, bare or in `with_connection`, ends without a connection, and `lib/` has no
  `Model.connection` call left.
- **Genesis and the reference-link catch-up assumed a second connection.** Inside an open
  transaction both ran their work on a thread that checked out a connection of its own and waited
  for it. Under Rails' transactional tests the pool's connection is pinned, every checkout returns
  the caller's own, locked connection, and the wait never ended: the Aegean testbed suite in
  ES-NoProj deadlocked at its first indexed lookup. Under load each caller took a second
  connection, and at 64 threads the pool ran out (5 s checkout timeouts, about 0.1% of ES-NoProj's
  operations in the benchmark's 64-thread cells). `Lyra::OwnConnection` now runs such work: on a
  connection of its own when one can be had, otherwise inline in the caller's transaction, with
  the model recorded as linked or imported only once that transaction commits (after a rollback
  the work runs again on the next use). The catch-up runs once per model and process; concurrent
  first lookups wait for it without a second connection. `test/projections/reference_links_test.rb`:
  a pinned connection, and concurrent first lookups inside transactions.
- **`has_and_belongs_to_many` links were not recorded.** The join table has no model of its own
  (Active Record writes it through an anonymous class), so `item.tags << tag` wrote the join row
  and no event recorded it: a rebuild lost the association and DualView did not compare it. Every
  insert into and delete from a HABTM join table is now an `AssociationLinked` or
  `AssociationUnlinked` event on the owner's stream, linked into each monitored associated
  record's stream (`Lyra::Associations::HabtmLinks`), in every mode. DualView compares each HABTM
  association's links with the join table, `Rebuild` restores join tables from the events, and
  Genesis records the links pre-existing rows had. Under ES-NoProj, HABTM writes failed before
  reaching Lyra (`CachedRelation` lacked `where_values_hash`); they now work and read back
  (`test/habtm_links_test.rb`, every mode).
- **Optimistic locking: a stale update silently won under event sourcing.** Active Record checks
  `lock_version` in the UPDATE or DELETE that writes the row; ES-Sync, ES-Async, ES-NoProj and
  ES-Lazy skip that statement, so a stale `update` or `destroy` overwrote the newer write (a lost
  update), and `touch` raised `StaleObjectError` on every call under ES-NoProj, where no row
  matches. No mode's events recorded the version's increment, so the log replayed to a
  `lock_version` the row did not have (DualView: `lock_version: { crud: 1, event_sourced: 0 }`).
  Every write's event now records the increment, `touch` included; the event-sourcing modes check
  the version against the log before appending, under the lock on the aggregate (taken for such a
  model in every event-sourcing mode), and raise `ActiveRecord::StaleObjectError` as Active Record
  does (`Lyra::OptimisticLocking`). A record that expects a newer version than the log's passes,
  so streams written before the change keep working (`test/optimistic_locking_test.rb`, every
  mode, concurrent writers included).
- **Encrypted attributes (Active Record `encrypts`) reached the event log in clear** while their
  row held ciphertext: events are built from attributes Active Record has already decrypted.
  `Lyra.append_events`, through which every event passes, now stores those attributes' values (in
  `attributes` and `changes`) as the ciphertext Active Record writes to the column
  (`Lyra::EncryptedAttributes`); projections, rebuilds and DualView decrypt them, and records
  instantiated from events are decrypted by Active Record. Events written before keep their clear
  values and still read; rows written from them are encrypted. No mode leaks the value, no value is
  encrypted twice (`test/encrypted_attributes_test.rb`).
- **ES-Lazy stopped projecting after the event store was emptied or restored without its
  checkpoint table**: the checkpoint then lay past the newest event, and every new event looked
  applied. A checkpoint past the newest event is now recognised, warned about and reset (applying
  is idempotent). It made two tests fail in some orders, since the test suite reloads the event
  tables but not the checkpoint table (`test/projections/lazy_projection_test.rb`).
- **Single-table inheritance: a record's events were filed under its concrete class's stream**
  (`Spree::Calculator::Shipping::FlatRate$1`), and anything given the base class read
  `Spree::Calculator$1` and found none: DualView reported the row as missing from the log, and
  under ES-NoProj, ES-Lazy or a rebuild the base class saw an empty stream. A record's stream is
  now named after the class that owns the table (`Lyra.stream_name`, `Lyra.stream_prefix`), at
  every one of the 21 places that built it; reference links and Lyra's caches follow the table.
  Under ES-NoProj a subclass reads only its own records and its subclasses', as ActiveRecord's
  type condition does; events naming a subclass of a monitored model resolve to it
  (`Configuration#monitored_model_named`, used by ES-Lazy's catch-up and erasure). Event types
  still name the concrete class. **Upgrade**: `bin/rails lyra:streams:migrate_sti`
  (`Lyra::StiStreamMigration`) links events written before into the base streams, once; it
  reports a base stream that already holds newer events instead of linking out of order
  (`test/sti_streams_test.rb`, every mode).
- **ES-Async projected inline could leave the row behind the log.** With
  `async_projections_inline` (the test environment's default) a write applied only its own event,
  inside its transaction and under no lock: of two writers of one record, the one that projected
  last could leave the row at its older value. Inline now runs what `AsyncProjectionJob` runs, in
  the writer's thread once its transaction has committed, under the per-stream lock. The job path
  was not affected (`test/concurrent_same_record_test.rb`).
- **ES-NoProj: a named scope called on an association was ignored** (`order.payments.completed`
  returned every payment) and its body loaded every record of the model; records an association
  loaded did not point back at their owner instance.
- **Documentation: `ReadYourWrites` projects a block's writes when the block ends**, so a read
  after the block sees them and a read inside it does not; `docs/API_REFERENCE.md` said or
  implied the latter.
- **ES-Lazy: concurrent first reads no longer fail creating the checkpoint table.** Two threads
  that both found `lyra_projection_checkpoints` missing both created it, and the second `CREATE`
  failed the write that triggered it (one write of the full BPI 2017 replay at two threads).
  `Lyra.create_own_table` now defines the table in one transaction and ignores a failed create
  once the table exists.
- **Leaving ES-Lazy skipped its catch-up** — `ModeTransition.to!` from `event_sourcing/lazy`
  calls `LazyProjection.catch_up!(force: true)`. Without `force:`, `catch_up!` returns 0 outside
  ES-Lazy, and the mode had already changed by the time the transition ran it, so the tables
  could be left behind the log.
- **Locks on databases other than PostgreSQL** — Genesis, ES-Lazy catch-up and ES-Async
  projection take their transaction-level advisory lock through `Lyra::AdvisoryLock.xact_lock`.
  On SQLite (which serialises writers) it does nothing; on other adapters it logs once per
  purpose that the step runs unlocked and is safe in a single process only. Before, those
  adapters ran unlocked silently.
- **`upsert_all` under ES-NoProj raised `ArgumentError`**; it now raises
  `Lyra::Projections::UnsupportedQuery`, like every other query ES-NoProj cannot answer, naming
  the reason (the `ON CONFLICT` check runs against the table, not the event stream) and the
  per-record alternative.
- **`DualView` reported a record for a stream of only `replay: false` events** — such a stream
  describes no record, so `exists` is now false.
- **`lyra.rb` required ActiveRecord and ActiveJob implicitly**, relying on the host to load them
  first; loading the gem after only `require "rails"` raised `NameError`. It now requires both.
- **`Lyra::Projection.subscribe_to` raised `RubyEventStore::InvalidHandler`** — RailsEventStore
  3.1 subscribers must respond to `call`. A projection class now does (`call(event)` hands the
  event to a new instance's `handle`), and `subscribe_to` returns the unsubscribe procs.
  `handle` takes the `apply_<name>` method from `event.event_type`, so an event read back as a
  plain `RubyEventStore::Event` reaches its handler too.
- **Nested `with_guaranteed_read` lost the outer block's writes** — the inner block reset the
  list of pending writes, then cleared it. An inner block now projects its own writes when it
  ends and restores the outer list; if it raises, its unprojected writes pass to the outer
  block. Every write is projected by the time the outermost block ends.
- **A process that only reads got plain `RubyEventStore::Event`s** — in a lazily loaded process
  (console, rake, development) no event class was registered, so events came back without
  Lyra's readers (`operation`, `attributes`, `changes`, ...). `Lyra::Events` now defines the
  class on first reference for a name a monitored model or the stored schema writes, loading
  the model from the name's stem (`PostCreated` → `Post`, `SpreeOrderCreated` →
  `Spree::Order`); other names still raise `NameError`. A model with a custom `event_prefix` or
  `event_mapping` that is not loaded resolves only through the schema store.
- **petri_flow was not optional** — `app/workflows/*.rb` subclass `PetriFlow::Workflow`, so
  without the gem eager loading (production boot, `lyra:mode:*`, `lyra:repair`,
  `lyra:schema:*`) raised `NameError`. Without petri_flow the engine neither autoloads nor
  eager-loads `app/workflows`.
- **`lyra:workflows:generate MODE=...` wrote a class its file did not name** — `MODE=monitor`
  defined `MonitorModeWorkflowWorkflow`, which Zeitwerk could not load. A mode's file and class
  are now the same whether one mode or all are generated (`monitor_mode_workflow.rb` defines
  `MonitorModeWorkflow`, `es_sync_mode_workflow.rb` `EsSyncModeWorkflow`;
  `WorkflowGenerator.workflow_file_basename(mode)`, `.workflow_class_name(mode)`).
- **`already initialized constant Lyra::VERSION` in a checkout holding a nested copy of the
  engine** — Bundler's default gemspec search also loaded the nested copy's `lyra.gemspec`. The root `Gemfile`
  uses `gemspec glob: "lyra.gemspec"`, and the example apps' Gemfiles `glob: "lyra.gemspec"`.
- **Hijack and event-sourcing events lost who wrote them** — the command handler wrote only
  the causal chain, so `user_id`, `request_id`, the user action and `config.metadata_proc`
  reached Monitor events alone. Every mode now carries the same attribution metadata
  (`record.lyra_event_metadata(operation)`), plus `source: "lyra_command_handler"`.
- **`ReadYourWrites` had no effect under ES-Async** — only the ES-Sync path recorded writes
  for it. Writes inside `with_guaranteed_read` are now projected when the block ends; the job
  is still enqueued and converges on the same row.
- **Aggregates never loaded their history** — `GenericAggregate.load` raised `NoMethodError`
  (no model class for its stream name) and the command handler swallowed it. A model's own
  `aggregate_class` is now loaded with its stream's history for updates and destroys; the
  default `GenericAggregate`, which decides nothing from history, starts empty and reads no
  stream, so its writes issue no extra SQL. A programming error while loading now fails the
  command instead of being swallowed.
- **`AuditProjection.audit_trail` always gave `user_id: nil`** — it read the user from the
  event data, which no longer holds the metadata; it reads the event's metadata now.
- **DualView reported every destroyed record as `exists_mismatch`** — a destroyed record
  whose row is gone now compares clean (`event_sourced_state` gains `destroyed:`).
- **The engine's root redirect was hard-coded to `/lyra/dashboard`** — it is now relative
  to wherever the engine is mounted.
- **`strict_schema` stopped the boot on any schema drift** — including info-level changes
  such as an added column. It now refuses to boot only on a breaking change (model or column
  removed, column type or event name changed) and logs the rest.
- **`PIIMasker.mask_events` was broken** — it built events with keywords
  `RubyEventStore::Event` does not accept. It returns masked copies now (same class, id and
  metadata; attributes and changes masked).
- **`Erasure::Result#shared_values` was sometimes `[]`, sometimes an Integer** — always an
  Integer count now.
- **`EventFlow#crud_to_event_mapping` found nothing for a class** — it accepts a class or its
  name, and string operations and ids (as the dashboard passes them); `data_lineage` likewise.
- **A test left a guard on `Article#body=`** (`multi_mode_integration_test`), failing 11 later
  tests under some seeds; it now removes it.
- **ES-NoProj answers more queries exactly instead of refusing them** — scopes with `order` or
  `limit` (their conditions, then the order and limit); `relation.or(other)` over the same model
  (the union); and `where` fragments of `col OP ?` terms joined all by AND or all by OR, with OP
  one of `= != <> < <= > >= LIKE ILIKE` (values cast to the column type, NULL never matching, LIKE
  patterns with `%`, `_` and `\` escapes). Anything else is still refused. `order("col DESC")`
  strings and Arel orderings are read, and an ordering it cannot read now raises: it used to
  compare as equal and leave the result silently unordered. The testbed suite under ES-NoProj
  goes from 20 failures to none (the domain-events tests also created their records before
  switching mode, so under ES-NoProj the parents existed only as events).
- **ES-NoProj lost `update_columns` and `touch`** — in the events-only store the `UPDATE` matched no
  row and returned false, so no event was published and the change was lost, against Bypass
  Coverage ("the events are the write"). The event is now published whatever the row count.
- **ES-Lazy lost a callback-bypassing write made right after a write** — a write appends events
  only, so the record's row did not exist until the next read; `update_columns`, `update_all`
  or `delete_all` on it matched nothing, recorded no event, and the change was lost.
  `BypassEvents.atomically` now brings the tables up to date first, as a read does.
- **Lyra's own tables vanished with a rolled-back transaction** — `lyra_projection_checkpoints`
  and `lyra_mode_transitions` were created inside whatever transaction was open, and remembered
  as created; when it rolled back (a failed request, every transactional test) the table was
  gone and every later use failed. Under ES-Lazy the testbed suite failed 395 tests this way.
  They are now created on a connection of their own when a transaction is open
  (`Lyra.create_own_table`).
- **ES-NoProj ignored `select` and hid purpose refusals as "not found"** — `CachedRelation#select`
  returned whole records, and the record builder swallowed a policy error, dropping the record.
  Query results are now narrowed to the selected columns and checked when returned
  (`CachedRelationDelivery`), as are the class-level `find`, `find_by` and `find_by!`.
- **The all-modes runner skipped ES-Lazy** — `lyra:test:all_modes` and the PAM-less run now cover
  all seven configurations.
- **Lyra's rake tasks ran twice, and host apps got the development checkout's maintenance tasks** — Rails
  loads every `lib/tasks/*.rake` under an engine's root, and the engine also loaded its three
  task files explicitly, so each `lyra:mode:*`, `lyra:projections:*` and `lyra:schema:*` task
  ran twice (`lyra:mode:check` ran its full check twice), and `gems:*`, `public:*`, `stats:*` and
  the other maintenance tasks appeared in every host app. The engine now loads `lyra_*.rake` only,
  once.
- **`lyra:mode:check` could certify a switch having checked nothing** — monitored models register
  as their classes load, which a rake task in development does not do, so the check saw no
  models, found no discrepancy and certified the switch. The mode, repair, projection and schema
  tasks now load the application's models first; check and repair refuse when none are monitored.
- **Renamed events were skipped on replay** — `Rebuild`, the ES-NoProj cache and the aggregate
  decided what an event did from the end of its name (`…Created`, `…Updated`, `…Destroyed`).
  An event renamed with `event_mapping` (or, now, a domain event) was skipped: `Rebuild` left
  the record's row empty and ES-NoProj could not read it. Every replay site now dispatches on
  the operation each event records in its data (`Lyra::Event.operation_of`); only events too
  old to carry one fall back to the name.
- **Event sourcing lost writes whose event could not be stored** — `lyra_store_events` logged a
  failed append and carried on (unless `strict_projections`, a setting about projections, was
  on): ES-NoProj reported a write that existed nowhere, and ES-Sync projected a row from an
  event that was never stored. In Hijack and the event-sourcing modes a write whose event
  cannot be stored now fails and is rolled back, bypass writes included
  (`BypassEvents.required?`, `BypassEvents.atomically`: the write and its events share a
  transaction). Monitor, where the table stays authoritative, still logs the failure and keeps
  the write.
- **A failed event-sourced create made the next insert on its thread vanish** — the
  skip-insert signal was cleared only at the end of a successful finalize, so after any
  failure the next insert of any model on that thread (a Puma thread, say) skipped its row while
  reporting success. It is now cleared as soon as the record's own INSERT has run, and
  finalize clears its state on every exit.
- **ES-NoProj evaluated association conditions record by record, and some wrongly** —
  `where(program: x)` loaded each cached record's association (one query per record: about
  10,000 for one `count` in the mode-comparison benchmark) and compared objects;
  `find_by(program: x)` compared against a `program` attribute the record does not have and
  silently found nothing; `where(program_id: record)` matched nothing. Conditions are now
  rewritten as ActiveRecord does (`Lyra::Projections::AssociationConditions`): a `belongs_to`
  becomes its foreign key (polymorphic: type and id), and a record given as a column value
  becomes its id. A `has_many`/`has_one` condition, which ActiveRecord accepts only with a
  join, raises `UnsupportedQuery`, as does a polymorphic condition over several types.
- **ES-NoProj could serve out-of-date records from its cache** — a write warmed its record's
  entry inside the write's transaction, so a rollback left a record cached that never existed;
  two processes filling one key could leave a stale entry for up to an hour; and
  `where`/`find_by` results were cached for five minutes and never invalidated, so they could
  return records a write had already changed. Stamped entries (see Changed) make all three
  impossible: a stale entry is never used.
- **An explicit id was replaced** — `CommandHandler#handle_create` generated an id even when the
  application set one; it now keeps it, in the event and in the row. From `thesis-restructure`
  (526908e), applied to master's own Hijack fix (cd3ea89).
- **ES-NoProj `insert_all` ran, then raised** — through `CachedRelation`'s scope branch the
  insert executed and the caller then got `UnsupportedQuery` ("not a scope"). Inserts and
  upserts now go to the table relation and return its result.
- **Genesis left a cached "not found" in place on Solid Cache** — an ES-NoProj lookup
  made before a record was imported (in an earlier process, or before the event store
  was reset) caches `nil` for it. Genesis cleared the cache with
  `CachedProjection.invalidate_all`, which cannot delete per-record entries on a store
  without prefix deletion (Solid Cache, the Rails 8 default), so the imported record stayed
  "not found" until the entry expired, up to an hour. Genesis now drops each imported
  record's entry by id. Found by the Aegean benchmark harness, which empties the event
  store between modes.
- **`CachedRelation#delete_all`/`destroy_all`/`update_all` wiped the whole table**
  (`Lyra::Projections::CachedRelation`, from `stack/latest-ruby-rails-res`) — the
  `method_missing` scope fallback rebuilt them from `model_class.unscoped` and ran them
  before checking the result, so `Model.where(id: ids).delete_all` under ES-NoProj issued
  a bare `DELETE FROM` the whole table (found when the Aegean benchmark's ES-NoProj
  cleanup emptied `registrations` mid-sweep). They now act only on the relation's own
  records. `where(column: [a, b])` (an `IN` with several values) is no longer silently
  dropped.
- **Projection wrote through the read-from-events override** (`Lyra::Projections::ModelProjection`)
  — with `projection_mode :disabled` (ES-NoProj) a monitored model's `where`/`all` answer
  from the event store. Projection's update and destroy go through
  `model_class.where(...)`, so they acted on event-store records instead of rows: a
  record destroyed in the log is absent there, so its row was never deleted.
  `Rebuild` (`rake lyra:projections:rebuild`) and `AsyncProjectionJob` both project
  through this path in any mode. Projection now always addresses the table.
- **`invalidate_all` raised on Solid Cache, and keyed `find_by` replayed every stream**
  (`Lyra::Projections::CachedProjection`) — `invalidate_all` guarded prefix deletion with
  `respond_to?(:delete_matched)`, which every cache store answers true; Solid Cache, the
  Rails 8 default, then raised `NotImplementedError`. The raise is now rescued and the
  fallback used. `find_by` took its single-stream path only when the primary key was the
  sole condition, so `find_by(id: 5, email: x)` replayed every stream of the model; any
  lookup that pins the primary key now reads that one stream and checks the remaining
  conditions against the record it yields.
- **ES-Async projected a record's events out of order** (`Lyra::Projections::AsyncProjectionJob`)
  — each job applied its one event, and a worker pool runs jobs concurrently, so an
  earlier update's job could land after a later one's and roll the row back; a late
  create job could even resurrect a destroyed record. The Olist replay through Solidus
  left 2 of 100 orders at `confirm` whose events ended at `complete`. Each job now
  brings its record up to date with the whole stream (`Rebuild.replay_record`, in place),
  under a PostgreSQL advisory lock held per stream, so jobs converge in any order. Cost:
  each job re-reads its stream, so projections lag more and ES-Async's read-after-write
  window widens (Olist, 100 orders: 151 -> 183 such failures).
- **Hijack and event-sourcing modes built events before the model's own callbacks**
  (`Lyra::Interceptors::CrudInterceptor`, new `WriteHooks`) — the create/update/destroy
  commands ran in `before_*` callbacks registered on `ActiveRecord::Base`, so ahead of
  every model's own `before_*` callbacks. Values those set were missing from the event:
  in Hijack mode the event disagreed with the row; under event sourcing, where the row is
  projected from the event, they were lost from the table, and DualView could not tell
  (both sides agreed). Replaying Olist orders through Solidus 4.7 under ES-Sync lost every
  order's `guest_token` and every payment's `number`. The commands now run in
  `WriteHooks`, prepended to `ActiveRecord::Persistence`: after all `before_*` callbacks,
  just before the SQL write. A failed command returns false (save returns false, the
  transaction rolls back) instead of throwing `:abort`. PaperTrail is still switched off
  first. SQL statements per write are unchanged in every mode, in order and count.
- **Hijack creates re-assigned every attribute** (`Lyra::Interceptors::CrudInterceptor`) —
  after the create command, the interceptor called `assign_attributes` with all of the
  record's attributes, although only the reserved ID had changed. That fails on models
  that guard a writer: Solidus makes `StockItem#count_on_hand=` unusable so stock moves
  only through `set_count_on_hand`, and Hijack mode could not create a variant. Only the
  ID is assigned now.
- **Writes that bypass callbacks went missing from the event log** (`Lyra::StrictDataAccess`)
  — three holes, found by the Olist replay through Solidus 4.7, where DualView then
  disagreed with the table for 17 of 20 orders and every shipment:
  - *Assign, then `update_columns`* published nothing. The old value was read from the
    in-memory attribute, which already held the new value, so no change was seen
    (Solidus's `Shipment#persist_amounts`). The old value now comes from
    `attribute_in_database` and the new one from the record after the write, which also
    covers the timestamps `touch: true` sets.
  - *`touch`* was not intercepted at all (Solidus records completion with
    `touch(:completed_at)`). It now publishes a bypass event; it is not a strict-mode
    violation, since Rails itself calls it for `belongs_to ... touch: true`.
  - *`update_column`* published its event twice (Lyra's override and Rails'
    `update_columns` underneath both published), and the override dropped Rails 8's
    `touch:` keyword, so callers passing it raised `ArgumentError`.
- **Hijack and event-sourcing modes failed on namespaced models** (`Lyra::CommandHandler`) —
  the event class name was built from the model name without stripping `::`, so
  `Spree::Price` produced the invalid constant `Spree::PriceCreated` and every create
  failed. The failure surfaced only as a parent record left unsaved, with no exception
  (`Spree::Product.create!` returned an unsaved product). Every other event path already
  stripped the separator; this one now does too. Found by the Olist replay through
  Solidus 4.7, where it, not STI or polymorphism, kept Solidus out of these modes.
- **Optional gems that failed to load were reported as missing** (`lyra.rb`,
  `Lyra::OptionalDependency`) — PAM DSL and PetriFlow were loaded inside a bare
  `rescue LoadError`, so a gem that was installed but could not load (PetriFlow without
  `rexml`) was treated as absent and left half-defined; eager-loading `app/workflows`
  then failed with `uninitialized constant PetriFlow::Workflow`. Only a gem that is itself
  not installed now counts as unavailable; any other load failure raises. PetriFlow now
  declares `rexml` (see `gems/petri_flow/CHANGELOG.md`).
- **DualView compared times at whole seconds** (`Lyra::DualView`) — `normalize_value` turned
  every time into `iso8601` with no fraction, so `15:49:11.420` in the table and
  `15:49:11 UTC` in a lossy event compared equal. That is how the sub-second loss fixed by
  `Lyra::EventSerializer` passed dual-view checks under Monitor mode. Times now compare at
  microseconds, the resolution of a PostgreSQL timestamp.
- **Hijack mode filed `Created` under a placeholder stream** (`Lyra::CommandHandler`) — for
  integer primary keys, hijack mode stored the Created event under `"pending-<hex>"` and let
  the database assign the ID afterwards. Nothing linked the two: later events went to the
  real `Model$<id>` stream, so every record's history began with an update and rebuilding it
  from events (dual view, projection rebuild) found no attributes. Hijack now reserves the
  ID up front through `IdGenerator`, as event-sourcing mode does, and the row is inserted
  under the ID the event carries. Hijack is now covered by the event-correctness
  integration tests it had been left out of.
- **ES-Async lost projections silently** (`Lyra::Projections::AsyncProjectionJob`) — the job
  was enqueued inside the transaction that stores its event, so a worker could run it
  before the commit, find no event, complete, and never project the row (no error, no
  retry). Replaying 40 BPI 2017 applications left 37 missing. The job now sets
  `enqueue_after_transaction_commit`, so it runs only once its event is visible and is
  never enqueued after a rollback. Eventual consistency itself is unchanged. The test dummy
  app now loads `active_job/railtie`.

## [0.8.0] - 2026-08-09

The version the PAM article (Requirements Engineering, 2026) describes, released from
lyra-engine commit `b863d2e`. Not published to RubyGems until 2026-10-10.

### Added
- **Projection rebuild from the event log** (`Lyra::Projections::Rebuild`) - Reconstruct
  read-model tables from the event streams alone, the load-bearing invariant of event
  sourcing (log is source of truth; tables are a derived projection):
  - `Lyra::Projections::Rebuild.rebuild(Model)` clears the read model and replays each
    stream through the same `ModelProjection.project` path used by live sync/async
    projection, so a rebuilt table matches what live projection would have produced.
  - `Lyra::Projections::Rebuild.rebuild_all` rebuilds every monitored model (or an
    explicit list); `truncate: false` reconstructs streamed rows in place.
  - `rake lyra:projections:rebuild [MODEL=Namespace::Model[,Other]] [TRUNCATE=false]`
    rake task wrapping the above.
  - Invalidates ES-NoProj cached reconstructions so reads reflect the rebuild.
  - Integration tests (`test/projections/rebuild_test.rb`) covering surviving-record
    reconstruction, destroyed-record omission, dual-view consistency after rebuild, and
    `rebuild_all` over monitored models.
- **PAM DSL** aligned with its formal foundations — see `gems/pam_dsl/CHANGELOG.md`.
- **Performance characterization** (`docs/PERFORMANCE.md`) — measured overhead of every
  Lyra mode against a plain-ORM baseline: throughput and P95 latency across 1–64 threads,
  the measurement controls used, and a SQL-level account of why Hijack mode outperforms
  Monitor mode. The benchmark harness itself is published on acceptance of the
  accompanying papers.

### Fixed
- **`:disabled` mode emitted events** (`Lyra::Interceptors::CrudInterceptor`) — the monitor
  callbacks were gated on `lyra_monitored?`, a class attribute carrying no mode check, so a
  model that had ever called `monitor_with_lyra` kept writing to the event store after Lyra
  was disabled. A 150-write workload emitted 150 `event_store_events` rows in `:disabled`
  mode, identical to `:monitor`. `:disabled` is now gated on `lyra_events_enabled?`
  (monitored **and** not disabled), making it a true plain-ORM baseline. Hijack and
  event-sourcing modes still pass the guard and are unaffected — their `after_*` callbacks
  already return early via `@lyra_hijacked`.

  If you have been using `:disabled` as an off switch on models that call
  `monitor_with_lyra`, those models were still writing events before this fix.

  The existing `test_disabled_mode_captures_no_events` could not catch this: it redefines the
  model *without* the interceptor, asserting the outcome by construction. The new
  `test_disabled_mode_writes_no_events_for_a_monitored_model` keeps the model monitored and
  flips only the mode — what a migrating team actually does — and counts rows directly.
- **Empty-stream reads raised `NameError`** (`Lyra::Projections::CachedProjection`) —
  `load_events` rescued `RubyEventStore::StreamNotFound`, which does not exist in
  `ruby_event_store` 2.18/3.0; the real class is `EventNotFoundInStream`. The bad constant
  reference raised instead of catching the empty-stream case, surfacing as silent failed
  operations on the ES (No Projection) read path.

## [0.6.0] - 2026-01-05

### Added

#### Core CRUD-to-Event Sourcing Engine
- Monitor mode for non-intrusive CRUD operation logging
- Hijack mode for full event sourcing transformation
- Rails Event Store integration
- CRUD interceptor using ActiveRecord callbacks
- Event mapping layer (CRUD operations → Domain events)
- Command/Aggregate pattern for hijack mode
- Dual-view comparison (CRUD state vs Event-sourced state)
- State reconstruction from event streams
- Audit trail generation
- Dashboard API endpoints
- ERB-based dashboard views
- Pluggable event store backend
- Custom aggregate support
- Custom event mapper support
- Projection system for read models
- **Custom Metadata Proc** (`metadata_proc`) - Inject custom metadata into every event:
  - Capture user context from `Current`/`CurrentAttributes`
  - Support for Devise/Warden authentication
  - Thread-safe per-request metadata
  - Graceful error handling (returns `{}` on failure)
- **Rails Engine Namespaced Model Support** - Properly handle namespaced models:
  - `MyEngine::Order` → `MyEngineOrderCreated` (sanitized event class name)
  - Preserves original namespace in `model_class` attribute
  - Supports deeply nested namespaces (e.g., `MyEngine::Admin::Widget`)

#### Privacy Extraction to PAM DSL
- **PAM DSL as Optional Dependency** - Privacy features gracefully degrade without PAM DSL
- **PIIDetector Delegation** - `Lyra::Privacy::PIIDetector` delegates to `PamDsl::PIIDetector`
- **PIIMasker Delegation** - `Lyra::Privacy::PIIMasker` delegates to `PamDsl::PIIMasker`
- **GDPRCompliance Delegation** - `Lyra::Privacy::GDPRCompliance` delegates to `PamDsl::GDPRCompliance`
- **PolicyIntegration Enhancements**:
  - `use_detector: true` option (default) - Falls back to PIIDetector for fields not in policy
  - `use_detector: false` - Policy-only mode, no pattern-based detection
  - `pam_dsl_available?` - Check if PAM DSL is loaded
  - `source: :policy` or `source: :detector` in detection results
  - Retention returns `nil` (infinite/manual) when no policy defined
  - 28 new tests for PolicyIntegration

#### Unified PII Detection System
- **Consolidated PIIDetector** - Lyra now delegates to `PamDsl::PIIDetector` for unified PII detection
- **Partial Matching Mode** (default) - Detects PII in compound field names using word boundaries
  - Matches prefixed fields: `customer_email`, `billing_phone`, `user_name`
  - Matches suffixed fields: `home_phone`, `work_email`, `shipping_address`
  - Supports camelCase suffix boundaries: `emailAddress`, `phoneNumber`
- **Exact Matching Mode** - Optional strict mode for specific known field names only
- **Configurable via `PamDsl::PIIDetector.partial_match`** - Toggle between matching modes
- **New PII Types**:
  - `:identifier` - VAT numbers, tax IDs, passport numbers, AFM (Greek tax ID)
  - `:financial` - IBAN, bank accounts, salary, income
  - `:health` - Medical records, diagnosis, prescriptions
  - `:biometric` - Fingerprints, face ID, retina scans
  - `:location` - GPS coordinates, latitude/longitude
- **Exclusion Patterns** - Prevents false positives on:
  - Timestamps: `*_at`, `*_on`, `*_date`, `*_time`
  - Counters/amounts: `*_count`, `*_amount`, `*_total`
  - Flags: `*_verified`, `*_confirmed`, `*_enabled`, `is_*`, `has_*`
  - Codes: `*_code` (except `postal_code`, `zip_code`)
  - Security: `*_digest`, `*_token`, `*_hash`, `encrypted_*`
- **Sensitivity Levels with Legislative Background**:
  - `:public` - Publicly accessible data
  - `:internal` - Low risk, basic protection (GDPR Art. 6)
  - `:confidential` - Medium risk, enhanced protection (GDPR Art. 6, Art. 32)
  - `:restricted` - High risk, special categories (GDPR Art. 9, PCI DSS)
- **PII Masking** - Type-specific masking for safe display
- **56 tests with 188 assertions** for comprehensive coverage

#### Event Schema Validation System
- **Schema Store** (`lib/lyra/schema/store.rb`) - Versioned schema file persistence in `db/lyra_schemas/`
- **Schema Generator** (`lib/lyra/schema/generator.rb`) - Generates schemas from monitored ActiveRecord models
- **Schema Diff** (`lib/lyra/schema/diff.rb`) - Compares schemas with severity classification (BREAKING, WARNING, INFO)
- **Schema Validator** (`lib/lyra/schema/validator.rb`) - Enforces schema consistency with strict mode support
- **Schema Reporter** (`lib/lyra/schema/reporter.rb`) - Human-readable model→event mapping reports
- **Rake Tasks** for schema management:
  - `rake lyra:schema:create` - Generate initial schema
  - `rake lyra:schema:update` - Create new schema version
  - `rake lyra:schema:verify` - Check for schema changes
  - `rake lyra:schema:report` - Display model→event mappings
  - `rake lyra:schema:history` - Show version history
  - `rake lyra:schema:diff[v1,v2]` - Compare two schema versions

#### Event Class Registration for RailsEventStore Compatibility
- **EventClassRegistrar** (`lib/lyra/schema/event_class_registrar.rb`) - Pre-registers event classes at Rails startup
- Ensures `Object.const_get()` works when RailsEventStore deserializes events after app restart
- Registers events from both monitored models configuration and stored schema (for legacy events)

#### Event Sourcing with Disabled Projections (Sixth Mode)
- **CachedRelation** (`lib/lyra/projections/cached_relation.rb`) - ActiveRecord::Relation-like wrapper for in-memory cached data
  - Full query interface: `where`, `order`, `limit`, `offset`, `first`, `last`, `find`, `find_by`
  - Type coercion for string/integer and boolean comparisons (handles params from controllers)
  - Aggregation methods: `sum`, `average`, `minimum`, `maximum`, `pluck`
  - Pagination support: `page`, `per` (Kaminari-compatible)
  - Chainable no-ops for AR methods: `includes`, `joins`, `preload`, `distinct`
  - Rails 8 Arel predicate value extraction support

- **AssociationInterceptor** (`lib/lyra/interceptors/association_interceptor.rb`) - Patches AR associations for cache-based loading
  - `BelongsToAssociationPatch` - Intercepts belongs_to association loading
  - `HasOneAssociationPatch` - Intercepts has_one association loading
  - `HasManyAssociationPatch` - Intercepts has_many association loading with count/size support
  - Polymorphic association support for belongs_to
  - Rails 8 async: keyword argument compatibility

- **EventStoreReader** (`lib/lyra/projections/event_store_reader.rb`) - Reads and caches entity state from event store
  - Reconstructs current state by replaying events
  - Solid Cache / Rails.cache integration for fast reads
  - Cache warming and invalidation on writes
  - Full query interface via CachedRelation

- **CrudInterceptor first/last overrides** - Proper ordering by primary key
  - `Model.first` now orders by `primary_key ASC` before returning first record
  - `Model.last` now orders by `primary_key DESC` before returning first record

#### Benchmark Infrastructure
- **Mode Comparison Benchmark** (`perf/run_mode_comparison_benchmark.rb`)
  - Comprehensive benchmarking across all 7 Lyra modes
  - Scales from 500 to 100,000 operations
  - Four scenarios: CRUD, batch, query, mixed workloads
  - Checkpoint/resume support for long-running benchmarks
  - Automatic chart generation (PNG) via gnuplot
  - JSON, CSV, and Markdown report output
  - **Object allocations tracking** - measures Ruby allocations per operation via GC.stat
  - **Allocations charts** - per-scale bar charts and scaling comparison line chart
- Warmup phase for JIT/cache priming
- Cache warming for ES Disabled mode before measurements

#### Testing Infrastructure
- **Comprehensive CachedRelation test suite** (`test/projections/cached_relation_test.rb`)
  - 37 tests covering enumerable, finders, where filtering, type coercion, ordering, pagination, aggregations
  - Isolated unit tests with MockRecord and MockModel classes

- **Unified 6-mode test runner** - All Lyra modes tested together
  - `rake lyra:test:all_modes` runs all 6 configurations in single execution
  - Configurations: disabled, monitor, hijack, event_sourcing+sync, event_sourcing+async, event_sourcing+disabled
  - Comprehensive report with pass/fail status per configuration

#### Configuration Options
- `strict_schema` - Fail startup if schema changes detected (recommended for production)
- `schema_path` - Custom path for schema files (defaults to `db/lyra_schemas/`)

#### Database Support
- PostgreSQL primary database support
- SQLite alternative for small deployments

#### Example Application
- Aegean E-Pay Testbed with student registrations
- Payment processing with multiple channels
- Complete database schema and seed data

### Fixed

#### StrictDataAccess Compatibility with Event Sourcing Mode
- Fixed conflict between `StrictDataAccess` and ES mode sync projections
- Projections now correctly bypass strict access checks (using `Thread.current[:lyra_bypass_strict_access]`)
- This is safe because projections are internal Lyra operations with events already recorded
- Fixed require order in `lib/lyra.rb` to load `strict_data_access` before projections

#### CachedRelation Exception Handling in ES Disabled Mode
- Fixed `CachedRelation.method_missing` swallowing `StrictDataAccessViolation` exceptions
- `update_all` and `delete_all` on `CachedRelation` now correctly raise violations when strict mode is enabled
- The generic scope delegation rescue clause now re-raises framework violations instead of suppressing them

#### Automatic Event Creation for `dependent: :nullify` Operations
- When `dependent: :nullify` triggers `update_all(foreign_key: nil)`, Lyra now creates events for affected child records
- This ensures the event stream captures foreign key nullification when parent records are destroyed
- Events include `nullify_source: "dependent_association"` in metadata for traceability
- Works in both DB-backed modes (plucks from DB) and ES Disabled mode (queries event store cache)
- Resolves event stream completeness gap where child state changes were previously invisible

#### Automatic Event Creation for Callback-Bypassing Operations
- `update_columns` and `update_column` now create events when allowed (strict mode off or bypassed)
- `delete` now creates a "Destroyed" event when allowed
- Events include `bypass_source: "update_columns"` or `bypass_source: "delete"` in metadata
- This ensures the event stream remains complete even when developers intentionally bypass callbacks
- Only applies to Lyra-monitored models when mode is not `:disabled`

#### Test Isolation Issues
- Fixed test contamination between controller and integration tests
- Integration tests now create their own event store if none exists
- Added `create_event_store` helper to `multi_mode_integration_test.rb` and `event_sourcing_mode_test.rb`
- Fixed `assert_not_nil` → `refute_nil` (Minitest syntax)
- Added proper `Lyra.config.monitor_model` calls for correct event naming

### Changed

#### Test Coverage Configuration
- Increased SimpleCov minimum coverage thresholds (50% line, 47% branch)
- Added coverage groups for Projections and Schema modules
- All 584 tests now pass with proper isolation
- Added comprehensive tests for Schema::Diff (column limit changes, event renames, config changes)
- Added comprehensive tests for Schema::Reporter (report generation, PII summaries, model mappings)
- Added comprehensive tests for Visualization::Timeline (Mermaid, ASCII, D3.js output)
- Added comprehensive tests for EventAnalyzer (timeline, operations, privacy analysis)
- Added comprehensive tests for CommandHandler (event data, metadata, error handling)
- Added comprehensive tests for DualView (value normalization, type coercion)

### Core Components
- `CrudInterceptor` - ActiveRecord callback integration
- `EventMapper` - CRUD to event mapping
- `Command` - Command pattern implementation
- `CommandHandler` - Command processing
- `Aggregate` - Domain aggregate base class
- `GenericAggregate` - Default aggregate for monitored models
- `Projection` - Read model projection base
- `StateProjection` - State reconstruction
- `AuditProjection` - Audit trail generation
- `DualView` - CRUD vs Event-sourced comparison
- `StateAnalyzer` - State analysis and recommendations
- `EventStoreAdapter` - Pluggable event storage
- `Configuration` - Centralized configuration
