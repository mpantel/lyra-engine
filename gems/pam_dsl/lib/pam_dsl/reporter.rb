# frozen_string_literal: true

module PamDsl
  # Privacy Report Generator
  #
  # Generates comprehensive privacy compliance reports based on PAM DSL policies.
  # Can optionally integrate with event stores (like Lyra) for runtime analytics.
  #
  # @example Basic usage
  #   reporter = PamDsl::Reporter.new(:my_policy)
  #   reporter.policy_summary
  #
  # @example With event store integration
  #   reporter = PamDsl::Reporter.new(:my_policy,
  #     event_store: Lyra.event_store,
  #     organization: "My Company",
  #     dpo_contact: "dpo@example.com"
  #   )
  #   reporter.full_report
  #
  # @example Export to JSON
  #   reporter.export_json("privacy_report.json")
  #
  class Reporter
    SEPARATOR = "=" * 80
    SUBSEPARATOR = "-" * 80

    # Configuration for the reporter
    class Configuration
      attr_accessor :organization, :dpo_contact, :event_store, :output

      def initialize
        @organization = "Organization Name"
        @dpo_contact = "dpo@example.com"
        @event_store = nil
        @output = $stdout
      end
    end

    attr_reader :policy_name, :policy, :config

    # @param policy_name [Symbol] Name of the PAM DSL policy to report on
    # @param options [Hash] Configuration options
    # @option options [Object] :event_store Event store for runtime analytics (optional)
    # @option options [String] :organization Organization name for Article 30
    # @option options [String] :dpo_contact DPO contact for Article 30
    # @option options [IO] :output Output stream (default: $stdout)
    def initialize(policy_name, **options)
      @policy_name = policy_name.to_sym
      @policy = load_policy
      @config = Configuration.new
      @config.organization = options[:organization] if options[:organization]
      @config.dpo_contact = options[:dpo_contact] if options[:dpo_contact]
      @config.event_store = options[:event_store]
      @config.output = options[:output] || $stdout
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Full Report
    # ─────────────────────────────────────────────────────────────────────────

    def full_report
      print_header("PRIVACY COMPLIANCE REPORT")
      puts "Generated: #{Time.current.strftime('%Y-%m-%d %H:%M:%S %Z')}"
      puts "Policy: #{@policy_name}"
      puts "Organization: #{@config.organization}"
      puts SEPARATOR

      policy_summary
      puts "\n"

      if @config.event_store
        pii_analysis
        puts "\n"
        retention_check
        puts "\n"
        access_patterns
        puts "\n"
      end

      article_30_report
      print_footer
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Policy Summary
    # ─────────────────────────────────────────────────────────────────────────

    def policy_summary
      print_header("PAM DSL POLICY SUMMARY")

      unless @policy
        puts "No policy loaded (policy: #{@policy_name})"
        return
      end

      puts "Policy Name: #{@policy_name}"
      puts SUBSEPARATOR

      print_fields_table
      print_purposes_table
      print_retention_rules
      print_sensitivity_breakdown
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Analysis (requires event store)
    # ─────────────────────────────────────────────────────────────────────────

    def pii_analysis
      print_header("PII ANALYSIS FROM EVENT STORE")

      unless @config.event_store
        puts "Event store not configured. Skipping PII analysis."
        return
      end

      events = load_events
      if events.empty?
        puts "No events found in event store"
        return
      end

      puts "Total events analyzed: #{events.count}"
      puts SUBSEPARATOR

      pii_stats = analyze_pii_in_events(events)
      print_pii_occurrences(pii_stats, events.count)
      print_pii_summary(pii_stats, events.count)
      print_pii_by_model(pii_stats)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Retention Check (requires event store)
    # ─────────────────────────────────────────────────────────────────────────

    def retention_check
      print_header("RETENTION COMPLIANCE CHECK")

      unless @config.event_store
        puts "Event store not configured. Skipping retention check."
        return
      end

      events = load_events
      if events.empty?
        puts "No events to check"
        return
      end

      puts SUBSEPARATOR

      retention_status = check_retention(events)
      print_retention_table(retention_status)
      print_retention_summary(retention_status)
      print_age_distribution(events)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Access Patterns (requires event store)
    # ─────────────────────────────────────────────────────────────────────────

    def access_patterns
      print_header("PII ACCESS PATTERNS")

      unless @config.event_store
        puts "Event store not configured. Skipping access patterns."
        return
      end

      events = load_events
      if events.empty?
        puts "No events to analyze"
        return
      end

      puts SUBSEPARATOR

      print_access_by_operation(events)
      print_access_by_hour(events)
      print_recent_pii_activity(events)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Article 30 Report
    # ─────────────────────────────────────────────────────────────────────────

    def article_30_report
      print_header("GDPR ARTICLE 30 - RECORDS OF PROCESSING ACTIVITIES")

      puts <<~HEADER
        Controller: #{@config.organization}
        DPO Contact: #{@config.dpo_contact}
        Generated: #{Time.current.strftime('%Y-%m-%d')}
      HEADER

      puts SUBSEPARATOR

      return puts "No policy loaded" unless @policy

      print_processing_activities
      print_retention_schedule
      print_technical_measures
      print_article_30_gaps
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Export
    # ─────────────────────────────────────────────────────────────────────────

    def export_json(output_path)
      report = build_export_data
      File.write(output_path, JSON.pretty_generate(report))
      puts "Report exported to: #{output_path}"
      puts "File size: #{File.size(output_path)} bytes"
      output_path
    end

    def to_h
      build_export_data
    end

    private

    # ─────────────────────────────────────────────────────────────────────────
    # Output Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def puts(message = "")
      @config.output.puts(message)
    end

    def print_header(title)
      puts "\n" + SEPARATOR
      puts " #{title}"
      puts SEPARATOR
    end

    def print_footer
      puts "\n" + SEPARATOR
      puts " END OF PRIVACY REPORT"
      puts SEPARATOR + "\n"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Policy Printing
    # ─────────────────────────────────────────────────────────────────────────

    def print_fields_table
      puts "\n## PII Fields Defined\n"
      puts "| %-20s | %-15s | %-15s | %-30s |" % ["Field", "Type", "Sensitivity", "Transformations"]
      puts "|" + "-" * 22 + "|" + "-" * 17 + "|" + "-" * 17 + "|" + "-" * 32 + "|"

      @policy.fields.values.each do |field|
        transforms = field.transformations.keys.join(", ")
        transforms = "-" if transforms.empty?
        puts "| %-20s | %-15s | %-15s | %-30s |" % [
          field.name,
          field.type,
          field.sensitivity,
          truncate(transforms, 30)
        ]
      end
    end

    def print_purposes_table
      puts "\n## Processing Purposes\n"
      puts "| %-25s | %-20s | %-15s | %-30s |" % ["Purpose", "Legal Basis", "Consent Req?", "Required Fields"]
      puts "|" + "-" * 27 + "|" + "-" * 22 + "|" + "-" * 17 + "|" + "-" * 32 + "|"

      @policy.purposes.values.each do |purpose|
        required = purpose.required_fields.join(", ")
        required = "-" if required.empty?
        consent = purpose.requires_consent? ? "Yes" : "No"

        puts "| %-25s | %-20s | %-15s | %-30s |" % [
          purpose.name,
          purpose.legal_basis,
          consent,
          truncate(required, 30)
        ]
      end
    end

    def print_retention_rules
      puts "\n## Retention Rules\n"
      if @policy.retention_policy&.rules&.any?
        @policy.retention_policy.rules.each do |rule|
          puts "  #{rule.model_class}: #{format_duration(rule.duration)}"
          puts "    On expiry: #{rule.deletion_strategy}" if rule.deletion_strategy
        end
      end
      puts "  Default: #{format_duration(@policy.retention_policy&.default_duration || 7.years)}"
    end

    def print_sensitivity_breakdown
      puts "\n## Sensitivity Breakdown\n"
      sensitivity_counts = @policy.fields.values.group_by(&:sensitivity).transform_values(&:count)
      sensitivity_counts.each do |level, count|
        bar = "\u2588" * [count * 5, 40].min
        puts "  %-15s %s (%d fields)" % [level, bar, count]
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # PII Analysis Printing
    # ─────────────────────────────────────────────────────────────────────────

    def print_pii_occurrences(pii_stats, total_events)
      puts "\n## PII Field Occurrences in Events\n"
      puts "| %-25s | %-10s | %-15s | %-20s |" % ["Field", "Count", "% of Events", "Last Seen"]
      puts "|" + "-" * 27 + "|" + "-" * 12 + "|" + "-" * 17 + "|" + "-" * 22 + "|"

      pii_stats[:field_counts].sort_by { |_, v| -v[:count] }.each do |field, data|
        percentage = total_events > 0 ? ((data[:count].to_f / total_events) * 100).round(1) : 0
        last_seen = data[:last_seen]&.strftime("%Y-%m-%d %H:%M") || "N/A"

        puts "| %-25s | %10d | %14.1f%% | %-20s |" % [field, data[:count], percentage, last_seen]
      end
    end

    def print_pii_summary(pii_stats, total_events)
      puts "\n## Events with PII Summary\n"
      puts "  Events containing PII: #{pii_stats[:events_with_pii]} (#{pii_stats[:pii_percentage].round(1)}%)"
      puts "  Events without PII: #{total_events - pii_stats[:events_with_pii]}"
      puts "  Unique PII fields detected: #{pii_stats[:field_counts].keys.count}"
    end

    def print_pii_by_model(pii_stats)
      puts "\n## PII by Model\n"
      pii_stats[:by_model].sort_by { |_, v| -v }.each do |model, count|
        bar = "\u2588" * [count / 10, 30].min
        puts "  %-30s %s (%d)" % [model, bar, count]
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Retention Printing
    # ─────────────────────────────────────────────────────────────────────────

    def print_retention_table(retention_status)
      puts "\n## Retention Status by Model\n"
      puts "| %-30s | %10s | %10s | %-15s | %-10s |" % ["Model", "Total", "Expired", "Retention", "Status"]
      puts "|" + "-" * 32 + "|" + "-" * 12 + "|" + "-" * 12 + "|" + "-" * 17 + "|" + "-" * 12 + "|"

      retention_status.each do |model, data|
        status_icon = data[:status] == :compliant ? "\u2713" : "\u26A0"
        puts "| %-30s | %10d | %10d | %-15s | %-10s |" % [
          truncate(model, 30),
          data[:total],
          data[:expired],
          format_duration(data[:retention_period]),
          "#{status_icon} #{data[:status]}"
        ]
      end
    end

    def print_retention_summary(retention_status)
      expired_total = retention_status.values.sum { |v| v[:expired] }
      if expired_total > 0
        puts "\n\u26A0 ACTION REQUIRED: #{expired_total} events have exceeded retention period"
      else
        puts "\n\u2713 All events are within retention periods"
      end
    end

    def print_age_distribution(events)
      puts "\n## Event Age Distribution\n"
      age_distribution = calculate_age_distribution(events)
      age_distribution.each do |range, count|
        bar = "\u2588" * [count / 5, 40].min
        puts "  %-20s %s (%d)" % [range, bar, count]
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Access Patterns Printing
    # ─────────────────────────────────────────────────────────────────────────

    def print_access_by_operation(events)
      puts "\n## PII Access by Operation\n"
      ops = events.group_by { |e| extract_operation(e) }
      ops.each do |op, op_events|
        pii_count = op_events.count { |e| event_has_pii?(e) }
        puts "  %-15s: %5d events (%d with PII)" % [op, op_events.count, pii_count]
      end
    end

    def print_access_by_hour(events)
      puts "\n## Access by Hour (UTC)\n"
      hourly = events.group_by { |e| extract_timestamp(e)&.hour || 0 }
      (0..23).each do |hour|
        count = hourly[hour]&.count || 0
        bar = "\u2588" * [count / 2, 30].min
        puts "  %02d:00  %s (%d)" % [hour, bar, count]
      end
    end

    def print_recent_pii_activity(events)
      puts "\n## Recent PII-Related Activity (Last 7 Days)\n"
      recent = events.select do |e|
        ts = extract_timestamp(e)
        ts && ts > 7.days.ago && event_has_pii?(e)
      end

      if recent.any?
        recent.sort_by { |e| extract_timestamp(e) }.reverse.first(10).each do |event|
          ts = extract_timestamp(event)
          model = extract_model_class(event)
          op = extract_operation(event)
          puts "  #{ts&.strftime('%Y-%m-%d %H:%M')} | %-20s | %-10s" % [model, op]
        end
        puts "  ... showing last 10 of #{recent.count} events"
      else
        puts "  No PII-related events in the last 7 days"
      end
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Article 30 Printing
    # ─────────────────────────────────────────────────────────────────────────

    # The record of processing states only what the policy declares. An item
    # the policy leaves undeclared is printed as such, with the Article 30(1)
    # clause that asks for it. (This report used to print "Internal staff" as
    # every purpose's recipients, "No international transfers", a security
    # section of asserted measures, and "[Configure implementation path]"
    # under a data-subject-rights heading Article 30 does not ask for.)
    def print_processing_activities
      puts "\n## Processing Activities (Art. 30(1)(b)-(e))\n"

      @policy.purposes.values.each_with_index do |purpose, idx|
        puts "\n### #{idx + 1}. #{purpose.name.to_s.titleize}\n"
        puts "  Description:      #{purpose.description.presence || 'N/A'}"
        puts "  Legal Basis:      #{legal_basis_text(purpose.legal_basis)}"
        puts "  Data Subjects:    #{declared(purpose.data_subjects, 'c')}"
        puts "  Data Categories:  #{purpose.required_fields.join(', ')}"
        puts "  Optional Data:    #{purpose.optional_fields.join(', ')}" if purpose.optional_fields.any?
        puts "  Consent Required: #{purpose.requires_consent? ? 'Yes' : 'No'}"
        puts "  Recipients:       #{declared(purpose.recipients, 'd')}"
        puts "  Transfers:        #{transfers_text(purpose)}"
      end
    end

    # Art. 30(1)(f): the envisaged time limits for erasure, as the policy's
    # retention rules state them.
    def print_retention_schedule
      retention = @policy.retention_policy
      puts "\n## Retention (Art. 30(1)(f))\n"
      puts "  Default:          #{format_duration(retention.default_duration)}"
      retention.rules.each do |rule|
        line = "  #{rule.model_class}: #{rule.duration ? format_duration(rule.duration) : 'default'}, then #{rule.deletion_strategy}"
        overrides = rule.field_overrides.map { |field, duration| "#{field} #{format_duration(duration)}" }
        line += " (#{overrides.join(', ')})" if overrides.any?
        puts line
      end
    end

    def print_technical_measures
      puts "\n## Technical & Organisational Measures (Art. 30(1)(g))\n"
      measures = @policy.security_measures
      if measures.any?
        measures.each { |measure| puts "  • #{measure}" }
      else
        puts "  NOT DECLARED (Art. 30(1)(g)): declare them with security_measures in the policy"
      end
    end

    def print_article_30_gaps
      gaps = @policy.article_30_gaps
      puts "\n## Completeness\n"
      if gaps.empty?
        puts "  Every Article 30(1) item is declared."
      else
        puts "  #{gaps.size} item#{'s' unless gaps.size == 1} not declared:"
        gaps.each { |purpose, clause| puts "  • #{purpose ? "#{purpose}: " : ''}#{clause}" }
      end
    end

    def declared(values, clause)
      values.any? ? values.join(', ') : "NOT DECLARED (Art. 30(1)(#{clause}))"
    end

    def transfers_text(purpose)
      return "NOT DECLARED (Art. 30(1)(e))" unless purpose.transfers_declared?
      return "None" if purpose.transfers.empty?

      purpose.transfers.map { |t| "#{t[:to]} (safeguard: #{t[:safeguard]})" }.join(', ')
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Data Loading
    # ─────────────────────────────────────────────────────────────────────────

    def load_policy
      PamDsl.policy(@policy_name)
    rescue PolicyNotFoundError
      nil
    end

    def load_events
      return [] unless @config.event_store

      if @config.event_store.respond_to?(:read)
        @config.event_store.read.to_a
      elsif @config.event_store.respond_to?(:all)
        @config.event_store.all
      else
        []
      end
    rescue => e
      puts "Error loading events: #{e.message}"
      []
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Analysis Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def analyze_pii_in_events(events)
      field_counts = Hash.new { |h, k| h[k] = { count: 0, last_seen: nil } }
      events_with_pii = 0
      by_model = Hash.new(0)

      events.each do |event|
        data = extract_event_data(event)
        pii_fields = detect_pii_fields(data)

        if pii_fields.any?
          events_with_pii += 1
          model = extract_model_class(event)
          by_model[model] += 1

          pii_fields.each do |field|
            field_counts[field][:count] += 1
            ts = extract_timestamp(event)
            if ts && (field_counts[field][:last_seen].nil? || ts > field_counts[field][:last_seen])
              field_counts[field][:last_seen] = ts
            end
          end
        end
      end

      {
        field_counts: field_counts,
        events_with_pii: events_with_pii,
        pii_percentage: events.count > 0 ? (events_with_pii.to_f / events.count) * 100 : 0,
        by_model: by_model
      }
    end

    def detect_pii_fields(data)
      return [] unless data.is_a?(Hash)

      # Use policy fields if available, otherwise use common PII patterns
      if @policy
        policy_fields = @policy.fields.keys.map(&:to_s)
        data.keys.map(&:to_s).select { |key| policy_fields.include?(key) }
      else
        pii_patterns = %w[
          email firstname lastname phone address vat_number iban
          first_name last_name full_name ip_address ssn date_of_birth
          credit_card payment_method billing_address
        ]
        data.keys.map(&:to_s).select do |key|
          pii_patterns.any? { |pii| key.downcase.include?(pii.downcase) }
        end
      end
    end

    def event_has_pii?(event)
      data = extract_event_data(event)
      detect_pii_fields(data).any?
    end

    def extract_event_data(event)
      if event.respond_to?(:data)
        event.data
      elsif event.respond_to?(:payload)
        event.payload
      elsif event.is_a?(Hash)
        event[:data] || event["data"] || event
      else
        {}
      end
    end

    def extract_model_class(event)
      if event.respond_to?(:metadata) && event.metadata[:model_class]
        event.metadata[:model_class]
      elsif event.respond_to?(:event_type)
        event.event_type.to_s.gsub(/Created|Updated|Deleted|Destroyed/, "")
      else
        "Unknown"
      end
    end

    def extract_operation(event)
      if event.respond_to?(:event_type)
        type = event.event_type.to_s
        if type.include?("Created")
          :created
        elsif type.include?("Updated")
          :updated
        elsif type.include?("Deleted") || type.include?("Destroyed")
          :deleted
        else
          :other
        end
      else
        :unknown
      end
    end

    def extract_timestamp(event)
      if event.respond_to?(:metadata) && event.metadata[:timestamp]
        event.metadata[:timestamp]
      elsif event.respond_to?(:timestamp)
        event.timestamp
      elsif event.respond_to?(:created_at)
        event.created_at
      else
        nil
      end
    end

    def check_retention(events)
      events.group_by { |e| extract_model_class(e) }.transform_values do |model_events|
        model_class = extract_model_class(model_events.first)
        retention_period = get_retention_for_model(model_class)
        cutoff = Time.current - retention_period

        expired = model_events.select do |e|
          ts = extract_timestamp(e)
          ts && ts < cutoff
        end

        {
          total: model_events.count,
          expired: expired.count,
          retention_period: retention_period,
          status: expired.empty? ? :compliant : :requires_action
        }
      end
    end

    def get_retention_for_model(model_class)
      if @policy&.retention_policy
        @policy.retention_policy.duration_for(model_class) || 7.years
      else
        7.years
      end
    end

    def calculate_age_distribution(events)
      ranges = {
        "< 1 day" => 0,
        "1-7 days" => 0,
        "1-4 weeks" => 0,
        "1-3 months" => 0,
        "3-6 months" => 0,
        "6-12 months" => 0,
        "> 1 year" => 0
      }

      now = Time.current
      events.each do |event|
        ts = extract_timestamp(event)
        next unless ts

        age = now - ts
        case age
        when 0..1.day then ranges["< 1 day"] += 1
        when 1.day..7.days then ranges["1-7 days"] += 1
        when 7.days..4.weeks then ranges["1-4 weeks"] += 1
        when 4.weeks..3.months then ranges["1-3 months"] += 1
        when 3.months..6.months then ranges["3-6 months"] += 1
        when 6.months..1.year then ranges["6-12 months"] += 1
        else ranges["> 1 year"] += 1
        end
      end

      ranges
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Formatting Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def format_duration(duration)
      return "N/A" unless duration

      case duration
      when DURATION_CLASS
        if duration >= 1.year then count((duration / 1.year).to_i, "year")
        elsif duration >= 1.month then count((duration / 1.month).to_i, "month")
        elsif duration >= 1.day then count((duration / 1.day).to_i, "day")
        else count(duration.to_i, "second")
        end
      when Numeric
        count(duration / 1.year.to_i, "year")
      else
        duration.to_s
      end
    end

    def count(n, unit) = "#{n} #{n == 1 ? unit : "#{unit}s"}"

    def legal_basis_text(basis)
      case basis&.to_sym
      when :consent
        "Consent (GDPR Art. 6(1)(a))"
      when :contract
        "Contract performance (GDPR Art. 6(1)(b))"
      when :legal_obligation
        "Legal obligation (GDPR Art. 6(1)(c))"
      when :vital_interests
        "Vital interests (GDPR Art. 6(1)(d))"
      when :public_task
        "Public interest (GDPR Art. 6(1)(e))"
      when :legitimate_interests
        "Legitimate interests (GDPR Art. 6(1)(f))"
      else
        basis.to_s.titleize
      end
    end

    def truncate(str, max_length)
      str.to_s.length > max_length ? "#{str[0..max_length - 4]}..." : str.to_s
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Export Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def build_export_data
      events = @config.event_store ? load_events : []
      pii_stats = events.any? ? analyze_pii_in_events(events) : nil

      {
        generated_at: Time.current.iso8601,
        organization: @config.organization,
        policy: export_policy_data,
        events_analysis: pii_stats ? export_events_analysis(pii_stats, events.count) : nil,
        retention_status: events.any? ? export_retention_status(events) : nil,
        article_30: export_article_30_data
      }
    end

    def export_policy_data
      return nil unless @policy

      {
        name: @policy_name.to_s,
        fields: @policy.fields.values.map do |f|
          {
            name: f.name.to_s,
            type: f.type.to_s,
            sensitivity: f.sensitivity.to_s,
            transformations: f.transformations.keys.map(&:to_s)
          }
        end,
        purposes: @policy.purposes.values.map do |p|
          {
            name: p.name.to_s,
            legal_basis: p.legal_basis.to_s,
            required_fields: p.required_fields.map(&:to_s),
            requires_consent: p.requires_consent?
          }
        end
      }
    end

    def export_events_analysis(pii_stats, total_events)
      {
        total_events: total_events,
        events_with_pii: pii_stats[:events_with_pii],
        pii_percentage: pii_stats[:pii_percentage].round(2),
        field_counts: pii_stats[:field_counts].transform_values { |v| v[:count] },
        by_model: pii_stats[:by_model]
      }
    end

    def export_retention_status(events)
      check_retention(events).transform_values do |data|
        {
          total: data[:total],
          expired: data[:expired],
          retention_period_seconds: data[:retention_period].to_i,
          status: data[:status].to_s
        }
      end
    end

    def export_article_30_data
      return nil unless @policy

      {
        controller: @config.organization,
        dpo_contact: @config.dpo_contact,
        processing_activities: @policy.purposes.values.map do |p|
          {
            name: p.name.to_s,
            description: p.description,
            legal_basis: p.legal_basis.to_s,
            data_subjects: p.data_subjects,
            data_categories: p.required_fields.map(&:to_s),
            requires_consent: p.requires_consent?,
            recipients: p.recipients,
            transfers: p.transfers # nil when not declared
          }
        end,
        retention: {
          default: @policy.retention_policy.default_duration.to_i,
          rules: @policy.retention_policy.rules.map do |rule|
            { model: rule.model_class, seconds: rule.duration&.to_i, on_expiry: rule.deletion_strategy.to_s,
              fields: rule.field_overrides.transform_values(&:to_i) }
          end
        },
        security_measures: @policy.security_measures,
        not_declared: @policy.article_30_gaps.map { |purpose, clause| { purpose: purpose&.to_s, item: clause } }
      }
    end
  end
end
