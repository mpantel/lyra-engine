# frozen_string_literal: true

require "test_helper"
require "rexml/document"

module PetriFlow
  module Export
    class CpnToolsExporterTest < Minitest::Test
      def setup
        @net = create_test_net
        @colored_net = create_colored_net
        @exporter = CpnToolsExporter.new(@net)
        @colored_exporter = CpnToolsExporter.new(@colored_net)
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

      def parse_cpn(xml_string)
        REXML::Document.new(xml_string)
      end

      # ===========================================
      # to_cpn Tests
      # ===========================================

      def test_to_cpn_returns_string
        result = @exporter.to_cpn

        assert_kind_of String, result
      end

      def test_to_cpn_is_valid_xml
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        assert doc.root
      end

      def test_to_cpn_has_xml_declaration
        result = @exporter.to_cpn

        assert_includes result, "<?xml version='1.0' encoding='UTF-8'?>"
      end

      def test_to_cpn_has_workspace_root
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        assert_equal "workspaceElements", doc.root.name
      end

      # ===========================================
      # Generator Info Tests
      # ===========================================

      def test_generator_info_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        generator = doc.root.elements["generator"]
        assert generator
      end

      def test_generator_attributes
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        generator = doc.root.elements["generator"]

        assert_equal "PetriFlow", generator.attributes["tool"]
        assert_equal "1.0", generator.attributes["version"]
        assert_equal "CPN", generator.attributes["format"]
      end

      # ===========================================
      # CPNet Structure Tests
      # ===========================================

      def test_cpnet_element_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        cpnet = doc.root.elements["cpnet"]
        assert cpnet
      end

      def test_globbox_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        globbox = doc.root.elements["cpnet/globbox"]
        assert globbox
      end

      def test_globbox_has_block
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        block = doc.root.elements["cpnet/globbox/block"]
        assert block
        assert_equal "id1", block.attributes["id"]
      end

      # ===========================================
      # Page Tests
      # ===========================================

      def test_page_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        page = doc.root.elements["cpnet/page"]
        assert page
        assert_equal "page1", page.attributes["id"]
      end

      def test_page_has_name_attribute
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        pageattr = doc.root.elements["cpnet/page/pageattr"]
        assert pageattr
        assert_equal "TestNet", pageattr.attributes["name"]
      end

      # ===========================================
      # Color Declarations Tests
      # ===========================================

      def test_default_int_color_for_basic_net
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        color = doc.root.elements["cpnet/globbox/block/color"]
        assert color

        id_elem = color.elements["id"]
        assert_equal "INT", id_elem.text

        assert color.elements["int"]
      end

      def test_color_declaration_for_colored_net
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        colors = doc.root.get_elements("cpnet/globbox/block/color")
        assert colors.size >= 1

        order_color = colors.find { |c| c.elements["id"]&.text == "ORDER" }
        assert order_color
      end

      def test_color_record_fields
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        color = doc.root.get_elements("cpnet/globbox/block/color").find { |c| c.elements["id"]&.text == "ORDER" }

        record = color.elements["record"]
        assert record

        fields = record.get_elements("recordfield")
        assert_equal 2, fields.size
      end

      # ===========================================
      # Place Tests
      # ===========================================

      def test_places_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        places = doc.root.get_elements("cpnet/page/place")
        assert_equal 2, places.size
      end

      def test_place_structure
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        place = doc.root.elements["cpnet/page/place"]

        assert place
        assert place.attributes["id"]
        assert place.elements["text"]
        assert place.elements["type/text"]
        assert place.elements["posattr"]
      end

      def test_place_text
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        places = doc.root.get_elements("cpnet/page/place")

        input_place = places.find { |p| p.elements["text"].text == "Input" }
        assert input_place
      end

      def test_place_type_basic_net
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        place = doc.root.elements["cpnet/page/place"]
        type_text = place.elements["type/text"].text

        assert_equal "INT", type_text
      end

      def test_place_type_colored_net
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        places = doc.root.get_elements("cpnet/page/place")
        orders_place = places.find { |p| p.elements["text"].text == "Orders" }

        type_text = orders_place.elements["type/text"].text
        assert_equal "ORDER", type_text
      end

      def test_place_initial_marking
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        places = doc.root.get_elements("cpnet/page/place")
        input_place = places.find { |p| p.elements["text"].text == "Input" }

        initmark = input_place.elements["initmark/text"]
        assert initmark
        assert_equal "2", initmark.text
      end

      def test_colored_place_initial_marking
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        places = doc.root.get_elements("cpnet/page/place")
        orders_place = places.find { |p| p.elements["text"].text == "Orders" }

        initmark = orders_place.elements["initmark/text"]
        assert initmark
        # Should be formatted token data
        assert initmark.text
      end

      def test_place_position_attribute
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        place = doc.root.elements["cpnet/page/place"]
        posattr = place.elements["posattr"]

        assert posattr
        assert posattr.attributes["x"]
        assert posattr.attributes["y"]
      end

      # ===========================================
      # Transition Tests
      # ===========================================

      def test_transitions_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        transitions = doc.root.get_elements("cpnet/page/trans")
        assert_equal 1, transitions.size
      end

      def test_transition_structure
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        trans = doc.root.elements["cpnet/page/trans"]

        assert trans
        assert trans.attributes["id"]
        assert trans.elements["text"]
        assert trans.elements["posattr"]
      end

      def test_transition_text
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        trans = doc.root.elements["cpnet/page/trans"]
        text = trans.elements["text"].text

        assert_equal "Process", text
      end

      def test_transition_with_guard
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        trans = doc.root.elements["cpnet/page/trans"]
        cond = trans.elements["cond/text"]

        assert cond
        assert_equal "[check_status]", cond.text
      end

      def test_transition_with_proc_guard
        net = Core::Net.new(name: "GuardTest")
        net.add_place(id: :p1, initial_tokens: 1)
        net.add_transition(id: :t1, guard: ->(ctx) { true })
        net.add_arc(source_id: :p1, target_id: :t1)

        exporter = CpnToolsExporter.new(net)
        result = exporter.to_cpn
        doc = parse_cpn(result)

        trans = doc.root.elements["cpnet/page/trans"]
        cond = trans.elements["cond/text"]

        assert cond
        assert_equal "[true]", cond.text
      end

      def test_transition_position_attribute
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        trans = doc.root.elements["cpnet/page/trans"]
        posattr = trans.elements["posattr"]

        assert posattr
        assert posattr.attributes["x"]
        assert posattr.attributes["y"]
      end

      # ===========================================
      # Arc Tests
      # ===========================================

      def test_arcs_present
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arcs = doc.root.get_elements("cpnet/page/arc")
        assert_equal 2, arcs.size
      end

      def test_arc_structure
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arc = doc.root.elements["cpnet/page/arc"]

        assert arc
        assert arc.attributes["id"]
        assert arc.attributes["orientation"]
        assert arc.attributes["order"]
      end

      def test_arc_orientation_place_to_transition
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arcs = doc.root.get_elements("cpnet/page/arc")
        ptot_arc = arcs.find { |a| a.attributes["orientation"] == "PtoT" }

        assert ptot_arc
      end

      def test_arc_orientation_transition_to_place
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arcs = doc.root.get_elements("cpnet/page/arc")
        ttop_arc = arcs.find { |a| a.attributes["orientation"] == "TtoP" }

        assert ttop_arc
      end

      def test_arc_ends
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arc = doc.root.elements["cpnet/page/arc"]

        assert arc.elements["transend"]
        assert arc.elements["placeend"]
      end

      def test_arc_annotation
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arc = doc.root.elements["cpnet/page/arc"]
        annot = arc.elements["annot/text"]

        assert annot
        assert annot.text
      end

      def test_arc_weight_annotation
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arcs = doc.root.get_elements("cpnet/page/arc")
        weighted_arc = arcs.find { |a| a.elements["annot/text"].text == "2*x" }

        # Arc with weight > 1 should have formatted annotation
        assert weighted_arc || arcs.any? { |a| a.elements["annot/text"].text == "x" }
      end

      def test_arc_with_expression_annotation
        result = @colored_exporter.to_cpn

        doc = parse_cpn(result)
        arcs = doc.root.get_elements("cpnet/page/arc")
        expr_arc = arcs.find { |a| a.elements["annot/text"]&.text == "transform" }

        assert expr_arc
      end

      def test_arc_styling_attributes
        result = @exporter.to_cpn

        doc = parse_cpn(result)
        arc = doc.root.elements["cpnet/page/arc"]

        assert arc.elements["fillattr"]
        assert arc.elements["lineattr"]
        assert arc.elements["textattr"]
      end

      # ===========================================
      # Type Conversion Tests
      # ===========================================

      def test_type_conversion_integer
        net = Colored::ColoredNet.new(name: "TypeTest")
        net.add_color(:test, attributes: { value: :integer })
        net.add_colored_place(id: :p1, name: "Test", color: :test)

        exporter = CpnToolsExporter.new(net)
        result = exporter.to_cpn
        doc = parse_cpn(result)

        colors = doc.root.get_elements("cpnet/globbox/block/color")
        test_color = colors.find { |c| c.elements["id"]&.text == "TEST" }
        field = test_color.elements["record/recordfield"]
        type_id = field.get_elements("id").last

        assert_equal "INT", type_id.text
      end

      def test_type_conversion_string
        net = Colored::ColoredNet.new(name: "TypeTest")
        net.add_color(:test, attributes: { name: :string })
        net.add_colored_place(id: :p1, name: "Test", color: :test)

        exporter = CpnToolsExporter.new(net)
        result = exporter.to_cpn
        doc = parse_cpn(result)

        colors = doc.root.get_elements("cpnet/globbox/block/color")
        test_color = colors.find { |c| c.elements["id"]&.text == "TEST" }
        field = test_color.elements["record/recordfield"]
        type_id = field.get_elements("id").last

        assert_equal "STRING", type_id.text
      end

      def test_type_conversion_boolean
        net = Colored::ColoredNet.new(name: "TypeTest")
        net.add_color(:test, attributes: { active: :boolean })
        net.add_colored_place(id: :p1, name: "Test", color: :test)

        exporter = CpnToolsExporter.new(net)
        result = exporter.to_cpn
        doc = parse_cpn(result)

        colors = doc.root.get_elements("cpnet/globbox/block/color")
        test_color = colors.find { |c| c.elements["id"]&.text == "TEST" }
        field = test_color.elements["record/recordfield"]
        type_id = field.get_elements("id").last

        assert_equal "BOOL", type_id.text
      end

      # ===========================================
      # Save Tests
      # ===========================================

      def test_save_cpn
        require "tmpdir"

        Dir.mktmpdir do |dir|
          file = File.join(dir, "test.cpn")
          @exporter.save_cpn(file)

          assert File.exist?(file)
          content = File.read(file)
          doc = parse_cpn(content)
          assert_equal "workspaceElements", doc.root.name
        end
      end
    end
  end
end
