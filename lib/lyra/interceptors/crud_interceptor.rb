module Lyra
  module Interceptors
    # Where hijack and event-sourcing modes take over a write.
    #
    # Prepended to ActiveRecord::Persistence, so these methods sit directly
    # above the ones that issue the INSERT, UPDATE and DELETE, and run inside
    # the create/update/destroy callbacks' block: after every before_* callback
    # of the model, whichever class defined it, and before the row write. The
    # event therefore sees the record as the application finished preparing it.
    #
    # This replaces before_create/before_update/before_destroy callbacks
    # registered on ActiveRecord::Base, which ran before the model's own. Values
    # those set (Solidus's Order#guest_token and Payment#number) were missing
    # from hijack events, and lost from the table under event sourcing, where
    # the row is projected from the event. A failed command returns false:
    # Rails then skips the after_* callbacks, save returns false and the
    # transaction rolls back (throw(:abort) is not caught inside the block).
    module WriteHooks
      def _create_record(*args)
        return super unless lyra_takes_over_write_here?
        return false unless lyra_hijack_mode? ? lyra_hijack_create : lyra_prepare_event_source_create

        # The columns to insert were chosen above this point (partial inserts),
        # before the command reserved the ID. Add the primary key, or the row
        # gets a database-assigned ID different from the one the event carries.
        pk = self.class.primary_key
        args[0] = Array(args[0]) | [pk] if args.any? && pk && !id.nil?
        super(*args)
      end

      def _update_record(*)
        return super unless lyra_takes_over_write_here?
        return false unless lyra_hijack_mode? ? lyra_hijack_update : lyra_prepare_event_source_update

        super
      end

      def destroy
        return super unless lyra_takes_over_write_here? && persisted?
        return false unless lyra_hijack_mode? ? lyra_hijack_destroy : lyra_prepare_event_source_destroy

        super
      end

      private

      def lyra_takes_over_write_here?
        respond_to?(:lyra_takes_over_write?, true) && lyra_takes_over_write?
      end
    end

    module CrudInterceptor
      extend ActiveSupport::Concern

      included do
        # Track if this model is being monitored
        class_attribute :lyra_monitored, default: false
        class_attribute :lyra_config

        # Callbacks for monitoring CRUD operations (after_* = non-blocking).
        # Gated on the mode as well as the model: in :disabled mode a monitored
        # model must behave exactly like plain ActiveRecord and emit no events.
        after_create :lyra_intercept_create, if: :lyra_events_enabled?
        after_update :lyra_intercept_update, if: :lyra_events_enabled?
        after_destroy :lyra_intercept_destroy, if: :lyra_events_enabled?

        # Hijack and event-sourcing modes build their event in WriteHooks, after
        # every before_* callback and just before the row write (see below).
        # Only PaperTrail is switched off here, first, so that its own
        # callbacks (a before_destroy among them) do not record a version that
        # Lyra's event replaces.
        before_create :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true
        before_update :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true
        before_destroy :lyra_disable_paper_trail!, if: :lyra_takes_over_write?, prepend: true

        ActiveRecord::Persistence.prepend(WriteHooks) unless ActiveRecord::Persistence.ancestors.include?(WriteHooks)

        # After callbacks to finalize event sourcing
        after_create :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?
        after_update :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?
        after_destroy :lyra_finalize_event_source, if: :lyra_event_sourcing_mode?
      end

      # Override _update_row to skip SQL UPDATE in event_sourcing mode.
      # Rails 6.1+ calls _update_row from within _run_update_callbacks,
      # so this runs AFTER before_update callbacks when @lyra_skip_sql is set.
      def _update_row(*)
        if @lyra_skip_sql
          # Skip the UPDATE - projection will handle it
          # Return 1 to indicate one row was "updated"
          1
        else
          super
        end
      end

      # Override _delete_row to skip SQL DELETE in event_sourcing mode.
      # Similar to _update_row, runs after before_destroy callbacks.
      def _delete_row
        if @lyra_skip_sql
          # Skip the DELETE - projection will handle it
          # Return 1 to indicate one row was "deleted"
          1
        else
          super
        end
      end

      class_methods do
        # Enable Lyra monitoring for this model
        def monitor_with_lyra(options = {})
          self.lyra_monitored = true
          self.lyra_config = Lyra::ModelConfiguration.new(self, options)
          Lyra.config.monitor_model(self, options)

          # Prepend strict data access modules to guard callback-bypassing methods
          # Using prepend ensures our methods run first and can call super
          prepend Lyra::StrictDataAccess
          singleton_class.prepend Lyra::StrictDataAccessClassMethods
        end

        # Override _insert_record to skip SQL INSERT when Lyra signals to skip.
        # Uses Thread.current to receive signal from instance-level before_create.
        def _insert_record(connection, values, returning)
          if Thread.current[:lyra_skip_insert]
            # Skip the INSERT - projection will handle it
            # Return the pre-assigned ID as the "returning" value
            id_value = values[primary_key] || values[primary_key.to_sym]
            returning.map { |col| col == primary_key ? id_value : nil }
          else
            super
          end
        end

        # =======================================================================
        # Read overrides for disabled projection mode
        # When projection_mode is :disabled, read from event store instead of DB
        # =======================================================================

        def find(*args)
          if lyra_read_from_events?
            id = args.first
            record = Lyra::Projections::EventStoreReader.find(self, id)
            raise ActiveRecord::RecordNotFound.new("Couldn't find #{name} with '#{primary_key}'=#{id}", self, primary_key, id) unless record
            record
          else
            super
          end
        end

        def find_by(attributes)
          if lyra_read_from_events?
            Lyra::Projections::EventStoreReader.find_by(self, attributes)
          else
            super
          end
        end

        def find_by!(attributes)
          if lyra_read_from_events?
            record = Lyra::Projections::EventStoreReader.find_by(self, attributes)
            raise ActiveRecord::RecordNotFound.new("Couldn't find #{name}", self) unless record
            record
          else
            super
          end
        end

        def exists?(conditions = :none)
          if lyra_read_from_events? && (conditions.is_a?(Integer) || conditions.is_a?(String))
            Lyra::Projections::EventStoreReader.exists?(self, conditions)
          else
            super
          end
        end

        # Override where to use cached projections in disabled mode
        # Returns a CachedRelation that supports method chaining
        def where(...)
          if lyra_read_from_events?
            Lyra::Projections::EventStoreReader.relation(self).where(...)
          else
            super
          end
        end

        # Override all to use cached projections in disabled mode
        # Note: Rails 8 passes arguments to all() in internal call chains (e.g., reload)
        def all(...)
          if lyra_read_from_events?
            Lyra::Projections::EventStoreReader.all(self)
          else
            super
          end
        end

        # Override first/last to properly order by primary key
        # Rails' Model.first is equivalent to Model.order(pk: :asc).limit(1).first
        # Rails' Model.last is equivalent to Model.order(pk: :desc).limit(1).first
        def first(limit = nil)
          if lyra_read_from_events?
            relation = Lyra::Projections::EventStoreReader.relation(self)
            relation.order(primary_key => :asc).first(limit)
          else
            super
          end
        end

        def last(limit = nil)
          if lyra_read_from_events?
            relation = Lyra::Projections::EventStoreReader.relation(self)
            relation.order(primary_key => :desc).first(limit)
          else
            super
          end
        end

        # NOTE: We intentionally do NOT override unscoped here.
        # Association loading is handled by AssociationInterceptor instead,
        # which patches AR's BelongsTo/HasOne/HasMany association classes directly.
        # This avoids compatibility issues with AR's internal scope building machinery.

        private

        def lyra_read_from_events?
          return false if Thread.current[:lyra_bypass_read_override]
          lyra_monitored &&
            Lyra.event_sourcing_mode? &&
            Lyra.config.projection_mode == :disabled
        end
      end

      private

      def lyra_monitored?
        self.class.lyra_monitored
      end

      # Monitoring a model is not enough to emit events: :disabled mode must be a
      # true ORM baseline. Hijack and event-sourcing modes still pass this guard;
      # their after_* callbacks return early via @lyra_hijacked.
      def lyra_events_enabled?
        lyra_monitored? && !Lyra.disabled_mode?
      end

      def lyra_hijack_mode?
        lyra_monitored? && Lyra.hijack_mode?
      end

      def lyra_event_sourcing_mode?
        lyra_monitored? && Lyra.event_sourcing_mode?
      end

      def lyra_takes_over_write?
        lyra_hijack_mode? || lyra_event_sourcing_mode?
      end

      # MONITOR MODE: After callbacks that log events
      def lyra_intercept_create
        return if @lyra_hijacked

        event_data = build_event_data(:created)
        publish_event(:created, event_data)
      end

      def lyra_intercept_update
        return if @lyra_hijacked

        event_data = build_event_data(:updated)
        publish_event(:updated, event_data)
      end

      def lyra_intercept_destroy
        return if @lyra_hijacked

        event_data = build_event_data(:destroyed)
        publish_event(:destroyed, event_data)
      end

      # HIJACK MODE: called from WriteHooks, after every before_* callback and
      # before the row write. Each command method returns true, or false with
      # an error on the record, which stops the write.
      def lyra_hijack_create
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::CreateCommand.new(self.class, attributes)
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          # Take the ID the Created event carries, so the row is inserted under
          # it. Nothing else changed: assigning every attribute back (as this
          # used to) is redundant and fails on models that guard a writer
          # (Solidus's StockItem#count_on_hand=).
          self.id = result.attributes[:id] if result.attributes.key?(:id)
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      def lyra_hijack_update
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::UpdateCommand.new(self.class, id, changes)
        result = Lyra::CommandHandler.handle(command)

        return true if result.success?

        errors.add(:base, result.error)
        false
      end

      def lyra_hijack_destroy
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::DestroyCommand.new(self.class, id)
        result = Lyra::CommandHandler.handle(command)

        return true if result.success?

        errors.add(:base, result.error)
        false
      end

      # EVENT SOURCING MODE: Prepare phase (called from WriteHooks, like hijack)
      # Generate ID, create event, mark to skip SQL.
      # For creates: Thread.current[:lyra_skip_insert] signals _insert_record to skip.
      # For updates/deletes: @lyra_skip_sql causes _update_row/_delete_row to skip.
      # The sync projection handles persistence instead.
      def lyra_prepare_event_source_create
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::CreateCommand.new(self.class, attributes)
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          # Store result for after callback
          @lyra_event_result = result
          @lyra_event_operation = :create
          @lyra_assigned_id = result.attributes[:id]

          # Assign the pre-generated ID
          self.id = @lyra_assigned_id if @lyra_assigned_id

          # Signal class method _insert_record to skip the SQL INSERT
          Thread.current[:lyra_skip_insert] = true
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      def lyra_prepare_event_source_update
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::UpdateCommand.new(self.class, id, changes)
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          @lyra_event_result = result
          @lyra_event_operation = :update
          @lyra_skip_sql = true
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      def lyra_prepare_event_source_destroy
        @lyra_hijacked = true
        lyra_disable_paper_trail!

        command = Lyra::Commands::DestroyCommand.new(self.class, id)
        result = Lyra::CommandHandler.handle(command)

        if result.success?
          @lyra_event_result = result
          @lyra_event_operation = :destroy
          @lyra_skip_sql = true
          true
        else
          errors.add(:base, result.error)
          false
        end
      end

      # EVENT SOURCING MODE: Finalize phase (after callbacks)
      # Store events and run projections
      def lyra_finalize_event_source
        return unless @lyra_event_result

        # Store events to the event store
        if @lyra_event_result.events&.any?
          lyra_store_events(@lyra_event_result.events)
        end

        # Run projection based on configured mode
        case Lyra.config.projection_mode
        when :sync
          lyra_run_sync_projection(@lyra_event_operation, @lyra_event_result)
        when :async
          lyra_enqueue_async_projection(@lyra_event_operation, @lyra_event_result)
        when :disabled
          # Warm cache with the new data (uses Solid Cache or Rails.cache)
          lyra_warm_cache(@lyra_event_operation, @lyra_event_result)
        when :lazy
          # ES-Lazy: nothing to do now. The next read brings the tables up to
          # date from the log (Projections::LazyProjection).
        end

        # Clear state
        @lyra_event_result = nil
        @lyra_event_operation = nil
        @lyra_skip_sql = false
        Thread.current[:lyra_skip_insert] = nil
      end

      # Run synchronous projection (update model table from event)
      def lyra_run_sync_projection(operation, result)
        # Record for read-your-writes consistency if in guaranteed block
        if Lyra::Consistency::ReadYourWrites.in_guaranteed_block?
          Lyra::Consistency::ReadYourWrites.record_write(self.class, operation, result)
          return  # Will be projected at end of block
        end

        Lyra::Projections::ModelProjection.project(self.class, operation, result)
      rescue => e
        if Lyra.config.strict_projections
          raise
        else
          Rails.logger.error("Lyra: Sync projection failed - #{e.message}")
          Lyra.config.projection_error_handler&.call(e, self, operation)
        end
      end

      # Enqueue asynchronous projection job
      def lyra_enqueue_async_projection(operation, result)
        event = result.events&.first
        return unless event

        # In test environment, run synchronously for immediate consistency
        if Rails.env.test? || Lyra.config.async_projections_inline
          Lyra::Projections::ModelProjection.project(self.class, operation, result)
        else
          Lyra::Projections::AsyncProjectionJob.perform_later(
            event.event_id,
            self.class.name,
            operation.to_s
          )
        end
      rescue => e
        if Lyra.config.strict_projections
          raise
        else
          Rails.logger.error("Lyra: Failed to enqueue async projection - #{e.message}")
          Lyra.config.projection_error_handler&.call(e, self, operation)
        end
      end

      # Warm cache after event stored (for disabled projection mode)
      # Uses Solid Cache (or any Rails.cache backend) for fast reads
      def lyra_warm_cache(operation, result)
        model_id = case operation
        when :create
          result.attributes[:id] || result.attributes["id"]
        when :update, :destroy
          event = result.events&.first
          event&.data&.dig(:model_id) || event&.data&.dig("model_id")
        end

        return unless model_id

        if operation == :destroy
          # Invalidate cache for destroyed record
          Lyra::Projections::EventStoreReader.invalidate(self.class, model_id)
        else
          # Warm cache with new/updated data
          Lyra::Projections::EventStoreReader.warm(self.class, model_id)
        end
      rescue => e
        Rails.logger.warn("Lyra: Failed to warm cache - #{e.message}")
      end

      # Store events to the event store
      def lyra_store_events(events)
        stream_name = lyra_stream_name
        events.each do |event|
          Lyra.config.event_store.publish(event, stream_name: stream_name)
        end
      rescue => e
        if Lyra.config.strict_projections
          raise
        else
          Rails.logger.error("Lyra: Failed to store events - #{e.message}")
        end
      end

      # Disable PaperTrail for this record in hijack/event_sourcing mode
      # (Lyra's event sourcing replaces PaperTrail's audit trail)
      def lyra_disable_paper_trail!
        return unless defined?(PaperTrail)

        # PaperTrail 17+ uses PaperTrail.request.enabled
        # This disables versioning for the current request/thread
        if PaperTrail.respond_to?(:request)
          PaperTrail.request.enabled = false
        elsif respond_to?(:paper_trail) && paper_trail.respond_to?(:enabled=)
          # Older PaperTrail versions use instance-level enabled
          paper_trail.enabled = false
        end
      rescue => e
        # Silently ignore if PaperTrail integration fails
      end

      def build_event_data(operation)
        # Base metadata from built-in context
        base_metadata = {
          user_id: lyra_current_user_id,
          request_id: lyra_current_request_id,
          correlation_id: Lyra::Correlation.current_id,
          causation_id: Lyra::Causation.current_id,
          action_id: lyra_current_action_id,
          user_action: lyra_current_user_action
        }

        # Merge custom metadata from metadata_proc if configured
        custom_metadata = lyra_custom_metadata(operation)
        merged_metadata = base_metadata.merge(custom_metadata)

        {
          model_class: self.class.name,
          model_id: id,
          operation: operation,
          attributes: attributes.except("created_at", "updated_at"),
          changes: previous_changes,
          timestamp: Time.current,
          metadata: merged_metadata
        }
      end

      # Get custom metadata from configured metadata_proc
      def lyra_custom_metadata(operation)
        return {} unless Lyra.config.metadata_proc

        begin
          result = Lyra.config.metadata_proc.call(self, operation)
          result.is_a?(Hash) ? result : {}
        rescue => e
          Rails.logger.warn("Lyra: metadata_proc failed - #{e.message}")
          {}
        end
      end

      def publish_event(operation, data)
        event_class = lyra_event_class_for(operation)

        # Extract metadata from data and pass separately to RailsEventStore
        metadata = data.delete(:metadata) || {}
        event = event_class.new(data: data, metadata: metadata)

        Lyra.config.event_store.publish(event, stream_name: lyra_stream_name)
      rescue => e
        Rails.logger.error("Lyra: Failed to publish event - #{e.message}")
        # Don't fail the CRUD operation if event publishing fails in monitor mode
      end

      def lyra_event_class_for(operation)
        config = self.class.lyra_config || Lyra.config.model_config(self.class)
        event_name = config.event_name_for(operation)
        # Sanitize namespaced event names (e.g., "Spree::OrderCreated" -> "SpreeOrderCreated")
        sanitized_name = event_name.to_s.gsub("::", "")

        # Find or create the event class in Lyra::Events namespace
        if Lyra::Events.const_defined?(sanitized_name, false)
          Lyra::Events.const_get(sanitized_name, false)
        else
          Lyra::Events.const_set(sanitized_name, Class.new(Lyra::Event))
        end
      end

      def lyra_stream_name
        "#{self.class.name}$#{id}"
      end

      # Hook methods for context (can be overridden by the application)
      def lyra_current_user_id
        defined?(Current) && Current.respond_to?(:user) ? Current.user&.id : nil
      end

      def lyra_current_request_id
        defined?(Current) && Current.respond_to?(:request_id) ? Current.request_id : nil
      end

      def lyra_current_action_id
        Lyra::UserActionContext.current&.action_id
      end

      def lyra_current_user_action
        context = Lyra::UserActionContext.current
        return nil unless context

        {
          type: context.action_type,
          controller: context.controller,
          action: context.action_name
        }
      end
    end
  end
end
