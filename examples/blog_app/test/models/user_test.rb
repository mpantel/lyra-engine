require_relative '../test_helper'

class UserTest < Minitest::Test
  def test_user_creation_publishes_event
    user = User.create!(
      email: 'test@example.com',
      name: 'Test User',
      age: 25
    )

    assert_event_published 'Lyra::Events::UserCreate', count: 1

    event = last_event
    assert_equal 'Lyra::Events::UserCreate', event.event_type
    assert_equal user.id, event.data[:aggregate_id]
    assert_equal 'test@example.com', event.data[:email]
    assert_equal 'Test User', event.data[:name]
    assert_equal 25, event.data[:age]
  end

  def test_user_update_publishes_event
    user = User.create!(email: 'test@example.com', name: 'Test User')

    user.update!(name: 'Updated User', age: 30)

    assert_event_published 'Lyra::Events::UserUpdate', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::UserUpdate').first
    assert_equal user.id, event.data[:aggregate_id]
    assert_equal 'Updated User', event.data[:name]
    assert_equal 30, event.data[:age]
  end

  def test_user_deletion_publishes_event
    user = User.create!(email: 'test@example.com', name: 'Test User')
    user_id = user.id

    user.destroy!

    assert_event_published 'Lyra::Events::UserDestroy', count: 1

    event = Lyra.config.event_store.read.of_type('Lyra::Events::UserDestroy').first
    assert_equal user_id, event.data[:aggregate_id]
  end

  def test_user_soft_delete
    user = User.create!(email: 'test@example.com', name: 'Test User')

    user.soft_delete!

    assert_not_nil user.deleted_at
    assert_event_published 'Lyra::Events::UserUpdate', count: 1
  end

  def test_user_restore
    user = User.create!(email: 'test@example.com', name: 'Test User')
    user.soft_delete!

    user.restore!

    assert_nil user.deleted_at
    assert_event_published 'Lyra::Events::UserUpdate', count: 2
  end

  def test_user_full_profile
    user = User.create!(
      email: 'test@example.com',
      name: 'Test User',
      age: 25
    )

    Post.create!(user: user, title: 'Test Post', body: 'Content')
    Comment.create!(user: user, post: Post.first, body: 'Test Comment')

    profile = user.full_profile

    assert_equal user.id, profile[:id]
    assert_equal 'Test User', profile[:name]
    assert_equal 'test@example.com', profile[:email]
    assert_equal 25, profile[:age]
    assert_equal 1, profile[:posts_count]
    assert_equal 1, profile[:comments_count]
    assert_equal user.created_at, profile[:member_since]
  end

  def test_user_validation_email_required
    user = User.new(name: 'Test User')

    refute user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  def test_user_validation_email_format
    user = User.new(email: 'invalid-email', name: 'Test User')

    refute user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  def test_user_validation_email_uniqueness
    User.create!(email: 'test@example.com', name: 'User 1')
    user2 = User.new(email: 'test@example.com', name: 'User 2')

    refute user2.valid?
    assert_includes user2.errors[:email], "has already been taken"
  end

  def test_user_validation_name_required
    user = User.new(email: 'test@example.com')

    refute user.valid?
    assert_includes user.errors[:name], "can't be blank"
  end

  def test_user_validation_age_positive
    user = User.new(email: 'test@example.com', name: 'Test User', age: -5)

    refute user.valid?
    assert_includes user.errors[:age], "must be greater than 0"
  end

  def test_user_validation_age_maximum
    user = User.new(email: 'test@example.com', name: 'Test User', age: 200)

    refute user.valid?
    assert_includes user.errors[:age], "must be less than 150"
  end

  def test_user_scope_active
    active_user = User.create!(email: 'active@example.com', name: 'Active User')
    deleted_user = User.create!(email: 'deleted@example.com', name: 'Deleted User')
    deleted_user.soft_delete!

    active_users = User.active.to_a

    assert_includes active_users, active_user
    refute_includes active_users, deleted_user
  end

  def test_user_scope_recent
    old_user = User.create!(email: 'old@example.com', name: 'Old User')
    old_user.update_column(:created_at, 60.days.ago)

    recent_user = User.create!(email: 'recent@example.com', name: 'Recent User')

    recent_users = User.recent.to_a

    assert_includes recent_users, recent_user
    refute_includes recent_users, old_user
  end

  def test_user_associations_posts_destroyed
    user = User.create!(email: 'test@example.com', name: 'Test User')
    post = Post.create!(user: user, title: 'Test Post', body: 'Content')
    post_id = post.id

    user.destroy!

    assert_nil Post.find_by(id: post_id)
  end

  def test_user_associations_comments_destroyed
    user = User.create!(email: 'test@example.com', name: 'Test User')
    post = Post.create!(user: user, title: 'Test Post', body: 'Content')
    comment = Comment.create!(user: user, post: post, content: 'Comment')
    comment_id = comment.id

    user.destroy!

    assert_nil Comment.find_by(id: comment_id)
  end

  def test_event_stream_for_user
    user = User.create!(email: 'test@example.com', name: 'Test User')
    user.update!(name: 'Updated User')
    user.update!(age: 30)

    events = events_for(User, user.id)

    assert_equal 3, events.size
    assert_equal 'Lyra::Events::UserCreate', events[0].event_type
    assert_equal 'Lyra::Events::UserUpdate', events[1].event_type
    assert_equal 'Lyra::Events::UserUpdate', events[2].event_type
  end

  def test_user_lifecycle_complete
    # Create
    user = User.create!(
      email: 'lifecycle@example.com',
      name: 'Lifecycle User',
      bio: 'Initial bio'
    )
    assert_equal 1, event_count

    # Update
    user.update!(bio: 'Updated bio')
    assert_equal 2, event_count

    # Soft delete
    user.soft_delete!
    assert_equal 3, event_count

    # Restore
    user.restore!
    assert_equal 4, event_count

    # Hard delete
    user.destroy!
    assert_equal 5, event_count

    # Verify event types
    events = Lyra.config.event_store.read.to_a
    assert_equal 'Lyra::Events::UserCreate', events[0].event_type
    assert_equal 'Lyra::Events::UserUpdate', events[1].event_type
    assert_equal 'Lyra::Events::UserUpdate', events[2].event_type
    assert_equal 'Lyra::Events::UserUpdate', events[3].event_type
    assert_equal 'Lyra::Events::UserDestroy', events[4].event_type
  end
end
