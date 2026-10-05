# Performance

What each Lyra mode costs against a plain-ORM baseline, and why.

**Status.** Lyra 0.8.0 is being re-measured on a concurrent mixed CRUD workload,
all modes including ES-Lazy; this page will carry the figures when the run is
complete. An earlier measurement (July 2026, Lyra 0.6.0) is withdrawn: it
predates two corrections to what it measured (Hijack and event-sourcing creates
now reserve the record's id first; ES-Async now enqueues its projection job
after commit), and its ES-NoProj figure was distorted by two harness defects
(see CHANGELOG). Its headline, Hijack about 11% slower than the baseline and
Monitor about 39%, should not be cited.

What does not wait for the measurement is the mechanism. It is countable, and it
is below.

---

## Where the cost comes from: append ordering

What a mode costs is set less by generating events than by *where in the ORM's
callback chain the event is appended*. Count the SQL statements ActiveRecord
issues for one write (Lyra 0.8.0, PostgreSQL, a model that also has PaperTrail
versioning, as in the testbed):

| Mode | SQL statements per create | per update |
|:-----|--------------------------:|-----------:|
| Disabled (baseline) | 4 | 4 |
| Monitor | 8 | 8 |
| Hijack | 8 | 5 |
| Hijack+PT (control: Hijack with PaperTrail left on) | 9 | 6 |
| ES-Sync | 8 | 5 |
| ES-Async | 7 | 4 |
| ES-NoProj | 11 | 8 |
| ES-Lazy | 7 | 4 |

A plain write is four statements: `BEGIN`, the row write, PaperTrail's version
insert, `COMMIT`. Every event adds two inserts (the event and its stream link),
which no design can avoid. The rest depends on ordering.

**Updates.** Compare Monitor and Hijack+PT, which have the same PaperTrail and the
same events and differ only in where the append happens:

```
Monitor update (8)               Hijack+PT update (6)
 1. BEGIN                         1. BEGIN
 2. UPDATE registrations          2. INSERT event_store_events
 3. SAVEPOINT              <--    3. INSERT event_store_events_in_streams
 4. INSERT event_store_events     4. UPDATE registrations
 5. INSERT ..._in_streams         5. INSERT versions
 6. RELEASE                <--    6. COMMIT
 7. INSERT versions
 8. COMMIT
```

Monitor appends in an `after_*` callback. By then the row write has materialised
the transaction, so RailsEventStore's nested append (`requires_new: true`) opens
and releases a savepoint: two extra round-trips. Hijack appends before the row
write, while the transaction is still unmaterialised, so the append *becomes*
the transaction and no savepoint is needed.

**Creates.** A create cannot take Hijack's path. Its `Created` event must carry
the record's id, and its stream is named by it, so Hijack (and every
event-sourcing mode) first reserves the id from the table's sequence
(`nextval`). That query is the transaction's first statement, the append that
follows nests, and the create pays Monitor's savepoint pair plus the
reservation: eight statements for Hijack, nine with PaperTrail. On creates,
Monitor and Hijack cost the same; Hijack's advantage is on updates only.

The event-sourcing modes follow the same pattern: ES-Sync adds its projection
write inside the transaction; ES-Async and ES-Lazy write no row at write time
(a job projects ES-Async's after commit; ES-Lazy projects before the next read);
ES-NoProj writes no rows at all, and its extra statements are reads that
rebuild records from their streams.

The practical consequence: an implementation that appended before the row write
on every path, or batched the append into the row write's round-trip, would
close most of the Monitor–Hijack gap on updates; reserving ids in blocks, or on a
separate connection, would do the same for creates. Lyra does neither yet.

---

## Workload and method

The measurement uses the Aegean ePay testbed, a Rails application with a
registrations/payments domain, driven through a mixed operation profile:

- **Operation mix**: 10% create, 60% read, 25% update, 5% delete
- **Thread counts**: 64, 32, 16, 8, 4, 1
- **Operations per thread**: 200
- **Trials per data point**: 10, reported as mean ± sample standard deviation
- **Cooldown before each cell**: configurable (120 s in the July run, which
  guarded a fanless laptop against thermal throttling)

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

Until the figures are in, choose on the mechanism above:

| If you want | Use | What it costs per write |
|:------------|:----|:------------------------|
| Audit trail, minimal disruption, the table stays authoritative | Monitor | the event inserts plus a savepoint pair, on every write |
| The event log authoritative | Hijack | the same on creates (plus an id reservation); no savepoint on updates |
| Full event sourcing with tables kept current | ES-Sync | Hijack's cost plus the projection write |
| Full event sourcing, projection off the request path | ES-Async | fewer statements per write, but a read can run before its projection (read-your-writes) |
| Full event sourcing, tables brought up to date when read | ES-Lazy | the projection moves from the write to the first read that needs it |
| Audit and replay; writes and reads rare | ES-NoProj | every read rebuilds records from their events, and its cost grows with the log |

Reads are unaffected in every mode except ES-NoProj and, on the first read after
writes, ES-Lazy, so an application with a higher read fraction sees
proportionally less overhead.

## Reproducing

The benchmark harness runs against the testbed, which is part of the research
evaluation for the accompanying papers and is published with them.

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
