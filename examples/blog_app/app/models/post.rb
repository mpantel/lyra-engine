# Example Post model demonstrating Lyra integration
#
# Shows how content changes are tracked as events
#
class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { minimum: 3, maximum: 200 }
  validates :body, presence: true, length: { minimum: 10 }
  validates :status, inclusion: { in: %w[draft published archived] }

  # Enable Lyra monitoring
  monitor_with_lyra event_prefix: "Post"

  scope :published, -> { where(status: "published") }
  scope :by_user, ->(user_id) { where(user_id: user_id) }

  def publish!
    update!(status: "published", published_at: Time.current)
  end

  def archive!
    update!(status: "archived")
  end

  def draft?
    status == "draft"
  end

  def published?
    status == "published"
  end
end
