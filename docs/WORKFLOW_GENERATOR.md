# Lyra Workflow Generator

Petri net workflow models generated from the Lyra implementation, and the
other verification nets that ship with Lyra.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Generated Workflows](#generated-workflows)
- [Output Files](#output-files)
- [API Reference](#api-reference)
- [Integration with PetriFlow](#integration-with-petriflow)
- [Other Verification Nets](#other-verification-nets)
- [Verification View](#verification-view)
- [Troubleshooting](#troubleshooting)

---

## Overview

`Lyra::Verification::WorkflowGenerator` (`lib/lyra/verification/workflow_generator.rb`)
builds PetriFlow workflow models of Lyra's write paths. They can be used for:

- **Formal verification** with PetriFlow (reachability, boundedness, liveness)
- **Documentation** of how each mode handles a write
- **Visualization** as Mermaid diagrams

The generator covers four modes, `WorkflowGenerator::AVAILABLE_MODES`:
Monitor, Hijack, ES-Sync and ES-Async. It has no nets for ES-NoProj or
ES-Lazy, and none for Disabled. Lyra's seven configurations are described in
[API_REFERENCE.md](API_REFERENCE.md#the-seven-configurations).

The mode nets themselves are written into the generator by hand. What it
reads from the running application is:
- the current mode (`Lyra.config.mode`)
- the monitored models (`Lyra.config.monitored_models`), with their table,
  event prefix and ActiveRecord callback chains
- the event classes defined under `Lyra::Events`
It does not read Lyra's own callback names: those are registered by
`monitor_with_lyra` (`Lyra::Interceptors::CrudInterceptor`), and the
lifecycle net's transitions use the triggers `after_create`, `after_update`
and `after_destroy`.

For the CRUD-to-event mapping check that runs the full set of nets, see
[Other Verification Nets](#other-verification-nets).

---

## Prerequisites

1. **PetriFlow** (the `orfeas_petri_flow` gem, whose entry file is `petri_flow`):

```ruby
# Gemfile
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"
```

2. **A Rails application that loads Lyra.** The rake tasks depend on
   `:environment`, so run them from the application, not from the Lyra
   repository root (which has no Rails application of its own).

```ruby
Lyra.petri_flow_available?    # => true/false
Lyra.verification_available?  # => the same
```

---

## Usage

The tasks are defined in `lib/tasks/lyra_workflows.rake`.

### Generate all workflows

```bash
bin/rails lyra:workflows:generate
bin/rails lyra:generate_workflows      # alias
```

This prints the analysis and writes one file for the lifecycle net and one per
mode (Monitor, Hijack, ES-Sync, ES-Async), plus a Markdown report.

### Generate one mode

```bash
MODE=monitor  bin/rails lyra:workflows:generate
MODE=hijack   bin/rails lyra:workflows:generate
MODE=es_sync  bin/rails lyra:workflows:generate
MODE=es_async bin/rails lyra:workflows:generate
MODE=all      bin/rails lyra:workflows:generate   # same as no MODE
```

With a single mode only that mode's file is written, alongside
`lifecycle_workflow.rb`. It has the same name and class as in a full run
(`MODE=monitor` writes `monitor_mode_workflow.rb` defining `MonitorModeWorkflow`;
`MODE=es_sync` writes `es_sync_mode_workflow.rb` defining `EsSyncModeWorkflow`),
so it replaces the file a full run wrote. See [Output Files](#output-files).

### Output locations

```bash
OUTPUT_DIR=tmp/workflows  bin/rails lyra:workflows:generate   # workflow files
REPORTS_DIR=tmp/reports   bin/rails lyra:workflows:generate   # reports
```

`OUTPUT_DIR` and `REPORTS_DIR` override the default directories (relative paths
are expanded against the current directory).

### Verify

```bash
bin/rails lyra:workflows:verify
```

Generates the four mode nets in memory, runs PetriFlow's verification on each,
and prints for each: reachable states, terminal states, whether it is safe
(1-bounded) and bounded, the maximum token count, whether it terminates
properly (deadlock-free except at terminal places), the raw deadlock-free
result (which counts the terminal marking as a deadlock), and a liveness
score. It writes no files.

---

## Generated Workflows

### 1. Lifecycle Workflow

The CRUD entity lifecycle:

```
States: nonexistent → created → persisted → updated → destroyed → deleted
```

| Transition | From | To | Trigger |
|------------|------|-----|---------|
| create | nonexistent | created | after_create |
| emit_created_event | created | persisted | publish Created event |
| update | persisted | updated | after_update |
| emit_updated_event | updated | persisted | publish Updated event |
| destroy | persisted | destroyed | after_destroy |
| emit_destroyed_event | destroyed | deleted | publish Destroyed event |

The `persisted ↔ updated` cycle is intentional: a record can be updated any
number of times. The terminal place is `deleted`.

### 2. Monitor Mode Workflow

```
idle → crud_executing → crud_completed → event_building → event_publishing → completed
```

The write runs as usual; the event is built and stored after it.

### 3. Hijack Mode Workflow

```
idle → crud_intercepted → command_created → command_validating →
command_valid → event_created → event_stored → projecting → completed
```

The write is turned into a command, its event is stored first, and the row is
written from it.

### 4. ES Sync Mode Workflow

```
idle → command_received → aggregate_loading → aggregate_loaded →
command_applying → events_generated → events_storing → events_stored →
projecting_sync → projection_complete → completed
```

The projection runs before the write returns.

### 5. ES Async Mode Workflow

Asynchronous projection, modelled with a **fork**:

```
idle → command_received → aggregate_loading → aggregate_loaded →
command_applying → events_generated → events_storing → events_stored →
async_fork ──┬──→ response_returned (terminal: immediate response)
             └──→ job_processing → projecting_async → projection_complete (terminal: eventual)
```

The `async_fork` transition puts a token in two places at once:
- `response_returned`: the caller gets its response without waiting
- `job_processing`: the background projection starts

Both `response_returned` and `projection_complete` are terminal places.

### Fork vs Choice

| Pattern | Visual | Semantics |
|---------|--------|-----------|
| **Choice** | `A → T1 → B` or `A → T2 → C` | One of several transitions fires (exclusive OR) |
| **Fork** | `A → T → [B, C]` | One transition, both outputs (parallel AND) |

```ruby
# Choice: several transitions from the same place
transition :cancel, from: :order, to: :cancelled
transition :complete, from: :order, to: :completed

# Fork: one transition to several places
transition :async_fork, from: :events_stored, to: [:response_returned, :job_processing]
```

---

## Output Files

### Workflow files

Written to `OUTPUT_DIR` if set, otherwise to `app/workflows/`:
- when the application is the Lyra gem itself (its root holds `lyra.gemspec`,
  or `Rails.root` lies inside the gem): Lyra's own `app/workflows/`
- otherwise: `<Rails.root>/app/workflows/`

| File | Class |
|------|-------|
| `lifecycle_workflow.rb` | `LifecycleWorkflow` |
| `monitor_mode_workflow.rb` | `MonitorModeWorkflow` |
| `hijack_mode_workflow.rb` | `HijackModeWorkflow` |
| `es_sync_mode_workflow.rb` | `EsSyncModeWorkflow` |
| `es_async_mode_workflow.rb` | `EsAsyncModeWorkflow` |

The classes are top-level constants named after their files
(`WorkflowGenerator.workflow_file_basename(mode)` and
`.workflow_class_name(mode)`), so Zeitwerk can load them from
`app/workflows/`. Lyra ships a generated set in its own `app/workflows/`.

### Report files

Written to `REPORTS_DIR` if set, otherwise to `<Rails.root>/reports/`:

| File | Content |
|------|---------|
| `workflow_analysis_<timestamp>.md` | The analysis and every generated net, with Mermaid diagrams |
| `workflow_analysis_latest.md` | The same, overwritten on each run |

### Example generated class

```ruby
# frozen_string_literal: true
# Auto-generated by Lyra::Verification::WorkflowGenerator
# Generated at: <time>

# Monitor Mode Workflow
# Passively observes CRUD operations without modification
class MonitorModeWorkflow < PetriFlow::Workflow
  workflow_name "Monitor Mode Workflow"

  places :idle, :crud_executing, :crud_completed, :event_building, :event_publishing, :completed
  initial_place :idle
  terminal_places :completed

  transition :receive_crud,
             from: :idle,
             to: :crud_executing,
             trigger: "ActiveRecord callback triggered"

  transition :crud_success,
             from: :crud_executing,
             to: :crud_completed,
             trigger: "CRUD operation completes successfully"

  # ... more transitions
end
```

---

## API Reference

### WorkflowGenerator

```ruby
require "lyra/verification/workflow_generator"

generator = Lyra::Verification::WorkflowGenerator.new

result = generator.generate!                   # lifecycle + all four mode nets
result = generator.generate!(mode: :monitor)   # lifecycle + one mode net
```

An unknown mode raises `ArgumentError`. The nets are only built when PetriFlow
is loaded; otherwise the workflow entries are `nil` (or `{}`).

### Result structure

```ruby
{
  lifecycle_workflow: {
    name: "CRUD Entity Lifecycle (Generated)",
    places: [:nonexistent, :created, :persisted, :updated, :destroyed, :deleted],
    initial_place: :nonexistent,
    terminal_places: [:deleted],
    transitions: [...],
    generated_at: Time,
    source: "Lyra::Verification::WorkflowGenerator"
  },

  # with mode:
  mode_workflow: { name:, description:, places:, initial_place:, terminal_places:, transitions:, ... },

  # without mode:
  mode_workflows: { monitor: {...}, hijack: {...}, es_sync: {...}, es_async: {...} },

  analysis: {
    modes: [:monitor, :hijack, :es_sync, :es_async, :disabled],   # a fixed list
    current_mode: :monitor,
    mode_methods: { monitor: true, hijack: true, event_sourcing: true },
    callbacks: { create: [], update: [], destroy: [] },
    callback_hooks: { before: [], after: [] },
    models: [ { name:, table_name:, callbacks:, event_prefix:, ... } ],
    event_types: [ { name:, class:, attributes: } ],
    crud_events: [:Created, :Updated, :Destroyed]
  }
}
```

### Available modes

```ruby
Lyra::Verification::WorkflowGenerator::AVAILABLE_MODES
# => [:monitor, :hijack, :es_sync, :es_async]
```

---

## Integration with PetriFlow

### Loading a generated workflow

In the application, Zeitwerk loads the classes from `app/workflows/`:

```ruby
workflow = MonitorModeWorkflow.new
```

### Running verification

```ruby
result = workflow.verify!

result[:boundedness][:is_bounded]
result[:boundedness][:is_safe]
result[:reachability][:total_reachable_states]
result[:liveness][:terminates_properly]   # deadlock-free except at terminal places
result[:liveness][:deadlock_free]         # raw: counts the terminal marking as a deadlock
workflow.terminal_reachability            # { completed: true }
```

`verify!` passes the workflow's terminal places to `PetriFlow.verify`, so
`liveness[:terminates_properly]` is the property the thesis calls
deadlock-freedom: a reachable marking in which nothing can fire is a deadlock
only if it marks no terminal place (`PetriFlow::Verification::LivenessChecker`).
The raw `deadlock_free` is false for every net that is meant to finish,
including the lifecycle net, whose update cycle does not prevent it from
terminating properly.

### Visualizations and export

```ruby
workflow.to_mermaid   # Mermaid source
workflow.to_dot       # GraphViz DOT source
workflow.simulate(steps: 20)

PetriFlow.save(workflow.net, "monitor_workflow.pnml")   # format from the extension
PetriFlow.save(workflow.net, "monitor_workflow.json")
```

---

## Other Verification Nets

The generated nets describe the modes; the nets Lyra checks its mapping with
live in `lib/lyra/verification/`:

- `CrudLifecycleWorkflow`, and `CreateModeWorkflow`, `UpdateModeWorkflow`,
  `DestroyModeWorkflow` (one per operation, branching on the mode)
  (`crud_lifecycle_workflow.rb`).
- `Lyra::Verification::BypassWorkflow` (`bypass_workflow.rb`): the writes
  that skip ActiveRecord callbacks (`update_column(s)`, `delete`, `touch`,
  `update_all`, `delete_all`, `insert_all(!)`, `upsert_all`, and
  `dependent: :nullify`), as `StrictDataAccess` and `CachedRelation`
  implement them, with strict mode on or off and a table-backed or
  events-only store. `BypassWorkflow.coverage` checks Bypass Coverage: every
  reachable marking in which nothing can fire is either a rejection or a
  store change with an event logged; it returns `covered:`, `dead_markings:`
  and `silent_writes:`. `BypassWorkflow::METHODS` is kept equal to the
  methods Lyra overrides by `test/verification/bypass_workflow_test.rb`.
- `Lyra::Verification::CrudVerifier#verify_all` runs the lifecycle net, the
  three operation nets, the bypass net and every `*_workflow.rb` found in
  Lyra's and the application's `app/workflows/`, and summarises them
  (`lifecycle_valid`, `modes_valid`, `all_terminals_reachable`,
  `deadlock_free` (the terminal-aware check), `bypass_covered`).

`Lyra.verify_crud_mapping` returns that report. `Lyra.verify_mapping!` raises
`Lyra::MappingVerificationError` naming every failed check (and any monitored
model without a table or primary key). To run it at boot:

```ruby
# config/initializers/lyra.rb
Lyra.configure do |config|
  config.models = %w[Order Payment]
  config.verify_mapping!   # after boot, it verifies immediately
end
```

See [API_REFERENCE.md](API_REFERENCE.md#formal-verification-needs-petri_flow).

---

## Verification View

With the engine mounted at `/lyra`, the dashboard's verification page is
`/lyra/verification` (JSON: `/lyra/verification.json`). It runs
`CrudVerifier#verify_all` and shows:

1. **Lifecycle Workflow**
2. **CRUD Mode Verification Workflows**: the Create, Update and Destroy nets
3. **Bypass writes**: whether every callback-bypassing write is recorded
4. **Generated Mode Workflows**: the files in `app/workflows/`

For each net: reachable states, terminal states, whether it is 1-bounded,
whether it is deadlock-free except at terminal places, terminal state
reachability, and a Mermaid diagram.

---

## Troubleshooting

### PetriFlow not available

```
Error: PetriFlow gem is required
```

Add the `orfeas_petri_flow` gem (with `require: "petri_flow"`) to the
Gemfile and run `bundle install`.

### Invalid mode

```
Error: Invalid mode 'foo'
Available modes: monitor, hijack, es_sync, es_async, all
```

Use one of the listed modes.

### "No callbacks detected in source"

Expected with the current code: the generator looks for callbacks in
`lib/lyra/monitorable.rb`, which does not exist. The lifecycle net then uses
the default triggers; the nets are otherwise unaffected.

### "Don't know how to build task 'environment'"

The tasks need a Rails application; run them from one that loads Lyra.
