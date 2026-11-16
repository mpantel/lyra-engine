# frozen_string_literal: true

module PamDsl
  # Wording for a retention period given as a plain number of seconds
  # (keep_for 86_400, or an Integer read from configuration), in plain Ruby so
  # that it reads the same with and without ActiveSupport.
  #
  # Plain seconds carry no calendar, so they are worded with the fixed-length
  # units of the polyfill (core_ext.rb): 1 minute = 60 s, 1 hour = 3 600 s,
  # 1 day = 86 400 s, 1 month = 30 days, 1 year = 365 days, rounded down to the
  # largest whole unit: 86_400 is "1 day", 30 * 86_400 "1 month",
  # 365 * 86_400 "1 year". An ActiveSupport::Duration (1.day, 7.years) is not
  # plain seconds and keeps its calendar-aware wording in the reporter and the
  # comparator.
  module DurationFormat
    UNITS = [
      ["year", 365 * 86_400],
      ["month", 30 * 86_400],
      ["day", 86_400],
      ["hour", 3_600],
      ["minute", 60],
      ["second", 1]
    ].freeze

    module_function

    # True for an ActiveSupport::Duration. (A Duration answers is_a?(Integer)
    # for its value, so Numeric alone does not tell the two apart.)
    def duration?(value)
      defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration) ? true : false
    end

    # True for a plain number of seconds: a Numeric that is not a Duration.
    def seconds?(value)
      value.is_a?(Numeric) && !duration?(value)
    end

    # "1 day", "7 years", "1 hour", ... for a number of seconds.
    def seconds(value)
      secs = value.to_i
      unit, size = UNITS.find { |_, length| secs >= length } || UNITS.last
      count(secs / size, unit)
    end

    def count(n, unit) = "#{n} #{n == 1 ? unit : "#{unit}s"}"
  end
end
