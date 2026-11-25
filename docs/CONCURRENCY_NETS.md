# The concurrency nets

Lyra's lock orders were chosen, and are checked, on six Place/Transition Petri nets that its code
builds in `Lyra::Verification` (`lib/lyra/verification/`). PetriFlow's `ReachabilityAnalyzer`
explores each net's reachable markings exhaustively; an exploration that stops at its bound of states
raises instead of reporting. The nets are hand-built models of the code; the trace-conformance tests
(`test/verification/lock_trace_conformance*_test.rb`) record the order in which the code's own runs
take their locks and replay each recorded order on the net as a firing sequence.

| Net | Class | What it decides |
|---|---|---|
| Writers on one record | `ConcurrentWritersNet` | The lock on the aggregate (serialized access) and the history clauses at the append, per mode |
| ES-Lazy's catch-up | `LazyCatchUpNet` | The catch-up in a transaction of its own rather than the reader's |
| ES-Lazy's lock order | `LazyLockOrderNet` | A locking read takes the aggregate lock, the row, then the stream head |
| ES-Async's lock order | `AsyncLockOrderNet` | A locking read takes the aggregate lock, the stream lock, then the row; the job's last pass |
| The mode gate's settle | `GateSettleNet` | A switch's certificate covers no write it did not see |
| Locks across records | `MultiRecordLockNet` | ES-NoProj's locks add no deadlock to plain Active Record's, for any number of transactions |

## Conventions

- **A lock** is a place holding one token when free. Taking it is an arc from the place into a
  writer's transition; a commit releases every lock its writer holds.
- **A value** (the log's, the row's, a checkpoint's) is a set of alternative places `v0 … vN`, exactly
  one marked. Reading `vk` takes its token and puts it back; writing moves it.
- **A writer** is a chain of places from `start` to `done`, one token in it, whose transitions are the
  steps the code takes, in the code's order; a step that can happen in more than one way branches.
- **A property** is a place that a transition marks when a run breaks it (so it holds when no
  reachable marking marks it), or a condition on the terminal markings. A **deadlock** is a terminal
  marking with a writer not at `done`: a wait cycle, which PostgreSQL detects and breaks by aborting a
  transaction.

## Writers on one record (`ConcurrentWritersNet`)

**Places.** The stream's committed status (absent, live, gone) and value (`l0 … lN`, the updates
applied); the row's status and value (`r0 … rN`) where the configuration has a row; the aggregate
lock `L` where it has one.

**A writer** runs one operation. An update: take `L` (before the read, as `with_lock` takes it), read
`k` from the row or the stream, take `L` (before the append, as Lyra takes it for every write), check
the operation against the stream's status (the history clauses, at the append), commit `k+1` to the
log and, in a mode that writes its table in the transaction, to the row, in one step. A lagging mode
(ES-Async, ES-Lazy) projects the row in a separate transition, later. Monitor writes the row first,
with the database's refusals.

