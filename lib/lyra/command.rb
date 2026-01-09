module Lyra
  # Base command class
  class Command
    attr_reader :model_class, :data

    def initialize(model_class, data = {})
      @model_class = model_class
      @data = data
    end

    def aggregate_id
      data[:id] || data['id']
    end
  end

  module Commands
    class CreateCommand < Command
      def initialize(model_class, attributes)
        super(model_class, attributes)
      end

      def attributes
        data
      end
    end

    class UpdateCommand < Command
      def initialize(model_class, id, changes)
        super(model_class, id: id, changes: changes)
      end

      def id
        data[:id]
      end

      def changes
        data[:changes]
      end
    end

    class DestroyCommand < Command
      def initialize(model_class, id)
        super(model_class, id: id)
      end

      def id
        data[:id]
      end
    end
  end

  # Command result
  class CommandResult
    attr_reader :success, :attributes, :error, :events

    def initialize(success:, attributes: {}, error: nil, events: [])
      @success = success
      @attributes = attributes
      @error = error
      @events = events
    end

    def success?
      @success
    end

    def failure?
      !success?
    end

    class << self
      def success(attributes: {}, events: [])
        new(success: true, attributes: attributes, events: events)
      end

      def failure(error:)
        new(success: false, error: error)
      end
    end
  end
end
