# frozen_string_literal: true

module Lyra
  module Projections
    # Synchronous projection handler for updating model tables from events.
    #
    # In event_sourcing mode, this class is responsible for keeping the model
    # (read model) tables in sync with the event store. It uses raw SQL operations
    # (insert, update_all, delete_all) to avoid triggering ActiveRecord callbacks
    # or PaperTrail versioning.
    #
    # Usage:
    #   ModelProjection.project(Registration, :create, result)
    #   ModelProjection.project(Registration, :update, result)
    #   ModelProjection.project(Registration, :destroy, result)
    #
    class ModelProjection
      class << self
        # Project a command result to the model table
        #
        # @param model_class [Class] The ActiveRecord model class
        # @param operation [Symbol] :create, :update, or :destroy
        # @param result [CommandResult] The result from CommandHandler
        def project(model_class, operation, result)
          # Projection writes the table, so it must address the table. With
          # projection_mode :disabled (ES-NoProj), the model's where/all answer
          # from the event store instead; update and destroy below go through
          # model_class.where(...), and would then act on event-store records
          # rather than rows. A record destroyed in the log is absent from
          # those, so its row was never deleted. Rebuild and AsyncProjectionJob
          # both project through here, whatever the projection mode.
          previous = Thread.current[:lyra_bypass_read_override]
          Thread.current[:lyra_bypass_read_override] = true
          Lyra::PurposeBoundReads.internal do
            case operation
            when :create
              project_create(model_class, result)
            when :update
              project_update(model_class, result)
            when :destroy
              project_destroy(model_class, result)
            else
              raise ArgumentError, "Unknown operation: #{operation}"
            end
          end
        ensure
          Thread.current[:lyra_bypass_read_override] = previous
        end

        # Insert a new record into the model table
        #
        # Uses insert() to bypass all callbacks and validations.
        # This is intentional - the event is the source of truth.
        def project_create(model_class, result)
          attributes = result.attributes.dup

          # Ensure we have an ID
          raise "Cannot project create without ID" unless attributes[:id] || attributes["id"]

          # Add timestamps if not present
          now = Time.current
          attributes[:created_at] ||= now
          attributes[:updated_at] ||= now

          # Convert to database-safe format
          insert_attrs = sanitize_attributes(model_class, attributes)

          # Use insert to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          Lyra.projection_write { model_class.insert(insert_attrs) }
        end

        # Update an existing record in the model table
        #
        # Uses update_all() to bypass all callbacks.
        def project_update(model_class, result)
          event = result.events&.first
          return unless event

          model_id = event.data[:model_id] || event.data["model_id"]
          changes = event.data[:changes] || event.data["changes"] || {}

          return if changes.empty?

          # Extract new values from changes (changes are [old_value, new_value] tuples)
          # Use symbol keys consistently to avoid duplicate column errors
          updates = {}
          changes.each do |field, change|
            new_value = change.is_a?(Array) ? change.last : change
            updates[field.to_sym] = new_value
          end

          # Ensure updated_at timestamp (may already be in changes)
          updates[:updated_at] ||= Time.current

          # Use update_all to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          Lyra.projection_write { model_class.where(id: model_id).update_all(updates) }
        end

        # Delete a record from the model table
        #
        # Uses delete_all() to bypass callbacks and dependent destroy.
        def project_destroy(model_class, result)
          event = result.events&.first
          return unless event

          model_id = event.data[:model_id] || event.data["model_id"]

          # Use delete_all to bypass callbacks
          # Lyra.projection_write: skips strict access and publishes no bypass events
          Lyra.projection_write { model_class.where(id: model_id).delete_all }
        end

        private

        # Sanitize attributes for database insertion
        #
        # Removes attributes that don't correspond to database columns
        # and ensures proper type conversion.
        def sanitize_attributes(model_class, attributes)
          column_names = model_class.column_names.map(&:to_s)

          attributes.stringify_keys.slice(*column_names).tap do |attrs|
            # Convert any special types
            attrs.each do |key, value|
              # Handle BigDecimal/Float precision
              column = model_class.columns_hash[key]
              if column&.type == :decimal && value.is_a?(Float)
                attrs[key] = BigDecimal(value.to_s)
              end
            end
          end
        end
      end
    end
  end
end
