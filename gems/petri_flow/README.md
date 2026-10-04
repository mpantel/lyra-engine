# PetriFlow

**Comprehensive Petri Net and Matrix Analysis for Event Sourcing Systems**

PetriFlow is a Ruby gem that provides a complete toolkit for modeling, analyzing, and verifying event-driven systems using Petri nets and matrix analysis. It's designed to support the Lyra framework's CRUD-to-Event mapping analysis and formal verification needs.

## Features

### 🎯 Core Petri Nets
- **Places**: States in your system
- **Transitions**: Operations that change state
- **Arcs**: Connections between places and transitions
- **Tokens**: Data flowing through the network
- **Markings**: System states (token distributions)

### 🎨 Colored Petri Nets (CPNs)
- **Token Colors**: Typed tokens carrying structured data
- **Guards**: Conditional transition firing (e.g., privacy policies)
- **Arc Expressions**: Data transformations during transitions

### 📊 Matrix Analysis
- **CRUD-Event Mapping Matrix**: Track which CRUD operations generate which events
- **Correlation Matrix**: Group related events by correlation ID
- **Causation Matrix**: Event causality chains and transitive closure
- **Data Lineage Matrix**: Field modification history (GDPR Article 15)
- **Reachability Matrix**: State space analysis

### 🔍 Formal Verification
- **Reachability Analysis**: What states are reachable?
- **Boundedness Checking**: Are token counts bounded?
- **Liveness Checking**: Can transitions fire? Deadlock detection, optionally relative to designated terminal places
- **Invariant Checking**: Custom property verification

### 🎬 Simulation
- **Step-by-step Execution**: Interactive debugging
- **Monte Carlo Simulation**: Statistical analysis
- **Trace Generation**: Execution path recording
- **Multiple Strategies**: Random, priority-based, least-used

### 📈 Visualization
- **GraphViz/DOT**: Professional diagrams
- **Mermaid**: Markdown-embeddable diagrams
- **ASCII**: Terminal-friendly output

## Installation

Add to your Gemfile:

```ruby
gem 'petri_flow', path: 'gems/petri_flow'
```

Then:
```bash
bundle install
```

## Quick Start

### Basic Petri Net

```ruby
require 'petri_flow'

# Create a net
net = PetriFlow.create_net(name: "OrderProcessing")

# Add places
net.add_place(id: :order_received, initial_tokens: 1)
net.add_place(id: :payment_processed, initial_tokens: 0)
net.add_place(id: :order_shipped, initial_tokens: 0)

# Add transitions
net.add_transition(id: :process_payment, name: "Process Payment")
net.add_transition(id: :ship_order, name: "Ship Order")

# Connect with arcs
net.add_arc(source_id: :order_received, target_id: :process_payment)
net.add_arc(source_id: :process_payment, target_id: :payment_processed)
net.add_arc(source_id: :payment_processed, target_id: :ship_order)
net.add_arc(source_id: :ship_order, target_id: :order_shipped)

# Fire transitions
net.fire_transition(:process_payment)
net.fire_transition(:ship_order)

puts net.current_marking
```

### Colored Petri Net with Guards

```ruby
# Create colored net
net = PetriFlow.create_colored_net(name: "StudentCRUD")

# Define token color
net.add_color(:crud_operation,
  attributes: { operation: :symbol, model_class: :string, data: :hash }
)

# Add places
net.add_colored_place(id: :crud_initiated, color: :crud_operation)
net.add_colored_place(id: :event_generated, color: :event)

# Add transition with guard (privacy check)
consent_guard = PetriFlow::Colored::Guards.has_consent(:enrollment)
net.add_colored_transition(
  id: :generate_event,
  name: "Generate Event",
  guard: consent_guard
)

# Add arc with expression (CRUD-to-Event transformation)
crud_to_event = PetriFlow::Colored::ArcExpressions.crud_to_event(:created)
net.add_colored_arc(
  source_id: :crud_initiated,
  target_id: :generate_event,
  expression: crud_to_event
)
```

### Matrix Analysis

