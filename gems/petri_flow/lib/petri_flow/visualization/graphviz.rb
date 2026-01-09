# frozen_string_literal: true

require "set"

module PetriFlow
  module Visualization
    # GraphViz visualization for Petri nets
    # Generates DOT format for rendering with Graphviz
    class Graphviz
      attr_reader :net, :options

      DEFAULT_OPTIONS = {
        place_color: "lightblue",
        transition_color: "lightgreen",
        marked_place_color: "yellow",
        enabled_transition_color: "lightcoral",
        show_token_count: true,
        show_arc_weights: true,
        show_pattern_labels: true,  # Label fork/choice patterns
        layout: "dot", # dot, neato, fdp, circo
        rankdir: "TB"  # TB (top-bottom), LR (left-right)
      }.freeze

      def initialize(net, options = {})
        @net = net
        @options = DEFAULT_OPTIONS.merge(options)
        analyze_patterns if @options[:show_pattern_labels]
      end

      # Generate DOT format
      def to_dot
        dot = []
        dot << "digraph #{sanitize_name(@net.name)} {"
        dot << "  rankdir=#{@options[:rankdir]};"
        dot << "  node [fontname=\"Helvetica\"];"
        dot << "  edge [fontname=\"Helvetica\"];"
        dot << ""

        # Places
        dot << "  // Places"
        @net.places.each do |id, place|
          dot << place_node(id, place)
        end
        dot << ""

        # Transitions
        dot << "  // Transitions"
        @net.transitions.each do |id, transition|
          dot << transition_node(id, transition)
        end
        dot << ""

        # Arcs
        dot << "  // Arcs"
        @net.arcs.each do |arc|
          dot << arc_edge(arc)
        end

        dot << "}"
        dot.join("\n")
      end

      # Save DOT file
      def save_dot(filename)
        File.write(filename, to_dot)
      end

      # Generate and render to image (requires graphviz installed)
      def render(output_file, format: "png")
        require 'open3'

        dot_content = to_dot
        cmd = "#{@options[:layout]} -T#{format} -o #{output_file}"

        stdout, stderr, status = Open3.capture3(cmd, stdin_data: dot_content)

        unless status.success?
          raise "Graphviz rendering failed: #{stderr}"
        end

        output_file
      end

      # Generate ASCII art representation
      def to_ascii
        ascii = []
        ascii << "=" * 60
        ascii << "Petri Net: #{@net.name}"
        ascii << "=" * 60
        ascii << ""

        ascii << "Places:"
        @net.places.each do |id, place|
          tokens = "●" * place.tokens
          ascii << "  #{place.name} [#{id}]: #{tokens} (#{place.tokens} token#{'s' unless place.tokens == 1})"
        end
        ascii << ""

        ascii << "Transitions:"
        @net.transitions.each do |id, transition|
          enabled = transition.enabled? ? "✓" : "✗"
          ascii << "  #{enabled} #{transition.name} [#{id}]"
          transition.input_arcs.each do |arc|
            ascii << "      ← #{arc.source.name} (weight: #{arc.weight})"
          end
          transition.output_arcs.each do |arc|
            ascii << "      → #{arc.target.name} (weight: #{arc.weight})"
          end
        end
        ascii << ""

        ascii << "=" * 60
        ascii.join("\n")
      end

      private

      def place_node(id, place)
        tokens = place.tokens
        color = tokens > 0 ? @options[:marked_place_color] : @options[:place_color]

        label = if @options[:show_token_count] && tokens > 0
                  "#{place.name}\\n(#{tokens})"
                else
                  place.name
                end

        "  #{node_id(:place, id)} [shape=circle, label=\"#{label}\", style=filled, fillcolor=\"#{color}\"];"
      end

      def transition_node(id, transition)
        enabled = transition.enabled?
        color = enabled ? @options[:enabled_transition_color] : @options[:transition_color]

        label = transition.name
        label += "\\n[enabled]" if enabled && @options[:show_enabled]

        "  #{node_id(:transition, id)} [shape=box, label=\"#{label}\", style=filled, fillcolor=\"#{color}\"];"
      end

      # Analyze the net to identify fork and choice patterns
      def analyze_patterns
        @fork_transitions = Set.new
        @choice_places = Set.new

        # Find fork transitions: transitions with multiple output arcs
        @net.transitions.each do |id, transition|
          output_arcs = @net.arcs.select { |arc| arc.source == transition }
          if output_arcs.size > 1
            @fork_transitions.add(id)
          end
        end

        # Find choice places: places with multiple outgoing transitions
        @net.places.each do |id, place|
          outgoing_arcs = @net.arcs.select { |arc| arc.source == place }
          if outgoing_arcs.size > 1
            @choice_places.add(id)
          end
        end
      end

      def arc_edge(arc)
        source_id = if arc.source.is_a?(Core::Place)
                     node_id(:place, arc.source.id)
                   else
                     node_id(:transition, arc.source.id)
                   end

        target_id = if arc.target.is_a?(Core::Place)
                     node_id(:place, arc.target.id)
                   else
                     node_id(:transition, arc.target.id)
                   end

        label = arc_label(arc)

        "  #{source_id} -> #{target_id}#{label};"
      end

      def arc_label(arc)
        labels = []

        # Check for fork/choice patterns
        if @options[:show_pattern_labels]
          if arc.source.is_a?(Core::Transition) && @fork_transitions&.include?(arc.source.id)
            # Fork: show target place name
            target_name = arc.target.name.to_s.split('_').map(&:capitalize).join(' ')
            labels << "∥ #{target_name}"
          elsif arc.source.is_a?(Core::Place) && @choice_places&.include?(arc.source.id)
            # Choice: show where this transition leads
            transition = arc.target
            output_arcs = @net.arcs.select { |a| a.source == transition }
            if output_arcs.any?
              targets = output_arcs.map { |a| a.target.name.to_s.split('_').map(&:capitalize).join(' ') }
              labels << "⊕ → #{targets.join(', ')}"
            else
              labels << "⊕"
            end
          end
        end

        # Check for arc weights
        if @options[:show_arc_weights] && arc.weight > 1
          labels << arc.weight.to_s
        end

        labels.empty? ? "" : " [label=\"#{labels.join(' ')}\"]"
      end

      def node_id(type, id)
        "#{type}_#{sanitize_name(id)}"
      end

      def sanitize_name(name)
        name.to_s.gsub(/[^a-zA-Z0-9_]/, '_')
      end
    end
  end
end
