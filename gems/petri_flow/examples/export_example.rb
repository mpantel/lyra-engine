#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/petri_flow'

puts "=" * 80
puts "PetriFlow Export Examples"
puts "=" * 80
puts

# ==============================================================================
# Example 1: Basic Petri Net Export
# ==============================================================================

puts "1. Creating a Simple Petri Net"
puts "-" * 80

net = PetriFlow.create_net(name: "OrderProcessing")

# Add places
net.add_place(id: :order_received, name: "Order Received", initial_tokens: 1)
net.add_place(id: :payment_verified, name: "Payment Verified", initial_tokens: 0)
net.add_place(id: :order_shipped, name: "Order Shipped", initial_tokens: 0)

# Add transitions
net.add_transition(id: :verify_payment, name: "Verify Payment")
net.add_transition(id: :ship_order, name: "Ship Order")

# Add arcs
net.add_arc(source_id: :order_received, target_id: :verify_payment)
net.add_arc(source_id: :verify_payment, target_id: :payment_verified)
net.add_arc(source_id: :payment_verified, target_id: :ship_order)
net.add_arc(source_id: :ship_order, target_id: :order_shipped)

puts "Created net: #{net}"
puts "Statistics: #{net.stats}"
puts

# ==============================================================================
# Example 2: Export to Different Formats
# ==============================================================================

puts "2. Exporting to Multiple Formats"
puts "-" * 80

# Export to PNML (ISO standard)
pnml = net.export(format: :pnml)
puts "✓ PNML export: #{pnml.lines.count} lines"

# Export to CPN Tools XML
cpn = net.export(format: :cpn)
puts "✓ CPN Tools export: #{cpn.lines.count} lines"

# Export to JSON
json = net.export(format: :json)
puts "✓ JSON export: #{json.lines.count} lines"

# Export to YAML
yaml = net.export(format: :yaml)
puts "✓ YAML export: #{yaml.lines.count} lines"
puts

# ==============================================================================
# Example 3: Save to Files
# ==============================================================================

puts "3. Saving to Files"
puts "-" * 80

output_dir = File.join(__dir__, 'output')
Dir.mkdir(output_dir) unless Dir.exist?(output_dir)

# Save with explicit format
net.export_to_file(File.join(output_dir, 'order_processing.pnml'), format: :pnml)
puts "✓ Saved: order_processing.pnml"

net.export_to_file(File.join(output_dir, 'order_processing.cpn'), format: :cpn)
puts "✓ Saved: order_processing.cpn"

# Save with auto-detected format (from extension)
net.export_to_file(File.join(output_dir, 'order_processing.json'))
puts "✓ Saved: order_processing.json"

net.export_to_file(File.join(output_dir, 'order_processing.yaml'))
puts "✓ Saved: order_processing.yaml"
puts

# ==============================================================================
# Example 4: Colored Petri Net Export
# ==============================================================================

puts "4. Creating and Exporting a Colored Petri Net"
puts "-" * 80

colored_net = PetriFlow.create_colored_net(name: "StudentCRUD")

# Define colors (token types)
colored_net.add_color(:crud_operation, attributes: {
  operation: :symbol,
  model_class: :string,
  model_id: :integer,
  attributes: :hash,
  user_id: :integer
})

colored_net.add_color(:event, attributes: {
  event_type: :string,
  event_id: :string,
  data: :hash,
  metadata: :hash
})

# Add colored places
colored_net.add_colored_place(
  id: :crud_initiated,
  name: "CRUD Initiated",
  color: :crud_operation
)

colored_net.add_colored_place(
  id: :event_generated,
  name: "Event Generated",
  color: :event
)

# Add transitions with guards
operation_guard = PetriFlow::Colored::Guards.field_equals(:operation, :create)
colored_net.add_colored_transition(
  id: :map_create,
  name: "Map Create Operation",
  guard: operation_guard
)

