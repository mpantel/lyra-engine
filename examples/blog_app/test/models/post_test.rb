require_relative '../test_helper'

class PostTest < Minitest::Test
  def setup
    super
    @user = User.create!(email: 'author@example.com', name: 'Author')
  end

  def test_post_creation_publishes_event
    post = Post.create!(
      user: @user,
      title: 'Test Post',
      body: 'This is a test post body with enough content'
    )

    assert_event_published 'Lyra::Events::PostCreate', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::PostCreate').first
    assert_equal post.id, event.data[:aggregate_id]
    assert_equal 'Test Post', event.data[:title]
    assert_equal 'This is a test post body with enough content', event.data[:body]
    assert_equal 'draft', event.data[:status]
  end

  def test_post_update_publishes_event
    post = Post.create!(
      user: @user,
      title: 'Original Title',
      body: 'Original body content'
    )

    post.update!(title: 'Updated Title', body: 'Updated body content')

    assert_event_published 'Lyra::Events::PostUpdate', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::PostUpdate').first
    assert_equal post.id, event.data[:aggregate_id]
    assert_equal 'Updated Title', event.data[:title]
    assert_equal 'Updated body content', event.data[:body]
  end

  def test_post_deletion_publishes_event
    post = Post.create!(
      user: @user,
      title: 'Test Post',
      body: 'Test content'
    )
    post_id = post.id

    post.destroy!

    assert_event_published 'Lyra::Events::PostDestroy', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::PostDestroy').first
    assert_equal post_id, event.data[:aggregate_id]
  end

  def test_post_publish
    post = Post.create!(
      user: @user,
      title: 'Draft Post',
      body: 'Draft content'
    )

    assert_equal 'draft', post.status
    assert_nil post.published_at

    post.publish!

    assert_equal 'published', post.status
    assert_not_nil post.published_at
    assert_event_published 'Lyra::Events::PostUpdate', count: 1
  end

  def test_post_archive
    post = Post.create!(
      user: @user,
      title: 'Published Post',
      body: 'Published content'
    )
    post.publish!

    post.archive!

    assert_equal 'archived', post.status
    assert_event_published 'Lyra::Events::PostUpdate', count: 2
  end

  def test_post_draft_predicate
    post = Post.create!(
      user: @user,
      title: 'Draft Post',
      body: 'Draft content',
      status: 'draft'
    )

    assert post.draft?
    refute post.published?
  end

  def test_post_published_predicate
    post = Post.create!(
      user: @user,
      title: 'Published Post',
      body: 'Published content'
    )
    post.publish!

    assert post.published?
    refute post.draft?
  end

  def test_post_validation_title_required
    post = Post.new(user: @user, body: 'Some content')

    refute post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  def test_post_validation_title_minimum_length
    post = Post.new(user: @user, title: 'ab', body: 'Some content')

    refute post.valid?
    assert_includes post.errors[:title], "is too short (minimum is 3 characters)"
  end

  def test_post_validation_title_maximum_length
    long_title = 'a' * 201
    post = Post.new(user: @user, title: long_title, body: 'Some content')

    refute post.valid?
    assert_includes post.errors[:title], "is too long (maximum is 200 characters)"
  end

  def test_post_validation_body_required
    post = Post.new(user: @user, title: 'Test Post')

    refute post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end

  def test_post_validation_body_minimum_length
    post = Post.new(user: @user, title: 'Test Post', body: 'short')

    refute post.valid?
    assert_includes post.errors[:body], "is too short (minimum is 10 characters)"
  end

  def test_post_validation_status_inclusion
    post = Post.new(
      user: @user,
      title: 'Test Post',
      body: 'Test content',
      status: 'invalid_status'
    )

    refute post.valid?
    assert_includes post.errors[:status], "is not included in the list"
  end

  def test_post_scope_published
    draft_post = Post.create!(
      user: @user,
      title: 'Draft Post',
      body: 'Draft content',
      status: 'draft'
    )

    published_post = Post.create!(
      user: @user,
      title: 'Published Post',
      body: 'Published content'
    )
    published_post.publish!

    published_posts = Post.published.to_a

    assert_includes published_posts, published_post
    refute_includes published_posts, draft_post
  end

  def test_post_scope_by_user
    user2 = User.create!(email: 'user2@example.com', name: 'User 2')

    post1 = Post.create!(
      user: @user,
      title: 'Post by User 1',
      body: 'Content by user 1'
    )

    post2 = Post.create!(
      user: user2,
      title: 'Post by User 2',
      body: 'Content by user 2'
    )

    user1_posts = Post.by_user(@user.id).to_a

    assert_includes user1_posts, post1
    refute_includes user1_posts, post2
  end

  def test_post_associations_user_required
    post = Post.new(title: 'Test Post', body: 'Test content')

    refute post.valid?
    assert_includes post.errors[:user], "must exist"
  end

  def test_post_associations_comments_destroyed
    post = Post.create!(
      user: @user,
      title: 'Test Post',
      body: 'Test content'
    )

    comment = Comment.create!(
      user: @user,
      post: post,
      body: 'Test comment'
    )
    comment_id = comment.id

    post.destroy!

    assert_nil Comment.find_by(id: comment_id)
  end

  def test_event_stream_for_post
    post = Post.create!(
      user: @user,
      title: 'Test Post',
      body: 'Test content'
    )
    post.update!(body: 'Updated content')
    post.publish!
    post.archive!

    events = events_for(Post, post.id)

    assert_equal 4, events.size
    assert_equal 'Lyra::Events::PostCreate', events[0].event_type
    assert_equal 'Lyra::Events::PostUpdate', events[1].event_type
    assert_equal 'Lyra::Events::PostUpdate', events[2].event_type
    assert_equal 'Lyra::Events::PostUpdate', events[3].event_type
  end

  def test_post_workflow_complete
    # Create as draft
    post = Post.create!(
      user: @user,
      title: 'Workflow Post',
      body: 'Workflow content'
    )
    assert_equal 'draft', post.status

    # Update content
    post.update!(body: 'Updated workflow content')

    # Publish
    post.publish!
    assert_equal 'published', post.status
    assert_not_nil post.published_at

    # Archive
    post.archive!
    assert_equal 'archived', post.status

    # Delete
    post.destroy!

    # Verify all events were published
    events = Lyra.config.event_store.read.to_a
    event_types = events.map(&:event_type)

    assert_includes event_types, 'Lyra::Events::PostCreate'
    assert_includes event_types, 'Lyra::Events::PostUpdate'
    assert_includes event_types, 'Lyra::Events::PostDestroy'
  end

  def test_view_count_increment
    post = Post.create!(
      user: @user,
      title: 'Popular Post',
      body: 'Popular content'
    )

    assert_equal 0, post.view_count

    post.update!(view_count: post.view_count + 1)
    post.reload

    assert_equal 1, post.view_count
    assert_event_published 'Lyra::Events::PostUpdate', count: 1
  end
end
