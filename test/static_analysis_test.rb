# frozen_string_literal: true

require "test_helper"

class StaticAnalysisTest < Minitest::Test
  # ===========================================================================
  # ERB Template Linting
  # ===========================================================================

  def test_no_unless_elsif_in_erb_templates
    # Ruby's `unless` doesn't support `elsif` - this is a common bug
    # that causes ActionView::SyntaxErrorInTemplate at runtime
    erb_files = Dir.glob(File.expand_path("../../app/views/**/*.erb", __FILE__))

    violations = []

    erb_files.each do |file|
      content = File.read(file)
      lines = content.lines

      in_unless_block = false
      unless_line = nil

      lines.each_with_index do |line, idx|
        line_num = idx + 1

        # Detect start of unless block (ERB style)
        if line =~ /<%[-=]?\s*unless\b/ && line !~ /\bend\s*%>/
          in_unless_block = true
          unless_line = line_num
        end

        # Detect elsif while inside unless block
        if in_unless_block && line =~ /<%[-=]?\s*elsif\b/
          violations << {
            file: file.sub(%r{.*/app/}, "app/"),
            line: line_num,
            unless_started_at: unless_line,
            content: line.strip
          }
        end

        # Detect end of block
        if line =~ /<%[-=]?\s*end\s*%>/
          in_unless_block = false
          unless_line = nil
        end
      end
    end

    if violations.any?
      message = "Found 'unless...elsif' pattern (invalid Ruby syntax) in ERB templates:\n"
      violations.each do |v|
        message += "  #{v[:file]}:#{v[:line]}: elsif found in unless block (started at line #{v[:unless_started_at]})\n"
        message += "    #{v[:content]}\n"
      end
      message += "\nFix: Change 'unless condition' to 'if !condition' to allow elsif"

      flunk message
    end
  end

  def test_no_unless_elsif_in_ruby_files
    # Also check Ruby files for the same pattern
    ruby_files = Dir.glob(File.expand_path("../../{app,lib}/**/*.rb", __FILE__))
    ruby_files.reject! { |f| f.include?("/vendor/") }

    violations = []

    ruby_files.each do |file|
      content = File.read(file)

      # Use a simple regex to find unless...elsif patterns
      # This checks for unless followed by elsif before the matching end
      # Note: This is a simplified check that may have false positives in complex nesting
      if content =~ /unless\b[^#\n]*\n(?:(?!(?:\bend\b|\bunless\b|\bif\b)).)*?\belsif\b/m
        # Found potential violation, now pinpoint the line
        lines = content.lines
        in_unless = 0
        unless_line = nil

        lines.each_with_index do |line, idx|
          # Skip comments
          next if line.strip.start_with?("#")

          # Track unless blocks (simplified - doesn't handle all edge cases)
          if line =~ /\bunless\b/ && line !~ /\bend\b/ && line !~ /return\s+unless/
            in_unless += 1
            unless_line ||= idx + 1
          end

          if in_unless > 0 && line =~ /\belsif\b/
            violations << {
              file: file.sub(%r{.*/}, ""),
              line: idx + 1,
              unless_started_at: unless_line,
              content: line.strip
            }
          end

          if line =~ /\bend\b/ && in_unless > 0
            in_unless -= 1
            unless_line = nil if in_unless == 0
          end
        end
      end
    end

    # This test is informational - Ruby files typically use proper patterns
    # but we still want to catch any violations
    if violations.any?
      message = "Found potential 'unless...elsif' pattern in Ruby files:\n"
      violations.each do |v|
        message += "  #{v[:file]}:#{v[:line]}: #{v[:content]}\n"
      end
      flunk message
    end
  end

  # ===========================================================================
  # Workflow Generator Path Test
  # ===========================================================================

  def test_workflow_generator_outputs_to_app_workflows
    # Verify that generated workflows go to app/workflows/
    # with top-level constants for Zeitwerk compatibility
    app_workflows = File.expand_path("../../app/workflows", __FILE__)

    # Check the directory exists
    assert Dir.exist?(app_workflows),
      "Workflow output directory should exist at app/workflows/"
  end

  def test_generated_workflows_follow_zeitwerk_conventions
    # Verify workflow files define top-level constants matching their filename
    # app/workflows/monitor_mode_workflow.rb -> class MonitorModeWorkflow
    app_workflows = File.expand_path("../../app/workflows", __FILE__)
    return unless Dir.exist?(app_workflows)

    Dir.glob("#{app_workflows}/*.rb").each do |file|
      content = File.read(file)
      filename = File.basename(file, ".rb")

      # Expected class name from filename (snake_case -> PascalCase)
      expected_class = filename.split("_").map(&:capitalize).join

      # Should define top-level class (not nested in modules)
      assert content.include?("class #{expected_class}") || content.include?("class #{expected_class} <"),
        "#{filename}.rb should define top-level class #{expected_class}"

      # Should NOT be nested in Lyra::Verification::Generated (causes Zeitwerk issues)
      refute content.include?("module Lyra") && content.include?("module Verification"),
        "#{filename}.rb should NOT use nested Lyra::Verification namespace in app/workflows"
    end
  end
end
