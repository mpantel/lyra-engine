class Post < ApplicationRecord
  STATUSES = %w[draft published archived].freeze

  belongs_to :user
  has_many :comments, dependent: :destroy

  validates :title, presence: true, length: { in: 3..200 }
  validates :body, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Every create, update and destroy appends an event to "Post$<id>".
  monitor_with_lyra

  scope :published, -> { where(status: "published") }

  def publish!
    update!(status: "published", published_at: Time.current)
  end
end
