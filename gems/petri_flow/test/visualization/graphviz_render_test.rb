# frozen_string_literal: true

require "test_helper"
require "open3"

module PetriFlow
  module Visualization
    # render passes Graphviz its arguments one by one, never as a shell string,
    # so a path or option with shell syntax in it is only ever a file name.
    class GraphvizRenderTest < Minitest::Test
      Status = Struct.new(:ok) do
        def success? = ok
      end

      def setup
        @net = Core::Net.new(name: "render_net")
        @net.add_place(id: :p, initial_tokens: 1)
      end

      def capture_render(graphviz, output_file, **opts)
        calls = []
        fake = ->(*args, **kw) { calls << [args, kw]; ["", "", Status.new(true)] }
        Open3.stub(:capture3, fake) { graphviz.render(output_file, **opts) }
        calls
      end

      def test_render_passes_each_argument_separately
        output = "/tmp/out; touch /tmp/pwned.png"
        calls = capture_render(Graphviz.new(@net), output, format: "png")

        assert_equal 1, calls.size
        args, kw = calls.first
        assert_equal ["dot", "-Tpng", "-o", output], args
        assert_includes kw[:stdin_data], "digraph"
      end

      def test_render_uses_the_chosen_layout_engine
        calls = capture_render(Graphviz.new(@net, layout: "neato"), "/tmp/out.svg", format: "svg")
        assert_equal "neato", calls.first.first.first
      end

      def test_render_refuses_an_unknown_layout_before_running_anything
        calls = []
        Open3.stub(:capture3, ->(*a, **k) { calls << a; ["", "", Status.new(true)] }) do
          error = assert_raises(ArgumentError) { Graphviz.new(@net, layout: "dot; rm -rf ~").render("/tmp/x.png") }
          assert_match(/unknown Graphviz layout/, error.message)
        end
        assert_empty calls
      end

      def test_render_refuses_a_format_with_shell_syntax
        assert_raises(ArgumentError) { Graphviz.new(@net).render("/tmp/x", format: "png -o /etc/passwd") }
      end
    end
  end
end
