# A few users, posts and comments. Every write below goes through
# ActiveRecord, so each record gets its own event stream. Idempotent.

alice = User.find_or_create_by!(email: "alice@example.com") do |user|
  user.name = "Alice Smith"
  user.bio = "Writes about event sourcing"
end
bob = User.find_or_create_by!(email: "bob@example.com") { |user| user.name = "Bob Jones" }

post = Post.find_or_create_by!(user: alice, title: "Getting started with event sourcing") do |p|
  p.body = "Every change to this post is also recorded as an event."
end
post.publish! unless post.published_at

Post.find_or_create_by!(user: alice, title: "A draft") { |p| p.body = "Not published yet." }

Comment.find_or_create_by!(user: bob, post: post, body: "Nice introduction.")

puts "#{User.count} users, #{Post.count} posts, #{Comment.count} comments; " \
     "#{Lyra.config.event_store.read.count} events"
