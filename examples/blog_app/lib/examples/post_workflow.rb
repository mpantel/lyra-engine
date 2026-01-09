# Example: Post Publishing Workflow
# Demonstrates draft → published → archived lifecycle with event tracking

puts "=" * 70
puts "Post Publishing Workflow Example"
puts "=" * 70

# Find or create a user
user = User.find_or_create_by!(email: "workflow@example.com") do |u|
  u.name = "Workflow User"
  u.bio = "User for workflow demonstrations"
end

# Create a draft post
puts "\n1. Creating draft post..."
post = Post.create!(
  user: user,
  title: "Understanding Event-Driven Architecture",
  body: "Event-driven architecture is a software design pattern...",
  status: :draft
)
puts "   ✓ Draft created: #{post.title} (ID: #{post.id})"
puts "   ✓ Status: #{post.status}"

stream_name = "Post$#{post.id}"
events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Events: #{events.count}"

# Edit the draft multiple times
puts "\n2. Editing draft (simulating author revisions)..."
revisions = [
  "Event-driven architecture is a software design pattern promoting loose coupling...",
  "Event-driven architecture is a software design pattern promoting loose coupling through asynchronous messaging...",
  "Event-driven architecture is a powerful software design pattern that promotes loose coupling through asynchronous messaging and event streams."
]

revisions.each_with_index do |body, index|
  post.update!(body: body)
  puts "   ✓ Revision #{index + 1} saved"
  sleep 0.1
end

events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Total events: #{events.count}"

# Review event flow
puts "\n3. Analyzing event flow..."
event_flow = Lyra::EventFlow.new(events)
analysis = event_flow.analyze

puts "   Timeline:"
puts "     - First event: #{analysis[:timeline][:first_event]}"
puts "     - Last event: #{analysis[:timeline][:last_event]}"
puts "     - Duration: #{analysis[:timeline][:duration_minutes].round(2)} minutes"

puts "   Operations:"
analysis[:operations].each do |op, count|
  puts "     - #{op}: #{count}"
end

# Publish the post
puts "\n4. Publishing post..."
post.update!(status: :published)
puts "   ✓ Post published!"
puts "   ✓ Status: #{post.status}"

# Track readership with view count updates
puts "\n5. Simulating reader engagement..."
[10, 25, 50, 100, 250].each do |views|
  post.update!(view_count: views)
  puts "   ✓ Views: #{views}"
  sleep 0.1
end

# Check event accumulation
events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Events accumulated: #{events.count}"

# Archive the post
puts "\n6. Archiving post..."
post.update!(status: :archived)
puts "   ✓ Post archived"
puts "   ✓ Final status: #{post.status}"

# Final analysis
puts "\n7. Complete lifecycle analysis..."
events = Rails.configuration.event_store.read.stream(stream_name).to_a
event_flow = Lyra::EventFlow.new(events)
analysis = event_flow.analyze

puts "   Summary:"
puts "     - Total events: #{events.count}"
puts "     - Created operations: #{analysis[:operations][:created] || 0}"
puts "     - Updated operations: #{analysis[:operations][:updated] || 0}"
puts "     - Operations per day: #{analysis[:metrics][:operations_per_day].round(2)}"

# Rebuild state at different points in time
puts "\n8. Time-travel: Rebuilding state at different points..."
projection = Lyra::StateProjection.new

checkpoints = [
  { label: "After creation", count: 1 },
  { label: "After 3 revisions", count: 4 },
  { label: "After publishing", count: 5 },
  { label: "Current state", count: events.count }
]

checkpoints.each do |checkpoint|
  next if checkpoint[:count] > events.count

  state = projection.rebuild_from_events(events.take(checkpoint[:count]))
  puts "   #{checkpoint[:label]}:"
  puts "     - Status: #{state[:status] || 'draft'}"
  puts "     - Body length: #{state[:body]&.length || 0} chars"
  puts "     - Views: #{state[:view_count] || 0}"
end

# State comparison
puts "\n9. Dual-view state comparison..."
dual_view = Lyra::DualView.new(Post, post.id)
comparison = dual_view.compare

puts "   CRUD state:"
puts "     - Status: #{comparison[:crud_view][:attributes]['status']}"
puts "     - Views: #{comparison[:crud_view][:attributes]['view_count']}"

puts "   Event-sourced state:"
puts "     - Status: #{comparison[:event_sourced_view][:state][:status]}"
puts "     - Views: #{comparison[:event_sourced_view][:state][:view_count]}"
puts "     - Events: #{comparison[:event_sourced_view][:events_count]}"

if comparison[:differences][:no_differences]
  puts "   ✓ States are consistent!"
else
  puts "   ⚠ Inconsistencies found - see details above"
end

puts "\n" + "=" * 70
puts "Post Publishing Workflow Complete!"
puts "=" * 70
puts "\nKey Takeaways:"
puts "  • Draft → Published → Archived lifecycle fully tracked"
puts "  • Every revision captured as an event"
puts "  • Time-travel possible: rebuild state at any point"
puts "  • Event flow analysis provides insights into content lifecycle"
puts "  • State consistency maintained between CRUD and event-sourced views"
