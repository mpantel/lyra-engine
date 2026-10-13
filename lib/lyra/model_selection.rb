# frozen_string_literal: true

module Lyra
  # Which models config.models enrols (Configuration#models=), resolved once
  # the application's code has loaded (Lyra::Engine, to_prepare):
  #
  #   config.models = %w[Order Payment]                     # by name
  #   config.models = { "Order" => { event_prefix: "Shop" } }  # with options
  #   config.models = %w[Spree::* Order]                    # a namespace pattern
  #   config.models = :all                                  # every eligible model
  #   config.models = :all, except: %w[Session Spree::LogEntry]
  #
  # A pattern, and :all, enrol only eligible models: concrete (not abstract),
  # named, with a table and a single-column primary key, and the base class
  # of a single-table-inheritance hierarchy (its subclasses follow it). Some
  # models are never enrolled, whatever is asked: the event store's own
  # tables (an event about an event would recurse), Lyra's, and those of the
  # Rails frameworks and gems that keep their own records (Solid Cache, Solid
  # Queue, Solid Cable, Active Storage, Action Text, Action Mailbox,
  # PaperTrail's versions). Naming one of those explicitly fails the boot; a
  # name that does not resolve fails it too.
  #
  # :all outside Monitor mode warns: Hijack and the event-sourcing modes then
  # route every write of every model through events, including models no one
  # has reviewed.
  module ModelSelection
    # Every enrolment request: all (true/false), the names and patterns asked
    # for with their options, and the names and patterns excepted.
    Spec = Struct.new(:all, :entries, :except, keyword_init: true)

    EXCLUDED_NAMESPACES = %w[
      Lyra:: RubyEventStore:: RailsEventStore:: ActiveRecord:: ActiveStorage:: ActionText::
      ActionMailbox:: SolidCache:: SolidQueue:: SolidCable:: PaperTrail::
    ].freeze
    EXCLUDED_TABLES = /\A(event_store_|lyra_|solid_cache_|solid_queue_|solid_cable_|active_storage_|action_text_|action_mailbox_)/

    class << self
      def parse(models)
        case models
        when :all, "all" then Spec.new(all: true, entries: {}, except: [])
        when Hash then Spec.new(all: false, entries: models.to_h { |n, o| [n.to_s, o || {}] }, except: [])
        else
          list = Array(models)
          options = list.last.is_a?(Hash) ? list.pop : {}
          all = list.delete(:all) || list.delete("all")
          except = Array(options[:except] || options["except"]).map(&:to_s)
          Spec.new(all: !all.nil?, entries: list.to_h { |n| [n.to_s, {}] }, except: except)
        end
      end

      # Enrol the models +spec+ selects; returns them.
      def apply(spec)
        return [] unless spec

        explicit, patterns = spec.entries.partition { |name, _| !pattern?(name) }
        chosen = explicit.to_h { |name, options| [resolve(name), options] }

        if spec.all || patterns.any?
          candidates = eligible_models
          candidates.each { |model| chosen[model] ||= {} } if spec.all
          patterns.each do |pattern, options|
            matched = candidates.select { |model| matches?(model.name, pattern) }
            warn_once("config.models pattern #{pattern.inspect} matches no model") if matched.empty?
            matched.each { |model| chosen[model] ||= options }
          end
        end

        chosen.reject! { |model, _| spec.except.any? { |name| matches?(model.name, name) } }
        warn_about_mode(chosen.size) if spec.all
        log(chosen.keys, spec)
        chosen.map do |model, options|
          model.monitor_with_lyra(options) unless model.respond_to?(:lyra_monitored) && model.lyra_monitored
          model
        end
      end

      # Whether Lyra may ever enrol +model+ (Lyra's own records, the event
      # store's and the frameworks' are excluded).
      def excluded?(model)
        name = model.name.to_s
        return true if EXCLUDED_NAMESPACES.any? { |prefix| name.start_with?(prefix) }

        table = model.respond_to?(:table_name) ? model.table_name.to_s : ""
        table.match?(EXCLUDED_TABLES)
      end

      # Concrete, named models with a table and a single-column primary key,
      # base classes only, not excluded.
      def eligible_models
        eager_load!
        ActiveRecord::Base.descendants.select { |model| eligible?(model) }.sort_by(&:name)
      end

      def eligible?(model)
        return false if model.abstract_class? || model.name.nil? || model.name.empty?
        return false unless model.base_class == model
        return false if excluded?(model)
        return false unless model.primary_key.is_a?(String)

        model.table_exists?
      rescue StandardError
        false # no database yet (assets:precompile), or a model that cannot reflect
      end

      private

      def resolve(name)
        model = begin
          name.constantize
        rescue NameError
          raise ArgumentError, "config.models names #{name.inspect}, which is not a loaded class"
        end
        if excluded?(model)
          raise ArgumentError, "config.models names #{name.inspect}, a model Lyra never enrols " \
                               "(the event store's, Lyra's own or a framework's records)"
        end
        model
      end

      def pattern?(name) = name.include?("*")

      # "Spree::*" matches every name under Spree::; "*" alone, any name.
      def matches?(name, pattern)
        return name == pattern unless pattern?(pattern)

        Regexp.new("\\A#{Regexp.escape(pattern).gsub('\\*', '.*')}\\z").match?(name)
      end

      def eager_load!
        return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        Rails.application.eager_load!
      end

      def warn_about_mode(count)
        return if Lyra.config.monitor_mode? || Lyra.disabled_mode?

        warn_once("config.models = :all enrols #{count} models in #{Lyra.config.mode} mode: every write of " \
                  "every one of them goes through events, including models no one has reviewed; " \
                  "consider an allowlist")
      end

      def log(models, spec)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        how = spec.all ? ":all" : "#{spec.entries.size} names/patterns"
        Rails.logger.info("Lyra: config.models (#{how}) enrols #{models.size} models: #{models.map(&:name).join(', ')}")
      end

      def warn_once(message)
        @warned ||= {}
        return if @warned[message]

        @warned[message] = true
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        logger ? logger.warn("Lyra: #{message}") : Kernel.warn("Lyra: #{message}")
      end
    end
  end
end
