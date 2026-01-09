# frozen_string_literal: true

require "test_helper"

module PetriFlow
  module Colored
    class ColoredNetTest < Minitest::Test
      def setup
        @net = ColoredNet.new(name: "TestColoredNet")
      end

      # ===========================================
      # Initialization Tests
      # ===========================================

      def test_initialization
        assert_equal "TestColoredNet", @net.name
        assert_empty @net.colors
        assert_empty @net.colored_places
        assert_kind_of Hash, @net.token_pools
      end

      def test_initialization_default_name
        net = ColoredNet.new

        assert_equal "ColoredPetriNet", net.name
      end

      def test_inherits_from_net
        assert_kind_of Core::Net, @net
      end

      # ===========================================
      # Add Color Tests
      # ===========================================

      def test_add_color
        color = @net.add_color(:order, attributes: { id: :integer, status: :string })

        assert_instance_of Color, color
        assert_equal :order, color.name
        assert @net.colors.key?(:order)
      end

      def test_add_color_with_validator
        validator = ->(data) { data[:amount] > 0 }
        color = @net.add_color(:payment, validator: validator)

        assert color.valid?({ amount: 100 })
        refute color.valid?({ amount: -1 })
      end

      def test_add_multiple_colors
        @net.add_color(:order)
        @net.add_color(:payment)
        @net.add_color(:user)

        assert_equal 3, @net.colors.size
      end

      # ===========================================
      # Add Colored Place Tests
      # ===========================================

      def test_add_colored_place
        @net.add_color(:order)
        place = @net.add_colored_place(id: :pending_orders, color: :order)

        assert @net.places.key?(:pending_orders)
        assert @net.colored_places.key?(:pending_orders)
        assert_equal :order, @net.colored_places[:pending_orders][:color]
      end

      def test_add_colored_place_with_initial_tokens
        @net.add_color(:item)
        token1 = Core::Token.new(color: :item, data: { id: 1 })
        token2 = Core::Token.new(color: :item, data: { id: 2 })

        @net.add_colored_place(id: :items, color: :item, initial_tokens: [token1, token2])

        assert_equal 2, @net.tokens_at_place(:items).size
      end

      # ===========================================
      # Add Colored Transition Tests
      # ===========================================

      def test_add_colored_transition
        @net.add_colored_transition(id: :process, name: "Process Order")

        assert @net.transitions.key?(:process)
      end

      def test_add_colored_transition_with_guard_proc
        @net.add_colored_transition(
          id: :approve,
          guard: ->(ctx) { ctx.dig(:tokens, :amount).to_i >= 100 }
        )

        transition = @net.transition(:approve)
        refute_nil transition.guard
      end

      def test_add_colored_transition_with_guard_object
        guard = Guard.new(name: "check_amount") { |ctx| ctx[:value] > 0 }
        @net.add_colored_transition(id: :validate, guard: guard)

        transition = @net.transition(:validate)
        assert_equal guard, transition.guard
      end

      # ===========================================
      # Add Colored Arc Tests
      # ===========================================

      def test_add_colored_arc
        @net.add_colored_place(id: :p1)
        @net.add_colored_transition(id: :t1)

        @net.add_colored_arc(source_id: :p1, target_id: :t1)

        assert_equal 1, @net.arcs.size
      end

      def test_add_colored_arc_with_expression_proc
        @net.add_colored_place(id: :p1)
        @net.add_colored_transition(id: :t1)

        @net.add_colored_arc(
          source_id: :p1,
          target_id: :t1,
          expression: ->(data, _ctx) { data.merge(processed: true) }
        )

        arc = @net.arcs.first
        assert_instance_of ArcExpression, arc.expression
      end

      def test_add_colored_arc_with_expression_object
        @net.add_colored_place(id: :p1)
        @net.add_colored_transition(id: :t1)

        expr = ArcExpression.new(name: "add_flag") { |d, _| d.merge(flag: true) }
        @net.add_colored_arc(source_id: :p1, target_id: :t1, expression: expr)

        arc = @net.arcs.first
        assert_equal expr, arc.expression
      end

      # ===========================================
      # Token Operations Tests
      # ===========================================

      def test_tokens_at_place
        @net.add_colored_place(id: :orders)
        token = Core::Token.new(color: :order, data: { id: 1 })
        @net.add_token_to_place(:orders, token)

        tokens = @net.tokens_at_place(:orders)

        assert_equal 1, tokens.size
        assert_equal token, tokens.first
      end

      def test_tokens_at_place_returns_empty_for_unknown
        tokens = @net.tokens_at_place(:unknown)

        assert_empty tokens
      end

      def test_add_token_to_place
        @net.add_colored_place(id: :queue)
        token = Core::Token.new(color: :task, data: { name: "task1" })

        @net.add_token_to_place(:queue, token)

        assert_equal 1, @net.tokens_at_place(:queue).size
        assert_equal 1, @net.place(:queue).tokens
      end

      def test_add_token_to_place_raises_for_unknown_place
        token = Core::Token.new(data: {})

        assert_raises(RuntimeError) do
          @net.add_token_to_place(:nonexistent, token)
        end
      end

      def test_remove_token_from_place
        @net.add_colored_place(id: :items)
        token = Core::Token.new(color: :item, data: { id: 1 })
        @net.add_token_to_place(:items, token)

        removed = @net.remove_token_from_place(:items, token)

        assert_equal token, removed
        assert_empty @net.tokens_at_place(:items)
        assert_equal 0, @net.place(:items).tokens
      end

      def test_remove_token_from_place_removes_first_if_not_specified
        @net.add_colored_place(id: :queue)
        token1 = Core::Token.new(data: { id: 1 })
        token2 = Core::Token.new(data: { id: 2 })
        @net.add_token_to_place(:queue, token1)
        @net.add_token_to_place(:queue, token2)

        removed = @net.remove_token_from_place(:queue)

        assert_equal token1, removed
        assert_equal 1, @net.tokens_at_place(:queue).size
      end

      def test_remove_token_from_place_raises_for_unknown_place
        assert_raises(RuntimeError) do
          @net.remove_token_from_place(:nonexistent)
        end
      end

      # ===========================================
      # Fire Colored Transition Tests
      # ===========================================

      def test_fire_colored_transition
        # Setup: p1 -> t1 -> p2
        @net.add_colored_place(id: :input)
        @net.add_colored_place(id: :output)
        @net.add_colored_transition(id: :process)
        @net.add_colored_arc(source_id: :input, target_id: :process)
        @net.add_colored_arc(source_id: :process, target_id: :output)

        token = Core::Token.new(data: { value: 42 })
        @net.add_token_to_place(:input, token)

        result = @net.fire_colored_transition(:process)

        assert result
        assert_empty @net.tokens_at_place(:input)
        assert_equal 1, @net.tokens_at_place(:output).size
      end

      def test_fire_colored_transition_with_guard
        @net.add_colored_place(id: :input)
        @net.add_colored_place(id: :output)
        @net.add_colored_transition(
          id: :validate,
          guard: ->(ctx) {
            # Access token data: ctx[:tokens][:input] is a Token object
            token = ctx.dig(:tokens, :input)
            token&.data&.dig(:amount).to_i >= 100
          }
        )
        @net.add_colored_arc(source_id: :input, target_id: :validate)
        @net.add_colored_arc(source_id: :validate, target_id: :output)

        token = Core::Token.new(data: { amount: 50 })
        @net.add_token_to_place(:input, token)

        # Guard should fail (amount 50 < 100)
        result = @net.fire_colored_transition(:validate, { input: token })

        refute result
        assert_equal 1, @net.tokens_at_place(:input).size
      end

      def test_fire_colored_transition_raises_for_unknown
        assert_raises(RuntimeError) do
          @net.fire_colored_transition(:nonexistent)
        end
      end

      # ===========================================
      # Colored Marking Tests
      # ===========================================

      def test_colored_marking
        @net.add_colored_place(id: :p1)
        @net.add_colored_place(id: :p2)

        token1 = Core::Token.new(data: { id: 1 })
        token2 = Core::Token.new(data: { id: 2 })
        @net.add_token_to_place(:p1, token1)
        @net.add_token_to_place(:p2, token2)

        marking = @net.colored_marking

        assert marking.key?(:p1)
        assert marking.key?(:p2)
        assert_equal 1, marking[:p1].size
        assert_equal 1, marking[:p2].size
      end

      # ===========================================
      # String Representation Tests
      # ===========================================

      def test_to_s
        @net.add_color(:order)
        @net.add_colored_place(id: :p1)
        @net.add_colored_transition(id: :t1)

        output = @net.to_s

        assert_includes output, "ColoredNet"
        assert_includes output, "TestColoredNet"
        assert_includes output, "P=1"
        assert_includes output, "T=1"
        assert_includes output, "Colors=1"
      end

      def test_inspect
        @net.add_color(:order)

        output = @net.inspect

        assert_includes output, "PetriFlow::Colored::ColoredNet"
        assert_includes output, "colors="
      end
    end
  end
end