```ruby
# Create analyzer
analyzer = PetriFlow.create_analyzer

# Analyze events
events = [
  { event_id: "e1", operation: :create, event_type: "StudentCreated", changes: { name: ["", "Alice"] }},
  { event_id: "e2", operation: :update, event_type: "StudentUpdated", changes: { email: ["old@", "new@"] }},
  # ... more events
]

analyzer.analyze_events(events)

# Get CRUD mapping
puts analyzer.crud_mapping.to_table

# Get data lineage
lineage = analyzer.field_history("email")
lineage.each do |mod|
  puts "#{mod[:timestamp]}: #{mod[:old_value]} → #{mod[:new_value]}"
end

# Generate report
report = analyzer.generate_report
puts JSON.pretty_generate(report)
```

### Formal Verification

```ruby
# Quick verification
results = PetriFlow.verify(net)

puts "Reachability: #{results[:reachability][:total_reachable_states]} states"
puts "Bounded: #{results[:boundedness][:is_bounded]}"
puts "Safe: #{results[:boundedness][:is_safe]}"
puts "Deadlock-free: #{results[:liveness][:deadlock_free]}"

# deadlock_free counts every reachable dead marking as a deadlock, including
# the intended end of the net. Pass terminal_places: to check deadlock-freedom
# except at markings that mark one of those places.
results = PetriFlow.verify(net, terminal_places: [:completed, :rejected])
puts "Terminates properly: #{results[:liveness][:terminates_properly]}"
puts "Improper dead markings: #{results[:liveness][:improper_dead_markings]}"

# Custom invariants
checker = PetriFlow::Verification::InvariantChecker.new(net)

# Check token conservation
checker.check_token_conservation(5)

# Check mutual exclusion
checker.check_mutual_exclusion([:place1, :place2])

# Custom invariant: PII always detected before storage
checker.add_invariant("PII Detection") do |marking, net|
  marking.tokens_at(:pii_detected) >= marking.tokens_at(:event_stored)
end

report = checker.report
puts report[:summary]
```

### Simulation

```ruby
# Quick simulation
trace = PetriFlow.simulate(net, steps: 100, strategy: :random)

puts "Steps: #{trace.steps}"
puts "Firing sequence: #{trace.firing_sequence_names.join(' → ')}"
puts "Unique states visited: #{trace.visited_markings.size}"

# Monte Carlo simulation
simulator = PetriFlow::Simulation::Simulator.new(net)
results = simulator.run_multiple(runs: 1000, steps: 50)

puts "Average steps: #{results[:average_steps]}"
puts "Deadlocked runs: #{results[:deadlocked_runs]}"
puts "Transition frequencies:"
results[:transition_frequencies].each do |tid, freq|
  puts "  #{tid}: #{(freq * 100).round(2)}%"
end

# Interactive simulation
simulator.reset
simulator.step(:transition_id)  # Fire specific transition
simulator.step                   # Fire any enabled transition
```

### Visualization

```ruby
# GraphViz DOT format
dot = PetriFlow.visualize(net, format: :dot)
File.write("net.dot", dot)
# Then: dot -Tpng net.dot -o net.png

# Mermaid diagram (for GitHub/Markdown)
mermaid = PetriFlow.visualize(net, format: :mermaid)
puts mermaid  # Embed in README

# ASCII (terminal)
ascii = PetriFlow.visualize(net, format: :ascii)
puts ascii
```

### Export

Nets (plain and colored) can be exported to PNML, CPN Tools XML, JSON and YAML:

```ruby
pnml = PetriFlow.export(net, format: :pnml)
cpn  = PetriFlow.export(net, format: :cpn)    # CPN Tools XML
json = PetriFlow.export(net, format: :json)   # pretty: true by default
yaml = PetriFlow.export(net, format: :yaml)

# Write to a file; the format is detected from the extension
# (.pnml, .cpn, .json, .yaml/.yml; .xml is PNML unless the name contains "cpn")
PetriFlow.save(net, "order.pnml")
PetriFlow.save(net, "order.xml", format: :cpn)
```

See [docs/PETRIFLOW_EXPORT.md](docs/PETRIFLOW_EXPORT.md) and `examples/export_example.rb`.

