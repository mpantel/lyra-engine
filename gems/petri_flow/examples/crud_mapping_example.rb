#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: CRUD-to-Event Mapping with Colored Petri Nets
# This demonstrates how PetriFlow models the Lyra framework's
# CRUD-to-Event transformation using Colored Petri Nets

require 'bundler/setup'
require 'petri_flow'

puts "=" * 70
puts "PetriFlow Example: CRUD-to-Event Mapping"
puts "=" * 70
puts ""

# Create a Colored Petri Net for CRUD-to-Event mapping
net = PetriFlow.create_colored_net(name: "StudentCRUD")

# Define token colors (data types)
puts "📋 Defining token colors..."
net.add_color(:crud_operation,
  attributes: {
    operation: :symbol,
    model_class: :string,
    model_id: :integer,
    attributes: :hash,
    user_id: :integer
  }
)

net.add_color(:event,
  attributes: {
    event_type: :string,
    event_id: :string,
    data: :hash,
    metadata: :hash
  }
)

# Add places
puts "🎯 Adding places..."
crud_place = net.add_colored_place(
  id: :crud_initiated,
  name: "CRUD Operation Initiated",
  color: :crud_operation,
  initial_tokens: []
)

event_place = net.add_colored_place(
  id: :event_generated,
  name: "Event Generated",
  color: :event,
  initial_tokens: []
)

pii_detected_place = net.add_colored_place(
  id: :pii_detected,
  name: "PII Detected",
  color: :event,
  initial_tokens: []
)

event_stored_place = net.add_colored_place(
  id: :event_stored,
  name: "Event Stored",
  color: :event,
  initial_tokens: []
)

puts "  ✓ #{net.places.size} places created"
puts ""

# Add transitions with guards
puts "⚙️  Adding transitions..."

# T_CREATE: Maps CREATE operation to Created event
t_create = net.add_colored_transition(
  id: :t_create,
  name: "Map CREATE → Created",
  guard: PetriFlow::Colored::Guard.new(name: "operation==:create") do |context|
    context.dig(:tokens, :crud_initiated)&.data&.dig(:operation) == :create
  end
)

# T_DETECT: Detect PII in event data
t_detect = net.add_colored_transition(
  id: :t_detect_pii,
  name: "Detect PII"
)

# T_STORE: Store event (with consent check)
consent_guard = PetriFlow::Colored::Guard.new(name: "has_consent") do |context|
  # In real implementation, check consent registry
  true # Simplified for example
end

t_store = net.add_colored_transition(
  id: :t_store_event,
  name: "Store Event",
  guard: consent_guard
)

puts "  ✓ #{net.transitions.size} transitions created"
puts ""

# Add arcs with expressions
puts "🔗 Connecting with arcs..."

# CRUD → Event mapping arc expression
crud_to_event_expr = PetriFlow::Colored::ArcExpression.new(
  name: "CRUD to Event"
) do |data, context|
  {
    event_type: "#{data[:model_class]}Created",
    event_id: SecureRandom.uuid,
    data: data[:attributes],
    metadata: {
      user_id: data[:user_id],
      model_id: data[:model_id],
      timestamp: Time.current
    }
  }
end

# PII detection arc expression
pii_detection_expr = PetriFlow::Colored::ArcExpression.new(
  name: "Detect PII"
) do |data, context|
  pii_fields = {}

  # Simple pattern matching
  data[:data]&.each do |key, value|
    if key.to_s.match?(/email/i) || (value.is_a?(String) && value.match?(/@/))
      pii_fields[key] = :email
    elsif key.to_s.match?(/phone/i)
      pii_fields[key] = :phone
    elsif key.to_s.match?(/ssn|social/i)
      pii_fields[key] = :ssn
    end
  end

  data.merge(pii_detected: pii_fields)
end

net.add_colored_arc(
  source_id: :crud_initiated,
  target_id: :t_create,
  expression: nil
)

net.add_colored_arc(
  source_id: :t_create,
  target_id: :event_generated,
  expression: crud_to_event_expr
)

net.add_colored_arc(
  source_id: :event_generated,
  target_id: :t_detect_pii,
  expression: nil
)

net.add_colored_arc(
  source_id: :t_detect_pii,
  target_id: :pii_detected,
  expression: pii_detection_expr
)

net.add_colored_arc(
  source_id: :pii_detected,
  target_id: :t_store_event,
  expression: nil
)

net.add_colored_arc(
  source_id: :t_store_event,
  target_id: :event_stored,
  expression: PetriFlow::Colored::ArcExpressions.identity
)

puts "  ✓ #{net.arcs.size} arcs created"
puts ""

# Add some tokens (simulate CRUD operations)
puts "🎲 Adding initial tokens (CRUD operations)..."
student_create_token = PetriFlow::Core::Token.new(
  color: :crud_operation,
  data: {
    operation: :create,
    model_class: "Student",
    model_id: 1,
    attributes: {
      name: "Alice Johnson",
      email: "alice@university.edu",
      phone: "555-0123",
      grade: "A"
    },
    user_id: 42
  }
)

net.add_token_to_place(:crud_initiated, student_create_token)
puts "  ✓ 1 CRUD operation token added"
puts ""

# Display initial state
puts "📊 Initial State:"
puts "  Places:"
net.places.each do |id, place|
  tokens = net.tokens_at_place(id)
  puts "    #{place.name}: #{tokens.size} token(s)"
end
puts ""

# Matrix Analysis
puts "📈 Setting up Matrix Analysis..."
analyzer = PetriFlow.create_analyzer

