# frozen_string_literal: true

module PetriFlow
  module Colored
    # Represents an arc expression for colored Petri nets
    # Arc expressions transform token data as it passes through the arc
    class ArcExpression
      attr_reader :name, :transformation

      def initialize(name: nil, &transformation)
        @name = name
        @transformation = transformation
      end

      # Execute the arc expression on token data
      # @param token_data [Hash] The token's data
      # @param context [Hash] Additional context (metadata, state, etc.)
      # @return [Hash] Transformed token data
      def execute(token_data, context = {})
        return token_data unless @transformation

        @transformation.call(token_data, context)
      end

      # Compose arc expressions (chain transformations)
      def then(other_expression)
        ArcExpression.new(name: "#{@name} then #{other_expression.name}") do |data, context|
          intermediate = execute(data, context)
          other_expression.execute(intermediate, context)
        end
      end

      def to_s
        "ArcExpression(#{@name || 'anonymous'})"
      end

      def inspect
        "#<PetriFlow::Colored::ArcExpression name=#{@name}>"
      end
    end

    # Common arc expression factories
    module ArcExpressions
      # Identity expression (pass-through)
      def self.identity
        ArcExpression.new(name: "identity") { |data, _| data }
      end

      # Map specific fields
      def self.map_fields(field_mappings)
        ArcExpression.new(name: "map_fields") do |data, _|
          result = data.dup
          field_mappings.each do |old_field, new_field|
            result[new_field] = result.delete(old_field) if result.key?(old_field)
          end
          result
        end
      end

      # Add metadata
      def self.add_metadata(metadata)
        ArcExpression.new(name: "add_metadata") do |data, _|
          data.merge(metadata: metadata)
        end
      end

      # Transform CRUD to Event (for Lyra integration)
      def self.crud_to_event(operation)
        ArcExpression.new(name: "crud_to_event(#{operation})") do |data, context|
          {
            event_type: "#{data[:model_class]}#{operation.to_s.capitalize}",
            event_id: SecureRandom.uuid,
            data: data[:attributes] || {},
            changes: data[:changes] || {},
            metadata: {
              correlation_id: data[:correlation_id],
              action_id: data[:action_id],
              user_id: data[:user_id],
              timestamp: Time.current
            }
          }
        end
      end

      # Detect PII in data
      def self.detect_pii(pii_detector = nil)
        ArcExpression.new(name: "detect_pii") do |data, context|
          pii_detected = if pii_detector
                          pii_detector.call(data)
                        else
                          # Simple pattern-based detection
                          detect_pii_patterns(data)
                        end

          data.merge(pii_detected: pii_detected)
        end
      end

      # Apply privacy policy transformations
      def self.apply_privacy_policy(policy)
        ArcExpression.new(name: "apply_policy(#{policy})") do |data, context|
          # Mask sensitive fields based on policy
          masked_data = data.dup
          policy_rules = context.dig(:policies, policy) || {}

          policy_rules.each do |field, rule|
            if masked_data[field] && rule[:mask]
              masked_data[field] = mask_value(masked_data[field], rule[:mask])
            end
          end

          masked_data
        end
      end

      # Extract specific fields
      def self.extract_fields(*fields)
        ArcExpression.new(name: "extract_fields(#{fields.join(',')})") do |data, _|
          data.slice(*fields)
        end
      end

      # Merge with context data
      def self.merge_context(*keys)
        ArcExpression.new(name: "merge_context") do |data, context|
          additional_data = keys.each_with_object({}) do |key, hash|
            hash[key] = context[key] if context.key?(key)
          end
          data.merge(additional_data)
        end
      end

      private

      def self.detect_pii_patterns(data)
        pii = {}
        data.each do |key, value|
          next unless value.is_a?(String)

          pii[key] = :email if key.to_s.match?(/email/i) || value.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
          pii[key] = :phone if key.to_s.match?(/phone/i) || value.match?(/\A\d{10,}\z/)
          pii[key] = :ssn if key.to_s.match?(/ssn|social/i)
          pii[key] = :credit_card if value.match?(/\A\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\z/)
        end
        pii
      end

      def self.mask_value(value, mask_type)
        case mask_type
        when :full
          "***MASKED***"
        when :partial
          return value if value.length < 4
          value[0..1] + "*" * (value.length - 4) + value[-2..-1]
        when :hash
          Digest::SHA256.hexdigest(value.to_s)[0..15]
        else
          value
        end
      end
    end
  end
end