## Rails Integration: Workflow DSL

PetriFlow includes a declarative DSL for defining workflows in Rails applications,
with automatic discovery and verification via rake tasks.

### Defining Workflows

Create workflow classes in `app/workflows/`:

```ruby
# app/workflows/refund_request_workflow.rb
class RefundRequestWorkflow < PetriFlow::Workflow
  workflow_name "RefundRequest Workflow"

  # Define all states
  places :requested, :under_review, :approved, :rejected, :processed, :cancelled

  # Starting state
  initial_place :requested

  # Terminal states (workflow completion)
  terminal_places :rejected, :processed, :cancelled

  # Define transitions between states
  transition :start_review, from: :requested, to: :under_review
  transition :approve, from: :under_review, to: :approved
  transition :reject, from: :requested, to: :rejected
  transition :reject, from: :under_review, to: :rejected
  transition :process, from: :approved, to: :processed
  transition :cancel, from: :requested, to: :cancelled
  transition :cancel, from: :under_review, to: :cancelled
end
```

### Rake Tasks

```bash
# Verify all workflows and generate reports
rake petri_flow:verify

# List registered workflows
rake petri_flow:verify:list

# Verify a specific workflow
rake petri_flow:verify:workflow[RefundRequestWorkflow]

# Show configuration
rake petri_flow:config

# Aliases
rake workflows:verify
rake workflows:list
```

### Generating Workflows from State Machines

Models that use `aasm` or `state_machines-activerecord` can be turned into
workflow classes:

```bash
# List models with a supported state machine
rake petri_flow:generate:scan

# Write app/workflows/order_workflow.rb from Order's state machine
# (state attribute defaults to :state), then verify it
rake petri_flow:generate:from_state_machine[Order,state]

# Aliases
rake workflows:scan
rake workflows:from_state_machine[Order,state]
```

`Workflow#verify!` passes the workflow's `terminal_places` to `PetriFlow.verify`,
so its results include `liveness[:terminates_properly]`.

### Generated Reports

Reports are saved to `reports/petri_flow_<timestamp>/`:

- `verification_report.md` - Summary of all workflows
- `<workflow_name>.md` - Individual workflow report
- `<workflow_name>_petri.png` - Petri net diagram
- `<workflow_name>_petri.dot` - GraphViz source
- `<workflow_name>_petri.mmd` - Mermaid diagram

### Configuration

Optional configuration in `config/initializers/petri_flow.rb`:

```ruby
Rails.application.configure do
  config.petri_flow.workflows_path = "app/workflows"  # Default
  config.petri_flow.auto_discover = true              # Default
end
```

### Programmatic Usage

```ruby
# Instantiate and verify a workflow
workflow = RefundRequestWorkflow.new
results = workflow.verify!

# Check terminal state reachability
workflow.terminal_reachability.each do |state, reachable|
  puts "#{state}: #{reachable ? 'REACHABLE' : 'UNREACHABLE'}"
end

# Export diagrams
puts workflow.to_mermaid
puts workflow.to_dot

# Run simulation
trace = workflow.simulate(steps: 10)
puts trace.firing_sequence
```

### Detecting Unreachable States

PetriFlow can detect workflow design flaws where terminal states are unreachable:

```ruby
# This workflow has a design flaw - :escalated has no incoming transition
class FlawedApprovalWorkflow < PetriFlow::Workflow
  places :draft, :submitted, :approved, :rejected, :completed, :escalated
  initial_place :draft
  terminal_places :completed, :rejected, :escalated  # escalated is declared but unreachable!

  transition :submit, from: :draft, to: :submitted
  transition :approve, from: :submitted, to: :approved
  transition :reject, from: :submitted, to: :rejected
  transition :complete, from: :approved, to: :completed
  # Missing: transition :escalate, from: :submitted, to: :escalated
end
```

Running verification will detect this:

```
Terminal State Reachability:
  completed    ✓ REACHABLE
  rejected     ✓ REACHABLE
  escalated    ✗ UNREACHABLE

> WARNING: Some terminal states are unreachable from the initial state.
```

