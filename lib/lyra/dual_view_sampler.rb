# frozen_string_literal: true

module Lyra
  # Sampled DualView verification in production: after a write commits, with
  # probability config.dual_view_sample_rate, compare the record's row with
  # the state replayed from its events.
  #
  # It never fails or delays the write: it runs after commit, logs a
  # discrepancy, and passes it to config.dual_view_discrepancy_handler (an
  # alert, a metric). Off by default (rate 0.0), as it costs a stream read
  # and a replay per sampled write; the thesis suggests 1-5% of operations.
  #
  # Skipped in modes whose tables lag the log by design (ES-NoProj, ES-Lazy,
  # ES-Async), where a difference right after a write is expected.
  module DualViewSampler
    module_function

    def after_commit(record)
      rate = Lyra.config.dual_view_sample_rate.to_f
      return unless rate.positive?
      return if Lyra::ModeTransition::LAGGING.include?(Lyra::ModeTransition.current)
      return unless rand < rate

      discrepancy = Lyra::ModeTransition.send(:compare, record.class, record.id.to_s)
      return unless discrepancy

      Rails.logger.warn("Lyra DualView sample: #{discrepancy}")
      Lyra.config.dual_view_discrepancy_handler&.call(discrepancy)
    rescue StandardError => e
      Rails.logger.error("Lyra DualView sample failed - #{e.message}")
    end
  end
end
