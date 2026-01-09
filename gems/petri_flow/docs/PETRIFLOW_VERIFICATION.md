# PetriFlow Verification Guide

This document explains how to run formal verification of Lyra's CRUD-to-Event mapping using PetriFlow.

## Overview

PetriFlow is a Ruby-based Colored Petri Net (CPN) library that provides:
- Formal model construction
- Structural property verification (boundedness, safety)
- Reachability analysis
- Simulation of token flow
- Correspondence verification between formal model and implementation

## Prerequisites

```bash
cd /path/to/lyra
bundle install  # Ensures PetriFlow gem is available
```

## Verification Scripts

### 1. Formal Model Verification

Run the formal CPN model verification:

```bash
ruby papertse/formal_crud_to_event_model.rb
```

This script:
1. **Creates the formal CPN model** matching the paper's Definitions 1-6
2. **Verifies structural properties**:
   - Reachable states (expected: 4)
   - Boundedness (expected: 1-bounded/safe)
   - Terminal states (expected: 1 - intentional completion)
3. **Simulates token flow**: P_crud → P_event → P_published → P_aggregate

Expected output:
```
==== CPN STRUCTURE ====
Places: 4
Transitions: 5

==== VERIFICATION RESULTS ====
Reachability:
  Total reachable states: 4
  Terminal states: 1

Boundedness:
  Is bounded: true
  Is safe (1-bounded): true

Property Verification:
  Property 1: true (Operation Completeness)
  Property 2: true (Deterministic Mapping)
  Property 3: true (State Consistency)
  Property 4: true (Reachability and Termination)
```

### 2. Model-Implementation Correspondence Verification

Run the correspondence verification:

```bash
ruby papertse/verify_model_correspondence.rb
```

This script:
1. **Loads the formal CPN model**
2. **Parses Lyra implementation files**:
   - `lib/lyra/interceptors/crud_interceptor.rb`
   - `lib/lyra/command_handler.rb`
   - `lib/lyra/event_mapper.rb`
   - `lib/lyra/aggregate.rb`
3. **Matches formal elements to implementation**:
   - Places → Implementation components
   - Transitions → Handler methods
   - Guards → Pattern matching
   - Arc expressions → EventMapper
4. **Verifies structural isomorphism**

Expected output:
```
Correspondence Table:
----------------------------------------------------------------------
| Formal (CPN)                   | Lyra Implementation           | Status   |
----------------------------------------------------------------------
| p_crud                         | CrudInterceptor callbacks     | MATCH    |
| T_map (T_create ∪ T_update ∪ T_delete) | handle_create/update/destroy | MATCH |
| t_publish                      | event_store.publish()         | MATCH    |
| t_apply                        | aggregate.apply()             | MATCH    |
| Guards G(T_x)                  | Commands::*Command matching   | MATCH    |
| Arc expression E(T_x)          | EventMapper.to_event          | MATCH    |
----------------------------------------------------------------------

Result: 12/12 checks pass - STRUCTURALLY ISOMORPHIC
```

## Understanding the Formal Model

### Token Colors

| Color | Attributes | Purpose |
|-------|-----------|---------|
| `crud_token` | operation, model_class, model_id, attributes | CRUD operation data |
| `event_token` | event_type, event_id, data, metadata | Generated event |
| `aggregate_token` | aggregate_id, state, version | Aggregate state |

### Places

| Place | Description | Implementation |
|-------|-------------|----------------|
| P_crud | CRUD operation initiated | CrudInterceptor callbacks |
| P_event | Event generated | Lyra::Event objects |
| P_published | Event stored | Rails Event Store streams |
| P_aggregate | Aggregate updated | GenericAggregate state |

### Transitions

| Transition | Guard | Arc Expression | Implementation |
|------------|-------|----------------|----------------|
| T_create | op == :create | ModelCreated event | handle_create |
| T_update | op == :update | ModelUpdated event | handle_update |
| T_delete | op == :delete | ModelDestroyed event | handle_destroy |
| T_publish | (none) | Store event | event_store.publish() |
| T_apply | (none) | Apply to aggregate | aggregate.apply() |

### Verified Properties

| Property | Description | Verification Method |
|----------|-------------|---------------------|
| **Operation Completeness** | Every CRUD generates event | All 3 handlers present |
| **Deterministic Mapping** | Guards mutually exclusive | case/when pattern |
| **State Consistency** | Aggregate matches ORM | dual-view verification |
| **Reachability/Termination** | Terminal state reachable | Simulation reaches P_aggregate |