# Add arcs with expressions
crud_to_event_expr = PetriFlow::Colored::ArcExpressions.crud_to_event(:created)
colored_net.add_colored_arc(
  source_id: :crud_initiated,
  target_id: :map_create
)
colored_net.add_colored_arc(
  source_id: :map_create,
  target_id: :event_generated,
  expression: crud_to_event_expr
)

puts "Created colored net: #{colored_net}"
puts

# Export colored net to all formats
puts "Exporting colored net..."
colored_net.export_to_file(File.join(output_dir, 'student_crud.pnml'), format: :pnml)
puts "✓ Saved: student_crud.pnml (with color declarations)"

colored_net.export_to_file(File.join(output_dir, 'student_crud.cpn'), format: :cpn)
puts "✓ Saved: student_crud.cpn (importable to CPN Tools)"

colored_net.export_to_file(File.join(output_dir, 'student_crud.json'))
puts "✓ Saved: student_crud.json (with color and guard info)"

colored_net.export_to_file(File.join(output_dir, 'student_crud.yaml'))
puts "✓ Saved: student_crud.yaml (human-readable)"
puts

# ==============================================================================
# Example 5: Export to Hash (for API responses)
# ==============================================================================

puts "5. Export to Hash (for API/serialization)"
puts "-" * 80

hash = net.to_export_hash
puts "Exported hash keys: #{hash.keys.join(', ')}"
puts "Net info: #{hash[:net]}"
puts "Places: #{hash[:places].size} places"
puts "Transitions: #{hash[:transitions].size} transitions"
puts

# ==============================================================================
# Example 6: Using Module-Level Convenience Methods
# ==============================================================================

puts "6. Module-Level Convenience Methods"
puts "-" * 80

# Use PetriFlow.export
json_str = PetriFlow.export(net, format: :json, pretty: true)
puts "✓ PetriFlow.export(net, format: :json)"

# Use PetriFlow.save
PetriFlow.save(net, File.join(output_dir, 'order_via_module.yaml'))
puts "✓ PetriFlow.save(net, 'order_via_module.yaml')"
puts

# ==============================================================================
# Example 7: Inspecting Export Format Information
# ==============================================================================

puts "7. Available Export Formats"
puts "-" * 80

formats = PetriFlow::Export.formats
puts "Available formats: #{formats.join(', ')}"
puts

format_info = PetriFlow::Export.format_info
format_info.each do |format, info|
  puts "#{format.to_s.upcase}:"
  puts "  Name: #{info[:name]}"
  puts "  Description: #{info[:description]}"
  puts "  Extension: #{info[:extension]}"
  puts "  Supports Colored Nets: #{info[:supports_colored]}"
  puts "  Interoperability: #{info[:interoperability]}"
  puts
end

# ==============================================================================
# Example 8: JSON Export with Pretty Printing Control
# ==============================================================================

puts "8. JSON Export Options"
puts "-" * 80

# Pretty JSON (default)
pretty_json = net.export(format: :json, pretty: true)
puts "Pretty JSON size: #{pretty_json.bytesize} bytes"

# Compact JSON
compact_json = net.export(format: :json, pretty: false)
puts "Compact JSON size: #{compact_json.bytesize} bytes"
puts "Size reduction: #{((1 - compact_json.bytesize.to_f / pretty_json.bytesize) * 100).round(1)}%"
puts

# ==============================================================================
# Summary
# ==============================================================================

puts "=" * 80
puts "Summary"
puts "=" * 80
puts "All exports saved to: #{output_dir}/"
puts
puts "Files created:"
Dir[File.join(output_dir, '*')].sort.each do |file|
  size = File.size(file)
  puts "  - #{File.basename(file)} (#{size} bytes)"
end
puts
puts "You can now:"
puts "  1. Import .pnml files into any PNML-compatible Petri net tool"
puts "  2. Open .cpn files in CPN Tools for analysis and simulation"
puts "  3. Use .json files in web applications or APIs"
puts "  4. Read .yaml files for documentation or configuration"
puts "=" * 80
