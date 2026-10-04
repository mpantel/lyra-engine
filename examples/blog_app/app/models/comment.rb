class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true, length: { maximum: 1000 }

  # Every create, update and destroy appends an event to "Comment$<id>".
  monitor_with_lyra
end
