# Adopting Lyra in an Existing Application

What "non-intrusive" means for Lyra, what adopting it costs, and what to check
in your own codebase before relying on it. Written from the real-data replays
(BPI Challenge 2017 and Olist orders through an unmodified Solidus 4.7; see
`BPI2017_REAL_DATA_FINDINGS.md`) and the Aegean ePay testbed.

## What "non-intrusive" means here

**It holds in two senses:**

- **No application code changes.** Solidus needed only the gem, an
  initializer, and `monitor_with_lyra` added to its models from outside
  (`class_eval`). No Solidus source was edited.
- **The same results as plain ActiveRecord**, in Monitor, Hijack, ES-Sync and
  ES-Lazy. On both replays these modes ended in the state an independent
  oracle expects (computed from the source data alone) and matched Disabled
  mode, with DualView finding every row consistent with its events.

**It does not mean:**

- **Zero cost.** Every mode costs throughput (below).
- **Unchanged behaviour in every mode.** ES-NoProj answers reads differently.
- **That Lyra sees every write.** Writes that bypass ActiveRecord never reach
  it.

## Is it worth it?

**Yes, when you want what only it gives you:**

- a complete event history of an application you cannot or will not rewrite;
- a migration path toward event sourcing in which every step is checked
  (DualView, and an oracle where you can build one) and can be undone by
  switching mode.

Its costs are the price of those two things, and each one can be measured
before you commit: start in Monitor against real traffic, which changes no
results.

**Probably not, if:**

- you need neither a history nor a migration, and your hot path is
  write-heavy and latency-critical;
- a large share of your writes are raw SQL or database triggers (Lyra cannot
  see them);
- you want to replay on every read (ES-NoProj) in code that reads through
  joins and merged relations. Use ES-Lazy, or stay with a projected mode.

## Costs, and what to do about each

| Caveat | Effect | What to do |
|---|---|---|
| **Throughput** | Every mode costs throughput against plain ActiveRecord. Published M4 figures: Hijack −10.7%, ES-Sync/Async −19 to −21%, Monitor −39.0% (it appends inside the row's transaction). These are being re-measured on the fixed code (`docs/PERFORMANCE.md`, `BENCHMARKING.md`). | Measure on your workload in Monitor first. The cost is per write, so it scales with your write share. |
| **ES-NoProj changes read semantics** | Reads come from event streams. Queries it cannot answer exactly (joins, merged relations, SQL fragments, association filters it cannot evaluate) raise `UnsupportedQuery` rather than guess. It cannot run Solidus. | Use **ES-Lazy** (`projection_mode :lazy`): it brings tables up to date from the log before each read and runs real SQL. |
| **ES-NoProj read cost** | Every answer is rebuilt from streams, from cached entries that are each checked against their stream's last event. Collection reads touch every stream of the model. A delete that nullifies children must find them by attribute: 0.1–0.4 s in the Aegean smoke runs. A filter on a `belongs_to` association compares foreign keys, as ActiveRecord does, but every collection read still assembles the whole model from the cache: about 1.3 s per query over 10,000 rows in the mode-comparison benchmark, against 1–6 ms with real SQL. | Keep ES-NoProj for code that reads through simple finders, or use ES-Lazy. |
| **Monitor and failed appends** | In Monitor, if the event append fails, the write still succeeds and the failure is only logged. | Alert on the log. If losing events is unacceptable, use Hijack or an event-sourcing mode, where the append is the write. |
| **Global hooks** | Hijack and the event-sourcing modes take over writes through modules prepended to `ActiveRecord::Persistence` and `ActiveRecord::Relation`. They act only on monitored models, and they switch PaperTrail off for those models. | Expect them in stack traces. If you rely on PaperTrail versions for monitored models, rely on Lyra's events instead. |
| **Bulk writes record events** | `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify` on a monitored model publish one event per affected row. | Wrap seeding, fixtures and table wipes in `Lyra.projection_write { … }`, which publishes nothing. |
| **Rows that predate Lyra** | In event-sourcing modes, a model's first use imports every row that has no stream yet (Genesis), so it can be slow once. | Run `rake lyra:genesis MODEL=…` before switching modes on large tables. |
| **Writes Lyra cannot see** | Raw SQL (`connection.execute`), database triggers, other applications writing the same tables. | Find them before you rely on the history. DualView reports the rows they changed as discrepancies. |
| **Unverified codebases** | Each real-data replay found Lyra defects that broke these guarantees until fixed: namespaced models could not use Hijack or event sourcing at all, events were built before the model's own callbacks ran, and `update_columns`/`touch` writes went unrecorded. | Treat "the hook sees every write" as something to verify for your codebase, not to assume. See the checklist. |

## Checklist for a new codebase

1. **Start in Monitor** against real traffic. Nothing changes but cost and
   the event log.
2. **Run DualView** over the monitored models (`Lyra::DualView`). A
   discrepancy means a write Lyra did not see, or a defect.
3. **Search for writes outside ActiveRecord**: `execute`, `exec_update`,
   triggers in the schema, other writers to the database.
4. **Wrap housekeeping bulk writes** in `Lyra.projection_write`.
5. **Import existing rows** with `rake lyra:genesis` before an
   event-sourcing mode.
6. **Pick the event-sourcing variant by how the code reads.** ES-Sync for
   table-shaped reads. ES-Lazy if reads use joins or merged relations.
   ES-NoProj only for simple finders.
7. **Where you can, replay a real workload with an oracle.** The BPI and
   Olist harnesses (`examples/bpi2017_loan_app`,
   `examples/solidus_case_study/lib/olist`) are templates. An oracle catches
   writes that never reached the database, which DualView cannot, because
   both of its views come from the same system.

## Evidence

- `BPI2017_REAL_DATA_FINDINGS.md`: the replays, the defects they found, and
  the fixes.
- `docs/PERFORMANCE.md` and `BENCHMARKING.md`: per-mode cost, and how to
  measure it.
- `CHANGELOG.md`: what changed and why, entry by entry.
