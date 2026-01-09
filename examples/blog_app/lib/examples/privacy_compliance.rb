# Example: Privacy Compliance and GDPR Features
# Demonstrates PII detection, masking, retention policies, and right to be forgotten

puts "=" * 70
puts "Privacy Compliance and GDPR Features Example"
puts "=" * 70

# Create a user with PII
puts "\n1. Creating user with PII data..."
user = User.create!(
  email: "privacy.demo@example.com",
  name: "Privacy Demo User",
  bio: "Testing GDPR compliance features"
)
puts "   ✓ User created: #{user.name}"
puts "   ✓ Email (PII): #{user.email}"

# Detect PII in user attributes
puts "\n2. Detecting PII in user attributes..."
pii_fields = Lyra::Privacy::PIIDetector.detect(user.attributes)

if pii_fields.any?
  puts "   ✓ PII fields detected:"
  pii_fields.each do |field, info|
    puts "     - #{field}: #{info[:type]} (#{info[:sensitivity]})"
  end
else
  puts "   ✗ No PII detected"
end

# Mask PII for display
puts "\n3. Masking PII for safe display..."
masked_attrs = Lyra::Privacy::PIIMasker.mask(user.attributes)
puts "   Original email: #{user.attributes['email']}"
puts "   Masked email: #{masked_attrs['email']}"
puts "   Original name: #{user.attributes['name']}"
puts "   Masked name: #{masked_attrs['name']}"

# Check events for PII
puts "\n4. Analyzing events for PII..."
stream_name = "User$#{user.id}"
events = Rails.configuration.event_store.read.stream(stream_name).to_a

event_flow = Lyra::EventFlow.new(events)
analysis = event_flow.analyze

puts "   Privacy analysis:"
puts "     - Events with PII: #{analysis[:privacy][:events_with_pii]} / #{events.count}"
puts "     - PII percentage: #{analysis[:privacy][:percentage]&.round(2) || 0}%"
puts "     - PII fields found:"
analysis[:privacy][:pii_fields].each do |field, info|
  puts "       • #{field}: #{info[:type]}"
end

# Apply PAM policy
puts "\n5. Applying Privacy Attribute Matrix (PAM) policy..."
policy = PamDsl.policies[:blog_data]

if policy
  puts "   ✓ Policy loaded: blog_data"

  # Check retention rules
  puts "   Retention rules:"
  model_policy = policy.find_model_policy("User")
  if model_policy
    puts "     - Default retention: #{model_policy[:retention][:default]}"

    model_policy[:retention][:fields]&.each do |field, duration|
      puts "     - #{field}: #{duration}"
    end
  end

  # Check legal basis
  puts "\n   Legal basis for processing:"
  policy.purposes.each do |purpose_name, purpose|
    puts "     - #{purpose_name}: #{purpose[:legal_basis]}"
    puts "       Required fields: #{purpose[:required_fields].join(', ')}"
  end
else
  puts "   ⚠ No policy defined"
end

# Demonstrate data export (Right to Data Portability)
puts "\n6. Data export (Right to Data Portability)..."
user_data = {
  profile: user.attributes,
  posts: user.posts.map(&:attributes),
  comments: user.comments.map(&:attributes)
}

puts "   ✓ Exported user data:"
puts "     - Profile attributes: #{user_data[:profile].keys.count}"
puts "     - Posts: #{user_data[:posts].count}"
puts "     - Comments: #{user_data[:comments].count}"

# Event-based data export
puts "\n   Event history export:"
all_user_events = []

# Collect events from all user-related streams
[
  "User-#{user.id}",
  *user.posts.map { |p| "Post-#{p.id}" },
  *user.comments.map { |c| "Comment-#{c.id}" }
].each do |stream|
  begin
    stream_events = Rails.configuration.event_store.read.stream(stream).to_a
    all_user_events.concat(stream_events)
  rescue => e
    # Stream might not exist
  end
end

puts "     - Total events: #{all_user_events.count}"
puts "     - Event types: #{all_user_events.map { |e| e.event_type }.uniq.join(', ')}"

