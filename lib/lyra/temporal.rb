# frozen_string_literal: true

module Lyra
  # Point-in-time reconstruction: what a record looked like at a given time,
  # rebuilt from its event stream.
  #
  #   Lyra.state_at(Order, 42, 3.days.ago)   # => { "id" => 42, "state" => "cart", ... } or nil
  #   Order.as_of(3.days.ago).find(42)       # => a read-only Order as it was then
  #   Order.as_of(3.days.ago).all            # => every Order that existed then
  #
  # The time of an event is when the event store stored it (precise to the
  # microsecond). A record's state at time t is its stream replayed up to and
  # including the last event stored at or before t: nil if it had no event
  # yet, or its last event by then destroyed it.
  #
  # Rows that predate Lyra start with an Imported event (Lyra::Genesis), which
  # holds the row as it was when imported. What happened to the row before
  # that was never recorded. Asking for an earlier time raises
  # HistoryNotRecorded instead of guessing, unless the row's own created_at
  # shows it did not exist yet (then the answer is nil). This works in every
  # mode that records events, Monitor included.
  module Temporal
    class HistoryNotRecorded < StandardError; end

    module_function

    # The record's attributes at +time+ (string keys), or nil if it did not
    # exist then. Raises HistoryNotRecorded for a time before an imported
    # record's recorded history begins.
    def state_at(model_class, id, time)
      events = Lyra.config.event_store.read.stream("#{model_class.name}$#{id}").to_a
      return nil if events.empty?

      time = time.to_time
      first = events.first
      if imported?(first) && event_time(first) > time
        created_at = attribute_time(first, "created_at")
        return nil if created_at && created_at > time

        raise HistoryNotRecorded,
              "#{model_class.name} #{id}: its history before #{event_time(first).iso8601(6)} " \
              "(when Lyra imported it) was not recorded"
      end

      replayed = events.take_while { |event| event_time(event) <= time }
      return nil if replayed.empty? || operation(replayed.last) == :destroyed

      state = Lyra::StateProjection.new.rebuild_from_events(replayed).transform_keys(&:to_s)
      state.merge("id" => id.to_s.match?(/\A\d+\z/) ? id.to_i : id)
    end

    def event_time(event)
      (event.timestamp || event.data[:timestamp] || event.data["timestamp"]).to_time
    end

    def operation(event)
      op = event.data[:operation] || event.data["operation"]
      op&.to_sym
    end

    def imported?(event)
      operation(event) == :imported
    end

    def attribute_time(event, name)
      attributes = event.data[:attributes] || event.data["attributes"] || {}
      value = attributes[name] || attributes[name.to_sym]
      return nil if value.blank?

      value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # Model.as_of(time): finders over the model as it was at +time+. Records
    # are read-only; they describe the past.
    class AsOf
      attr_reader :model_class, :time

      def initialize(model_class, time)
        @model_class = model_class
        @time = time
      end

      def find(id)
        attributes = Temporal.state_at(model_class, id, time)
        unless attributes
          raise ActiveRecord::RecordNotFound.new(
            "Couldn't find #{model_class.name} with '#{model_class.primary_key}'=#{id} as of #{time}",
            model_class, model_class.primary_key, id
          )
        end

        build(attributes)
      end

      def find_by_id(id)
        find(id)
      rescue ActiveRecord::RecordNotFound
        nil
      end

      # Every record that existed at +time+, in primary-key order. Raises
      # HistoryNotRecorded if any record's state then was not recorded.
      def all
        stream_ids.filter_map { |id| (attributes = Temporal.state_at(model_class, id, time)) && build(attributes) }
      end

      private

      def build(attributes)
        record = model_class.instantiate(attributes.slice(*model_class.column_names))
        record.readonly!
        record
      end

      def stream_ids
        connection = ActiveRecord::Base.connection
        prefix = "#{model_class.name}$"
        pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
        ids = connection.select_values("SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE #{pattern}")
                        .map { _1.delete_prefix(prefix) }
        ids.all? { _1.match?(/\A\d+\z/) } ? ids.sort_by(&:to_i) : ids.sort
      end
    end
  end

  # See Lyra::Temporal.state_at.
  def self.state_at(model_class, id, time)
    Temporal.state_at(model_class, id, time)
  end
end
