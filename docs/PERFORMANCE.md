# Performance

What each Lyra mode costs against a plain-ORM baseline, and why.

**Status.** Measured on Lyra 0.9.0 (October 2026): three runs of ten trials
per cell on one machine, all modes and their controls. The runs are published
with their machine description and settings at
https://doi.org/10.5281/zenodo.23640846. An earlier measurement (July 2026,
Lyra 0.6.0, an Apple M4) is superseded: it predates the lock on the aggregate,
the id reservation before a `Created` event, ES-Lazy and one process per mode,
and its ES-NoProj figure was distorted by two harness defects (see CHANGELOG).
Its headline, Hijack about 11% slower than the baseline and Monitor about 39%,
is superseded by the figures below.

## Results

Throughput and P95 latency at 16 threads, and the change against the baseline
at 16 and 64 threads (mean ± SD of three runs' means; Ruby 4.0.7 with YJIT,
Rails 8.1.4, Rails Event Store 3.2.0, PostgreSQL 18.6; a 16-vCPU virtual
machine):

| Mode | ops/s | P95 (ms) | vs. ORM, 16 thr. | vs. ORM, 64 thr. | SQL per create, update |
|:-----|------:|---------:|-----------------:|-----------------:|:----------------------:|
| Disabled (baseline) | 417 ± 2 | 93 ± 1 | — | — | 4, 4 |
| Monitor | 284 ± 4 | 148 ± 5 | −31.9% | −33.0% | 8, 8 |
| Hijack | 353 ± 0 | 116 ± 0 | −15.3% | −16.9% | 8, 8 |
| *Hijack+PT* (control: PaperTrail left on) | 276 ± 2 | 155 ± 5 | −33.8% | −34.9% | 9, 9 |
| *Hijack, no lock* (control) | 384 ± 9 | 112 ± 8 | −7.8% | −9.1% | 8, 5 |
| ES-Sync | 338 ± 3 | 120 ± 2 | −18.9% | −19.9% | 8, 8 |
| *ES-Sync, no lock* (control) | 369 ± 2 | 111 ± 1 | −11.4% | −12.2% | 8, 5 |
| ES-Async | 292 ± 2 | 135 ± 1 | −29.9% | −11.0% | 7, 7 |
| *ES-Async, no lock* (control) | 323 ± 3 | 116 ± 1 | −22.5% | −1.0% | 7, 4 |
| ES-Lazy | 126 ± 0 | 261 ± 2 | −69.8% | −68.9% | 8, 4 |
| ES-NoProj | 198 ± 7 | 238 ± 7 | −52.4% | −52.0% | 16, 9 |

Every mode costs throughput. The controls show what the cost is made of. Of
Hijack+PT's 34 points, switching PaperTrail off (as Lyra does from Hijack on,
the event log superseding it) recovers about 18.5, and dropping the lock on the
aggregate about 7.5 more; the rest, about 8, is recording the event at all.
ES-Async's throughput counts requests, which return before their rows are
projected: at 64 threads most of a trial's projection jobs are still queued
when its last request returns, so its lead there is work deferred as much as
work saved. ES-Lazy pays at the next read, which applies every event since its
checkpoint; ES-NoProj pays on every read, which checks the record's stream.
Absolute figures are specific to the machine; compare modes within one run.

---

## Where the cost comes from: append ordering

What a mode costs is set less by generating events than by *where in the ORM's
callback chain the event is appended*. Count the SQL statements ActiveRecord
issues for one write (Lyra 0.9.0, PostgreSQL, a model that also has PaperTrail
versioning, as in the testbed; the last column of the table above).

A plain write is four statements: `BEGIN`, the row write, PaperTrail's version
insert, `COMMIT`. Every event adds two inserts (the event and its stream link),
which no design can avoid. The rest depends on ordering.

**Updates.** Compare Monitor, Hijack without the lock, and Hijack:

```
Monitor update (8)        Hijack, no lock (5)       Hijack update (8)
 1. BEGIN                  1. BEGIN                  1. BEGIN
 2. UPDATE registrations   2. INSERT events          2. SELECT ... FOR NO KEY UPDATE
 3. SAVEPOINT              3. INSERT ..._in_streams  3. SAVEPOINT
 4. INSERT events          4. UPDATE registrations   4. INSERT events
 5. INSERT ..._in_streams  5. COMMIT                 5. INSERT ..._in_streams
 6. RELEASE                                          6. RELEASE
 7. INSERT versions                                  7. UPDATE registrations
 8. COMMIT                                           8. COMMIT
```

Monitor appends in an `after_*` callback. By then the row write has opened the
transaction, so RailsEventStore's nested append (`requires_new: true`) opens
and releases a savepoint: two extra round-trips. Hijack appends before the row
write; without the lock nothing has opened the transaction yet, so the append
*becomes* the transaction and no savepoint is needed (and PaperTrail's insert is
gone, since Lyra switches it off from Hijack on). With the lock on the
aggregate, the default, the lock statement opens the transaction first, the
append nests, and the savepoint pair returns: eight statements, as many as
Monitor's, made of different parts. The lock keeps concurrent writers of one
record in order, so that the row and the log agree.