## Interpreting Results

### "Deadlock-free: false" - Is This a Problem?

No. The verifier reports `deadlock-free: false` because there is a **terminal state** (P_aggregate with 1 token). This is intentional:
- Terminal state = successful completion of CRUD-to-event flow
- Not a deadlock = no pathological state where progress is blocked

This is correct behavior for a workflow that has a defined endpoint.

### Boundedness and Safety

- **Bounded**: No place accumulates unbounded tokens
- **1-bounded (safe)**: Each place holds at most 1 token at any time

This ensures memory safety and no token accumulation.

## Running Custom Verifications

### Create Custom Net

```ruby
require 'petri_flow'

net = PetriFlow.create_net(name: "Custom_Workflow")

# Add places
net.add_place(id: :p_start, initial_tokens: 1)
net.add_place(id: :p_end, initial_tokens: 0)

# Add transition
net.add_transition(id: :t_process)

# Connect arcs
net.add_arc(source_id: :p_start, target_id: :t_process)
net.add_arc(source_id: :t_process, target_id: :p_end)

# Verify
results = PetriFlow.verify(net)
puts results
```

### Simulate Execution

```ruby
# Fire transitions manually
net.fire(:t_process)

# Check marking
puts net.places[:p_end].tokens  # => 1
```

## Fork/Join Patterns

PetriFlow supports **fork** (parallel split) and **join** (synchronization) patterns for modeling concurrent workflows.

### Fork Pattern (Parallel Split)

A fork transition produces tokens in multiple output places simultaneously:

```ruby
class AsyncWorkflow < PetriFlow::Workflow
  workflow_name "Async Processing"

  places :start, :response_sent, :background_job, :job_complete
  initial_place :start
  terminal_places :response_sent, :job_complete

  # FORK: One transition → multiple output places
  transition :async_fork, from: :start, to: [:response_sent, :background_job]
  transition :process_job, from: :background_job, to: :job_complete
end
```

**Mermaid diagram shows:**
```
start --> async_fork
async_fork --> response_sent
async_fork --> background_job
```

### Join Pattern (Synchronization)

A join transition consumes tokens from multiple input places:

```ruby
class ParallelWorkflow < PetriFlow::Workflow
  workflow_name "Parallel Processing"

  places :start, :task_a, :task_b, :synchronized, :complete
  initial_place :start
  terminal_places :complete

  # Fork: split into parallel tasks
  transition :split, from: :start, to: [:task_a, :task_b]

  # JOIN: Multiple input places → one transition
  transition :sync, from: [:task_a, :task_b], to: :synchronized

  transition :finish, from: :synchronized, to: :complete
end
```

### When to Use Fork vs Choice

| Pattern | Syntax | Semantics | Example |
|---------|--------|-----------|---------|
| **Choice** | Multiple transitions from same place | Pick ONE path (exclusive OR) | Order: complete OR cancel |
| **Fork** | `to: [:a, :b]` | ALL paths execute (parallel AND) | Async: response AND background job |
| **Join** | `from: [:a, :b]` | Wait for ALL inputs (synchronization) | Wait for all tasks to complete |

### Terminal Reachability with Forks

When using fork patterns, terminal reachability is checked differently:
- **Old behavior**: Check if ONLY the terminal place has a token
- **New behavior**: Check if ANY reachable marking has a token in the terminal place

This correctly handles fork patterns where multiple places have tokens simultaneously.

## Integration with Lyra Tests

The verification scripts can be integrated into the test suite:

```ruby
# test/verification/petriflow_verification_test.rb
require 'test_helper'

class PetriFlowVerificationTest < ActiveSupport::TestCase
  test "formal model verifies successfully" do
    output = `ruby papertse/formal_crud_to_event_model.rb`
    assert_match(/All 4 properties verified/, output)
  end

  test "model-implementation correspondence" do
    output = `ruby papertse/verify_model_correspondence.rb`
    assert_match(/12\/12 checks pass/, output)
  end
end
```

## References

- [PetriFlow Gem](gems/petri_flow/README.md)
- [Theoretical Model: Colored Petri Nets](docs/THEORETICAL_MODEL_PETRI_NETS.md)
- [IEEE TSE Paper](papertse/orfeas_tse.tex) - Section 3: Formal Model
