# Example blog data demonstrating Lyra event sourcing and privacy features

puts "Seeding blog application with example data..."

# Clear existing data
Comment.destroy_all
Post.destroy_all
User.destroy_all

# Create users with PII data
puts "\nCreating users..."
alice = User.create!(
  email: "alice@example.com",
  name: "Alice Smith",
  bio: "Tech blogger and Ruby enthusiast"
)
puts "  ✓ Created user: #{alice.name} (#{alice.email})"

bob = User.create!(
  email: "bob@example.com",
  name: "Bob Johnson",
  bio: "Software engineer writing about best practices"
)
puts "  ✓ Created user: #{bob.name} (#{bob.email})"

charlie = User.create!(
  email: "charlie@example.com",
  name: "Charlie Davis",
  bio: "Full-stack developer and open source contributor"
)
puts "  ✓ Created user: #{charlie.name} (#{charlie.email})"

# Create posts in various states
puts "\nCreating posts..."
post1 = Post.create!(
  user: alice,
  title: "Getting Started with Event Sourcing",
  body: "Event sourcing is a powerful pattern for building maintainable applications. In this post, we'll explore the basics...",
  status: :published
)
puts "  ✓ Created published post: #{post1.title}"

post2 = Post.create!(
  user: alice,
  title: "Advanced Event Sourcing Patterns",
  body: "Building on the basics, let's look at some advanced patterns...",
  status: :draft
)
puts "  ✓ Created draft post: #{post2.title}"

post3 = Post.create!(
  user: bob,
  title: "GDPR Compliance in Modern Applications",
  body: "Privacy regulations require careful consideration of how we store and process user data...",
  status: :published
)
puts "  ✓ Created published post: #{post3.title}"

post4 = Post.create!(
  user: bob,
  title: "Old Post About Deprecated Technology",
  body: "This post is no longer relevant...",
  status: :archived
)
puts "  ✓ Created archived post: #{post4.title}"

post5 = Post.create!(
  user: charlie,
  title: "Building REST APIs with Rails",
  body: "REST APIs are fundamental to modern web development. Here's how to build them effectively...",
  status: :published
)
puts "  ✓ Created published post: #{post5.title}"

# Create comments
puts "\nCreating comments..."
Comment.create!(
  user: bob,
  post: post1,
  body: "Great introduction! Looking forward to the next part."
)
puts "  ✓ Bob commented on Alice's post"

Comment.create!(
  user: charlie,
  post: post1,
  body: "This helped me understand the concept much better. Thanks!"
)
puts "  ✓ Charlie commented on Alice's post"

Comment.create!(
  user: alice,
  post: post3,
  body: "Excellent overview of GDPR requirements. Very helpful!"
)
puts "  ✓ Alice commented on Bob's post"

Comment.create!(
  user: charlie,
  post: post3,
  body: "We implemented these patterns in our application last year. Highly recommended!"
)
puts "  ✓ Charlie commented on Bob's post"

Comment.create!(
  user: alice,
  post: post5,
  body: "Nice guide! Have you considered adding authentication examples?"
)
puts "  ✓ Alice commented on Charlie's post"

# Perform some updates to generate more events
puts "\nPerforming updates to generate event history..."
alice.update!(bio: "Tech blogger, Ruby enthusiast, and event sourcing advocate")
puts "  ✓ Updated Alice's bio"

post2.update!(
  body: "Building on the basics, let's look at some advanced patterns like CQRS, sagas, and process managers...",
  status: :published
)
puts "  ✓ Published Alice's draft post"

post4.update!(status: :archived)
puts "  ✓ Archived Bob's old post"

# Demonstrate soft delete
puts "\nDemonstrating soft delete (data retained in events)..."
deleted_comment = Comment.create!(
  user: bob,
  post: post1,
  body: "This comment will be deleted but retained in event history"
)
deleted_comment.destroy
puts "  ✓ Created and deleted a comment (retained in events)"

puts "\n" + "=" * 60
puts "Seeding complete!"
puts "=" * 60
puts "\nSummary:"
puts "  Users: #{User.count}"
puts "  Posts: #{Post.count} (#{Post.where(status: :published).count} published, #{Post.where(status: :draft).count} drafts, #{Post.where(status: :archived).count} archived)"
puts "  Comments: #{Comment.count}"
puts "\nLyra is monitoring all changes. Check the event store to see captured events!"
puts "\nTry these example workflows in the Rails console:"
puts "  1. rails runner lib/examples/user_lifecycle.rb"
puts "  2. rails runner lib/examples/post_workflow.rb"
puts "  3. rails runner lib/examples/event_inspection.rb"
puts "  4. rails runner lib/examples/privacy_compliance.rb"
