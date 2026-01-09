# Lyra Workflow Generator

Automatic Petri net workflow generation from Lyra implementation via metaprogramming introspection.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Generated Workflows](#generated-workflows)
- [Output Files](#output-files)
- [API Reference](#api-reference)
- [Integration with PetriFlow](#integration-with-petriflow)

---

## Overview

The Workflow Generator uses Ruby metaprogramming to analyze Lyra's implementation and automatically generate Petri net workflow models. These models can be used for:

- **Formal verification** of CRUD→Event mapping correctness
- **Documentation** of system behavior
- **Analysis** using PetriFlow verification tools
- **Visualization** with Mermaid diagrams

The generator introspects:
- Available Lyra modes (monitor, hijack, es_sync, es_async)
- ActiveRecord callbacks registered by Lyra::Monitorable
- Monitored models and their configurations
- Event types published by the system

---

## Prerequisites

### Required Dependencies

1. **PetriFlow gem** - Required for workflow generation and verification

```ruby
# Gemfile
gem 'petri_flow', path: 'gems/petri_flow'
```

2. **Rails environment** - The generator runs as a rake task

### Checking Availability

```ruby
# In Rails console or code
Lyra.petri_flow_available?  # => true/false
Lyra.verification_available?  # => true/false (alias)
```

---

## Usage

### Generate All Workflows

Generate workflows for all Lyra modes:

```bash
bundle exec rake lyra:generate_verification_model
```

This generates separate files for:
- Lifecycle workflow (CRUD entity states)
- Monitor mode workflow
- Hijack mode workflow
- ES Sync mode workflow
- ES Async mode workflow

### Generate Specific Mode

Generate workflow for a single mode:

```bash
# Monitor mode only
MODE=monitor bundle exec rake lyra:generate_verification_model

# Hijack mode only
MODE=hijack bundle exec rake lyra:generate_verification_model

# Event Sourcing Sync mode
MODE=es_sync bundle exec rake lyra:generate_verification_model

# Event Sourcing Async mode
MODE=es_async bundle exec rake lyra:generate_verification_model
```

---

## Generated Workflows

### 1. Lifecycle Workflow

Models the CRUD entity lifecycle:

```
States: nonexistent → created → persisted → updated → destroyed → deleted
```

| Transition | From | To | Trigger |
|------------|------|-----|---------|
| create | nonexistent | created | after_create callback |
| emit_created_event | created | persisted | publish Created event |
| update | persisted | updated | after_update callback |
| emit_updated_event | updated | persisted | publish Updated event |
| destroy | persisted | destroyed | after_destroy callback |
| emit_destroyed_event | destroyed | deleted | publish Destroyed event |

**Note:** The `persisted ↔ updated` cycle is intentional - entities can be updated multiple times.

### 2. Monitor Mode Workflow

Passive observation of CRUD operations:

```
idle → crud_executing → crud_completed → event_building → event_publishing → completed
```

- CRUD operations execute normally
- Events are published after the fact
- No modification to original operation

### 3. Hijack Mode Workflow

Intercepts CRUD operations:

```
idle → crud_intercepted → command_created → command_validating →
command_valid → event_created → event_stored → projecting → completed
```

- CRUD intercepted before execution
- Converted to Command/Event pattern
- State projected from events

### 4. ES Sync Mode Workflow

Full event sourcing with synchronous projection:

```
idle → command_received → aggregate_loading → aggregate_loaded →
command_applying → events_generated → events_storing → events_stored →
projecting_sync → projection_complete → completed
```

- Command drives aggregate
- Events generated and stored
- Projection blocks until complete

### 5. ES Async Mode Workflow

Full event sourcing with asynchronous projection using **fork pattern**:

```
idle → command_received → aggregate_loading → aggregate_loaded →
command_applying → events_generated → events_storing → events_stored →
async_fork ──┬──→ response_returned (terminal: immediate response)
             └──→ job_processing → projecting_async → projection_complete (terminal: eventual)
```

**Fork Pattern:** The `async_fork` transition uses Petri net fork semantics - a single transition produces tokens in TWO places simultaneously:
- `response_returned` - Caller gets response immediately (non-blocking)
- `job_processing` - Background projection starts independently

- Two terminal states: `response_returned` (immediate) and `projection_complete` (eventual)
- Background job handles projection
- Eventually consistent read model

### Fork vs Choice Pattern

The ES Async workflow uses a **fork** pattern, which is different from a **choice** pattern:

| Pattern | Visual | Semantics |
|---------|--------|-----------|
| **Choice** | `A → T1 → B` or `A → T2 → C` | Pick ONE transition (exclusive OR) |
| **Fork** | `A → T → [B, C]` | ONE transition, BOTH outputs (parallel AND) |

```ruby
# Choice pattern (multiple transitions from same place)
transition :cancel, from: :order, to: :cancelled
transition :complete, from: :order, to: :completed

# Fork pattern (one transition to multiple places)
transition :async_fork, from: :events_stored, to: [:response_returned, :job_processing]
```

---

## Output Files

### Workflow Files

Workflow files are generated in `app/workflows/` directory:
- **Lyra gem context**: `lyra/app/workflows/`
- **Normal application**: `<rails_root>/app/workflows/`

| File | Content |
|------|---------|
| `lifecycle_workflow.rb` | CRUD lifecycle PetriFlow class |
| `monitor_mode_workflow.rb` | Monitor mode PetriFlow class |
| `hijack_mode_workflow.rb` | Hijack mode PetriFlow class |
| `es_sync_mode_workflow.rb` | ES Sync mode PetriFlow class |
| `es_async_mode_workflow.rb` | ES Async mode PetriFlow class |

### Report Files

Report files are generated in `reports/` directory:

| File Pattern | Content |
|--------------|---------|
| `workflow_analysis_<timestamp>.md` | Timestamped report for history |
| `workflow_analysis_latest.md` | Latest report for easy access |

### Example Generated Class

```ruby
# frozen_string_literal: true
# Auto-generated by Lyra::Verification::WorkflowGenerator

module Lyra
  module Verification
    module Generated

      class MonitorModeWorkflow < PetriFlow::Workflow
        workflow_name "Monitor Mode Workflow"

        places :idle, :crud_executing, :crud_completed,
               :event_building, :event_publishing, :completed
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

    end
  end
end
```

---

## API Reference

### WorkflowGenerator Class

```ruby
require 'lyra/verification/workflow_generator'

generator = Lyra::Verification::WorkflowGenerator.new

# Generate all workflows
result = generator.generate!

# Generate specific mode workflow
result = generator.generate!(mode: :monitor)
result = generator.generate!(mode: :hijack)
result = generator.generate!(mode: :es_sync)
result = generator.generate!(mode: :es_async)
```

### Result Structure

```ruby
{
  lifecycle_workflow: {
    name: "CRUD Entity Lifecycle (Generated)",
    places: [:nonexistent, :created, :persisted, ...],
    initial_place: :nonexistent,
    terminal_places: [:deleted],
    transitions: [...],
    generated_at: Time,
    source: "Lyra::Verification::WorkflowGenerator"
  },

  # When mode: specified
  mode_workflow: { ... },

  # When all modes generated
  mode_workflows: {
    monitor: { ... },
    hijack: { ... },
    es_sync: { ... },
    es_async: { ... }
  },

  analysis: {
    modes: [:monitor, :hijack, :es_sync, :es_async, :disabled],
    current_mode: :monitor,
    callbacks: { ... },
    models: [ ... ],
    event_types: [ ... ]
  }
}
```

### Available Modes

```ruby
Lyra::Verification::WorkflowGenerator::AVAILABLE_MODES
# => [:monitor, :hijack, :es_sync, :es_async]
```

---

## Integration with PetriFlow

### Loading Generated Workflows

```ruby
# Load a generated workflow
require_relative 'reports/monitor_mode_workflow_20260103_103348'

workflow = Lyra::Verification::Generated::MonitorModeWorkflow.new
```

### Running Verification

```ruby
# Verify the workflow
result = workflow.verify

puts "Bounded: #{result[:boundedness][:is_bounded]}"
puts "Safe: #{result[:boundedness][:is_safe]}"
puts "Reachable states: #{result[:reachability][:reachable_states].count}"
```

### Generating Visualizations

```ruby
# Generate Mermaid diagram
mermaid = workflow.to_mermaid
puts mermaid

# Export to other formats
workflow.export(:pnml, 'monitor_workflow.pnml')
workflow.export(:json, 'monitor_workflow.json')
```

---

## Customization

### Extending the Generator

You can subclass the generator to add custom analysis:

```ruby
class CustomWorkflowGenerator < Lyra::Verification::WorkflowGenerator
  def generate!
    result = super
    result[:custom_analysis] = perform_custom_analysis
    result
  end

  private

  def perform_custom_analysis
    # Your custom introspection logic
  end
end
```

### Adding New Mode Workflows

To add support for a new mode, update the `AVAILABLE_MODES` constant and add a corresponding `generate_*_workflow` method:

```ruby
AVAILABLE_MODES = [:monitor, :hijack, :es_sync, :es_async, :custom].freeze

def generate_custom_workflow
  {
    name: "Custom Mode Workflow",
    description: "Description of custom mode",
    places: [...],
    transitions: [...],
    # ...
  }
end
```

---

## Verification View

The Lyra dashboard includes a verification view at `/lyra/verification` that displays:

1. **Lifecycle Workflow** - Entity CRUD lifecycle verification
2. **Mode Verification Workflow** - Combined mode switching verification
3. **Generated Mode Workflows** - Individual mode workflows from `app/workflows/`

Each workflow shows:
- Verification status (PASS/FAIL)
- Reachable states count
- Terminal state reachability
- Petri net diagram (Mermaid)

### Understanding "Not Deadlock Free"

In Petri net theory, a net is **deadlock-free** if every reachable state can eventually reach a terminal state. However, this can be misleading for workflows with intentional cycles.

**The Lifecycle Workflow** contains a cycle: `persisted ↔ updated`. This is *intentional behavior*: entities can be updated indefinitely without being deleted. From a formal standpoint, once in the update cycle, the system *could* stay there forever (never reaching `deleted`), which is technically "not deadlock free."

**What matters for correctness:**
- **Terminal reachability** - The `deleted` state *can* be reached from any state
- **No unwanted deadlocks** - No state where operations are blocked
- **Boundedness** - The system is safe (1-bounded)

**Summary:** "Not deadlock free" in the lifecycle workflow is expected and correct behavior for CRUD semantics.

---

## Troubleshooting

### PetriFlow Not Available

```
Error: PetriFlow gem is required
```

**Solution:** Ensure `petri_flow` gem is in your Gemfile and bundle is installed.

### Invalid Mode

```
Error: Invalid mode 'foo'. Available modes: monitor, hijack, es_sync, es_async, all
```

**Solution:** Use one of the available modes or `all`.

### No Callbacks Detected

If "No callbacks detected in source" appears, ensure:
1. `lib/lyra/monitorable.rb` exists and contains callback definitions
2. The generator can find the Lyra gem root directory

---

*Documentation generated for Lyra::Verification::WorkflowGenerator*