**Properties.** `bad_double_created`, `bad_headless`, `bad_after_destroy` (the history clauses);
`bad_lost_update` (counted against Lyra only when the writer read under the lock); `bad_overlap`
(two writers inside the lock's critical section); and, at rest, row and stream agreeing.

**Configurations** (`CONFIGS`): the mode (table, lagging, events only, Monitor), where the lock is
taken, whether a create takes it, the guard, and whether an update reads the row or the stream.
`explore_all` runs every multiset of operations of the given number of writers, from an absent and
from a live record. With the lock taken before the read, no configuration reaches a bad marking.

## ES-Lazy's catch-up (`LazyCatchUpNet`)

**Places.** One record: the log's value and the row's projected value (starting with one event
committed and not projected), the catch-up's lock `g` (one for all records), and the row lock `x`.

**Writers.** Each updates once: plain (takes `x` at its append), `with_lock` (holds `x` from its locking
read to its commit), or rereading (reads again under `x`).

**Designs.** Lyra's: `with_lock` takes `x` first and, under it, replays its own record and reads; a
plain writer's read first catches up in a transaction of its own: it takes `g` and `x`, brings the row up
to the log and commits at once (or skips the row where another transaction holds `x`). The alternative:
the catch-up runs in the reader's transaction and holds `g` and the row to the reader's commit.

**Properties.** Deadlock; `bad_lost_update` (a `with_lock` commit from a value the log had moved past);
`bad_stale_read` (a read under `x` of a row behind the log). Lyra's design reaches none; the
alternative deadlocks in some mixes and loses updates and reads stale rows in others.

## ES-Lazy's lock order (`LazyLockOrderNet`)

**Places.** One record; locks `a` (aggregate, advisory), `x` (row), `h` (stream head), `c` (catch-up,
advisory, one for all records); the log's and the row's values.

**Writers.** `plain` (`a`, `h`, commit; its read's catch-up runs on a connection of its own, takes no
lock a writer holds, and is left out of the net); `bulk` (`a`, `x`, `h`); `writes_then_reads` (appends, then reads again, replaying
its own uncommitted event onto the row under `x`); the locking reader, `with_lock_a_first` (`a`, `x`,
`h`, replay, read, commit `+1`) and its alternative `with_lock_x_first`; and the fallbacks where no
second connection is free (`plain_inline`, `writes_then_reads_inline`, `falls_back_then_reads`), with
the catch-up's bounded wait for `c`.

**Properties.** Deadlock; **hang** (a deadlock through a wait for `c` on a connection of its own, which
PostgreSQL's detector cannot see); `bad_lost_update`. With `a` first, no mix of up to four writers
deadlocks; with `x` first, some three-writer mixes do.

## ES-Async's lock order (`AsyncLockOrderNet`)

**Places.** Locks `a` (aggregate), `s` (the stream's), `x` (row; a held `x` also marks `x_taken` for
`SKIP LOCKED`); values `l` (log), `r` (row), `c` (the job's checkpoint).

**Actors.** `writer` (`a`, append, commit; its job runs after); `bypass` (a write that skips callbacks:
`a`; if behind, `s` and the row brought up to date; `x`; write; move `c`); `ryw` (read-your-writes);
the locking reader `with_lock_ordered` (`a`, `s`, `x`, row up to date, write) and its alternatives; and
the job (`s`, the row with `SKIP LOCKED`: free, apply the events after `c`; taken, let `s` go and
retry; after its retries, its last pass).

**Properties.** Deadlock; `diverged_at_rest` (every actor done, the row not the log's value). In the
order Lyra takes, no mix of up to four actors deadlocks, and a job's last pass never leaves the row
behind its log.

## The mode gate's settle (`GateSettleNet`)

**The gate** reads the store's position `P`, settles it (waits for every transaction that held a
transaction id when it was read, or refuses after a timeout), compares each record, reads `P2`,
settles it, and re-checks every record with an event above `P`; the certificate keeps `P2`.

**Writers**, one event each on records of their own: begin, take a transaction id, insert the event
(its id the next), commit. In Lyra the transaction id comes first (the stream head is written before
the append); `xid_first: false` models the other order.

**Property.** `missed`: a certificate covering an event, with an id up to `P2`, that neither the
comparison nor the re-check saw. With the transaction id first, no reachable marking has one, for two
and three writers; without it, one does.

## Locks across records (`MultiRecordLockNet`)

**Places.** For each record `r`: `a_r` (plain Active Record's row lock; ES-NoProj's aggregate lock) and,
in ES-NoProj, `h_r` (its stream head), all held to the commit.

**Transactions** are programs of steps: a write of `r` (`a_r`; ES-NoProj `a_r` then `h_r`); a locking
read of `r` (`a_r`); a locking read of several records (plain: their row locks in the scan's order, any;
ES-NoProj: their aggregate locks in stream-name order); a bulk write (plain: the scan's order; ES-NoProj:
the aggregate locks in one statement, in the keys' hash order, then the heads). Plain Active Record's
scan order is a choice made before the step takes a lock. `read: :all` models a locking read that
locks every record of the model before narrowing to its own.

**Property and conditions.** Deadlock. `#conditions` checks three conditions on the net's structure —
a head is taken only under its record's aggregate lock, a step locks only its own records, in an order
plain Active Record's scans can take — which make every deadlock ES-NoProj can reach one plain Active
Record can reach, for any number of transactions, steps and records. Assumed: each record's lock is its
own (the advisory locks are keyed by a 32-bit hash; two streams whose keys collide share one).
Explored: over every mix of two transactions of two steps on three records, with single-record steps
the deadlocking mixes equal plain Active Record's (48 of 666); with every step kind, 8,056 of 19,306
deadlock in ES-NoProj, all among plain Active Record's 13,192; `read: :all` deadlocks in 219 of the 666.

## Running them

```sh
# the tests (exploration, conditions, trace conformance)
bundle exec ruby -Ilib -Itest test/verification/multi_record_lock_net_test.rb   # and the other *_net_test.rb
# the two scripts below are in the monorepo and the replication package (benchmarks/petri-concurrent-writers/),
# not in the gem: the bounded check the benchmark campaign runs (up to five writers)
bundle exec ruby -Ilib -Igems/petri_flow/lib benchmarks/petri-concurrent-writers/bounded.rb
# one configuration of each net as PNML and Graphviz DOT, with a summary of its exploration
bundle exec ruby -Ilib -Igems/petri_flow/lib benchmarks/petri-concurrent-writers/export_nets.rb OUT_DIR
dot -Tsvg OUT_DIR/multi_record.dot -o multi_record.svg   # Graphviz, to draw one
```

The PNML files open in Petri-net tools that read the ISO/IEC 15909-2 interchange format. The full nets
are large (the writers net's exported configuration has 512 transitions); the figures in the thesis
(Appendix C, "The Concurrency Nets") draw one writer of each, folded.
