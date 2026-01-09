# frozen_string_literal: true

require 'yaml'

module PetriFlow
  module Export
    # Exports Petri nets and Colored Petri Nets to YAML format
    # Provides the most human-readable format, ideal for configuration and documentation
    class YamlExporter
      attr_reader :net

      def initialize(net)
        @net = net
      end

      # Export to YAML string
      # @return [String] YAML representation of the net
      def to_yaml
        to_hash.to_yaml
      end

      # Export to Ruby hash
      # @return [Hash] Hash representation of the net
      def to_hash
        {
          'meta' => meta_info,
          'net' => net_structure,
          'colors' => color_definitions,
          'places' => places_data,
          'transitions' => transitions_data,
          'arcs' => arcs_data,
          'marking' => current_marking,
          'statistics' => statistics
        }
      end

      # Save to YAML file
      def save_yaml(filename)
        File.write(filename, to_yaml)
      end

      private

      def colored_net?
        @net.is_a?(PetriFlow::Colored::ColoredNet)
      end

      def meta_info
        {
          'format' => 'PetriFlow YAML Export',
          'version' => '1.0',
          'exported_at' => Time.now.utc.iso8601,
          'net_type' => colored_net? ? 'colored_petri_net' : 'petri_net'
        }
      end

      def net_structure
        {
          'name' => @net.name,
          'type' => colored_net? ? 'ColoredPetriNet' : 'PetriNet',
          'place_count' => @net.places.size,
          'transition_count' => @net.transitions.size,
          'arc_count' => @net.arcs.size
        }
      end

      def color_definitions
        return [] unless colored_net?

        @net.colors.map do |color_name, color|
          {
            'name' => color_name.to_s,
            'attributes' => format_attributes(color.attributes),
            'has_validator' => !color.validator.nil?
          }
        end
      end

      def format_attributes(attributes)
        attributes.transform_keys(&:to_s).transform_values do |v|
          v.is_a?(Symbol) ? v.to_s : v
        end
      end

      def places_data
        @net.places.map do |place_id, place|
          place_hash = {
            'id' => place_id.to_s,
            'name' => place.name,
            'tokens' => place.tokens,
            'capacity' => place.capacity == Float::INFINITY ? 'infinite' : place.capacity
          }

          # Add colored net place info
          if colored_net? && @net.colored_places[place_id]
            colored_info = @net.colored_places[place_id]
            place_hash['color'] = colored_info[:color].to_s if colored_info[:color]

            colored_tokens = format_colored_tokens(place_id)
            place_hash['colored_tokens'] = colored_tokens if colored_tokens.any?
          end

          place_hash
        end
      end

      def format_colored_tokens(place_id)
        return [] unless colored_net?

        tokens = @net.token_pools[place_id] || []
        tokens.map do |token|
          token_hash = {
            'id' => token.id,
            'color' => token.color.to_s
          }

          token_hash['data'] = stringify_hash(token.data) if token.data.any?
          token_hash['timestamp'] = token.timestamp if token.timestamp

          token_hash
        end
      end

      def stringify_hash(hash)
        hash.transform_keys(&:to_s).transform_values do |v|
          case v
          when Symbol
            v.to_s
          when Hash
            stringify_hash(v)
          when Array
            v.map { |item| item.is_a?(Hash) ? stringify_hash(item) : item }
          else
            v
          end
        end
      end

      def transitions_data
        @net.transitions.map do |trans_id, transition|
          trans_hash = {
            'id' => trans_id.to_s,
            'name' => transition.name,
            'input_arcs' => transition.input_arcs.size,
            'output_arcs' => transition.output_arcs.size,
            'enabled' => transition.enabled?
          }

          # Add guard info
          if transition.guard
            trans_hash['guard'] = format_guard(transition.guard)
          end

          trans_hash
        end
      end

      def format_guard(guard)
        if guard.respond_to?(:name) && guard.name
          {
            'type' => 'named_guard',
            'name' => guard.name,
            'description' => guard.name
          }
        elsif guard.respond_to?(:condition)
          {
            'type' => 'guard',
            'description' => 'Custom guard condition'
          }
        else
          {
            'type' => 'proc',
            'description' => 'Lambda/Proc guard'
          }
        end
      end

      def arcs_data
        @net.arcs.map.with_index do |arc, index|
          arc_hash = {
            'id' => "arc_#{index}",
            'source' => {
              'id' => arc.source.id.to_s,
              'name' => arc.source.name,
              'type' => arc.source.class.name.split('::').last
            },
            'target' => {
              'id' => arc.target.id.to_s,
              'name' => arc.target.name,
              'type' => arc.target.class.name.split('::').last
            },
            'weight' => arc.weight,
            'direction' => arc.input_arc? ? 'place_to_transition' : 'transition_to_place'
          }

          # Add arc expression info
          if arc.expression
            arc_hash['expression'] = format_expression(arc.expression)
          end

          arc_hash
        end
      end

      def format_expression(expression)
        if expression.respond_to?(:name) && expression.name
          {
            'type' => 'named_expression',
            'name' => expression.name,
            'description' => expression.name
          }
        elsif expression.respond_to?(:transformation)
          {
            'type' => 'arc_expression',
            'description' => 'Custom arc expression'
          }
        else
          {
            'type' => 'proc',
            'description' => 'Lambda/Proc expression'
          }
        end
      end

      def current_marking
        marking_hash = {
          'tokens_by_place' => stringify_hash(@net.places.transform_values(&:tokens)),
          'total_tokens' => @net.places.values.sum(&:tokens)
        }

        if colored_net?
          marking_hash['colored_marking'] = stringify_hash(@net.colored_marking)
        end

        marking_hash
      end

      def statistics
        stringify_hash(@net.stats.merge({
          enabled_transitions_list: @net.enabled_transitions.map { |t| t.id.to_s },
          deadlocked: @net.deadlocked?
        }))
      end
    end
  end
end