**Creates.** A create cannot take the unnested path. Its `Created` event must
carry the record's id, and its stream is named by it, so Hijack (and every
event-sourcing mode) first reserves the id from the table's sequence
(`nextval`). That query is the transaction's first statement, the append that
follows nests, and the create pays the savepoint pair plus the reservation:
eight statements for Hijack, nine with PaperTrail.

The event-sourcing modes follow the same pattern: ES-Sync adds its projection
write inside the transaction; ES-Async and ES-Lazy write no row at write time
(a job projects ES-Async's after commit; ES-Lazy projects before the next read,
and takes no lock on the aggregate); ES-NoProj writes no rows at all, and its
extra statements are reads that rebuild records from their streams and its
reference links.

The practical consequence: reserving the id and taking the lock without opening
the transaction would recover the savepoint pair, two statements per write.
Lyra does not do this yet; it is a limitation of the implementation, not of the
approach.

---

## Workload and method

The measurement uses the Aegean ePay testbed, a Rails application with a
registrations/payments domain, driven through a mixed operation profile:

- **Operation mix**: 10% create, 60% read, 25% update, 5% delete
- **Thread counts**: 64 and 16 for the table above (three runs); 64, 32, 16, 8, 4, 1 for the sweep
- **Operations per thread**: 200
- **Trials per data point**: 10, reported as mean ± sample standard deviation
- **Cooldown before each cell**: 30 s (configurable; the July run used 120 s, which
  guarded a fanless laptop against thermal throttling)
- **One process per mode**, so no mode inherits another's caches or connections

The baseline is the same application with Lyra disabled, **not** bare
ActiveRecord: PaperTrail stays on, because that is the configuration a team
migrating to Lyra is actually leaving behind. `Hijack+PT` isolates PaperTrail's
contribution: it is Hijack with PaperTrail left on, so the `Hijack` vs
`Hijack+PT` gap is PaperTrail's cost and nothing else.

## Measurement controls

These are what make a comparison between modes trustworthy.

**Drift.** Sustained load can make later modes look slower than earlier ones.
The baseline is therefore measured first *and* last; if the two disagree, the
machine was not in the same state throughout the sweep.

**Connection exhaustion.** At 64 threads the pool must cover the request threads
*plus* the projection jobs ES-Async dispatches. Undersized, that cell fails with
"too many clients already" and reports inflated throughput on fast-failing
operations.

**A baseline that is not a baseline.** An earlier version of the benchmark
reported a much smaller Hijack overhead because the `:disabled` baseline was
still emitting events: the monitor callbacks were gated on whether a model was
monitored, with no check on the mode. That is fixed (see CHANGELOG). If you
benchmark Lyra yourself, **check that your baseline writes no events** before
trusting the delta:

```ruby
Lyra.config.disable!
before = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM event_store_events")
# ... run your workload ...
after  = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM event_store_events")
raise "baseline is not a baseline" unless before == after
```

---

## Choosing a mode

Choose on consistency first, then on the figures above:

| If you want | Use | What it costs (16 threads) |
|:------------|:----|:---------------------------|
| Audit trail, minimal disruption, the table stays authoritative | Monitor | about 32%: the event inserts plus a savepoint pair, on every write |
| The event log authoritative | Hijack | about 15%: as many statements as Monitor, but PaperTrail is switched off; 8% without the lock |
| Full event sourcing with tables kept current | ES-Sync | about 19%: Hijack's cost plus the projection write |
| Full event sourcing, projection off the request path | ES-Async | about 30% at 16 threads, 11% at 64, with projections still queued; a read can run before its projection (read-your-writes) |
| Full event sourcing, tables brought up to date when read | ES-Lazy | about 70%: the projection moves from the write to the first read that needs it |
| Audit and replay; writes and reads rare | ES-NoProj | about 52%: every read checks the record's stream, and a record read after a write is rebuilt from it |
Reads are unaffected in every mode except ES-NoProj and, on the first read after
writes, ES-Lazy, so an application with a higher read fraction sees
proportionally less overhead.

## Reproducing

The benchmark harness and the testbed are in the replication package
(https://doi.org/10.5281/zenodo.17770613): `bin/run_benchmarks` runs every
benchmark, and `BENCHMARKING.md` describes each phase and its settings.

The statement counts above need no harness. Subscribe to `sql.active_record`
around a single write in each mode and count:

```ruby
statements = []
ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
  next if payload[:name].in?(["SCHEMA", "CACHE"])
  statements << payload[:sql]
end

record.update!(name: "changed")
puts statements.length
```

Run it under `Lyra.config.mode = :monitor` and again under `:hijack`, and the
savepoint pair appears on Monitor's update and disappears on Hijack's.
