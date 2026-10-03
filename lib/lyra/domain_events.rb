# frozen_string_literal: true

module Lyra
  # Domain events: name a write after what it means for the business, not
  # after the CRUD operation that recorded it.
  #
  #   monitor_with_lyra domain_events: [
  #     { name: "PaymentCompleted", on: %i[create update],
  #       if: ->(payment, changes) { payment.status_success? && changes.key?("status") },
  #       payload: ->(payment, _changes) { { amount: payment.amount } } },
  #     { name: "PaymentFailed", on: %i[create update],
  #       if: ->(payment) { payment.status.in?(%w[failure error cancelled]) } },
  #     { class: ReceiptDue, on: :update, if: ->(p, c) { c.key?("status") }, also: true }
  #   ]
  #
  # Rules are checked in order against each write that goes through the
  # model's callbacks (Monitor, Hijack, event sourcing):
  #
  # - The first matching rule names the write's own event: it is stored as
  #   PaymentCompleted instead of PaymentTransactionUpdated, with the same
  #   envelope (model, id, operation, attributes, changes), so replay,
  #   projections, DualView and Lyra.state_at work unchanged. A write no rule
  #   matches keeps its CRUD event.
  # - payload: adds fields the consumers of the event need under
  #   data[:payload] (the block gets the record and its changes).
  # - class: uses an event class of your own (a subclass of Lyra::Event, or
  #   any RubyEventStore::Event) instead of a generated
  #   Lyra::Events::<name>. Give name:, class:, or both.
  # - also: true makes a rule emit an additional event alongside the write's
  #   own, in the same stream and transaction: several domain events from one
  #   write. Additional events are marked replay: false (the write is replayed
  #   once, from its own event) and carry the own event's id as their
  #   causation_id. They do not stop the search for the rule that names the
  #   write's own event.
  #
  # if: and payload: receive (record, changes), where changes maps each
  # changed attribute to [old, new]; a one-argument block gets the record
  # only. If a block raises, the write fails in Hijack and the event-sourcing
  # modes (its event could not be built) and the event is lost with a log
  # line in Monitor, as for any failed publish.
  #
  # Writes that skip callbacks (update_all, delete_all, insert_all, ...) are
  # recorded as CRUD bypass events: there is no record instance to evaluate
  # rules against.
  module DomainEvents
    OPERATIONS = {
      create: :create, created: :create,
      update: :update, updated: :update,
      destroy: :destroy, destroyed: :destroy
    }.freeze

    Rule = Struct.new(:name, :event_class, :operations, :condition, :payload, :also, keyword_init: true) do
      def applies?(operation, record, changes)
        return false unless operations.include?(OPERATIONS.fetch(operation.to_sym))
        return true unless condition

        DomainEvents.call_block(condition, record, changes) ? true : false
      end
    end

    class << self
      # Parse a model's domain_events option into Rules.
      def rules(definitions)
        Array(definitions).map { |definition| rule(definition) }
      end

      def rule(definition)
        definition = definition.to_h.transform_keys(&:to_sym)
        unknown = definition.keys - %i[name class on if payload also]
        raise ArgumentError, "Unknown domain event option(s): #{unknown.join(', ')}" if unknown.any?

        klass = definition[:class]
        name = (definition[:name] || klass&.name&.demodulize).to_s
        raise ArgumentError, "A domain event needs name: or class:" if name.empty?
        if klass && !(klass.is_a?(Class) && klass <= RubyEventStore::Event)
          raise ArgumentError, "class: for #{name} must be a RubyEventStore::Event subclass"
        end

        operations = Array(definition.fetch(:on) { %i[create update destroy] }).map do |op|
          OPERATIONS.fetch(op.to_sym) { raise ArgumentError, "on: #{op.inspect} for #{name} is not create, update or destroy" }
        end

        Rule.new(name: name, event_class: klass, operations: operations.uniq,
                 condition: definition[:if], payload: definition[:payload], also: definition[:also] ? true : false)
      end

      # The events to store for one write: its own event first (renamed by
      # the first matching rule, if any), then one per matching also: rule.
      #
      # @param default_class [Class] the CRUD event class for the operation
      # @param data [Hash] the event envelope; metadata [Hash] its metadata
      def build(model_class, operation, data:, metadata:, default_class:, record:, changes:)
        rules = rules_for(model_class)
        return [default_class.new(data: data, metadata: metadata)] if rules.empty? || record.nil?

        changes = normalize_changes(changes)
        matching = rules.select { |rule| rule.applies?(operation, record, changes) }
        own_rule = matching.find { |rule| !rule.also }

        own = event_class_for(own_rule, default_class).new(
          data: with_payload(data, own_rule, record, changes), metadata: metadata
        )
        extras = matching.select(&:also).map do |rule|
          event_class_for(rule, nil).new(
            data: with_payload(data, rule, record, changes).merge(replay: false),
            metadata: metadata.merge(causation_id: own.event_id)
          )
        end
        [own, *extras]
      end

      def rules_for(model_class)
        config = model_class.respond_to?(:lyra_config) && model_class.lyra_config
        config ||= Lyra.config.model_config(model_class)
        config.respond_to?(:domain_events) ? config.domain_events : []
      end

      # Every generated event name the model's rules use (for registering the
      # classes at boot, so stored events deserialize after a restart).
      def generated_names(model_class)
        rules_for(model_class).reject(&:event_class).map(&:name)
      end

      def call_block(block, record, changes)
        block.arity == 1 ? block.call(record) : block.call(record, changes)
      end

      private

      def event_class_for(rule, default_class)
        return default_class unless rule
        return rule.event_class if rule.event_class

        name = rule.name.gsub("::", "")
        return Lyra::Events.const_get(name, false) if Lyra::Events.const_defined?(name, false)

        Lyra::Events.const_set(name, Class.new(Lyra::Event))
      end

      def with_payload(data, rule, record, changes)
        return data unless rule&.payload

        payload = call_block(rule.payload, record, changes)
        raise ArgumentError, "payload: for #{rule.name} must return a Hash" unless payload.is_a?(Hash)

        data.merge(payload: payload)
      end

      # { "attribute" => [old, new] } whatever form the changes came in.
      def normalize_changes(changes)
        (changes || {}).to_h.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value.is_a?(Array) ? value : [nil, value]
        end
      end
    end
  end
end
