# Example: Event Inspection and Analysis
# Demonstrates querying, filtering, and analyzing events in the event store

puts "=" * 70
puts "Event Inspection and Analysis Example"
puts "=" * 70

# Ensure we have some data
if User.count == 0
  puts "\nNo data found. Running seeds first..."
  load Rails.root.join("db/seeds.rb")
end

# Read all events across the system
puts "\n1. Reading all events from event store..."
all_events = Rails.configuration.event_store.read.to_a
puts "   ✓ Total events in store: #{all_events.count}"

# Group events by type
puts "\n2. Grouping events by model type..."
events_by_model = all_events.group_by { |e| e.data[:model_class] }
events_by_model.each do |model, events|
  puts "   #{model}: #{events.count} events"
end

# Group events by operation
puts "\n3. Grouping events by operation..."
events_by_op = all_events.group_by { |e| e.data[:operation] }
events_by_op.each do |operation, events|
  puts "   #{operation}: #{events.count} events"
end

# Analyze a specific user's event stream
puts "\n4. Analyzing specific user's event stream..."
user = User.first
puts "   User: #{user.name} (ID: #{user.id})"

stream_name = "User$#{user.id}"
user_events = Rails.configuration.event_store.read.stream(stream_name).to_a
puts "   ✓ Events for this user: #{user_events.count}"

puts "   Event timeline:"
user_events.each_with_index do |event, index|
  operation = event.data[:operation]
  timestamp = event.metadata[:timestamp] || event.metadata[:created_at]
  changes = event.data[:changes]&.keys || []

  puts "     #{index + 1}. #{operation.to_s.upcase}"
  puts "        Time: #{timestamp}"
  if changes.any?
    puts "        Changed: #{changes.join(', ')}"
  end
end

# Event flow analysis
puts "\n5. Event flow analysis for user..."
event_flow = Lyra::EventFlow.new(user_events)
analysis = event_flow.analyze

puts "   Timeline:"
puts "     - First: #{analysis[:timeline][:first_event]}"
puts "     - Last: #{analysis[:timeline][:last_event]}"
puts "     - Duration: #{analysis[:timeline][:duration_minutes]&.round(2) || 'N/A'} minutes"

puts "   Operations:"
analysis[:operations].each do |op, count|
  puts "     - #{op}: #{count}"
end

puts "   Metrics:"
puts "     - Ops/day: #{analysis[:metrics][:operations_per_day]&.round(2) || 'N/A'}"

# Privacy analysis
puts "\n6. Privacy impact analysis..."
privacy_impact = analysis[:privacy]
puts "   PII fields detected:"
if privacy_impact[:pii_fields].any?
  privacy_impact[:pii_fields].each do |field, info|
    puts "     - #{field}: #{info[:type]} (#{info[:sensitivity]})"
  end
else
  puts "     (none detected)"
end

puts "   Events with PII: #{privacy_impact[:events_with_pii]} / #{user_events.count}"
if privacy_impact[:percentage]
  puts "   PII percentage: #{privacy_impact[:percentage].round(2)}%"
end

# Analyze all posts
puts "\n7. Analyzing all posts..."
Post.find_each do |post|
  stream_name = "Post$#{post.id}"
  post_events = Rails.configuration.event_store.read.stream(stream_name).to_a

  puts "   Post: \"#{post.title[0..40]}...\""
  puts "     - Author: #{post.user.name}"
  puts "     - Status: #{post.status}"
  puts "     - Events: #{post_events.count}"

  # Count operations
  ops = post_events.group_by { |e| e.data[:operation] }.transform_values(&:count)
  puts "     - Operations: #{ops.map { |k, v| "#{k}:#{v}" }.join(', ')}"
end

# Comments analysis
puts "\n8. Analyzing comments..."
total_comment_events = 0
Comment.find_each do |comment|
  stream_name = "Comment$#{comment.id}"
  comment_events = Rails.configuration.event_store.read.stream(stream_name).to_a
  total_comment_events += comment_events.count
end
puts "   ✓ Total comments: #{Comment.count}"
puts "   ✓ Total comment events: #{total_comment_events}"
puts "   ✓ Average events per comment: #{(total_comment_events.to_f / Comment.count).round(2)}"

# Correlation analysis
puts "\n9. Correlation analysis..."
correlated_events = all_events.select { |e| e.metadata[:correlation_id] }
puts "   ✓ Events with correlation IDs: #{correlated_events.count} / #{all_events.count}"

if correlated_events.any?
  correlations = correlated_events.group_by { |e| e.metadata[:correlation_id] }
  puts "   ✓ Unique correlation chains: #{correlations.count}"

  puts "   Sample correlation chain:"
  sample = correlations.first
  puts "     Correlation ID: #{sample[0]}"
  puts "     Events in chain: #{sample[1].count}"
  sample[1].each_with_index do |event, index|
    puts "       #{index + 1}. #{event.data[:model_class]}.#{event.data[:operation]}"
  end
end

# Causation analysis
puts "\n10. Causation analysis..."
caused_events = all_events.select { |e| e.metadata[:causation_id] }
puts "   ✓ Events with causation IDs: #{caused_events.count} / #{all_events.count}"

# System health check
puts "\n11. System health check..."
puts "   Checking for discrepancies between CRUD and Event-sourced states..."

discrepancies = []
[User, Post, Comment].each do |model_class|
  model_class.find_each do |record|
    dual_view = Lyra::DualView.new(model_class, record.id)
    comparison = dual_view.compare

    unless comparison[:differences][:no_differences]
      discrepancies << {
        model: model_class.name,
        id: record.id,
        differences: comparison[:differences]
      }
    end
  end
end

if discrepancies.empty?
  puts "   ✓ All states consistent - no discrepancies found!"
else
  puts "   ⚠ Found #{discrepancies.count} discrepancies:"
  discrepancies.each do |disc|
    puts "     - #{disc[:model]}##{disc[:id]}: #{disc[:differences].keys.join(', ')}"
  end
end

# Event store statistics
puts "\n12. Event store statistics..."
puts "   Total events: #{all_events.count}"
puts "   Models with events: #{events_by_model.keys.count}"
puts "   Event types:"
event_types = all_events.group_by { |e| e.event_type }
event_types.each do |type, events|
  puts "     - #{type}: #{events.count}"
end

puts "\n" + "=" * 70
puts "Event Inspection Complete!"
puts "=" * 70
puts "\nKey Takeaways:"
puts "  • Event store contains complete history of all changes"
puts "  • Events can be queried by stream, type, or metadata"
puts "  • Privacy analysis identifies PII in events"
puts "  • Correlation and causation tracking shows relationships"
puts "  • Health checks ensure CRUD and event-sourced consistency"