# Demonstrate audit trail (Accountability)
puts "\n7. Audit trail for accountability..."
audit = Lyra::AuditProjection.audit_trail(User, user.id)

puts "   ✓ Audit entries: #{audit.count}"
puts "   Recent activity:"
audit.last(5).each_with_index do |entry, index|
  puts "     #{index + 1}. #{entry[:operation].to_s.upcase}"
  puts "        Timestamp: #{entry[:timestamp]}"
  puts "        User: #{entry[:user_id] || 'system'}"
  if entry[:changes] && entry[:changes].any?
    puts "        Changed: #{entry[:changes].keys.join(', ')}"
  end
end

# Anonymization demonstration
puts "\n8. Data anonymization (alternative to deletion)..."
puts "   Creating anonymized copy of user data..."

anonymized = user.attributes.dup
anonymized['email'] = "anonymized-#{user.id}@example.com"
anonymized['name'] = "Anonymized User #{user.id}"
anonymized['bio'] = "[Redacted for privacy]"

puts "   Original:"
puts "     - Email: #{user.email}"
puts "     - Name: #{user.name}"
puts "\n   Anonymized:"
puts "     - Email: #{anonymized['email']}"
puts "     - Name: #{anonymized['name']}"
puts "     - Bio: #{anonymized['bio']}"

# Right to be forgotten simulation
puts "\n9. Right to be forgotten (GDPR Article 17)..."
puts "   Steps for implementing right to be forgotten:"
puts "     1. Mark user as deleted (soft delete)"
puts "     2. Anonymize PII in database"
puts "     3. Mark events for retention policy enforcement"
puts "     4. Schedule PII removal from events after legal retention"

puts "\n   Simulating soft delete..."
user.soft_delete!
puts "   ✓ User soft-deleted at: #{user.deleted_at}"

puts "\n   Current state:"
puts "     - Database record: present (soft deleted)"
puts "     - Event history: present (#{events.count} events)"
puts "     - PII in events: present (pending retention policy)"

# Retention policy check
puts "\n10. Retention policy enforcement..."
puts "   Checking event ages against retention policy..."

now = Time.current
events.each_with_index do |event, index|
  event_time = event.metadata[:timestamp] || event.metadata[:created_at] || now
  age_days = ((now - event_time) / 1.day).round(2)

  retention_days = 365 * 7 # 7 years default
  should_retain = age_days < retention_days

  if index < 3 # Show first few events
    puts "   Event #{index + 1}:"
    puts "     - Age: #{age_days} days"
    puts "     - Retention: #{retention_days} days"
    puts "     - Status: #{should_retain ? 'RETAIN' : 'ELIGIBLE FOR DELETION'}"
  end
end

# Privacy compliance score
puts "\n11. Privacy compliance score..."
score = {
  pii_detection: pii_fields.any? ? 100 : 0,
  policy_defined: policy ? 100 : 0,
  audit_trail: audit.any? ? 100 : 0,
  event_tracking: events.any? ? 100 : 0,
  masking_available: true ? 100 : 0
}

total_score = score.values.sum / score.count
puts "   Compliance checks:"
score.each do |check, points|
  status = points == 100 ? "✓" : "✗"
  puts "     #{status} #{check.to_s.humanize}: #{points}%"
end

puts "\n   Overall compliance score: #{total_score}%"

puts "\n" + "=" * 70
puts "Privacy Compliance Example Complete!"
puts "=" * 70
puts "\nKey Takeaways:"
puts "  • PII automatically detected in attributes and events"
puts "  • Masking available for safe display and logging"
puts "  • PAM policy defines retention, legal basis, and purposes"
puts "  • Complete audit trail for accountability"
puts "  • Data export supports Right to Data Portability"
puts "  • Soft delete + anonymization supports Right to be Forgotten"
puts "  • Retention policies enforce time-based data lifecycle"
puts "  • Event sourcing enables complete compliance documentation"
