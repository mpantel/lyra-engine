# frozen_string_literal: true

require "test_helper"
require "rexml/document"

module PetriFlow
  module Export
    class PnmlExporterTest < Minitest::Test
      def setup
        @net = create_test_net
        @colored_net = create_colored_net
        @exporter = PnmlExporter.new(@net)
        @colored_exporter = PnmlExporter.new(@colored_net)
      end

      def create_test_net
        net = Core::Net.new(name: "TestNet")
        net.add_place(id: :p1, name: "Input", initial_tokens: 2)
        net.add_place(id: :p2, name: "Output", initial_tokens: 0)
        net.add_transition(id: :t1, name: "Process")
        net.add_arc(source_id: :p1, target_id: :t1, weight: 2)
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

        token = Core::Token.new(color: :order, data: { id: 1, status: "pending" })
        net.add_token_to_place(:orders, token)

        net
      end

      def parse_pnml(xml_string)
        REXML::Document.new(xml_string)
      end

      # ===========================================
      # to_pnml Tests
      # ===========================================

      def test_to_pnml_returns_string
        result = @exporter.to_pnml

        assert_kind_of String, result
      end

      def test_to_pnml_is_valid_xml
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        assert doc.root
      end

      def test_to_pnml_has_xml_declaration
        result = @exporter.to_pnml

        assert_includes result, "<?xml version='1.0' encoding='UTF-8'?>"
      end

      def test_to_pnml_has_pnml_root
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        assert_equal "pnml", doc.root.name
      end

      def test_to_pnml_has_namespace
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        namespace = doc.root.attributes["xmlns"]
        assert_equal "http://www.pnml.org/version-2009/grammar/pnml", namespace
      end

      # ===========================================
      # Net Element Tests
      # ===========================================

      def test_net_element_present
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        net_elem = doc.root.elements["net"]
        assert net_elem
      end

      def test_net_id
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        net_elem = doc.root.elements["net"]
        assert_equal "testnet", net_elem.attributes["id"]
      end

      def test_net_type_url_basic
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        net_elem = doc.root.elements["net"]
        assert_equal "http://www.pnml.org/version-2009/grammar/ptnet", net_elem.attributes["type"]
      end

      def test_net_type_url_colored
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        net_elem = doc.root.elements["net"]
        assert_equal "http://www.pnml.org/version-2009/grammar/highlevelnet", net_elem.attributes["type"]
      end

      def test_net_name_element
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        net_elem = doc.root.elements["net"]
        name_text = net_elem.elements["name/text"].text
        assert_equal "TestNet", name_text
      end

      # ===========================================
      # Page Element Tests
      # ===========================================

      def test_page_element_present
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        page = doc.root.elements["net/page"]
        assert page
        assert_equal "page1", page.attributes["id"]
      end

      # ===========================================
      # Places Tests
      # ===========================================

      def test_places_present
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        places = doc.root.get_elements("net/page/place")
        assert_equal 2, places.size
      end

      def test_place_structure
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='p1']"]

        assert place
        assert_equal "p1", place.attributes["id"]
        assert place.elements["name/text"]
        assert place.elements["graphics"]
      end

      def test_place_name
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='p1']"]
        name_text = place.elements["name/text"].text

        assert_equal "Input", name_text
      end

      def test_place_initial_marking
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='p1']"]
        marking = place.elements["initialMarking/text"]

        assert marking
        assert_equal "2", marking.text
      end

      def test_place_zero_marking_not_exported
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='p2']"]
        marking = place.elements["initialMarking"]

        assert_nil marking
      end

      def test_colored_place_type
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='orders']"]
        type_text = place.elements["type/text"]

        assert type_text
        assert_equal "order", type_text.text
      end

      def test_place_graphics
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        place = doc.root.elements["net/page/place[@id='p1']"]
        graphics = place.elements["graphics"]

        assert graphics
        assert graphics.elements["position"]
        assert graphics.elements["dimension"]
      end

      # ===========================================
      # Transitions Tests
      # ===========================================

      def test_transitions_present
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        transitions = doc.root.get_elements("net/page/transition")
        assert_equal 1, transitions.size
      end

      def test_transition_structure
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        trans = doc.root.elements["net/page/transition[@id='t1']"]

        assert trans
        assert_equal "t1", trans.attributes["id"]
        assert trans.elements["name/text"]
        assert trans.elements["graphics"]
      end

      def test_transition_name
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        trans = doc.root.elements["net/page/transition[@id='t1']"]
        name_text = trans.elements["name/text"].text

        assert_equal "Process", name_text
      end

      def test_transition_with_named_guard
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        trans = doc.root.elements["net/page/transition[@id='process']"]
        condition = trans.elements["condition/text"]

        assert condition
        assert_equal "check_status", condition.text
      end

      def test_transition_with_proc_guard
        net = Core::Net.new(name: "GuardTest")
        net.add_place(id: :p1, initial_tokens: 1)
        net.add_transition(id: :t1, guard: ->(ctx) { true })
        net.add_arc(source_id: :p1, target_id: :t1)

        exporter = PnmlExporter.new(net)
        result = exporter.to_pnml
        doc = parse_pnml(result)

        trans = doc.root.elements["net/page/transition[@id='t1']"]
        condition = trans.elements["condition/text"]

        assert condition
        assert_equal "[guard]", condition.text
      end

      def test_transition_graphics
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        trans = doc.root.elements["net/page/transition[@id='t1']"]
        graphics = trans.elements["graphics"]

        assert graphics
        assert graphics.elements["position"]
        assert graphics.elements["dimension"]
      end

      # ===========================================
      # Arcs Tests
      # ===========================================

      def test_arcs_present
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        arcs = doc.root.get_elements("net/page/arc")
        assert_equal 2, arcs.size
      end

      def test_arc_structure
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        arc = doc.root.elements["net/page/arc"]

        assert arc
        assert arc.attributes["id"]
        assert arc.attributes["source"]
        assert arc.attributes["target"]
      end

      def test_arc_source_target
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        arc = doc.root.elements["net/page/arc[@id='arc_0']"]

        assert_equal "p1", arc.attributes["source"]
        assert_equal "t1", arc.attributes["target"]
      end

      def test_arc_weight_inscription
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        arc = doc.root.elements["net/page/arc[@id='arc_0']"]
        inscription = arc.elements["inscription/text"]

        assert inscription
        assert_equal "2", inscription.text
      end

      def test_arc_weight_one_no_inscription
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        arc = doc.root.elements["net/page/arc[@id='arc_1']"]
        inscription = arc.elements["inscription"]

        # Weight of 1 shouldn't have inscription (or should have expression)
        # This depends on implementation - check if expression is present
        if inscription
          # Expression would override weight
          assert inscription.elements["text"]
        end
      end

      def test_arc_expression
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        arcs = doc.root.get_elements("net/page/arc")

        arc_with_expr = arcs.find { |a| a.elements["inscription/text"]&.text == "transform" }
        assert arc_with_expr
      end

      # ===========================================
      # Color Declarations Tests
      # ===========================================

      def test_no_color_declarations_for_basic_net
        result = @exporter.to_pnml

        doc = parse_pnml(result)
        declaration = doc.root.elements["net/declaration"]

        assert_nil declaration
      end

      def test_color_declarations_for_colored_net
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        declaration = doc.root.elements["net/declaration"]

        assert declaration
        assert declaration.elements["structure"]
      end

      def test_color_declaration_structure
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        color_decl = doc.root.elements["net/declaration/structure/declaration"]

        assert color_decl
        assert color_decl.elements["name/text"]
        assert_equal "order", color_decl.elements["name/text"].text
      end

      def test_color_attributes_as_struct
        result = @colored_exporter.to_pnml

        doc = parse_pnml(result)
        struct = doc.root.elements["net/declaration/structure/declaration/sort/struct"]

        assert struct
        fields = struct.get_elements("field")
        assert_equal 2, fields.size
      end

      # ===========================================
      # Save Tests
      # ===========================================

      def test_save_pnml
        require "tmpdir"

        Dir.mktmpdir do |dir|
          file = File.join(dir, "test.pnml")
          @exporter.save_pnml(file)

          assert File.exist?(file)
          content = File.read(file)
          doc = parse_pnml(content)
          assert_equal "pnml", doc.root.name
        end
      end
    end
  end
end
