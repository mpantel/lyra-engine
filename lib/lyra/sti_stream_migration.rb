# frozen_string_literal: true

module Lyra
  # One-time step for event stores written before a record's stream was named
  # after its table's class (Lyra.stream_name): under single-table inheritance
  # those wrote a record's events to its concrete class's stream
  # (Spree::Calculator::Shipping::FlatRate$1), which readers now never look
  # at. This links each such stream's events into the base class's stream
  # (Spree::Calculator$1), in their order. Linking adds stream references; no
  # event is copied, changed or deleted, and running it again links nothing.
  #
  # A base stream that already holds events (written since the upgrade) is
  # left alone and reported: linking the older events after them would put
  # the record's history out of order. Run it before writing in a Lyra mode
  # after the upgrade (lyra:streams:migrate_sti).
  module StiStreamMigration
    class << self
      # Returns { streams:, linked:, already:, conflicts: [old stream names] }.
      def run!(models: Lyra.config.monitored_models, store: Lyra.config.event_store, dry_run: false)
        result = { streams: 0, linked: 0, already: 0, conflicts: [] }
        bases(models).each do |base|
          base.descendants.each do |subclass|
            subclass_streams(subclass).each { |old| migrate(old, subclass, base, store, dry_run, result) }
          end
        end
        result
      end

      private

      def bases(models)
        models.filter_map { |model| model.respond_to?(:base_class) ? model.base_class : nil }.uniq
      end

      # Record streams named after +subclass+ ("Sub$<id>", not a reference
      # stream such as "Sub.foreign_key$<value>").
      def subclass_streams(subclass)
        connection = ActiveRecord::Base.connection
        prefix = "#{subclass.name}$"
        pattern = connection.quote("#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
        connection.select_values("SELECT DISTINCT stream FROM event_store_events_in_streams WHERE stream LIKE #{pattern}")
                  .reject { |stream| stream.delete_prefix(prefix).include?("$") }
      end

      def migrate(old, subclass, base, store, dry_run, result)
        result[:streams] += 1
        id = old.delete_prefix("#{subclass.name}$")
        target = Lyra.stream_name(base, id)
        old_ids = read(store, old).map(&:event_id)
        present = read(store, target).map(&:event_id)

        if (old_ids - present).empty?
          result[:already] += 1
        elsif present.any?
          result[:conflicts] << old
        else
          store.link(old_ids, stream_name: target) unless dry_run
          result[:linked] += old_ids.size
        end
      end

      def read(store, stream)
        store.read.stream(stream).to_a
      rescue RubyEventStore::EventNotFoundInStream
        []
      end
    end
  end
end
