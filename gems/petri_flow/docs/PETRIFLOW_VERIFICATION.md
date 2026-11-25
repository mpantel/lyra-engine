# PetriFlow Verification Guide

This document explains how to run formal verification of Lyra's CRUD-to-Event mapping using PetriFlow.

## Overview

PetriFlow is a Ruby-based Colored Petri Net (CPN) library that provides:
- Formal model construction
- Structural property verification (boundedness, safety)
- Reachability analysis
- Simulation of token flow

The correspondence check between the formal model and Lyra's code is a test in
Lyra's suite (`test/verification/model_correspondence_test.rb`), by pattern
matching on the source; it is not part of PetriFlow.

## Prerequisites

The checks run with Lyra's own test suite, from the repository root, with the
test database running (`docs/TESTING.md`):

```bash
bundle install  # Ensures PetriFlow gem is available
bundle exec rake docker:start
```

## Verification Tests

### 1. Formal Model Verification

```bash
bundle exec ruby -Itest test/verification/crud_lifecycle_workflow_test.rb
```

This test builds the core CRUD-to-event net (`P_crud`, `P_event`,
`P_aggregate`, `P_published`; `T_create`, `T_update`, `T_delete`, `T_apply`,
`T_publish`) and each mode's net, and checks:
- **Reachable states:** 4 in the core net, with one terminal marking (the event
  stored: intentional completion, not a deadlock);
- **Boundedness:** every place 1-bounded (safe);
- **Terminal reachability:** from every reachable marking, in every mode's net;
- **Simulation:** the firing sequence `T_map → T_apply → T_publish`;
- **Diagrams:** the nets export to DOT and Mermaid (the guards drawn as a choice).

`Lyra.verify_crud_mapping` runs the same verification from a console.

### 2. Model-Implementation Correspondence Verification

```bash
bundle exec ruby -Itest test/verification/model_correspondence_test.rb
```

The test parses Lyra's source and matches each element of the net to its
counterpart:

| Formal (CPN) | Lyra implementation |
|---|---|
| `P_crud` | `CrudInterceptor` callbacks |
| `T_create`, `T_update`, `T_delete` | `CommandHandler#handle_*` |
| Guards `G(T_x)` | the `Commands::*Command` cases of `CommandHandler#call` |
| Arc expression `E(T_x)` | `CommandHandler#create_event`, `CrudInterceptor#publish_event` |
| `P_event` | `Lyra::Event` objects (`create_events`) |
| `T_apply`, `P_aggregate` | the aggregate's `apply` and its state, before the append |
| `T_publish` | `Lyra.append_events` to the record's stream |
| `P_published` | Rails Event Store streams |

It also checks that the core net is safe with one terminal marking. It checks
structure, not behaviour: `trace_conformance_test.rb` replays the steps of real
writes, in each mode, on that mode's net, and the concurrency nets
(`docs/CONCURRENCY_NETS.md` in the repository root) are checked against the
code's lock traces the same way. A change to the code that breaks a pattern
fails the suite.

## Understanding the Formal Model

### Token Colors

| Color | Attributes | Purpose |
|-------|-----------|---------|
| `crud_token` | operation, model_class, model_id, attributes, correlation_id | CRUD operation data |
| `event_token` | event_type, event_id, stream_name, data, metadata | Generated event |
| `aggregate_token` | aggregate_id, state, version | Aggregate state |

### Places

| Place | Description | Implementation |
|-------|-------------|----------------|
| P_crud | CRUD operation initiated | CrudInterceptor callbacks |
| P_event | Event generated | Lyra::Event objects |
| P_aggregate | Aggregate updated | GenericAggregate state |
| P_published | Event stored | Rails Event Store streams |

### Transitions

| Transition | Guard | Arc Expression | Implementation |
|------------|-------|----------------|----------------|
| T_create | op == :create | ModelCreated event | handle_create |
| T_update | op == :update | ModelUpdated event | handle_update |
| T_delete | op == :delete | ModelDestroyed event | handle_destroy |
| T_apply | (none) | Apply to aggregate | aggregate.apply() |
| T_publish | (none) | Store event | Lyra.append_events() (via aggregate.store) |

### Verified Properties

| Property | Description | Verification Method |
|----------|-------------|---------------------|
| **Operation Completeness** | Every CRUD generates event | All 3 handlers present |
| **Deterministic Mapping** | Guards mutually exclusive | case/when pattern |
| **State Consistency** | Aggregate matches ORM | dual-view verification |
| **Reachability/Termination** | Terminal state reachable | Simulation reaches P_published |

## Interpreting Results

### "Deadlock-free: false" - Is This a Problem?

Not by itself. `liveness[:deadlock_free]` counts every reachable dead marking
as a deadlock, including the intended end of the net (here, P_published with
one token), so it is false for any net with a defined endpoint. The
formal-model script prints this raw value.

To check deadlock-freedom except at the intended end, pass the terminal
places to `PetriFlow.verify`:

```ruby
results = PetriFlow.verify(net, terminal_places: [:p_published])
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
results = PetriFlow.verify(net, terminal_places: [:p_end])
puts results
```

### Simulate Execution

`PetriFlow.verify` explores the state space on the net itself, then restores
the marking the net had before the call, so the net can be fired straight away:

```ruby
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

**Mermaid diagram shows** (`AsyncWorkflow.new.to_mermaid`, edges only):
```
start --> t_async_fork_from_start
t_async_fork_from_start -->|∥ Response sent| response_sent
t_async_fork_from_start -->|∥ Background job| background_job
background_job --> t_process_job_from_background_job
t_process_job_from_background_job --> job_complete
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

The verification scripts could be wired into a test suite (no such test exists
today). A sketch, for the replication package's layout:

```ruby
# test/verification/petriflow_verification_test.rb (sketch)
require 'test_helper'

class PetriFlowVerificationTest < ActiveSupport::TestCase
  PAPER_DIR = File.expand_path("../../formal_model", __dir__)

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
- The ORFEAS manuscript (IEEE Transactions on Software Engineering, under review), Section III: the formal model
