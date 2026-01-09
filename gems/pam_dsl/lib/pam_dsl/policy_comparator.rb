# frozen_string_literal: true

module PamDsl
  # Compares two PAM DSL policies and generates comparison reports
  #
  # @example Basic usage
  #   comparator = PolicyComparator.new(:policy1, :policy2)
  #   report = comparator.generate_report
  #
  # @example With output path
  #   comparator = PolicyComparator.new(:policy1, :policy2)
  #   comparator.generate_report(output_path: "reports/comparison.md")
  #
  class PolicyComparator
    attr_reader :policy1, :policy2, :name1, :name2

    # Initialize comparator with two policy names
    #
    # @param policy1_name [Symbol] Name of the first policy
    # @param policy2_name [Symbol] Name of the second policy
    # @raise [PolicyNotFoundError] if either policy doesn't exist
    def initialize(policy1_name, policy2_name)
      @name1 = policy1_name
      @name2 = policy2_name
      @policy1 = PamDsl.policy(policy1_name)
      @policy2 = PamDsl.policy(policy2_name)
    end

    # Generate a markdown comparison report
    #
    # @param output_path [String, nil] Optional path to write the report
    # @return [String] The generated markdown report
    def generate_report(output_path: nil)
      report = build_report

      if output_path
        FileUtils.mkdir_p(File.dirname(output_path))
        File.write(output_path, report)
      end

      report
    end

    # Get field comparison data
    #
    # @return [Hash] Hash with :common, :only_in_first, :only_in_second keys
    def field_comparison
      fields1 = policy1.fields.keys.to_set
      fields2 = policy2.fields.keys.to_set

      {
        common: (fields1 & fields2).sort,
        only_in_first: (fields1 - fields2).sort,
        only_in_second: (fields2 - fields1).sort
      }
    end

    # Get purpose comparison data
    #
    # @return [Hash] Hash with :first and :second purpose arrays
    def purpose_comparison
      {
        first: policy1.purposes.values.map { |p| purpose_to_hash(p) },
        second: policy2.purposes.values.map { |p| purpose_to_hash(p) }
      }
    end

    # Get retention comparison data
    #
    # @return [Hash] Hash with default durations and rules
    def retention_comparison
      {
        first: {
          default_duration: policy1.retention&.default_duration,
          rules_count: policy1.retention&.rules&.count || 0
        },
        second: {
          default_duration: policy2.retention&.default_duration,
          rules_count: policy2.retention&.rules&.count || 0
        }
      }
    end

    # Check if a common field matches between policies
    #
    # @param field_name [Symbol] The field name to check
    # @return [Boolean] True if type and sensitivity match
    def field_matches?(field_name)
      f1 = policy1.fields[field_name]
      f2 = policy2.fields[field_name]
      return false unless f1 && f2

      f1.type == f2.type && f1.sensitivity == f2.sensitivity
    end

    # Get summary statistics
    #
    # @return [Hash] Summary with field, purpose, and retention counts
    def summary
      {
        first: {
          name: name1,
          fields: policy1.fields.count,
          purposes: policy1.purposes.count,
          retention_rules: policy1.retention&.rules&.count || 0
        },
        second: {
          name: name2,
          fields: policy2.fields.count,
          purposes: policy2.purposes.count,
          retention_rules: policy2.retention&.rules&.count || 0
        }
      }
    end

    # Export comparison as hash
    #
    # @return [Hash] Complete comparison data
    def to_h
      {
        generated_at: Time.now.utc.iso8601,
        policies: [name1.to_s, name2.to_s],
        summary: summary,
        fields: field_comparison_detail,
        purposes: purpose_comparison,
        retention: retention_comparison
      }
    end

    private

    def build_report
      lines = []
      lines << "# PAM DSL Policy Comparison Report"
      lines << ""
      lines << "Generated: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << ""
      lines << "Comparing:"
      lines << "- **#{name1}**"
      lines << "- **#{name2}**"
      lines << ""

      append_summary(lines)
      append_field_comparison(lines)
      append_purpose_comparison(lines)
      append_retention_comparison(lines)

      lines.join("\n")
    end

    def append_summary(lines)
      lines << "## Summary"
      lines << ""
      lines << "| Metric | #{name1} | #{name2} |"
      lines << "|--------|#{'-' * name1.to_s.length}--|#{'-' * name2.to_s.length}--|"
      lines << "| Fields | #{policy1.fields.count} | #{policy2.fields.count} |"
      lines << "| Purposes | #{policy1.purposes.count} | #{policy2.purposes.count} |"
      lines << "| Retention Rules | #{policy1.retention&.rules&.count || 0} | #{policy2.retention&.rules&.count || 0} |"
      lines << ""
    end

    def append_field_comparison(lines)
      comparison = field_comparison

      lines << "## Field Comparison"
      lines << ""

      # Common fields
      lines << "### Common Fields (#{comparison[:common].count})"
      lines << ""
      if comparison[:common].any?
        lines << "| Field | #{name1} Type | #{name2} Type | #{name1} Sensitivity | #{name2} Sensitivity | Match? |"
        lines << "|-------|--------------|--------------|---------------------|---------------------|--------|"
        comparison[:common].each do |f|
          f1 = policy1.fields[f]
          f2 = policy2.fields[f]
          match = field_matches?(f) ? "✓" : "✗"
          lines << "| #{f} | #{f1.type} | #{f2.type} | #{f1.sensitivity} | #{f2.sensitivity} | #{match} |"
        end
      else
        lines << "_No common fields_"
      end
      lines << ""

      # Only in first policy
      lines << "### Only in #{name1} (#{comparison[:only_in_first].count})"
      lines << ""
      if comparison[:only_in_first].any?
        lines << "| Field | Type | Sensitivity |"
        lines << "|-------|------|-------------|"
        comparison[:only_in_first].each do |f|
          field = policy1.fields[f]
          lines << "| #{f} | #{field.type} | #{field.sensitivity} |"
        end
      else
        lines << "_None_"
      end
      lines << ""

      # Only in second policy
      lines << "### Only in #{name2} (#{comparison[:only_in_second].count})"
      lines << ""
      if comparison[:only_in_second].any?
        lines << "| Field | Type | Sensitivity |"
        lines << "|-------|------|-------------|"
        comparison[:only_in_second].each do |f|
          field = policy2.fields[f]
          lines << "| #{f} | #{field.type} | #{field.sensitivity} |"
        end
      else
        lines << "_None_"
      end
      lines << ""
    end

    def append_purpose_comparison(lines)
      lines << "## Purpose Comparison"
      lines << ""
      lines << "### #{name1} Purposes"
      lines << ""
      lines << "| Purpose | Legal Basis | Required Fields |"
      lines << "|---------|-------------|-----------------|"
      policy1.purposes.values.each do |p|
        lines << "| #{p.name} | #{p.legal_basis} | #{p.required_fields.join(', ')} |"
      end
      lines << ""

      lines << "### #{name2} Purposes"
      lines << ""
      lines << "| Purpose | Legal Basis | Required Fields |"
      lines << "|---------|-------------|-----------------|"
      policy2.purposes.values.each do |p|
        lines << "| #{p.name} | #{p.legal_basis} | #{p.required_fields.join(', ')} |"
      end
      lines << ""
    end

    def append_retention_comparison(lines)
      lines << "## Retention Comparison"
      lines << ""
      lines << "| Policy | Default Duration |"
      lines << "|--------|-----------------|"
      lines << "| #{name1} | #{format_duration(policy1.retention&.default_duration)} |"
      lines << "| #{name2} | #{format_duration(policy2.retention&.default_duration)} |"
      lines << ""
    end

    def format_duration(duration)
      return "N/A" unless duration

      if duration >= 1.year
        years = (duration / 1.year).to_i
        "#{years} year#{'s' if years != 1}"
      elsif duration >= 1.day
        days = (duration / 1.day).to_i
        "#{days} day#{'s' if days != 1}"
      else
        "#{duration} seconds"
      end
    end

    def purpose_to_hash(purpose)
      {
        name: purpose.name,
        legal_basis: purpose.legal_basis,
        required_fields: purpose.required_fields,
        optional_fields: purpose.optional_fields
      }
    end

    def field_comparison_detail
      comparison = field_comparison

      {
        common: comparison[:common].map do |f|
          {
            name: f,
            first: field_to_hash(policy1.fields[f]),
            second: field_to_hash(policy2.fields[f]),
            matches: field_matches?(f)
          }
        end,
        only_in_first: comparison[:only_in_first].map { |f| field_to_hash(policy1.fields[f]) },
        only_in_second: comparison[:only_in_second].map { |f| field_to_hash(policy2.fields[f]) }
      }
    end

    def field_to_hash(field)
      {
        name: field.name,
        type: field.type,
        sensitivity: field.sensitivity
      }
    end
  end
end
