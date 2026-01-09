# frozen_string_literal: true

require "set"

module PetriFlow
  module Visualization
    # Mermaid diagram visualization for Petri nets
    # Generates Mermaid syntax for embedding in Markdown/documentation
    class Mermaid
      attr_reader :net, :options

      DEFAULT_OPTIONS = {
        direction: "TB", # TB, BT, LR, RL
        show_tokens: true,
        show_weights: true,
        show_pattern_labels: true  # Label fork/choice patterns
      }.freeze

      def initialize(net, options = {})
        @net = net
        @options = DEFAULT_OPTIONS.merge(options)
        analyze_patterns if @options[:show_pattern_labels]
      end

      # Generate Mermaid flowchart
      def to_mermaid
        mermaid = []
        mermaid << "flowchart #{@options[:direction]}"

        # Places
        @net.places.each do |id, place|
          mermaid << place_node(id, place)
        end

        # Transitions
        @net.transitions.each do |id, transition|
          mermaid << transition_node(id, transition)
        end

        # Arcs
        @net.arcs.each do |arc|
          mermaid << arc_edge(arc)
        end

        # Styling
        mermaid << ""
        mermaid << style_definitions

        mermaid.join("\n")
      end

      # Generate state diagram (alternative representation)
      def to_state_diagram
        mermaid = []
        mermaid << "stateDiagram-v2"

        @net.transitions.each do |id, transition|
          transition.input_arcs.each do |input_arc|
            transition.output_arcs.each do |output_arc|
              source = input_arc.source.name
              target = output_arc.target.name
              label = escape_label(transition.name)

              mermaid << "  #{sanitize(source)} --> #{sanitize(target)}: #{label}"
            end
          end
        end

        mermaid.join("\n")
      end

      private

      def place_node(id, place)
        node_id = sanitize(id)
        label = escape_label(place.name)

        if @options[:show_tokens] && place.tokens > 0
          label = "#{label} x#{place.tokens}"
        end

        "  #{node_id}((\"#{label}\"))"
      end

      def transition_node(id, transition)
        node_id = sanitize(id)
        label = escape_label(transition.name)
        enabled = transition.enabled? ? " *" : ""

        "  #{node_id}[\"#{label}#{enabled}\"]"
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
        source_id = sanitize(arc.source.id)
        target_id = sanitize(arc.target.id)

        label = arc_label(arc)

        if label
          "  #{source_id} -->|#{label}| #{target_id}"
        elsif @options[:show_weights] && arc.weight > 1
          "  #{source_id} -->|#{arc.weight}| #{target_id}"
        else
          "  #{source_id} --> #{target_id}"
        end
      end

      def arc_label(arc)
        return nil unless @options[:show_pattern_labels]

        # Fork pattern: transition → multiple places (parallel outputs)
        # Show target place name to distinguish parallel paths
        if arc.source.is_a?(PetriFlow::Core::Transition)
          transition_id = arc.source.id
          if @fork_transitions&.include?(transition_id)
            target_name = arc.target.name.to_s.split('_').map(&:capitalize).join(' ')
            return "∥ #{target_name}"
          end
        end

        # Choice pattern: place → multiple transitions (exclusive choice)
        # Show where each choice leads (the transition's output place)
        if arc.source.is_a?(PetriFlow::Core::Place)
          place_id = arc.source.id
          if @choice_places&.include?(place_id)
            # Find where this transition leads
            transition = arc.target
            output_arcs = @net.arcs.select { |a| a.source == transition }
            if output_arcs.any?
              targets = output_arcs.map { |a| a.target.name.to_s.split('_').map(&:capitalize).join(' ') }
              return "⊕ → #{targets.join(', ')}"
            end
            return "⊕"
          end
        end

        nil
      end

      def style_definitions
        styles = []

        # Style places (circles) - light blue
        place_ids = @net.places.keys.map { |id| sanitize(id) }
        if place_ids.any?
          styles << "  classDef placeClass fill:#add8e6,stroke:#333,stroke-width:2px"
          styles << "  class #{place_ids.join(',')} placeClass"
        end

        # Style transitions (rectangles) - light green
        transition_ids = @net.transitions.keys.map { |id| sanitize(id) }
        if transition_ids.any?
          styles << "  classDef transitionClass fill:#90ee90,stroke:#333,stroke-width:2px"
          styles << "  class #{transition_ids.join(',')} transitionClass"
        end

        styles.join("\n")
      end

      def sanitize(name)
        name.to_s.gsub(/[^a-zA-Z0-9]/, '_')
      end

      def escape_label(text)
        text.to_s.gsub('"', "'").gsub(/[<>]/, '')
      end
    end
  end
end
