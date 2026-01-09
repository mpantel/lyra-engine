# Example: User Lifecycle Workflow
# Demonstrates creating, updating, and soft-deleting a user while tracking all events

puts "=" * 70
puts "User Lifecycle Workflow Example"
puts "=" * 70

# Create a new user
puts "\n1. Creating a new user..."
user = User.create!(
  email: "demo@example.com",
  name: "Demo User",
  bio: "This is a demo user for testing Lyra"
)
puts "   ✓ User created: #{user.name} (ID: #{user.id})"

# Check events in the event store
stream_name = "User$#{user.id}"
events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Events captured: #{events.count}"
events.each do |event|
  puts "     - #{event.event_type} at #{event.metadata[:timestamp]}"
end

# Update user information
puts "\n2. Updating user profile..."
user.update!(
  bio: "Updated bio with more information about event sourcing",
  name: "Demo User (Updated)"
)
puts "   ✓ User updated"

events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Total events now: #{events.count}"
latest_event = events.last
puts "   ✓ Latest event: #{latest_event.event_type}"
puts "   ✓ Changes: #{latest_event.data[:changes].keys.join(', ')}"

# Multiple updates to show event accumulation
puts "\n3. Performing multiple updates..."
3.times do |i|
  user.update!(bio: "Update ##{i + 2}: #{Time.current}")
  sleep 0.1 # Small delay to show distinct events
end

events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Total events now: #{events.count}"

# Rebuild state from events
puts "\n4. Rebuilding state from events..."
projection = Lyra::StateProjection.new
state = projection.rebuild_from_events(events)
puts "   ✓ Rebuilt state:"
puts "     - Name: #{state[:name]}"
puts "     - Email: #{state[:email]}"
puts "     - Bio: #{state[:bio][0..50]}..."

# Compare CRUD vs Event-sourced state
puts "\n5. Comparing CRUD and Event-sourced views..."
dual_view = Lyra::DualView.new(User, user.id)
comparison = dual_view.compare

puts "   CRUD View:"
puts "     - Exists: #{comparison[:crud_view][:exists]}"
puts "     - Name: #{comparison[:crud_view][:attributes]['name']}"

puts "   Event-Sourced View:"
puts "     - Events count: #{comparison[:event_sourced_view][:events_count]}"
puts "     - State name: #{comparison[:event_sourced_view][:state][:name]}"

puts "   Differences:"
if comparison[:differences][:no_differences]
  puts "     ✓ No differences - states are consistent!"
else
  puts "     ⚠ Differences detected:"
  comparison[:differences].each do |field, values|
    puts "       #{field}: CRUD=#{values[:crud]}, ES=#{values[:event_sourced]}"
  end
end

# Soft delete
puts "\n6. Performing soft delete..."
user.soft_delete!
puts "   ✓ User soft-deleted at: #{user.deleted_at}"
puts "   ✓ User still exists in database: #{User.unscoped.exists?(user.id)}"

# Check final event stream
events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Final event count: #{events.count}"
puts "\n   Event timeline:"
events.each_with_index do |event, index|
  puts "     #{index + 1}. #{event.event_type} - #{event.data[:operation]}"
end

# Audit trail
puts "\n7. Generating audit trail..."
audit = Lyra::AuditProjection.audit_trail(User, user.id)
puts "   ✓ Audit entries: #{audit.count}"
audit.last(3).each do |entry|
  puts "     - #{entry[:operation]} at #{entry[:timestamp]} by user #{entry[:user_id] || 'system'}"
  if entry[:changes].any?
    puts "       Changes: #{entry[:changes].keys.join(', ')}"
  end
end

puts "\n" + "=" * 70
puts "User Lifecycle Workflow Complete!"
puts "=" * 70
puts "\nKey Takeaways:"
puts "  • All state changes are captured as events"
puts "  • State can be rebuilt from events at any time"
puts "  • CRUD and event-sourced views remain consistent"
puts "  • Soft deletes preserve data for compliance and recovery"
puts "  • Complete audit trail available for regulatory compliance"
