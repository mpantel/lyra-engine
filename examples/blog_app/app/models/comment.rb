# Example Comment model demonstrating Lyra integration
#
# Shows tracking of user interactions
#
class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true, length: { minimum: 1, maximum: 1000 }

  # Enable Lyra monitoring
  monitor_with_lyra event_prefix: "Comment"

  scope :recent, -> { order(created_at: :desc) }
  scope :for_post, ->(post_id) { where(post_id: post_id) }

  def edited?
    updated_at > created_at + 1.minute
  end
end
