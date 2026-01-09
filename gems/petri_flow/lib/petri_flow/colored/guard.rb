# frozen_string_literal: true

module PetriFlow
  module Colored
    # Represents a guard condition for colored Petri net transitions
    # Guards determine if a transition can fire based on token data
    class Guard
      attr_reader :name, :condition

      def initialize(name: nil, &condition)
        @name = name
        @condition = condition
      end

      # Evaluate the guard condition
      # @param context [Hash] Context including token data, event data, etc.
      # @return [Boolean] true if guard is satisfied
      def satisfied?(context = {})
        return true unless @condition

        @condition.call(context)
      end

      # Combine guards with AND logic
      def and(other_guard)
        Guard.new(name: "#{@name} AND #{other_guard.name}") do |context|
          satisfied?(context) && other_guard.satisfied?(context)
        end
      end

      # Combine guards with OR logic
      def or(other_guard)
        Guard.new(name: "#{@name} OR #{other_guard.name}") do |context|
          satisfied?(context) || other_guard.satisfied?(context)
        end
      end

      # Negate guard
      def not
        Guard.new(name: "NOT #{@name}") do |context|
          !satisfied?(context)
        end
      end

      def to_s
        "Guard(#{@name || 'anonymous'})"
      end

      def inspect
        "#<PetriFlow::Colored::Guard name=#{@name}>"
      end
    end

    # Common guard factories
    module Guards
      # Guard that checks if a field equals a value
      def self.field_equals(field, value)
        Guard.new(name: "#{field}==#{value}") do |context|
          context.dig(:token, :data, field) == value
        end
      end

      # Guard that checks if a field matches a pattern
      def self.field_matches(field, pattern)
        Guard.new(name: "#{field}=~/#{pattern}/") do |context|
          context.dig(:token, :data, field)&.match?(pattern)
        end
      end

      # Guard that checks if a condition is met
      def self.condition(name, &block)
        Guard.new(name: name, &block)
      end

      # Guard that always passes (true)
      def self.always_true
        Guard.new(name: "always_true") { |_| true }
      end

      # Guard that never passes (false)
      def self.always_false
        Guard.new(name: "always_false") { |_| false }
      end

      # Guard for privacy policy checks (PAM integration)
      def self.has_consent(purpose)
        Guard.new(name: "has_consent(#{purpose})") do |context|
          user_id = context.dig(:token, :data, :user_id)
          # In real implementation, check consent registry
          context[:consent_granted]&.include?([user_id, purpose])
        end
      end

      # Guard for retention policy checks
      def self.within_retention(model_class)
        Guard.new(name: "within_retention(#{model_class})") do |context|
          timestamp = context.dig(:token, :timestamp)
          retention_period = context.dig(:retention_policies, model_class) || 7.years
          timestamp && (Time.current - timestamp) < retention_period
        end
      end
    end
  end
end
