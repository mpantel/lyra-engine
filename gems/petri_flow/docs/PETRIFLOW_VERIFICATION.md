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

The two verification scripts live in the Lyra monorepo under papers/papertse
(they are not part of the public lyra-engine repository). Run them from that
directory: `formal_crud_to_event_model.rb` writes its DOT files to `figures/`
relative to the current directory.

```bash
cd /path/to/lyra
bundle install  # Ensures PetriFlow gem is available
```

## Verification Scripts

### 1. Formal Model Verification

Run the formal CPN model verification:

```bash
cd papers/papertse && ruby formal_crud_to_event_model.rb
```

This script:
1. **Creates the formal CPN model** matching the paper's Definitions 1-6
   (five places, including P_orm, and five transitions)
2. **Verifies structural properties** on a simplified verification net:
   - Reachable states (expected: 4)
   - Boundedness (expected: 1-bounded/safe)
   - Terminal states (expected: 1 - intentional completion)
3. **Simulates token flow**: P_crud → P_event → P_published → P_aggregate
4. **Writes** `figures/formal_crud_to_event_model.dot` and `figures/crud_to_event_petri.dot`

Output (trimmed):
```
📋 Creating Colored Petri Net Model...
  ✓ Token colors defined (Definitions 1-3)
  ✓ Places defined: P_crud, P_event, P_published, P_aggregate, P_orm
  ✓ Guards defined: G(T_create), G(T_update), G(T_delete)
  ✓ Transitions defined: T_create, T_update, T_delete, T_publish, T_apply
  ✓ Arcs connected with expressions

📊 Structural Verification Results:
  Reachable states: 4
  Terminal states:  1
  Is bounded:       true
  Is safe (1-bound):true
  Max tokens/place: 1
  Deadlock-free:    false

Property 2: Deterministic Mapping
  Verified by construction: each T_create/T_update/T_delete has exactly one output
  Guards are mutually exclusive (operation ∈ {CREATE, UPDATE, DELETE})

Property 4: Liveness
  "All transitions can eventually fire (no deadlock)"
  ⚠ Terminal state exists (expected: aggregate updated is final state)

Invariant Check Summary
  Total invariants: 2
  Passed: 2
  Failed: 0

📊 Simulation Results:
  Steps executed:    3
  Firing sequence:   t_map → t_publish → t_apply
  States visited:    4

Properties Verified:
  ✓ Property 1 (Completeness): Every CRUD generates an event
  ✓ Property 2 (Determinism): Each CRUD maps to exactly one event type
  ✓ Property 3 (Consistency): Token conservation holds
  ✓ Property 4 (Liveness): No unintended deadlocks
```

### 2. Model-Implementation Correspondence Verification

Run the correspondence verification:

```bash
cd papers/papertse && ruby verify_model_correspondence.rb
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

Output (trimmed):
```
📋 Loading Formal CPN Model...
  ✓ Formal model: 4 places, 3 transitions

📊 Correspondence Table:
----------------------------------------------------------------------
| Formal (CPN)                   | Lyra Implementation       | Status   |
----------------------------------------------------------------------
| p_crud                         | CrudInterceptor callbacks | ✓ MATCH  |
| p_aggregate                    | Aggregate state           | ✓ MATCH  |
| T_map (T_create ∪ T_update ∪ T_delete) | handle_create/update/destroy | ✓ MATCH  |
| t_apply                        | aggregate.apply()         | ✓ MATCH  |
| Guards G(T_x)                  | Commands::*Command pattern matching | ✓ MATCH  |
| Arc expression E(T_x)          | EventMapper.to_event      | ✓ MATCH  |
----------------------------------------------------------------------

⚠ Mismatches found:
  p_event: ✗ NOT FOUND
  p_published: ✗ NOT FOUND

  Total checks:  9
  Passed:        9
  Failed:        0

  🎉 FORMAL MODEL AND IMPLEMENTATION ARE STRUCTURALLY ISOMORPHIC
```

The script's text matching does not locate `p_event` or `p_published` in the
parsed files and reports them as mismatches; these two are not among the nine
counted checks, so the summary still reads 9/9.

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

Not by itself. `liveness[:deadlock_free]` counts every reachable dead marking
as a deadlock, including the intended end of the net (here, P_aggregate with
one token), so it is false for any net with a defined endpoint. The
formal-model script prints this raw value.

To check deadlock-freedom except at the intended end, pass the terminal
places to `PetriFlow.verify`:

```ruby
results = PetriFlow.verify(net, terminal_places: [:p_aggregate])
results[:liveness][:terminates_properly]     # true when every dead marking marks a terminal place
results[:liveness][:improper_dead_markings]  # number of dead markings that mark none
```

`PetriFlow::Workflow#verify!` passes the workflow's `terminal_places` for you,
so a workflow's results always carry `terminates_properly`.

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

# Verify (p_end is the intended end, not a deadlock)
initial = net.current_marking
results = PetriFlow.verify(net, terminal_places: [:p_end])
puts results
```

### Simulate Execution

`PetriFlow.verify` explores the state space on the net itself and leaves it in
the last marking it visited, so restore the initial marking before firing:

```ruby
net.set_marking(initial)

# Fire transitions manually
net.fire_transition(:t_process)

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

The verification scripts could be wired into the monorepo's test suite (no such
test exists today). A sketch, running each script from papers/papertse:

```ruby
# test/verification/petriflow_verification_test.rb (sketch)
require 'test_helper'

class PetriFlowVerificationTest < ActiveSupport::TestCase
  PAPER_DIR = File.expand_path("../../papers/papertse", __dir__)

  test "formal model verifies successfully" do
    output = Dir.chdir(PAPER_DIR) { `ruby formal_crud_to_event_model.rb` }
    assert_match(/Property 4 \(Liveness\): No unintended deadlocks/, output)
  end

  test "model-implementation correspondence" do
    output = Dir.chdir(PAPER_DIR) { `ruby verify_model_correspondence.rb` }
    assert_match(/Total checks:\s+9\s+Passed:\s+9/, output)
  end
end
```

## References

- [PetriFlow Gem](../README.md)
- [Theoretical Model: Colored Petri Nets](THEORETICAL_MODEL_PETRI_NETS.md)
- IEEE TSE paper, papers/papertse/orfeas_tse.tex in the Lyra monorepo - Section 3: Formal Model
