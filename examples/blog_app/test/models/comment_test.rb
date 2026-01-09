require_relative '../test_helper'

class CommentTest < Minitest::Test
  def setup
    super
    @user = User.create!(email: 'commenter@example.com', name: 'Commenter')
    @post = Post.create!(
      user: @user,
      title: 'Test Post',
      body: 'Test post content'
    )
  end

  def test_comment_creation_publishes_event
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'This is a test comment'
    )

    assert_event_published 'Lyra::Events::CommentCreate', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::CommentCreate').first
    assert_equal comment.id, event.data[:aggregate_id]
    assert_equal 'This is a test comment', event.data[:body]
  end

  def test_comment_update_publishes_event
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'Original comment'
    )

    comment.update!(body: 'Updated comment')

    assert_event_published 'Lyra::Events::CommentUpdate', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::CommentUpdate').first
    assert_equal comment.id, event.data[:aggregate_id]
    assert_equal 'Updated comment', event.data[:body]
  end

  def test_comment_deletion_publishes_event
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'Comment to delete'
    )
    comment_id = comment.id

    comment.destroy!

    assert_event_published 'Lyra::Events::CommentDestroy', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::CommentDestroy').first
    assert_equal comment_id, event.data[:aggregate_id]
  end

  def test_comment_validation_body_required
    comment = Comment.new(user: @user, post: @post)

    refute comment.valid?
    assert_includes comment.errors[:body], "can't be blank"
  end

  def test_comment_validation_body_maximum_length
    long_body = 'a' * 1001
    comment = Comment.new(
      user: @user,
      post: @post,
      body: long_body
    )

    refute comment.valid?
    assert_includes comment.errors[:body], "is too long (maximum is 1000 characters)"
  end

  def test_comment_associations_user_required
    comment = Comment.new(post: @post, body: 'Test comment')

    refute comment.valid?
    assert_includes comment.errors[:user], "must exist"
  end

  def test_comment_associations_post_required
    comment = Comment.new(user: @user, body: 'Test comment')

    refute comment.valid?
    assert_includes comment.errors[:post], "must exist"
  end

  def test_comment_scope_recent
    comment1 = Comment.create!(
      user: @user,
      post: @post,
      body: 'First comment'
    )
    comment1.update_column(:created_at, 2.hours.ago)

    comment2 = Comment.create!(
      user: @user,
      post: @post,
      body: 'Second comment'
    )
    comment2.update_column(:created_at, 1.hour.ago)

    comment3 = Comment.create!(
      user: @user,
      post: @post,
      body: 'Third comment'
    )

    recent_comments = Comment.recent.to_a

    assert_equal comment3.id, recent_comments[0].id
    assert_equal comment2.id, recent_comments[1].id
    assert_equal comment1.id, recent_comments[2].id
  end

  def test_comment_scope_for_post
    post2 = Post.create!(
      user: @user,
      title: 'Another Post',
      body: 'Another post content'
    )

    comment1 = Comment.create!(
      user: @user,
      post: @post,
      body: 'Comment on first post'
    )

    comment2 = Comment.create!(
      user: @user,
      post: post2,
      body: 'Comment on second post'
    )

    post_comments = Comment.for_post(@post.id).to_a

    assert_includes post_comments, comment1
    refute_includes post_comments, comment2
  end

  def test_comment_edited_predicate
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'Original comment'
    )

    refute comment.edited?

    # Simulate passage of time
    comment.update_column(:updated_at, comment.created_at + 2.minutes)
    comment.reload

    assert comment.edited?
  end

  def test_event_stream_for_comment
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'Original comment'
    )
    comment.update!(body: 'First edit')
    comment.update!(body: 'Second edit')

    events = events_for(Comment, comment.id)

    assert_equal 3, events.size
    assert_equal 'Lyra::Events::CommentCreate', events[0].event_type
    assert_equal 'Lyra::Events::CommentUpdate', events[1].event_type
    assert_equal 'Lyra::Events::CommentUpdate', events[2].event_type
  end

  def test_comment_lifecycle_complete
    # Create
    comment = Comment.create!(
      user: @user,
      post: @post,
      body: 'Lifecycle comment'
    )

    # Update
    comment.update!(body: 'Updated lifecycle comment')

    # Delete
    comment.destroy!

    # Verify all events
    events = Lyra.config.event_store.read.to_a
    event_types = events.map(&:event_type)

    assert_includes event_types, 'Lyra::Events::CommentCreate'
    assert_includes event_types, 'Lyra::Events::CommentUpdate'
    assert_includes event_types, 'Lyra::Events::CommentDestroy'
  end

  def test_multiple_comments_on_post
    comment1 = Comment.create!(
      user: @user,
      post: @post,
      body: 'First comment'
    )

    user2 = User.create!(email: 'user2@example.com', name: 'User 2')
    comment2 = Comment.create!(
      user: user2,
      post: @post,
      body: 'Second comment'
    )

    assert_equal 2, @post.comments.count
    assert_includes @post.comments, comment1
    assert_includes @post.comments, comment2
  end

  def test_comment_thread_tracking
    # Create a conversation thread
    comment1 = Comment.create!(
      user: @user,
      post: @post,
      body: 'Original comment'
    )

    user2 = User.create!(email: 'responder@example.com', name: 'Responder')
    comment2 = Comment.create!(
      user: user2,
      post: @post,
      body: 'Reply to comment'
    )

    comment3 = Comment.create!(
      user: @user,
      post: @post,
      body: 'Follow-up comment'
    )

    # Verify all comments are tracked in event store
    comment_events = Lyra.config.event_store.read.of_type('Lyra::Events::CommentCreate').to_a
    assert_equal 3, comment_events.size

    # Verify comments can be retrieved in order
    recent_comments = Comment.recent.to_a
    assert_equal 3, recent_comments.size
    assert_equal comment3.id, recent_comments[0].id
    assert_equal comment2.id, recent_comments[1].id
    assert_equal comment1.id, recent_comments[2].id
  end
end
