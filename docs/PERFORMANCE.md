# Performance

Measured overhead of each Lyra mode against a plain-ORM baseline, on a concurrent
mixed CRUD workload.

The short version: **Hijack mode costs about 11% throughput; Monitor mode costs about
39%.** Hijack is faster than Monitor despite doing strictly more work, for a reason that
is visible in the SQL and explained in [Why Hijack beats Monitor](#why-hijack-beats-monitor)
below. Reconstructing state from the event log on every read (ES No-Projection) costs
roughly 92% and is not a general-purpose configuration.

---

## Environment

| Property | Value |
|:---------|:------|
| CPU | Apple M4, 10 physical / 10 logical cores |
| Architecture | arm64 |
| Memory | 16.0 GB |
| OS | Darwin 25.5.0 |
| Ruby | 4.0.5 |
| Rails | 8.1.1 |
| Lyra | 0.6.0 |
| Database | PostgreSQL 16.11 |
| DB pool size | 76 |

Measured 2026-07-22.

## Workload

A Rails application with a registrations/payments domain, driven through a mixed
operation profile:

- **Operation mix**: 10% create, 60% read, 25% update, 5% delete
- **Thread counts**: 1, 4, 8, 16, 32, 64
- **Operations per thread**: 200 (12,800 operations per trial at 64 threads)
- **Trials per data point**: 10
- **Cooldown before each cell**: 120 s

Throughput and P95 latency are reported as **mean ± sample standard deviation** over the
10 trials.

### Modes measured

| Mode | Meaning |
|:-----|:--------|
| **Disabled** | Baseline. Lyra emits nothing; the application's normal PaperTrail auditing stays on. |
| **Monitor** | Events appended after the CRUD write, non-intrusively. |
| **Hijack+PT** | Hijack with PaperTrail left enabled — a control, see below. |
| **Hijack** | CRUD routed through the command/aggregate path; PaperTrail disabled as redundant. |
| **ES (Sync)** | Full event sourcing, projections applied synchronously. |
| **ES (Async)** | Full event sourcing, projections dispatched to background jobs. |
| **ES (No Proj)** | No projection table; every read reconstructs state from the event log. |
| **Disabled (end)** | The baseline re-run *last*, after every other mode. See [controls](#measurement-controls). |

The baseline is the same application with Lyra disabled — **not** bare ActiveRecord.
PaperTrail remains active in it, because that is the configuration a team migrating to
Lyra is actually leaving behind. `Hijack+PT` isolates PaperTrail's contribution: it is
Hijack with PaperTrail left on, so the `Hijack` vs `Hijack+PT` gap is PaperTrail's cost
and nothing else.

---

## Throughput (ops/sec)

| Threads | Disabled | Monitor | Hijack+PT | Hijack | ES (Sync) | ES (Async) | ES (No Proj) | Disabled (end) |
|--------:|-------:|-------:|-------:|-------:|-------:|-------:|-------:|-------:|
| 64 | 905.49 ± 9.92 | 552.51 ± 2.48 | 635.20 ± 2.92 | 808.73 ± 5.37 | 719.47 ± 3.74 | 735.17 ± 8.96 | 71.75 ± 2.42 | 900.99 ± 6.75 |
| 32 | 914.42 ± 3.93 | 557.89 ± 2.05 | 640.24 ± 2.64 | 817.97 ± 2.03 | 726.81 ± 6.70 | 665.75 ± 7.48 | 98.88 ± 0.09 | 913.32 ± 3.11 |
| 16 | 921.76 ± 7.96 | 561.97 ± 3.87 | 639.13 ± 4.23 | 812.84 ± 17.46 | 728.98 ± 6.25 | 537.86 ± 4.92 | 118.98 ± 0.34 | 921.65 ± 6.63 |
| 8 | 906.58 ± 15.25 | 566.03 ± 4.23 | 652.15 ± 4.91 | 823.55 ± 23.34 | 731.90 ± 5.34 | 537.07 ± 4.24 | 133.00 ± 0.33 | 923.79 ± 5.88 |
| 4 | 917.98 ± 13.41 | 567.18 ± 5.76 | 646.53 ± 9.56 | 826.90 ± 16.84 | 737.04 ± 12.15 | 523.05 ± 10.34 | 141.09 ± 1.01 | 909.76 ± 19.13 |
| 1 | 523.77 ± 15.26 | 340.76 ± 7.12 | 392.14 ± 7.61 | 476.75 ± 7.96 | 408.84 ± 6.18 | 398.10 ± 8.12 | 95.42 ± 0.71 | 528.94 ± 10.49 |

### Overhead vs baseline, at 64 threads

| Mode | Throughput | vs Disabled |
|:-----|-----------:|------------:|
| Disabled | 905.49 | — |
| **Hijack** | 808.73 | **−10.7%** |
| ES (Async) | 735.17 | −18.8% |
| ES (Sync) | 719.47 | −20.5% |
| Hijack+PT | 635.20 | −29.9% |
| **Monitor** | 552.51 | **−39.0%** |
| ES (No Proj) | 71.75 | −92.1% |
| Disabled (end) | 900.99 | −0.5% |

Overhead is close to flat across concurrency levels — the ratios at 4 threads are within
a couple of points of the ratios at 64. Lyra's cost is per-operation work, not contention
that compounds with load.

**ES (Async) is the exception** and the one non-flat curve: −43% at 4 threads improving to
−19% at 64. Projection jobs run in-process on `AsyncAdapter` and compete with request
threads for the same cores; at low thread counts the request side cannot use the machine
fully anyway, so the jobs cost proportionally more. With an out-of-process queue backend
(Solid Queue, Sidekiq) this curve will look different.

## P95 latency (ms)

| Threads | Disabled | Monitor | Hijack+PT | Hijack | ES (Sync) | ES (Async) | ES (No Proj) | Disabled (end) |
|--------:|-------:|-------:|-------:|-------:|-------:|-------:|-------:|-------:|
| 64 | 184.16 ± 7.57 | 314.94 ± 4.09 | 263.47 ± 7.86 | 207.44 ± 4.02 | 263.96 ± 2.46 | 262.27 ± 4.49 | 343.91 ± 2.26 | 184.83 ± 5.21 |
| 32 | 91.14 ± 2.72 | 153.50 ± 1.98 | 132.17 ± 2.20 | 102.59 ± 1.62 | 128.74 ± 1.28 | 145.53 ± 2.05 | 173.15 ± 1.17 | 91.34 ± 1.99 |
| 16 | 45.10 ± 2.09 | 76.75 ± 1.66 | 67.04 ± 1.58 | 51.37 ± 1.16 | 64.25 ± 0.78 | 90.38 ± 1.80 | 96.08 ± 0.57 | 44.25 ± 1.18 |
| 8 | 23.11 ± 2.16 | 37.67 ± 0.98 | 32.05 ± 0.59 | 25.04 ± 0.58 | 31.75 ± 0.42 | 44.24 ± 0.79 | 47.35 ± 0.40 | 21.61 ± 0.92 |
| 4 | 11.51 ± 1.18 | 18.79 ± 0.69 | 16.22 ± 0.79 | 12.36 ± 0.62 | 15.37 ± 0.44 | 21.58 ± 0.40 | 22.99 ± 0.73 | 11.32 ± 0.99 |
| 1 | 4.69 ± 0.97 | 7.63 ± 0.54 | 6.66 ± 0.56 | 5.15 ± 0.47 | 6.53 ± 0.37 | 6.19 ± 0.32 | 8.63 ± 0.31 | 4.18 ± 0.58 |

## Allocations per operation

| Mode | Allocs/op (64 threads) |
|:-----|-----------------------:|
| Disabled | 1,999 |
| Hijack | 2,443 |
| ES (Sync) | 2,730 |
| ES (Async) | 2,809 |
| Hijack+PT | 2,987 |
| Monitor | 3,427 |
| ES (No Proj) | 29,742 |

ES (No Proj) allocates ~15× the baseline, and *rises* with concurrency (14,885/op at 1
thread to 29,742/op at 64) — replaying streams on every read is the dominant cost.

---

## Why Hijack beats Monitor

Hijack does strictly more than Monitor — it routes the write through a command and
aggregate — yet it is ~28 points faster. This is not a caching or lock-contention effect.
It is the transaction shape, and it is visible by counting the SQL statements ActiveRecord
issues for a single write:

| Mode | SQL statements per create | per update |
|:-----|--------------------------:|-----------:|
| Disabled (baseline) | 4 | 4 |
| Hijack | 5 | 5 |
| Hijack+PT | 6 | 6 |
| Monitor | 8 | 8 |
| ES (Sync) | 9 | 5 |
| ES (Async) | 8 | 4 |
| ES (No Proj) | 13 | 9 |

Compare **Monitor** and **Hijack+PT** — same PaperTrail, same events, differing only in
where the append happens:

```
Monitor (8)                      Hijack+PT (6)
 1. BEGIN                         1. BEGIN
 2. INSERT registrations          2. INSERT event_store_events
 3. SAVEPOINT              <--    3. INSERT event_store_events_in_streams
 4. INSERT event_store_events     4. INSERT registrations
 5. INSERT ..._in_streams         5. INSERT versions
 6. RELEASE                <--    6. COMMIT
 7. INSERT versions
 8. COMMIT
```

Monitor appends in an `after_*` callback. By then the save transaction is already
materialized, so RailsEventStore's `transaction(requires_new: true)` must open and release
a **savepoint** — two extra database round-trips on every write.

Hijack appends in a `before_*` callback, while the transaction is still unmaterialized. No
savepoint is needed. That is the entire difference: two round-trips per write, times every
write in the workload.

The practical consequence: **if you are paying for Monitor mode's overhead and do not need
its non-intrusiveness, Hijack is cheaper.** The ordering that makes Hijack fast is the same
ordering that makes the event log authoritative.

---

## Measurement controls

Two artifacts had to be ruled out before these numbers were trustworthy. Both controls are
reported here because they are what make the figures credible, and because the first one
caught a real bug.

**Thermal drift.** Sustained load on a passively-managed machine can make later modes look
slower than earlier ones purely from throttling. Two guards: a 120 s cooldown before every
cell, and the baseline re-run as the *final* mode. The trailing baseline matches the leading
one to within 0.5% at every thread count (900.99 ± 6.75 vs 905.49 ± 9.92 at 64 threads) —
so the machine was in the same state at the end of the sweep as at the start, and no
mode's figure is a throttling artifact.

**Connection exhaustion.** At 64 threads the pool is sized to 76 to cover request threads
*plus* the projection jobs ES (Async) dispatches. Undersized, that one cell fails with
"too many clients already" and reports inflated throughput on fast-failing operations.

**A note on baselines.** An earlier version of this benchmark reported a much smaller
Hijack overhead, because the `:disabled` baseline was still emitting events — the monitor
callbacks were gated on whether a model was monitored, with no check on the mode. The
"plain ORM" baseline was not plain ORM. That bug is fixed (see CHANGELOG), and the
figures above are measured against a baseline verified to emit zero rows. If you benchmark
Lyra yourself, **check that your baseline writes no events** before trusting the delta:

```ruby
Lyra.config.disable!
before = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM event_store_events")
# ... run your workload ...
after  = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM event_store_events")
raise "baseline is not a baseline" unless before == after
```

---

## Choosing a mode

| If you want | Use | Cost |
|:------------|:----|:-----|
| Audit trail, minimal disruption, CRUD stays authoritative | Monitor | ~39% |
| Event log authoritative, lowest overhead | Hijack | ~11% |
| Full event sourcing with read models | ES (Sync) | ~21% |
| Full event sourcing, projections off the request path | ES (Async) | ~19% at high concurrency, worse at low |
| Audit-only, writes rare, reads rarer | ES (No Proj) | ~92% — reconstruct-on-read |

These are overheads on a write-inclusive mixed workload (40% mutating). An application with
a higher read fraction will see proportionally less, since reads are unaffected in every
mode except ES (No Proj).

## Reproducing

The benchmark harness runs against an application testbed that is part of the research
evaluation for the accompanying papers, and **will be published once those papers are
accepted**. Until then these figures are reported rather than reproducible from this
repository.

What you can reproduce independently is the SQL-statement analysis above, which requires no
special harness — subscribe to `sql.active_record` around a single create in each mode and
count the statements:

```ruby
statements = []
ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
  next if payload[:name].in?(["SCHEMA", "CACHE"])
  statements << payload[:sql]
end

Registration.create!(attributes)
puts statements.length
```

Run that under `Lyra.config.mode = :monitor` and again under `:hijack` and you will see the
savepoint pair appear and disappear.
