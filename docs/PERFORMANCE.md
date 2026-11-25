# Performance

What each Lyra mode costs against a plain-ORM baseline, and why.

**Status.** Measured on Lyra 1.0.1 (23-25 November 2026): three runs of ten
trials per cell on one machine, all modes and their controls, with a thread
sweep from 1 to 64. The runs are published with their machine description,
settings and statement traces in the replication package,
https://doi.org/10.5281/zenodo.24390709 (version 1.0.1). Earlier measurements,
on Lyra 0.9.0 (October 2026, https://doi.org/10.5281/zenodo.23640846) and on
Lyra 0.6.0 (July 2026, an Apple M4), are superseded: the code has changed since
(the stream heads among other changes), and so have the figures.

## Results

Throughput and P95 latency at 16 threads, and the change in throughput against
the baseline at 4, 16 and 64 threads (mean ± SD of three runs' means; each
change against its own run's baseline, averaged over the runs; Ruby 4.0.10 with
YJIT, Rails 8.1.4.1, Rails Event Store 3.2.0, PostgreSQL 18.7; a 16-vCPU
virtual machine, AMD EPYC 7543). Indented rows are controls, each changing one
thing.

| Mode | ops/s | P95 (ms) | vs. ORM, 4 thr. | 16 thr. | 64 thr. | SQL per create, update |
|:-----|------:|---------:|----------------:|--------:|--------:|:----------------------:|
| Disabled (baseline) | 856 ± 37 | 49 ± 6 | — | — | — | 4, 4 |
| &nbsp;&nbsp;*no PaperTrail* | 1,238 ± 69 | 32 ± 5 | +44.5% | +44.9% | +46.8% | — |
| Monitor | 479 ± 20 | 97 ± 4 | −42.8% | −44.0% | −39.0% | 10, 9 |
| &nbsp;&nbsp;*no PaperTrail* | 573 ± 27 | 81 ± 4 | −31.2% | −33.1% | −25.6% | — |
| Hijack | 639 ± 35 | 69 ± 5 | −23.2% | −25.3% | −23.3% | 10, 9 |
| &nbsp;&nbsp;*Hijack+PT* (PaperTrail left on) | 515 ± 23 | 88 ± 7 | −38.7% | −39.8% | −38.6% | 11, 10 |
| &nbsp;&nbsp;*no lock* (no lock, no heads) | 746 ± 40 | 61 ± 6 | −11.2% | −12.8% | −10.9% | 8, 5 |
| &nbsp;&nbsp;*no heads* | 682 ± 30 | 65 ± 5 | −18.3% | −20.3% | −19.0% | 8, 8 |
| ES-Sync | 598 ± 31 | 74 ± 5 | −28.3% | −30.2% | −28.4% | 10, 9 |
| &nbsp;&nbsp;*no lock* | 698 ± 35 | 67 ± 5 | −16.4% | −18.5% | −16.4% | 8, 5 |
| &nbsp;&nbsp;*no heads* | 630 ± 17 | 71 ± 3 | −25.0% | −26.3% | −23.8% | 8, 8 |
| ES-Async (requests served) | 464 ± 18 | 88 ± 4 | −68.0% | −45.7% | −30.6% | 10, 9 |
| &nbsp;&nbsp;*no lock* | 592 ± 18 | 74 ± 2 | −63.7% | −30.8% | −14.7% | 8, 4 |
| &nbsp;&nbsp;*no heads* | 512 ± 24 | 78 ± 4 | −66.2% | −40.2% | −25.1% | 8, 8 |
| ES-Lazy | 303 ± 9 | 130 ± 4 | −69.0% | −64.6% | −62.3% | 11, 9 |
| ES-NoProj | 283 ± 10 | 155 ± 6 | −65.0% | −66.9% | −62.9% | 19, 14 |
| &nbsp;&nbsp;*cold* (caches emptied before every trial) | 280 ± 16 | 153 ± 9 | −66.7% | −67.3% | −61.7% | — |
| Disabled, re-run last | 830 ± 41 | 51 ± 7 | −3.8% | −3.0% | −2.2% | 4, 4 |

*no lock* is the mode without the lock on the aggregate and without the stream
heads (`lock_aggregate_before_append` and `stream_heads` off); *no heads*, without
the stream heads only.

Every mode costs throughput. The controls show what the cost is made of:

- **PaperTrail.** With as many statements per write, Monitor costs 44% at 16
  threads and Hijack 25%. The difference is PaperTrail, which Lyra switches off
  from Hijack on, the event log superseding it: Hijack with it left on costs
  40%. PaperTrail builds each version in Ruby from the record's previous state;
  without it the baseline runs 45% faster.
- **The stream heads** (`stream_heads`, which check a record's history where its
  events are appended) cost Hijack about 6%, ES-Sync about 5% and ES-Async
  about 9% of their throughput; **the lock on the aggregate** costs Hijack about
  7.5 points more.
- **Monitor's figure is partly the benchmark's.** The harness resets the store
  after every trial, so most of Monitor's timed writes create a record's stream
  head, which a deployment does once per record. A supplementary run (both
  orders, same protocol) measured Monitor at 16 threads at 32.9% without the
  heads, 41.7% with them, and 36.9% with them when the seeded records are
  imported first (Genesis, as Hijack does): about four points are the heads' own
  cost, about five the benchmark's.

ES-Async's throughput counts requests, which return before their rows are
projected, by jobs in the same process: the more request threads, the more
projection work is still queued when a trial ends (none at 4 threads, about 750
jobs at 16, 4,100 at 64), so its smaller cost at 64 threads is work deferred
past the measured window, not work saved. Counting that work it completes 292
to 329 operations per second, 59-68% below the baseline; the 4-thread figure,
with nothing left queued, is the one that measures the mode. ES-Lazy pays at the
next read, whose catch-up applies the events written since its checkpoint;
ES-NoProj pays on every read, which is served from records rebuilt from their
streams and cached until the stream moves. Its cold cell is close to the warm
one because the harness's reset after each trial leaves the warm cache stale
from the second trial on, so the two say nothing about what a warm cache is
worth.

**History.** All of the above runs on a store that holds little history. Two
further sweeps held the workload at 16 threads and grew the history beneath it,
from 10^4 to 10^6 events and from one to 1,000 events per stream: the modes that
write their tables add a fixed number of statements per write and do not slow
as history accumulates; ES-NoProj pays for the length of the streams it replays.

Absolute figures are specific to the machine; compare modes within one run.

---

## Where the cost comes from: append ordering

What a mode costs is set less by generating events than by *where in the ORM's
callback chain the event is appended* and by what the mode switches off. Count
the SQL statements ActiveRecord issues for one write (Lyra 1.0.1, PostgreSQL, a
model that also has PaperTrail versioning, as in the testbed; the last column of
the table above).

A plain write is four statements: `BEGIN`, the row write, PaperTrail's version
insert, `COMMIT`. Every event adds two inserts (the event and its stream link),
which no design can avoid; the stream heads add one more (the head's insert or
update), and a create's head also reads the record's stream to check its
history. The rest depends on ordering.

**Updates.** Compare Monitor, Hijack without the lock and the heads, and Hijack:

```
Monitor update (9)        Hijack, no lock (5)       Hijack update (9)
 1. BEGIN                  1. BEGIN                  1. BEGIN
 2. UPDATE registrations   2. INSERT events          2. SELECT ... FOR NO KEY UPDATE
 3. UPDATE stream_heads    3. INSERT ..._in_streams  3. UPDATE stream_heads
 4. SAVEPOINT              4. UPDATE registrations   4. SAVEPOINT
 5. INSERT events          5. COMMIT                 5. INSERT events
 6. INSERT ..._in_streams                            6. INSERT ..._in_streams
 7. RELEASE                                          7. RELEASE
 8. INSERT versions                                  8. UPDATE registrations
 9. COMMIT                                           9. COMMIT
```

Monitor appends in an `after_*` callback. By then the row write has opened the
transaction, so RailsEventStore's nested append (`requires_new: true`) opens
and releases a savepoint: two extra round-trips. Hijack appends before the row
write; without the lock and the heads nothing has opened the transaction yet, so
the append *becomes* the transaction and no savepoint is needed (and
PaperTrail's insert is gone, since Lyra switches it off from Hijack on). With
the lock on the aggregate, the default, the lock statement opens the
transaction first, the append nests, and the savepoint pair returns: nine
statements, as many as Monitor's, made of different parts. The lock keeps
concurrent writers of one record in order, so that the row and the log agree.

**Creates.** A create cannot take the unnested path. Its `Created` event must
carry the record's id, and its stream is named by it, so Hijack (and every
event-sourcing mode) first reserves the id from the table's sequence
(`nextval`). That query is the transaction's first statement, the head's insert
and the read of the stream follow, the append nests, and the create pays the
savepoint pair plus the reservation: ten statements for Hijack, eleven with
PaperTrail.

The event-sourcing modes follow the same pattern. ES-Sync issues Hijack's
statements, its projection the row write. ES-Async and ES-Lazy write no row at
write time (a job projects ES-Async's after commit; ES-Lazy projects before the
next read): their create links the event to the model's stream in place of the
row write, and their update takes an advisory lock on the record's stream and
reads its last event, to check that the stream does not end in a `Destroyed`
event, in place of the row's lock and write. ES-NoProj writes no rows at all:
its extra statements (19 per create, 14 per update) are the reference links and
the reads that rebuild the record from its stream and cache it.

The practical consequence: reserving the id and taking the lock without opening
the transaction would recover the savepoint pair, two statements per write.
Lyra does not do this yet; it is a limitation of the implementation, not of the
approach.

---

## Workload and method

The measurement uses the Aegean ePay testbed, a Rails application with a
registrations/payments domain, driven through a mixed operation profile:

- **Operation mix**: 10% create, 60% read, 25% update, 5% delete
- **Records**: every trial starts on exactly 1,000 seeded records of one model, read by primary key
- **Thread counts**: 4, 16 and 64 for the table above (three runs, the second with the cells in
  reverse order); 64, 32, 16, 8, 4, 1 for the sweep
- **Operations per thread**: 200 (800 at 4 threads in the table's runs)
- **Trials per data point**: 10, reported as mean ± sample standard deviation
- **Settle before each cell**: garbage collection, `VACUUM (ANALYZE)` of the benchmark's tables, a
  PostgreSQL `CHECKPOINT`, a wait of at most 60 s for autovacuum, then 5 s idle
- **One process per mode**, so no mode inherits another's caches or connections; the
  application is one Ruby process, so the thread counts measure concurrency within a
  process, not the use of the machine's cores; ES-Async's projection jobs run on a thread
  pool in the same process
- **PAM's checks off**, and the benchmark calls Active Record directly, with no HTTP layer

The baseline is the same application with Lyra disabled, **not** bare
ActiveRecord: PaperTrail stays on, because that is the configuration a team
migrating to Lyra is actually leaving behind. `Hijack+PT` isolates PaperTrail's
contribution: it is Hijack with PaperTrail left on, so the `Hijack` vs
`Hijack+PT` gap is PaperTrail's cost and nothing else. `Disabled-PT` and `Monitor-PT`
switch PaperTrail off in the baseline and in Monitor.

## Measurement controls

These are what make a comparison between modes trustworthy.

**Drift.** Sustained load can make later modes look slower than earlier ones.
The baseline is therefore measured first *and* last; if the two disagree, the
machine was not in the same state throughout the sweep. In the runs above the
last baseline was 0.6-7.8% slower than the first: each cost is taken against its
own run's baseline and averaged over the runs, and the reversed run shows how much
the order moves them (two points or less for 33 of 48 costs).

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
| Audit trail, minimal disruption, the table stays authoritative | Monitor | about 44%: the event inserts, a savepoint pair and the stream head on every write, with PaperTrail still on (33% without it); part of it is the benchmark's (above) |
| The event log authoritative | Hijack | about 25%: as many statements as Monitor, but PaperTrail is switched off; 13% without the lock and the heads |
| Full event sourcing with tables kept current | ES-Sync | about 30%: Hijack's cost plus the projection write |
| Full event sourcing, projection off the request path | ES-Async | about 46% in requests served at 16 threads and 31% at 64, with projections still queued; 59-68% in work completed; a read can run before its projection (read-your-writes) |
| Full event sourcing, tables brought up to date when read | ES-Lazy | about 65%: the projection moves from the write to the first read that needs it |
| Audit and replay; writes and reads rare | ES-NoProj | about 67%: every read is served from records rebuilt from their streams, and a record's cache is renewed whenever its stream moves |

Monitor, which leaves every write as it was, costs the most of the modes that
write their tables in the request: it suits a staging or canary posture before a
commitment, not a resting place. Reads are unaffected in every mode except
ES-NoProj and, on the first read after writes, ES-Lazy, so an application with a
higher read fraction sees proportionally less overhead. On other workloads the
order of the modes changes: in the Olist replay through Solidus, ES-NoProj takes
about twice ES-Lazy's time, and about seven times the baseline's.

## Reproducing

The benchmark harness, the testbed and the runs behind every figure above are in
the replication package (https://doi.org/10.5281/zenodo.24390709, version 1.0.1):
`bin/run_benchmarks` runs every benchmark, `BENCHMARKING.md` describes each phase
and its settings, and each run's `aegean_sql_trace.md` holds the statement traces.

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
savepoint pair stays on both; with `lock_aggregate_before_append` and `stream_heads`
switched off, it disappears from Hijack's update.