This is valuable for GDPR compliance - proving that the `anonymized` state IS reachable
guarantees that the Right to Erasure (Article 17) can be fulfilled.

## Use Cases for Lyra Framework

### 1. CRUD-to-Event Mapping Verification

```ruby
# Model the CRUD-to-Event transformation
net = PetriFlow.create_colored_net(name: "CRUDMapping")

# Places for CRUD operations
net.add_colored_place(id: :create_op, color: :crud)
net.add_colored_place(id: :update_op, color: :crud)
net.add_colored_place(id: :delete_op, color: :crud)

# Places for events
net.add_colored_place(id: :created_event, color: :event)
net.add_colored_place(id: :updated_event, color: :event)
net.add_colored_place(id: :deleted_event, color: :event)

# Transitions model the mapping
net.add_colored_transition(id: :map_create, name: "Map CREATE → Created")
# ... add arcs ...

# Verify mapping completeness
checker = PetriFlow::Verification::InvariantChecker.new(net)
checker.add_invariant("All CRUD mapped") do |marking|
  # Every CRUD operation must generate at least one event
  total_crud = marking.tokens_at(:create_op) +
               marking.tokens_at(:update_op) +
               marking.tokens_at(:delete_op)

  total_events = marking.tokens_at(:created_event) +
                 marking.tokens_at(:updated_event) +
                 marking.tokens_at(:deleted_event)

  total_events >= total_crud
end
```

### 2. Privacy Policy Verification

```ruby
# Model PAM privacy policies as guards
pii_required_guard = PetriFlow::Colored::Guard.new(name: "PII Required") do |context|
  context[:token][:data][:pii_fields]&.any?
end

consent_guard = PetriFlow::Colored::Guards.has_consent(:data_processing)

# Combine guards: PII required AND consent granted
privacy_guard = pii_required_guard.and(consent_guard)

net.add_colored_transition(
  id: :process_pii,
  guard: privacy_guard
)

# Verify no PII is processed without consent
checker.add_invariant("No PII without consent") do |marking|
  # Check that PII processing place has no tokens when consent is not granted
  # (This is a simplified example)
  true
end
```

### 3. Event Flow Analysis

```ruby
# Build causation matrix from event store
analyzer = PetriFlow.create_analyzer

events = EventStore.read_all_events
analyzer.analyze_events(events)

# Find causation chain
chain = analyzer.find_causation_chain("OrderCreated", "EmailSent")
puts "Causation chain: #{chain.join(' → ')}"

# Get transitive causation
closure = analyzer.causation.transitive_closure
puts "Events caused by OrderCreated (transitively):"
puts closure.effects_of("OrderCreated")

# Identify most influential events
centrality = analyzer.causation.centrality_scores
top_events = centrality.sort_by { |_, score| -score }.first(10)
puts "Most influential events:"
top_events.each do |event_id, score|
  puts "  #{event_id}: #{score}"
end
```

### 4. Data Lineage Tracking (GDPR Article 15)

```ruby
# Track complete data lineage
analyzer.lineage.record_modification(
  "email",
  "event_123",
  old_value: "old@example.com",
  new_value: "new@example.com",
  timestamp: Time.current
)

# Get complete field history
history = analyzer.field_history("email")
history.each do |mod|
  puts "Event #{mod[:event_id]} at #{mod[:timestamp]}"
  puts "  #{mod[:old_value]} → #{mod[:new_value]}"
end

# Reconstruct value at specific time
value = analyzer.lineage.reconstruct_value("email", 1.month.ago)
puts "Email value 1 month ago: #{value}"

# Privacy impact analysis
impact = analyzer.privacy_impact_analysis
puts "Fields tracked: #{impact[:fields_tracked]}"
puts "Total modifications: #{impact[:total_modifications]}"
```

## Architecture Integration with Lyra

