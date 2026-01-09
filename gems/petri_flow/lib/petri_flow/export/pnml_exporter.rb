# frozen_string_literal: true

require 'rexml/document'

module PetriFlow
  module Export
    # Exports Petri nets and Colored Petri Nets to PNML format
    # PNML (Petri Net Markup Language) is the ISO/IEC 15909 standard
    class PnmlExporter
      attr_reader :net

      def initialize(net)
        @net = net
      end

      # Export to PNML XML string
      def to_pnml
        doc = REXML::Document.new
        doc << REXML::XMLDecl.new('1.0', 'UTF-8')

        # Root element
        pnml = doc.add_element('pnml', {
          'xmlns' => 'http://www.pnml.org/version-2009/grammar/pnml'
        })

        # Add net element
        net_element = pnml.add_element('net', {
          'id' => net_id,
          'type' => net_type_url
        })

        # Add name
        add_name(net_element, @net.name)

        # Add page (container for net elements)
        page = net_element.add_element('page', { 'id' => 'page1' })

        # Add places
        @net.places.each do |place_id, place|
          add_place(page, place)
        end

        # Add transitions
        @net.transitions.each do |trans_id, transition|
          add_transition(page, transition)
        end

        # Add arcs
        @net.arcs.each_with_index do |arc, index|
          add_arc(page, arc, index)
        end

        # Add colored net extensions if applicable
        if colored_net?
          add_color_declarations(net_element)
        end

        # Format XML nicely
        formatter = REXML::Formatters::Pretty.new(2)
        formatter.compact = true
        output = String.new
        formatter.write(doc, output)
        output
      end

      # Save to file
      def save_pnml(filename)
        File.write(filename, to_pnml)
      end

      private

      def net_id
        @net.name.downcase.gsub(/\s+/, '_')
      end

      def net_type_url
        if colored_net?
          'http://www.pnml.org/version-2009/grammar/highlevelnet'
        else
          'http://www.pnml.org/version-2009/grammar/ptnet'
        end
      end

      def colored_net?
        @net.is_a?(PetriFlow::Colored::ColoredNet)
      end

      def add_name(element, name)
        name_elem = element.add_element('name')
        text_elem = name_elem.add_element('text')
        text_elem.text = name
      end

      def add_place(page, place)
        place_elem = page.add_element('place', { 'id' => place.id.to_s })
        add_name(place_elem, place.name)

        # Add initial marking
        if place.tokens > 0
          marking_elem = place_elem.add_element('initialMarking')
          text_elem = marking_elem.add_element('text')
          text_elem.text = place.tokens.to_s
        end

        # Add colored net place extensions
        if colored_net? && @net.colored_places[place.id]
          add_place_type(place_elem, @net.colored_places[place.id])
        end

        # Add graphics (optional - for visualization)
        add_place_graphics(place_elem)
      end

      def add_place_type(place_elem, place_info)
        return unless place_info[:color]

        type_elem = place_elem.add_element('type')
        text_elem = type_elem.add_element('text')
        text_elem.text = place_info[:color].to_s
      end

      def add_place_graphics(place_elem)
        graphics = place_elem.add_element('graphics')
        position = graphics.add_element('position', { 'x' => '0', 'y' => '0' })
        dimension = graphics.add_element('dimension', { 'x' => '40', 'y' => '40' })
      end

      def add_transition(page, transition)
        trans_elem = page.add_element('transition', { 'id' => transition.id.to_s })
        add_name(trans_elem, transition.name)

        # Add guard if present
        if transition.guard
          add_guard(trans_elem, transition.guard)
        end

        # Add graphics
        add_transition_graphics(trans_elem)
      end

      def add_guard(trans_elem, guard)
        condition_elem = trans_elem.add_element('condition')
        text_elem = condition_elem.add_element('text')

        guard_text = if guard.respond_to?(:name) && guard.name
                      guard.name
                    else
                      '[guard]'
                    end
        text_elem.text = guard_text
      end

      def add_transition_graphics(trans_elem)
        graphics = trans_elem.add_element('graphics')
        position = graphics.add_element('position', { 'x' => '0', 'y' => '0' })
        dimension = graphics.add_element('dimension', { 'x' => '40', 'y' => '25' })
      end

      def add_arc(page, arc, index)
        arc_id = "arc_#{index}"
        source_id = arc.source.id.to_s
        target_id = arc.target.id.to_s

        arc_elem = page.add_element('arc', {
          'id' => arc_id,
          'source' => source_id,
          'target' => target_id
        })

        # Add inscription (arc weight)
        if arc.weight != 1
          inscription_elem = arc_elem.add_element('inscription')
          text_elem = inscription_elem.add_element('text')
          text_elem.text = arc.weight.to_s
        end

        # Add arc expression if present
        if arc.expression
          add_arc_expression(arc_elem, arc.expression)
        end
      end

      def add_arc_expression(arc_elem, expression)
        inscription_elem = arc_elem.add_element('inscription')
        text_elem = inscription_elem.add_element('text')

        expr_text = if expression.respond_to?(:name) && expression.name
                     expression.name
                    else
                      '[expression]'
                    end
        text_elem.text = expr_text
      end

      def add_color_declarations(net_element)
        return unless colored_net? && @net.colors.any?

        declaration_elem = net_element.add_element('declaration')
        structure_elem = declaration_elem.add_element('structure')

        @net.colors.each do |color_name, color|
          add_color_declaration(structure_elem, color_name, color)
        end
      end

      def add_color_declaration(structure_elem, color_name, color)
        declaration = structure_elem.add_element('declaration')

        name_elem = declaration.add_element('name')
        text_elem = name_elem.add_element('text')
        text_elem.text = color_name.to_s

        # Add color attributes as structure
        if color.attributes.any?
          sort_elem = declaration.add_element('sort')
          struct_elem = sort_elem.add_element('struct')

          color.attributes.each do |attr_name, attr_type|
            field_elem = struct_elem.add_element('field', {
              'name' => attr_name.to_s,
              'type' => attr_type.to_s
            })
          end
        end
      end
    end
  end
end
