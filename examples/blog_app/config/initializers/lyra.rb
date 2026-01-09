# Lyra Configuration
#
# This initializer configures Lyra for the blog application.
# It sets up event sourcing, privacy tracking, and GDPR compliance.

Rails.application.config.to_prepare do
  # Configure Lyra
  Lyra.configure do |config|
    # Set the mode: :monitor or :hijack
    # :monitor - CRUD operations happen normally, events are logged (safe for production)
    # :hijack - CRUD operations are intercepted and replaced with event sourcing
    config.mode = :monitor

    # Configure event store (uses RailsEventStore by default)
    config.event_store = Rails.configuration.event_store

    # Enable privacy features
    config.privacy_enabled = true

    # Set retention policy (default: 7 years)
    config.retention_policy = 7.years

    # Models to monitor (optional - can also use monitor_with_lyra in models)
    # config.monitor_model User, event_prefix: "User"
    # config.monitor_model Post, event_prefix: "Post"
    # config.monitor_model Comment, event_prefix: "Comment"
  end

  # Initialize RailsEventStore
  Rails.configuration.event_store = RailsEventStore::Client.new(
    repository: RailsEventStoreActiveRecord::EventRepository.new(
      serializer: RubyEventStore::NULL
    )
  )

  # Set Lyra's event store
  Lyra.config.event_store = Rails.configuration.event_store

  # Define Privacy Policy using PAM DSL
  PamDsl.define_policy :blog_data do
    # Define PII fields
    field :email, type: :email, sensitivity: :confidential
    field :name, type: :name, sensitivity: :internal
    field :ip_address, type: :ip_address, sensitivity: :internal

    # Define data processing purposes
    purpose :user_account do
      description "User account management and authentication"
      legal_basis :contract
      required_fields [:email, :name]
    end

    purpose :content_moderation do
      description "Moderating user-generated content"
      legal_basis :legitimate_interest
      optional_fields [:email, :ip_address]
    end

    purpose :marketing do
      description "Marketing communications"
      legal_basis :consent
      optional_fields [:email, :name]
    end

    # Define retention rules
    retention do
      default 7.years

      for_model "User" do
        keep_for 7.years
        field :email, duration: 2.years # Shorter retention for email
      end

      for_model "Post" do
        keep_for 10.years # Keep content longer
      end

      for_model "Comment" do
        keep_for 3.years
      end
    end

    # Define consent requirements
    consent do
      for_purpose :marketing do
        required! true
        withdrawable! true
        granular! true
        describe "We need your consent to send marketing emails"
        expires_in 1.year
      end

      for_purpose :content_moderation do
        required! false # Legitimate interest
      end
    end
  end

  # Register the policy
  PamDsl.registry.register(:blog_data, PamDsl.policy(:blog_data))

  puts "✓ Lyra initialized in #{config.mode} mode"
  puts "✓ Privacy policy 'blog_data' registered"
  puts "✓ Monitoring: User, Post, Comment models"
end
