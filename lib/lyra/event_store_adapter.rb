module Lyra
  # Pluggable event store adapter
  class EventStoreAdapter
    class << self
      def build(backend = nil)
        backend ||= Lyra.config.event_backend

        case backend
        when :rails_event_store, :res
          RailsEventStoreAdapter.new
        when :custom
          CustomEventStoreAdapter.new
        else
          raise "Unknown event backend: #{backend}"
        end
      end
    end
  end

  class RailsEventStoreAdapter
    def initialize
      @client = build_client
    end

    def publish(event, stream_name:)
      @client.publish(event, stream_name: stream_name)
    end

    def read_stream(stream_name)
      @client.read.stream(stream_name).to_a
    end

    def read_all_streams
      @client.read.to_a
    end

    def subscribe(subscriber, to:)
      @client.subscribe(subscriber, to: to)
    end

    private

    def build_client
      RailsEventStore::Client.new(
        repository: RailsEventStoreActiveRecord::EventRepository.new(
          serializer: RailsEventStore::Serializers::YAML
        )
      )
    end
  end

  class CustomEventStoreAdapter
    # Placeholder for custom event store implementations
    # Users can implement their own adapter by extending this class

    def publish(event, stream_name:)
      raise NotImplementedError, "Custom event store adapter must implement #publish"
    end

    def read_stream(stream_name)
      raise NotImplementedError, "Custom event store adapter must implement #read_stream"
    end

    def read_all_streams
      raise NotImplementedError, "Custom event store adapter must implement #read_all_streams"
    end

    def subscribe(subscriber, to:)
      raise NotImplementedError, "Custom event store adapter must implement #subscribe"
    end
  end
end
