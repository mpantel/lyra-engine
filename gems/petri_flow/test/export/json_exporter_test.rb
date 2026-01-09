# frozen_string_literal: true

require "test_helper"
require "json"

module PetriFlow
  module Export
    class JsonExporterTest < Minitest::Test
      def setup
        @net = create_test_net
        @colored_net = create_colored_net
        @exporter = JsonExporter.new(@net)
        @colored_exporter = JsonExporter.new(@colored_net)
      end

      def create_test_net
        net = Core::Net.new(name: "TestNet")
        net.add_place(id: :p1, name: "Input", initial_tokens: 2)
        net.add_place(id: :p2, name: "Output", initial_tokens: 0)
        net.add_transition(id: :t1, name: "Process")
        net.add_arc(source_id: :p1, target_id: :t1)
        net.add_arc(source_id: :t1, target_id: :p2)
        net
      end

      def create_colored_net
        net = Colored::ColoredNet.new(name: "ColoredTestNet")
        net.add_color(:order, attributes: { id: :integer, status: :string })
        net.add_colored_place(id: :orders, name: "Orders", color: :order)
        net.add_colored_place(id: :processed, name: "Processed", color: :order)

        guard = Colored::Guard.new(name: "check_status") { |ctx| true }
        net.add_colored_transition(id: :process, name: "Process Order", guard: guard)

        expr = Colored::ArcExpression.new(name: "transform") { |d, _| d }
        net.add_colored_arc(source_id: :orders, target_id: :process, expression: expr)
        net.add_colored_arc(source_id: :process, target_id: :processed)

        # Add a token
        token = Core::Token.new(color: :order, data: { id: 1, status: "pending" })
        net.add_token_to_place(:orders, token)

        net
      end

      # ===========================================
      # to_json Tests
      # ===========================================

      def test_to_json_returns_string
        result = @exporter.to_json

        assert_kind_of String, result
      end

      def test_to_json_is_valid_json
        result = @exporter.to_json

        parsed = JSON.parse(result)
        assert_kind_of Hash, parsed
      end

      def test_to_json_pretty_includes_newlines
        result = @exporter.to_json(pretty: true)

        assert_includes result, "\n"
      end

      def test_to_json_not_pretty_is_compact
        result = @exporter.to_json(pretty: false)

        refute_includes result, "\n  "
      end

      # ===========================================
      # to_hash Structure Tests
      # ===========================================

      def test_to_hash_has_required_keys
        hash = @exporter.to_hash

        assert hash.key?(:meta)
        assert hash.key?(:net)
        assert hash.key?(:colors)
        assert hash.key?(:places)
        assert hash.key?(:transitions)
        assert hash.key?(:arcs)
        assert hash.key?(:marking)
        assert hash.key?(:statistics)
      end

      # ===========================================
      # Meta Info Tests
      # ===========================================

      def test_meta_info_format
        hash = @exporter.to_hash

        assert_equal "PetriFlow JSON Export", hash[:meta][:format]
        assert_equal "1.0", hash[:meta][:version]
        assert hash[:meta][:exported_at]
      end

      def test_meta_info_net_type_basic
        hash = @exporter.to_hash

        assert_equal "petri_net", hash[:meta][:net_type]
      end

      def test_meta_info_net_type_colored
        hash = @colored_exporter.to_hash

        assert_equal "colored_petri_net", hash[:meta][:net_type]
      end

      # ===========================================
      # Net Structure Tests
      # ===========================================

      def test_net_structure
        hash = @exporter.to_hash

        assert_equal "TestNet", hash[:net][:name]
        assert_equal "PetriNet", hash[:net][:type]
        assert_equal 2, hash[:net][:place_count]
        assert_equal 1, hash[:net][:transition_count]
        assert_equal 2, hash[:net][:arc_count]
      end

      def test_colored_net_structure
        hash = @colored_exporter.to_hash

        assert_equal "ColoredTestNet", hash[:net][:name]
        assert_equal "ColoredPetriNet", hash[:net][:type]
      end

      # ===========================================
      # Colors Tests
      # ===========================================

      def test_colors_empty_for_basic_net
        hash = @exporter.to_hash

        assert_empty hash[:colors]
      end

      def test_colors_for_colored_net
        hash = @colored_exporter.to_hash

        assert_equal 1, hash[:colors].size
        color = hash[:colors].first
        assert_equal :order, color[:name]
        assert_equal({ id: :integer, status: :string }, color[:attributes])
        refute color[:has_validator]
      end

      # ===========================================
      # Places Tests
      # ===========================================

      def test_places_data
        hash = @exporter.to_hash

        assert_equal 2, hash[:places].size

        input_place = hash[:places].find { |p| p[:id] == :p1 }
        assert_equal "Input", input_place[:name]
        assert_equal 2, input_place[:tokens]
        assert_equal "infinite", input_place[:capacity]
      end

      def test_colored_places_include_color_info
        hash = @colored_exporter.to_hash

        orders_place = hash[:places].find { |p| p[:id] == :orders }
        assert_equal :order, orders_place[:color]
        assert orders_place[:colored_tokens]
        assert_equal 1, orders_place[:colored_tokens].size
      end

      def test_colored_tokens_data
        hash = @colored_exporter.to_hash

        orders_place = hash[:places].find { |p| p[:id] == :orders }
        token = orders_place[:colored_tokens].first

        assert token[:id]
        assert_equal :order, token[:color]
        assert_equal 1, token[:data][:id]
        assert_equal "pending", token[:data][:status]
      end

      # ===========================================
      # Transitions Tests
      # ===========================================

      def test_transitions_data
        hash = @exporter.to_hash

        assert_equal 1, hash[:transitions].size
        trans = hash[:transitions].first

        assert_equal :t1, trans[:id]
        assert_equal "Process", trans[:name]
        assert_equal 1, trans[:input_arcs]
        assert_equal 1, trans[:output_arcs]
        assert trans[:enabled]
      end

      def test_transition_with_guard
        hash = @colored_exporter.to_hash

        trans = hash[:transitions].find { |t| t[:id] == :process }
        assert trans[:guard]
        assert_equal "named_guard", trans[:guard][:type]
        assert_equal "check_status", trans[:guard][:name]
      end

      def test_transition_with_proc_guard
        net = Core::Net.new(name: "GuardTest")
        net.add_place(id: :p1, initial_tokens: 1)
        net.add_transition(id: :t1, guard: ->(ctx) { true })
        net.add_arc(source_id: :p1, target_id: :t1)

        exporter = JsonExporter.new(net)
        hash = exporter.to_hash

        trans = hash[:transitions].first
        assert trans[:guard]
        assert_equal "proc", trans[:guard][:type]
      end

      # ===========================================
      # Arcs Tests
      # ===========================================

      def test_arcs_data
        hash = @exporter.to_hash

        assert_equal 2, hash[:arcs].size
        arc = hash[:arcs].first

        assert arc[:id]
        assert arc[:source]
        assert arc[:target]
        assert_equal 1, arc[:weight]
        assert_includes ["place_to_transition", "transition_to_place"], arc[:direction]
      end

      def test_arc_source_target_details
        hash = @exporter.to_hash

        arc = hash[:arcs].find { |a| a[:direction] == "place_to_transition" }
        assert_equal :p1, arc[:source][:id]
        assert_equal "Place", arc[:source][:type]
        assert_equal :t1, arc[:target][:id]
        assert_equal "Transition", arc[:target][:type]
      end

      def test_arc_with_expression
        hash = @colored_exporter.to_hash

        arc_with_expr = hash[:arcs].find { |a| a[:expression] }
        assert arc_with_expr
        assert_equal "named_expression", arc_with_expr[:expression][:type]
        assert_equal "transform", arc_with_expr[:expression][:name]
      end

      # ===========================================
      # Marking Tests
      # ===========================================

      def test_marking_data
        hash = @exporter.to_hash

        assert hash[:marking][:tokens_by_place]
        assert_equal 2, hash[:marking][:tokens_by_place][:p1]
        assert_equal 0, hash[:marking][:tokens_by_place][:p2]
        assert_equal 2, hash[:marking][:total_tokens]
      end

      def test_colored_marking
        hash = @colored_exporter.to_hash

        assert hash[:marking][:colored_marking]
        assert hash[:marking][:colored_marking][:orders]
      end

      # ===========================================
      # Statistics Tests
      # ===========================================

      def test_statistics
        hash = @exporter.to_hash

        assert hash[:statistics]
        assert hash[:statistics][:enabled_transitions_list]
        assert_includes [true, false], hash[:statistics][:deadlocked]
      end

      # ===========================================
      # Save Tests
      # ===========================================

      def test_save_json
        require "tmpdir"

        Dir.mktmpdir do |dir|
          file = File.join(dir, "test.json")
          @exporter.save_json(file)

          assert File.exist?(file)
          content = File.read(file)
          parsed = JSON.parse(content)
          assert_equal "TestNet", parsed["net"]["name"]
        end
      end

      def test_save_json_compact
        require "tmpdir"

        Dir.mktmpdir do |dir|
          file = File.join(dir, "test.json")
          @exporter.save_json(file, pretty: false)

          content = File.read(file)
          refute_includes content, "\n  "
        end
      end
    end
  end
end