```
┌─────────────────────────────────────────────────┐
│              Lyra Framework                     │
│                                                 │
│  ┌─────────────┐         ┌─────────────┐      │
│  │   CRUD      │────────▶│   Events    │      │
│  │ Operations  │         │   Store     │      │
│  └─────────────┘         └──────┬──────┘      │
│                                  │             │
│                                  ▼             │
│                          ┌──────────────┐     │
│                          │  PetriFlow   │     │
│                          │   Analysis   │     │
│                          └──────────────┘     │
│                                  │             │
│            ┌─────────────────────┼──────────┐ │
│            ▼                     ▼          ▼ │
│     ┌──────────┐        ┌──────────┐  ┌──────────┐
│     │ CPN      │        │ Matrix   │  │ Verify   │
│     │ Model    │        │ Analysis │  │ Props    │
│     └──────────┘        └──────────┘  └──────────┘
└─────────────────────────────────────────────────┘
```

## Research Foundation

This gem implements the theoretical models described in:

- `gems/petri_flow/docs/THEORETICAL_MODEL_PETRI_NETS.md` - Colored Petri Net formalization
- `gems/petri_flow/docs/THEORETICAL_MODEL_MATRICES.md` - Matrix analysis techniques

It provides the formal verification foundation for the CRUD-to-Event mapping framework described in:

> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". PCI 2022.

## API Documentation

### Core Classes

- `PetriFlow::Core::Net` - Basic Petri net
- `PetriFlow::Core::Place` - Places (states)
- `PetriFlow::Core::Transition` - Transitions (operations)
- `PetriFlow::Core::Arc` - Connections
- `PetriFlow::Core::Token` - Data tokens
- `PetriFlow::Core::Marking` - System state

### Colored Extensions

- `PetriFlow::Colored::ColoredNet` - Colored Petri net
- `PetriFlow::Colored::Color` - Token color definitions
- `PetriFlow::Colored::Guard` - Transition guards
- `PetriFlow::Colored::ArcExpression` - Data transformations

### Matrix Analysis

- `PetriFlow::Matrix::Analyzer` - Main analysis interface
- `PetriFlow::Matrix::CrudEventMapping` - CRUD-Event mapping matrix
- `PetriFlow::Matrix::Correlation` - Event correlation matrix
- `PetriFlow::Matrix::Causation` - Event causation matrix
- `PetriFlow::Matrix::Lineage` - Data lineage matrix
- `PetriFlow::Matrix::Reachability` - State reachability matrix

### Verification

- `PetriFlow::Verification::ReachabilityAnalyzer` - Reachability analysis
- `PetriFlow::Verification::BoundednessChecker` - Boundedness checking
- `PetriFlow::Verification::LivenessChecker` - Liveness analysis
- `PetriFlow::Verification::InvariantChecker` - Custom invariants

### Simulation

- `PetriFlow::Simulation::Simulator` - Execution simulator
- `PetriFlow::Simulation::Trace` - Execution trace

### Visualization

- `PetriFlow::Visualization::Graphviz` - DOT/GraphViz output
- `PetriFlow::Visualization::Mermaid` - Mermaid diagrams

### Export

- `PetriFlow::Export` - `export` / `save` dispatch by format
- `PetriFlow::Export::PnmlExporter`, `CpnToolsExporter`, `JsonExporter`, `YamlExporter`

### Workflows

- `PetriFlow::Workflow` - Declarative workflow DSL
- `PetriFlow::Generators::WorkflowGenerator` - Workflow classes from AASM / state_machines

## Development

```bash
# Install dependencies
bundle install

# Run tests (Minitest)
bundle exec rake test

# Run examples
ruby examples/crud_mapping_example.rb
```

## Contributing

This gem is part of the ORFEAS PhD thesis research. Contributions are welcome!

## License

MIT License. See MIT-LICENSE file.

## References

1. Jensen, K., & Kristensen, L. M. (2009). *Colored Petri Nets*. Springer.
2. Murata, T. (1989). Petri nets: Properties, analysis and applications. *IEEE*.
3. Pantelelis, M., & Kalloniatis, C. (2022). *Mapping CRUD to Events*. PCI 2022.

## Citation

```bibtex
@software{petriflow2026,
  title={PetriFlow: Petri Net and Matrix Analysis for Event Sourcing},
  author={Pantelelis, Michail},
  year={2026},
  note={Part of ORFEAS PhD Thesis},
  url={https://github.com/mpantel/lyra-engine/gems/petri-flow}
}
```
