# frozen_string_literal: true

require 'rexml/document'

module PetriFlow
  module Export
    # Exports Colored Petri Nets to CPN Tools XML format
    # CPN Tools is a popular tool for editing, simulating and analyzing CPNs
    class CpnToolsExporter
      attr_reader :net

      def initialize(net)
        @net = net
        @place_counter = 0
        @trans_counter = 0
        @arc_counter = 0
      end

      # Export to CPN Tools XML string
      def to_cpn
        doc = REXML::Document.new
        doc << REXML::XMLDecl.new('1.0', 'UTF-8')

        # Root workspaceElements element
        workspace = doc.add_element('workspaceElements')

        # Add generator info
        generator = workspace.add_element('generator', {
          'tool' => 'PetriFlow',
          'version' => '1.0',
          'format' => 'CPN'
        })

        # Add cpnet element
        cpnet = workspace.add_element('cpnet')

        # Add globbox (global declarations)
        add_globbox(cpnet)

        # Add page
        page = add_page(cpnet)

        # Add color declarations to page
        add_page_attributes(page)

        # Add places
        @net.places.each do |place_id, place|
          add_place_node(page, place)
        end

        # Add transitions
        @net.transitions.each do |trans_id, transition|
          add_transition_node(page, transition)
        end

        # Add arcs
        @net.arcs.each do |arc|
          add_arc_node(page, arc)
        end

        # Format XML nicely
        formatter = REXML::Formatters::Pretty.new(2)
        formatter.compact = true
        output = String.new
        formatter.write(doc, output)
        output
      end

      # Save to file
      def save_cpn(filename)
        File.write(filename, to_cpn)
      end

      private

      def colored_net?
        @net.is_a?(PetriFlow::Colored::ColoredNet)
      end

      def add_globbox(cpnet)
        globbox = cpnet.add_element('globbox')

        # Add standard declarations
        block = globbox.add_element('block', { 'id' => 'id1' })

        # Add color declarations
        if colored_net? && @net.colors.any?
          @net.colors.each_with_index do |(color_name, color), index|
            add_color_block(block, color_name, color, index + 2)
          end
        else
          # Add default INT color
          add_default_color(block)
        end
      end

      def add_color_block(block, color_name, color, id_num)
        color_elem = block.add_element('color', { 'id' => "id#{id_num}" })

        # Color name
        id_elem = color_elem.add_element('id')
        id_elem.text = color_name.to_s.upcase

        # Color type (record/product type)
        if color.attributes.any?
          record_elem = color_elem.add_element('record')

          color.attributes.each do |attr_name, attr_type|
            record_field = record_elem.add_element('recordfield')

            field_id = record_field.add_element('id')
            field_id.text = attr_name.to_s

            field_type = record_field.add_element('id')
            field_type.text = type_to_cpn_type(attr_type)
          end
        else
          # Simple type
          int_elem = color_elem.add_element('int')
        end
      end

      def add_default_color(block)
        color_elem = block.add_element('color', { 'id' => 'id2' })
        id_elem = color_elem.add_element('id')
        id_elem.text = 'INT'
        int_elem = color_elem.add_element('int')
      end

      def type_to_cpn_type(type)
        case type.to_s
        when 'integer', 'int'
          'INT'
        when 'string'
          'STRING'
        when 'boolean', 'bool'
          'BOOL'
        when 'float', 'real'
          'REAL'
        when 'symbol'
          'STRING'
        when 'hash'
          'STRING'  # Serialize hash as string
        else
          'STRING'  # Default to string
        end
      end

      def add_page(cpnet)
        page = cpnet.add_element('page', { 'id' => 'page1' })

        # Page attributes
        pageattr = page.add_element('pageattr', { 'name' => @net.name })

        page
      end

      def add_page_attributes(page)
        # Optional: Add color set references at page level
      end

      def add_place_node(page, place)
        @place_counter += 1
        place_id = "place_#{@place_counter}"

        place_elem = page.add_element('place', { 'id' => place_id })

        # Place text (name)
        text_elem = place_elem.add_element('text')
        text_elem.text = place.name

        # Place type (color set)
        type_elem = place_elem.add_element('type')
        type_text = type_elem.add_element('text')

        if colored_net? && @net.colored_places[place.id]
          color = @net.colored_places[place.id][:color]
          type_text.text = color ? color.to_s.upcase : 'INT'
        else
          type_text.text = 'INT'
        end

        # Initial marking
        if place.tokens > 0 || (colored_net? && @net.token_pools[place.id]&.any?)
          initmark_elem = place_elem.add_element('initmark')
          mark_text = initmark_elem.add_element('text')

          if colored_net? && @net.token_pools[place.id]&.any?
            # Format colored tokens
            tokens = @net.token_pools[place.id].map { |t| format_token(t) }
            mark_text.text = tokens.join('++')
          else
            mark_text.text = place.tokens.to_s
          end
        end

        # Position (for graphical layout)
        posattr = place_elem.add_element('posattr', {
          'x' => (100 + @place_counter * 150).to_s,
          'y' => '100'
        })

        # Store mapping for arc creation
        @place_mapping ||= {}
        @place_mapping[place.id] = place_id
      end

      def format_token(token)
        if token.data.any?
          fields = token.data.map { |k, v| "#{k}=#{format_value(v)}" }
          "{#{fields.join(', ')}}"
        else
          "1"
        end
      end

      def format_value(value)
        case value
        when String
          "\"#{value}\""
        when Symbol
          "\"#{value}\""
        when Hash
          "\"#{value.to_json}\""
        else
          value.to_s
        end
      end

      def add_transition_node(page, transition)
        @trans_counter += 1
        trans_id = "trans_#{@trans_counter}"

        trans_elem = page.add_element('trans', { 'id' => trans_id })

        # Transition text (name)
        text_elem = trans_elem.add_element('text')
        text_elem.text = transition.name

        # Guard condition
        if transition.guard
          cond_elem = trans_elem.add_element('cond')
          cond_text = cond_elem.add_element('text')

          guard_text = if transition.guard.respond_to?(:name) && transition.guard.name
                        transition.guard.name
                      else
                        'true'
                      end
          cond_text.text = "[#{guard_text}]"
        end

        # Position
        posattr = trans_elem.add_element('posattr', {
          'x' => (100 + @trans_counter * 150).to_s,
          'y' => '200'
        })

        # Store mapping for arc creation
        @trans_mapping ||= {}
        @trans_mapping[transition.id] = trans_id
      end

      def add_arc_node(page, arc)
        @arc_counter += 1
        arc_id = "arc_#{@arc_counter}"

        # Determine arc orientation and get IDs
        if arc.input_arc?
          # Place -> Transition
          from_place = @place_mapping[arc.source.id]
          to_trans = @trans_mapping[arc.target.id]

          arc_elem = page.add_element('arc', {
            'id' => arc_id,
            'orientation' => 'PtoT',
            'order' => @arc_counter.to_s
          })

          arc_elem.add_element('posattr', { 'x' => '0', 'y' => '0' })
          arc_elem.add_element('fillattr', { 'colour' => 'Black' })
          arc_elem.add_element('lineattr', { 'colour' => 'Black' })
          arc_elem.add_element('textattr', { 'colour' => 'Black' })

          transend = arc_elem.add_element('transend', { 'idref' => to_trans })
          placeend = arc_elem.add_element('placeend', { 'idref' => from_place })

        elsif arc.output_arc?
          # Transition -> Place
          from_trans = @trans_mapping[arc.source.id]
          to_place = @place_mapping[arc.target.id]

          arc_elem = page.add_element('arc', {
            'id' => arc_id,
            'orientation' => 'TtoP',
            'order' => @arc_counter.to_s
          })

          arc_elem.add_element('posattr', { 'x' => '0', 'y' => '0' })
          arc_elem.add_element('fillattr', { 'colour' => 'Black' })
          arc_elem.add_element('lineattr', { 'colour' => 'Black' })
          arc_elem.add_element('textattr', { 'colour' => 'Black' })

          transend = arc_elem.add_element('transend', { 'idref' => from_trans })
          placeend = arc_elem.add_element('placeend', { 'idref' => to_place })
        end

        # Arc annotation (expression or weight)
        annot_elem = arc_elem.add_element('annot')
        annot_text = annot_elem.add_element('text')

        if arc.expression && arc.expression.respond_to?(:name) && arc.expression.name
          annot_text.text = arc.expression.name
        elsif arc.weight > 1
          annot_text.text = "#{arc.weight}*x"
        else
          annot_text.text = 'x'
        end
      end
    end
  end
end
