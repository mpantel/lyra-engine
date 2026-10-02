# frozen_string_literal: true

require "json"
require "bigdecimal"

module Lyra
  # JSON serializer for RailsEventStore that does not lose time precision.
  #
  # Passing Ruby's JSON module as the serializer (serializer: JSON) writes Time
  # values with Time#to_s, which drops the fractional seconds: a change from
  # 09:51:15.304 to 09:51:15.352 is stored as "09:51:15 UTC" -> "09:51:15 UTC",
  # an update that changed nothing. This serializer writes times as ISO 8601
  # with microseconds, the resolution of a PostgreSQL timestamp, so what the
  # event says is what the row holds. Everything else is encoded as JSON would
  # encode it; load is plain JSON.parse, so readers see the same string-keyed
  # hashes they saw with serializer: JSON.
  #
  #   RailsEventStore::Client.new(
  #     repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: Lyra::EventSerializer)
  #   )
  module EventSerializer
    TIME_PRECISION = 6

    module_function

    def dump(value)
      JSON.generate(prepare(value))
    end

    def load(string)
      JSON.parse(string)
    end

    def prepare(value)
      case value
      when Hash then value.to_h { |k, v| [k, prepare(v)] }
      when Array then value.map { |v| prepare(v) }
      when Time, DateTime then value.to_time.utc.iso8601(TIME_PRECISION)
      when ActiveSupport::TimeWithZone then value.utc.iso8601(TIME_PRECISION)
      when BigDecimal then value.to_s("F")
      else value
      end
    end
  end
end
