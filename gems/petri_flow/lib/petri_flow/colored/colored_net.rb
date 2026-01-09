# frozen_string_literal: true

module PetriFlow
  module Colored
    # Represents a Colored Petri Net (CPN)
    # Extends basic Petri net with colored tokens, guards, and arc expressions
    class ColoredNet < Core::Net
      attr_reader :colors, :colored_places, :token_pools

      def initialize(name: "ColoredPetriNet")
        super(name: name)
        @colors = {}
        @colored_places = {}
        @token_pools = Hash.new { |h, k| h[k] = [] }
      end

      # Register a color (token type)
      def add_color(name, attributes: {}, validator: nil)
        color = Color.new(name: name, attributes: attributes, validator: validator)
        @colors[name] = color
        color
      end

      # Add a colored place
      def add_colored_place(id:, name: nil, color: nil, initial_tokens: [])
        place = add_place(id: id, name: name, initial_tokens: 0)
        @colored_places[id] = {
          color: color,
          tokens: initial_tokens
        }
        @token_pools[id] = initial_tokens.dup
        place
      end

      # Add a colored transition with guard
      def add_colored_transition(id:, name: nil, guard: nil)
        guard_obj = case guard
                    when Guard
                      guard
                    when Proc
                      Guard.new(&guard)
                    else
                      nil
                    end

        add_transition(id: id, name: name, guard: guard_obj)
      end

      # Add an arc with expression
      def add_colored_arc(source_id:, target_id:, weight: 1, expression: nil)
        expr_obj = case expression
                   when ArcExpression
                     expression
                   when Proc
                     ArcExpression.new(&expression)
                   else
                     nil
                   end

        add_arc(
          source_id: source_id,
          target_id: target_id,
          weight: weight,
          expression: expr_obj
        )
      end

      # Get tokens from a colored place
      def tokens_at_place(place_id)
        @token_pools[place_id] || []
      end

      # Add a token to a colored place
      def add_token_to_place(place_id, token)
        raise "Place #{place_id} not found" unless @places[place_id]

        @token_pools[place_id] << token
        @places[place_id].add_tokens(1)
      end

      # Remove a token from a colored place
      def remove_token_from_place(place_id, token = nil)
        raise "Place #{place_id} not found" unless @places[place_id]

        token_to_remove = token || @token_pools[place_id].first
        @token_pools[place_id].delete(token_to_remove)
        @places[place_id].remove_tokens(1)
        token_to_remove
      end

      # Fire a colored transition
      def fire_colored_transition(transition_id, token_bindings = {}, context = {})
        transition = @transitions[transition_id]
        raise "Transition #{transition_id} not found" unless transition

        # Check guard with token data
        guard_context = context.merge(tokens: token_bindings)
        return false unless transition.enabled?(guard_context)

        # Process input arcs (consume tokens with expressions)
        input_tokens = {}
        transition.input_arcs.each do |arc|
          token = remove_token_from_place(arc.source.id, token_bindings[arc.source.id])
          input_tokens[arc.source.id] = token
        end

        # Process output arcs (produce tokens with expressions)
        transition.output_arcs.each do |arc|
          # Get token data from corresponding input
          input_token = input_tokens.values.first
          output_data = if arc.expression
                         arc.expression.execute(input_token&.data || {}, context)
                       else
                         input_token&.data || {}
                       end

          output_token = Core::Token.new(
            color: @colored_places.dig(arc.target.id, :color) || :default,
            data: output_data
          )

          add_token_to_place(arc.target.id, output_token)
        end

        true
      end

      # Get colored marking (with token data)
      def colored_marking
        marking = {}
        @token_pools.each do |place_id, tokens|
          marking[place_id] = tokens.map(&:to_h)
        end
        marking
      end

      def to_s
        "ColoredNet(#{@name}, P=#{@places.size}, T=#{@transitions.size}, Colors=#{@colors.size})"
      end

      def inspect
        "#<PetriFlow::Colored::ColoredNet name=#{@name} colors=#{@colors.keys} #{stats}>"
      end
    end
  end
end
