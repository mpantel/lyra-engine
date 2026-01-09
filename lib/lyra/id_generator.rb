# frozen_string_literal: true

module Lyra
  # Generates IDs for new records before event storage in event_sourcing mode.
  #
  # In event_sourcing mode, we need the record ID before the event is stored
  # (since we abort the actual database save). This class handles ID generation
  # for different database adapters and primary key types.
  #
  # Strategies:
  # - PostgreSQL: Use nextval() to reserve sequence value
  # - SQLite: Use max(id) + 1 (less safe for concurrent writes)
  # - MySQL/Other: Hi-Lo algorithm with configurable block size
  # - UUID columns: Generate SecureRandom.uuid
  #
  class IdGenerator
    # Thread-safe Hi-Lo state storage
    @hilo_mutex = Mutex.new
    @hilo_state = {}

    class << self
      # Generate the next ID for a model class
      #
      # @param model_class [Class] The ActiveRecord model class
      # @return [Integer, String] The generated ID
      def next_id(model_class)
        pk_column = model_class.columns_hash[model_class.primary_key]

        case pk_column&.type
        when :uuid
          SecureRandom.uuid
        when :integer, :bigint, nil
          next_integer_id(model_class)
        else
          # Default to UUID for unknown types
          SecureRandom.uuid
        end
      end

      private

      def next_integer_id(model_class)
        case adapter_name(model_class)
        when /postgresql/i
          next_postgresql_id(model_class)
        when /mysql/i, /trilogy/i
          next_hilo_id(model_class)
        when /sqlite/i
          next_sqlite_id(model_class)
        else
          next_hilo_id(model_class)
        end
      end

      def adapter_name(model_class)
        model_class.connection.adapter_name
      end

      # PostgreSQL: Reserve next sequence value atomically
      def next_postgresql_id(model_class)
        table = model_class.table_name
        pk = model_class.primary_key

        # Get the sequence name for this table's primary key
        result = model_class.connection.execute(
          "SELECT pg_get_serial_sequence('#{table}', '#{pk}')"
        )
        sequence = result.first&.values&.first

        if sequence
          # Reserve the next value from the sequence
          result = model_class.connection.execute("SELECT nextval('#{sequence}')")
          result.first["nextval"].to_i
        else
          # No sequence (maybe not a serial column), fall back to Hi-Lo
          next_hilo_id(model_class)
        end
      rescue StandardError => e
        Rails.logger.warn("Lyra::IdGenerator: PostgreSQL sequence failed (#{e.message}), using Hi-Lo")
        next_hilo_id(model_class)
      end

      # SQLite: Use max(id) + 1 (not ideal for concurrency)
      def next_sqlite_id(model_class)
        table = model_class.table_name
        pk = model_class.primary_key

        result = model_class.connection.execute(
          "SELECT MAX(#{pk}) as max_id FROM #{table}"
        )
        max_id = result.first&.fetch("max_id", 0) || 0
        max_id.to_i + 1
      rescue StandardError => e
        Rails.logger.warn("Lyra::IdGenerator: SQLite max failed (#{e.message}), using Hi-Lo")
        next_hilo_id(model_class)
      end

      # Hi-Lo Algorithm: Reserve blocks of IDs to minimize DB queries
      #
      # This algorithm reserves a block of IDs at once, reducing DB roundtrips.
      # Thread-safe implementation using mutex.
      #
      # @param model_class [Class] The model class
      # @param block_size [Integer] Number of IDs to reserve per hi value (default: 100)
      # @return [Integer] The next ID
      def next_hilo_id(model_class, block_size: 100)
        key = model_class.name

        @hilo_mutex.synchronize do
          @hilo_state[key] ||= { hi: nil, lo: 0, max_lo: block_size }
          state = @hilo_state[key]

          # Need to fetch new hi value?
          if state[:hi].nil? || state[:lo] >= state[:max_lo]
            state[:hi] = fetch_next_hi(model_class, block_size)
            state[:lo] = 0
          end

          # Calculate ID: hi * block_size + lo
          id = (state[:hi] * state[:max_lo]) + state[:lo]
          state[:lo] += 1
          id
        end
      end

      # Fetch the next hi value based on current max ID
      def fetch_next_hi(model_class, block_size)
        max_id = model_class.unscoped.maximum(model_class.primary_key) || 0
        # Calculate hi value that puts us above any existing ID
        (max_id / block_size) + 1
      rescue StandardError
        # If query fails, use timestamp-based hi to avoid collisions
        (Time.current.to_i / 100) % 1_000_000
      end
    end
  end
end