# Record CRUD mapping
analyzer.crud_mapping.record_mapping(:create, "StudentCreated", 1)
analyzer.crud_mapping.record_mapping(:create, "AuditLogCreated", 1)
analyzer.crud_mapping.record_mapping(:update, "StudentUpdated", 1)
analyzer.crud_mapping.record_mapping(:delete, "StudentDeleted", 1)

puts "\n📋 CRUD-to-Event Mapping Matrix:"
table = analyzer.crud_mapping.to_table
puts "  " + table[:header].join(" | ")
puts "  " + ("-" * 60)
table[:rows].each do |row|
  puts "  " + row.join(" | ")
end
puts ""

# Visualization
puts "🎨 Generating visualizations..."

# ASCII visualization
puts "\n" + "=" * 70
puts "ASCII Visualization:"
puts "=" * 70
ascii = PetriFlow.visualize(net, format: :ascii)
puts ascii
puts ""

# Mermaid diagram
puts "=" * 70
puts "Mermaid Diagram (for Markdown):"
puts "=" * 70
mermaid = PetriFlow.visualize(net, format: :mermaid)
puts mermaid
puts ""

# Formal Verification
puts "=" * 70
puts "🔍 Formal Verification"
puts "=" * 70

# Note: For colored nets with tokens, we need to ensure
# the basic net structure is set up for verification
basic_net = PetriFlow.create_net(name: "StudentCRUD_Basic")
basic_net.add_place(id: :crud_initiated, initial_tokens: 1)
basic_net.add_place(id: :event_generated, initial_tokens: 0)
basic_net.add_place(id: :pii_detected, initial_tokens: 0)
basic_net.add_place(id: :event_stored, initial_tokens: 0)

basic_net.add_transition(id: :t_create)
basic_net.add_transition(id: :t_detect_pii)
basic_net.add_transition(id: :t_store_event)

basic_net.add_arc(source_id: :crud_initiated, target_id: :t_create)
basic_net.add_arc(source_id: :t_create, target_id: :event_generated)
basic_net.add_arc(source_id: :event_generated, target_id: :t_detect_pii)
basic_net.add_arc(source_id: :t_detect_pii, target_id: :pii_detected)
basic_net.add_arc(source_id: :pii_detected, target_id: :t_store_event)
basic_net.add_arc(source_id: :t_store_event, target_id: :event_stored)

results = PetriFlow.verify(basic_net)

puts "\n📊 Verification Results:"
puts "  Reachable states: #{results[:reachability][:total_reachable_states]}"
puts "  Terminal states: #{results[:reachability][:terminal_states]}"
puts "  Is bounded: #{results[:boundedness][:is_bounded]}"
puts "  Is safe (1-bounded): #{results[:boundedness][:is_safe]}"
puts "  Max tokens per place: #{results[:boundedness][:max_tokens]}"
puts "  Deadlock-free: #{results[:liveness][:deadlock_free]}"
puts ""

# Invariant checking
puts "🔒 Checking Invariants..."
checker = PetriFlow::Verification::InvariantChecker.new(basic_net)
checker.analyze_events if checker.respond_to?(:analyze_events)

# Custom invariant: PII always detected before storage
reachability = PetriFlow::Verification::ReachabilityAnalyzer.new(basic_net)
reachability.analyze
checker = PetriFlow::Verification::InvariantChecker.new(basic_net, reachability)

checker.add_invariant("PII detected before storage") do |marking|
  # Event can only be stored if PII was detected
  marking.tokens_at(:event_stored) <= marking.tokens_at(:pii_detected)
end

checker.check_token_conservation(1)

invariant_report = checker.report
puts "  Total invariants: #{invariant_report[:total_invariants]}"
puts "  Passed: #{invariant_report[:passed]}"
puts "  Failed: #{invariant_report[:failed]}"
puts "  Summary: #{invariant_report[:summary]}"
puts ""

# Simulation
puts "=" * 70
puts "🎬 Running Simulation"
puts "=" * 70

simulator = PetriFlow::Simulation::Simulator.new(basic_net)
trace = simulator.run(steps: 10, strategy: :random)

puts "\n📊 Simulation Results:"
puts "  Steps executed: #{trace.steps}"
puts "  Firing sequence: #{trace.firing_sequence.join(' → ')}"
puts "  Unique states visited: #{trace.visited_markings.size}"
puts ""

puts "📈 Transition firing counts:"
trace.transition_firing_counts.each do |tid, count|
  puts "  #{tid}: #{count}"
end
puts ""

puts "=" * 70
puts "✅ Example Complete!"
puts "=" * 70
puts ""

puts "Summary:"
puts "  • Created Colored Petri Net for CRUD-Event mapping"
puts "  • Defined token colors for CRUD operations and events"
puts "  • Added guards for privacy checks (consent)"
puts "  • Added arc expressions for CRUD-to-Event transformation and PII detection"
puts "  • Built CRUD-Event mapping matrix"
puts "  • Generated visualizations (ASCII, Mermaid)"
puts "  • Performed formal verification (reachability, boundedness, liveness)"
puts "  • Checked custom invariants"
puts "  • Ran simulation and analyzed traces"
puts ""

puts "Next steps:"
puts "  • Integrate with Lyra framework for real event analysis"
puts "  • Add more complex privacy policies from PAM DSL"
puts "  • Extend matrix analysis with causation and lineage"
puts "  • Visualize with GraphViz for publication-quality diagrams"
puts ""
