require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "create, update and destroy each append an event to the post's stream" do
    post = Post.create!(user: author, title: "Hello", body: "First post")
    post.publish!
    id = post.id
    post.destroy!

    events = Lyra.config.event_store.read.stream("Post$#{id}").to_a
    assert_equal %w[PostCreated PostUpdated PostDestroyed], events.map { _1.event_type.demodulize }
    assert_equal %i[created updated destroyed], events.map(&:operation)

    created, updated, = events
    assert_equal "Hello", created.attributes["title"]
    assert_equal %w[draft published], updated.changes["status"]
    assert_equal "blog_app", updated.metadata[:source]
  end

  test "DualView finds the row and the replayed stream in agreement" do
    post = Post.create!(user: author, title: "Hello", body: "First post")
    post.update!(title: "Hello again")

    comparison = Lyra::DualView.new(Post, post.id).compare
    assert_equal({ no_differences: true }, comparison[:differences])
    assert_equal "Hello again", comparison[:event_sourced_view][:state]["title"]
  end

  test "Lyra.state_at rebuilds the post as it was" do
    post = Post.create!(user: author, title: "Before", body: "First post")
    between = Time.current
    post.update!(title: "After")

    assert_equal "Before", Lyra.state_at(Post, post.id, between)["title"]
    assert_equal "After", Lyra.state_at(Post, post.id, Time.current)["title"]
  end

  test "in Hijack the event is appended first and the row is still written" do
    previous_mode = Lyra.config.mode
    Lyra.config.mode = :hijack # the raw setter: ungated, for tests only

    post = Post.create!(user: author, title: "Hijacked", body: "Written through a command")

    assert_equal "Hijacked", Post.find(post.id).title
    assert_equal [:created], stream(post).map(&:operation)
    assert_equal({ no_differences: true }, Lyra::DualView.new(Post, post.id).compare[:differences])
  ensure
    Lyra.config.mode = previous_mode
  end
end
