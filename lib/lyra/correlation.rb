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

    # The writes of one HTTP request share a correlation: the request id
    # (ActionDispatch::RequestId), or a new id without one. A correlation
    # already in scope is kept. Installed by the engine; off with
    # config.correlate_writes = false.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless Lyra.config.correlate_writes && Correlation.current_id.nil?

        Correlation.with_id(env["action_dispatch.request_id"].presence) { @app.call(env) }
      end
    end

    # The writes of one background job share a correlation: the one in scope
    # where the job was created (perform_later in a request, or in another
    # write's callbacks), or the job id without one. A write in scope there is
    # the cause of the job's outermost writes. Both are taken when the job is
    # created, not when it is serialized: a job deferred to after the commit
    # (enqueue_after_transaction_commit) is serialized outside the write that
    # enqueued it. They travel in the job's payload, so a retry keeps them.
    # Included into ActiveJob::Base by the engine; off with
    # config.correlate_writes = false.
    #
    # A job created inside a transaction and sent at once (not deferred: the
    # Rails default) can outlive a rollback of the write that caused it. Its
    # cause is unconfirmed, and kept when the job runs only if that event is
    # in the log, so no job names a cause the log lacks. A job that runs
    # before the enqueuing transaction commits loses the link, not its
    # correlation.
    module Job
      extend ActiveSupport::Concern

      included do
        around_perform :lyra_with_enqueuing_scope
      end

      attr_reader :lyra_correlation_id, :lyra_causation_id

      def initialize(...)
        super
        return unless Lyra.config.correlate_writes

        @lyra_correlation_id = Correlation.current_id
        @lyra_causation_id = Causation.current_id
        @lyra_cause_unconfirmed = !!@lyra_causation_id && !self.class.enqueue_after_transaction_commit &&
                                  ActiveRecord::Base.with_connection(&:transaction_open?)
      end

      def serialize
        data = super
        data["lyra_correlation_id"] = lyra_correlation_id if lyra_correlation_id
        data["lyra_causation_id"] = lyra_causation_id if lyra_causation_id
        data["lyra_cause_unconfirmed"] = true if @lyra_cause_unconfirmed
        data
      end

      def deserialize(job_data)
        super
        @lyra_correlation_id = job_data["lyra_correlation_id"]
        @lyra_causation_id = job_data["lyra_causation_id"]
        @lyra_cause_unconfirmed = job_data["lyra_cause_unconfirmed"] == true
      end

      private

      # A correlation already in scope (a job performed inline, inside the
      # request that created it) is kept, as by the Middleware.
      def lyra_with_enqueuing_scope
        return yield unless Lyra.config.correlate_writes && Correlation.current_id.nil?

        Correlation.with_id(lyra_correlation_id || job_id) do
          Causation.with_id(lyra_confirmed_cause) { yield }
        end
      end

      # The cause, once it is in the log; nil if it is not. Decided on the
      # first attempt: a retry carries the outcome in its payload.
      def lyra_confirmed_cause
        return lyra_causation_id unless @lyra_cause_unconfirmed

        @lyra_cause_unconfirmed = false
        @lyra_causation_id = nil unless Lyra.config.event_store.read.event(lyra_causation_id)
        lyra_causation_id
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
