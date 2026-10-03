# Switching Modes

How Lyra keeps an application in one mode, and how to move it to another
safely. The safety rule comes from the thesis (Mode Transition Safety): a
switch that changes which store is authoritative is allowed only when the
rows and the events agree, for every monitored record.

## Who holds the mode

- **Each process holds the mode it runs in**, in its own memory
  (`Lyra.config.mode`, `Lyra.config.projection_mode`), set by the
  application's initializer (`config/initializers/lyra.rb`).
- **The database holds the application's mode**: the latest `applied` row in
  `lyra_mode_transitions`. A process writes one when it boots into a new mode
  (after the boot gate) and on every gated switch (`ModeTransition.to!`). The
  table also keeps the certificates of clean checks. Lyra creates it on first
  use; it needs no migration.
- **`Lyra::ModeSync` keeps the two in step.** At most every
  `config.mode_sync_interval` seconds (default 5) each process looks for a
  newer `applied` row and adopts its mode. It looks before each web request,
  each background job and each write to a monitored model, and never inside an
  open transaction, so a mode cannot change half-way through a write.

## Which switches are checked

| From | To | Checked? | Why |
|---|---|---|---|
| Disabled or Monitor | Hijack or any event-sourcing mode | yes | the events become authoritative, so they must reproduce every row |
| ES-NoProj, ES-Lazy or ES-Async | a mode that reads tables | yes | those tables lag the log by design; they must catch up first |
| anything else (Monitor → Disabled, ES-Sync → ES-NoProj, …) | | no | the authoritative store does not change |

A check imports rows that predate Lyra first (Genesis), compares every row and
every stream, re-checks what changed while it ran, and stores a clean result
as a certificate (valid for `config.mode_transition_certificate_ttl`, 1 hour by
default).

## The rule: switch modes with a deploy

Switching is a deploy, not a console command:

1. **Check ahead**, on the running application:
   ```bash
   bin/rails lyra:mode:check TO=hijack
   bin/rails lyra:mode:check TO=event_sourcing PROJECTION=sync
   bin/rails lyra:mode:check TO=monitor REBUILD=1   # leaving ES-NoProj
   ```
   It prints the discrepancies, if any, and certifies the switch when there
   are none. On a large table this is the slow part; it runs while the
   application keeps serving.
2. **Deploy the new configuration** (`config.mode = :hijack`, or the
   environment variable your initializer reads).
3. **The boot gate** lets each process start in the new mode only with a fresh
   certificate, after re-checking just what changed since the check. Without
   one, the process refuses to start and says which check to run.
4. **ModeSync** brings any process still running the old configuration (during
   a rolling deploy) into the new mode within seconds of the first new process
   recording it.

`bin/rails lyra:mode:status` shows the configured mode, the last applied one,
and whether the gate is on.

## Switching at run time

`Lyra::ModeTransition.to!(:hijack)` (and the `config.enable_*!` helpers after
boot) runs the same gate in the current process: a fresh certificate is
re-checked for what changed since, otherwise a full check runs. A clean switch
is recorded as the application's mode, so the other processes adopt it through
ModeSync; the log line says so. With ModeSync off, it says the switch reached
this process only. Use it for single-process work (a console during an
incident, a maintenance script, tests); for a planned change, prefer the deploy
above.

## Overrides

- `ModeTransition.to!(mode, force: true)` switches without the check.
- `LYRA_FORCE_MODE_TRANSITION=1` lets a process boot into an uncertified mode.
- Rake tasks are not gated at boot, so migrations and the check itself can run
  in any configuration.
- `config.mode = ...` is the raw setter: no gate, no record, and ModeSync does
  not override it unless another process records a new switch. Tests and the
  benchmark harnesses use it.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `mode_transition_gate` | `nil` | `nil` gates everywhere but the test environment; `true`; `false` |
| `mode_transition_certificate_ttl` | `3600` | seconds a clean check certifies a switch |
| `mode_sync` | `nil` | `nil` follows the gate; `true`; `false` |
| `mode_sync_interval` | `5` | seconds between a process's checks for a switch made elsewhere |
| `dual_view_sample_rate` | `0.0` | share of writes compared with their events after commit (sampled verification) |
| `dual_view_discrepancy_handler` | `nil` | called with each sampled discrepancy |
