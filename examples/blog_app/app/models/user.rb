# Example User model demonstrating Lyra integration
#
# This model shows:
# - How to enable Lyra monitoring
# - PII field tracking (email, name)
# - Event generation on CRUD operations
# - Privacy-aware data handling
#
class User < ApplicationRecord
  # Standard Rails associations
  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  # Validations
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :age, numericality: { greater_than: 0, less_than: 150 }, allow_nil: true

  # Enable Lyra monitoring for this model
  # This will automatically:
  # - Track all CRUD operations as events
  # - Detect and flag PII fields (email, name)
  # - Enable dual-view comparison (CRUD state vs Event-sourced state)
  # - Provide event-based audit trail
  #
  monitor_with_lyra event_prefix: "User"

  # Example scopes
  scope :active, -> { where(deleted_at: nil) }
  scope :recent, -> { where("created_at > ?", 30.days.ago) }

  # Example methods
  def full_profile
    {
      id: id,
      name: name,
      email: email,
      age: age,
      posts_count: posts.count,
      comments_count: comments.count,
      member_since: created_at
    }
  end

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end
end
