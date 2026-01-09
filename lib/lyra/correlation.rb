module Lyra
  # Correlation system for grouping related operations and events
  # correlation_id: Groups all events from the same user action (e.g., all events from one HTTP request)
  class Correlation
    class << self
      # Generate a unique correlation ID for a group of operations
      def generate_id
        "corr_#{Time.now.to_i}_#{SecureRandom.hex(8)}"
      end

      # Current correlation ID (thread-safe)
      def current_id
        Thread.current[:lyra_correlation_id]
      end

      # Set correlation ID for current context
      def with_id(correlation_id = nil)
        correlation_id ||= generate_id
        previous_id = Thread.current[:lyra_correlation_id]
        Thread.current[:lyra_correlation_id] = correlation_id

        yield correlation_id if block_given?
      ensure
        Thread.current[:lyra_correlation_id] = previous_id
      end
    end
  end

  # Causation system for tracking event chains
  # causation_id: Points to the specific event that directly caused this event (parent-child relationship)
  #
  # Example:
  #   OrderPlaced (causation_id: nil)           <- root event
  #     └── PaymentProcessed (causation_id: OrderPlaced.id)
  #           └── InventoryReserved (causation_id: PaymentProcessed.id)
  #
  class Causation
    class << self
      # Current causation ID (the event that caused the current operation)
      def current_id
        Thread.current[:lyra_causation_id]
      end

      # Set causation ID for current context (when processing/handling an event)
      def with_id(causation_id)
        previous_id = Thread.current[:lyra_causation_id]
        Thread.current[:lyra_causation_id] = causation_id

        yield causation_id if block_given?
      ensure
        Thread.current[:lyra_causation_id] = previous_id
      end

      # Clear causation (for root events)
      def clear
        Thread.current[:lyra_causation_id] = nil
      end

      # Track causation relationship (for building causation chains)
      def track(cause_event_id, effect_event_id)
        causation_store[effect_event_id] = cause_event_id
      end

      # Get the full causation chain for an event (root -> ... -> event)
      def chain_for(event_id)
        chain = [event_id]
        current = event_id

        while (parent = causation_store[current])
          chain.unshift(parent)
          current = parent
          break if chain.size > 100 # Prevent infinite loops
        end

        chain
      end

      # Get direct cause of an event
      def cause_of(event_id)
        causation_store[event_id]
      end

      private

      def causation_store
        @causation_store ||= {}
      end
    end
  end

  # User action context for tracking what user action triggered events
  class UserActionContext
    attr_reader :action_id, :user_id, :action_type, :controller, :action_name, :params

    def initialize(action_type:, user_id: nil, controller: nil, action_name: nil, params: {})
      @action_id = "action_#{Time.now.to_i}_#{SecureRandom.hex(6)}"
      @action_type = action_type  # :web_request, :api_call, :background_job, :console
      @user_id = user_id
      @controller = controller
      @action_name = action_name
      @params = sanitize_params(params)
      @started_at = Time.current
    end

    def to_h
      {
        action_id: action_id,
        action_type: action_type,
        user_id: user_id,
        controller: controller,
        action_name: action_name,
        params: params,
        started_at: @started_at
      }
    end

    class << self
      def current
        Thread.current[:lyra_user_action_context]
      end

      def with_context(action_type:, user_id: nil, **options)
        context = new(action_type: action_type, user_id: user_id, **options)
        previous = Thread.current[:lyra_user_action_context]
        Thread.current[:lyra_user_action_context] = context

        # Also set correlation ID
        Lyra::Correlation.with_id(context.action_id) do
          yield context if block_given?
        end
      ensure
        Thread.current[:lyra_user_action_context] = previous
      end
    end

    private

    def sanitize_params(params)
      # Remove sensitive parameters
      sensitive_keys = [:password, :password_confirmation, :token, :secret, :api_key]
      params.except(*sensitive_keys)
    end
  end
end
