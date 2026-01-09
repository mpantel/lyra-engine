# frozen_string_literal: true

namespace :lyra do
  namespace :testbed do
    LYRA_TESTBED_PATH = File.expand_path("../../examples/aegean_epay_testbed", __dir__)

    desc "Run testbed tests in all Lyra modes (part of comprehensive test suite)"
    task :all_modes do
      puts "\n" + "=" * 80
      puts " TESTBED TESTS - ALL LYRA MODES"
      puts " Path: #{LYRA_TESTBED_PATH}"
      puts "=" * 80

      Dir.chdir(LYRA_TESTBED_PATH) do
        # Ensure bundle is up to date
        system("bundle check || bundle install") || raise("Bundle install failed")

        # Install required assets (pico CSS and fonts) before running tests
        puts "\n[Setup] Installing required assets..."
        system("bundle exec rails pico:update")
        system("bundle exec rake fonts:install")

        # Run the comprehensive all_modes test
        success = system("bundle exec rake lyra:test:all_modes")
        raise "Testbed tests failed in some modes" unless success
      end

      puts "\n" + "=" * 80
      puts " TESTBED TESTS PASSED IN ALL MODES"
      puts "=" * 80
    end

    desc "Run testbed tests in a specific mode (LYRA_MODE=disabled|monitor|hijack|event_sourcing)"
    task :mode do
      mode = ENV["LYRA_MODE"] || "disabled"
      projection = ENV["LYRA_PROJECTION_MODE"]

      puts "\n=== Running testbed tests in #{mode} mode ==="
      puts "    Projection mode: #{projection || 'default'}" if projection

      Dir.chdir(LYRA_TESTBED_PATH) do
        # Ensure required assets are installed
        system("bundle exec rails pico:update > /dev/null 2>&1")
        system("bundle exec rake fonts:install > /dev/null 2>&1")

        env = { "LYRA_MODE" => mode, "RAILS_ENV" => "test" }
        env["LYRA_PROJECTION_MODE"] = projection if projection

        success = system(env, "bundle exec rails test")
        raise "Testbed tests failed in #{mode} mode" unless success
      end
    end

    desc "Run testbed integration tests only"
    task :integration do
      puts "\n=== Running testbed integration tests ==="

      Dir.chdir(LYRA_TESTBED_PATH) do
        # Ensure required assets are installed
        system("bundle exec rails pico:update > /dev/null 2>&1")
        system("bundle exec rake fonts:install > /dev/null 2>&1")

        success = system("bundle exec rails test test/integration/")
        raise "Testbed integration tests failed" unless success
      end
    end
  end
end

# Helper module for running tests and collecting results
module ComprehensiveTestRunner
  LYRA_CORE_MODES = [
    { lyra_mode: "disabled", projection_mode: nil, name: "Disabled" },
    { lyra_mode: "monitor", projection_mode: nil, name: "Monitor" },
    { lyra_mode: "hijack", projection_mode: nil, name: "Hijack" },
    { lyra_mode: "event_sourcing", projection_mode: "sync", name: "ES Sync" },
    { lyra_mode: "event_sourcing", projection_mode: "async", name: "ES Async" },
    { lyra_mode: "event_sourcing", projection_mode: "disabled", name: "ES Disabled" }
  ].freeze

  TESTBED_MODES = [
    { lyra_mode: "disabled", projection_mode: nil, name: "Lyra Disabled" },
    { lyra_mode: "monitor", projection_mode: nil, name: "Monitor Mode" },
    { lyra_mode: "hijack", projection_mode: nil, name: "Hijack Mode" },
    { lyra_mode: "event_sourcing", projection_mode: "sync", name: "ES Sync" },
    { lyra_mode: "event_sourcing", projection_mode: "async", name: "ES Async" },
    { lyra_mode: "event_sourcing", projection_mode: "disabled", name: "ES Disabled" }
  ].freeze

  GEM_COMPONENTS = [
    { path: "gems/pam_dsl", name: "PAM DSL" },
    { path: "gems/petri_flow", name: "PetriFlow" }
  ].freeze

  class << self
    def run_core_tests
      require "open3"
      results = []

      LYRA_CORE_MODES.each_with_index do |config, index|
        puts "\n[#{index + 1}/#{LYRA_CORE_MODES.size}] Core tests: #{config[:name]}"
        puts "-" * 60

        env = { "LYRA_MODE" => config[:lyra_mode] }
        env["LYRA_PROJECTION_MODE"] = config[:projection_mode] if config[:projection_mode]

        config_start = Time.now
        stdout, stderr, status = Open3.capture3(env, "bundle exec rake test")
        config_duration = Time.now - config_start

        result = parse_test_output(stdout + stderr)
        result[:name] = config[:name]
        # Use parsed output for success (SimpleCov may return exit code 2 for coverage issues)
        result[:passed] = result[:tests] > 0 && result[:failures] == 0 && result[:errors] == 0
        result[:duration] = config_duration
        results << result

        print_result(result, config_duration)
      end

      results
    end

    def run_gem_tests
      require "open3"
      results = []
      lyra_root = File.expand_path("../..", __dir__)

      GEM_COMPONENTS.each_with_index do |component, index|
        puts "\n[#{index + 1}/#{GEM_COMPONENTS.size}] #{component[:name]}"
        puts "-" * 60

        gem_path = File.join(lyra_root, component[:path])

        # Use unbundled_env to use each gem's own Gemfile
        Bundler.with_unbundled_env do
          Dir.chdir(gem_path) do
            system("bundle check > /dev/null 2>&1 || bundle install > /dev/null 2>&1")

            config_start = Time.now
            stdout, stderr, status = Open3.capture3("bundle exec rake test")
            config_duration = Time.now - config_start

            result = parse_test_output(stdout + stderr)
            result[:name] = component[:name]
            # Use parsed output for success (SimpleCov may return exit code 2 for coverage issues)
            result[:passed] = result[:tests] > 0 && result[:failures] == 0 && result[:errors] == 0
            result[:duration] = config_duration
            results << result

            print_result(result, config_duration)
          end
        end
      end

      results
    end

    def run_testbed_tests
      require "open3"
      testbed_path = File.expand_path("../../examples/aegean_epay_testbed", __dir__)
      results = []

      # Use unbundled_env to avoid inheriting Lyra's bundler environment
      # The testbed has its own Gemfile with gems like prawn that Lyra doesn't have
      Bundler.with_unbundled_env do
        Dir.chdir(testbed_path) do
          system("bundle check > /dev/null 2>&1 || bundle install > /dev/null 2>&1")

          # Install required assets (pico CSS and fonts) before running tests
          puts "\n[Setup] Installing required assets..."
          system("bundle exec rails pico:update > /dev/null 2>&1")
          system("bundle exec rake fonts:install > /dev/null 2>&1")

          TESTBED_MODES.each_with_index do |config, index|
            puts "\n[#{index + 1}/#{TESTBED_MODES.size}] Testbed: #{config[:name]}"
            puts "-" * 60

            # Reset database between modes to prevent state pollution
            system("bundle exec rails db:test:prepare > /dev/null 2>&1")

            env = { "LYRA_MODE" => config[:lyra_mode], "RAILS_ENV" => "test" }
            env["LYRA_PROJECTION_MODE"] = config[:projection_mode] if config[:projection_mode]

            config_start = Time.now
            stdout, stderr, status = Open3.capture3(env, "bundle exec rails test")
            config_duration = Time.now - config_start

            result = parse_test_output(stdout + stderr)
            result[:name] = config[:name]
            # Use parsed output for success (SimpleCov may return exit code 2 for coverage issues)
            result[:passed] = result[:tests] > 0 && result[:failures] == 0 && result[:errors] == 0
            result[:duration] = config_duration
            results << result

            print_result(result, config_duration)

            # Print failure details if any
            unless result[:passed]
              output = stdout + stderr
              # Print last 100 lines to capture failure details
              puts "\n--- FAILURE OUTPUT (last 100 lines) ---"
              puts output.lines.last(100).join
              puts "--- END FAILURE OUTPUT ---\n"
            end
          end
        end
      end

      results
    end

    def run_no_pam_dsl_tests
      require "open3"
      results = []
      lyra_root = File.expand_path("../..", __dir__)

      LYRA_CORE_MODES.each_with_index do |config, index|
        puts "\n[#{index + 1}/#{LYRA_CORE_MODES.size}] #{config[:name]} (no PAM DSL)"
        puts "-" * 60

        env = {
          "LYRA_MODE" => config[:lyra_mode],
          "LYRA_DISABLE_PAM_DSL" => "true"
        }
        env["LYRA_PROJECTION_MODE"] = config[:projection_mode] if config[:projection_mode]

        config_start = Time.now
        Dir.chdir(lyra_root) do
          stdout, stderr, status = Open3.capture3(env, "bundle exec rake test")
          config_duration = Time.now - config_start

          result = parse_test_output(stdout + stderr)
          result[:name] = config[:name]
          # Use parsed output for success (SimpleCov may return exit code 2)
          result[:passed] = result[:tests] > 0 && result[:failures] == 0 && result[:errors] == 0
          result[:duration] = config_duration
          results << result

          print_result(result, config_duration)
        end
      end

      results
    end

    def parse_test_output(output)
      clean_output = output.gsub(/\e\[[0-9;]*m/, "")
      if clean_output =~ /(\d+) tests?, (\d+) assertions?, (\d+) failures?, (\d+) errors?, (\d+) skips?/
        { tests: $1.to_i, assertions: $2.to_i, failures: $3.to_i, errors: $4.to_i, skips: $5.to_i }
      else
        { tests: 0, assertions: 0, failures: 0, errors: 0, skips: 0 }
      end
    end

    def print_result(result, duration)
      status_icon = result[:passed] ? "\u2713" : "\u2717"
      status_color = result[:passed] ? "\e[32m" : "\e[31m"
      puts "#{status_color}#{status_icon}\e[0m #{result[:tests]} tests, #{result[:failures]} failures, " \
           "#{result[:errors]} errors, #{result[:skips].to_i} skips (#{duration.round(1)}s)"
    end

    def generate_report(core_results, gem_results, testbed_results, total_duration, no_pam_dsl_results: [])
      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      # Save to testbed reports folder
      reports_dir = File.expand_path("../../examples/aegean_epay_testbed/reports", __dir__)
      FileUtils.mkdir_p(reports_dir)
      report_path = File.join(reports_dir, "comprehensive_test_#{timestamp}.md")

      report = generate_markdown_report(core_results, gem_results, testbed_results, total_duration, no_pam_dsl_results: no_pam_dsl_results)
      File.write(report_path, report)

      puts "\nReport saved to: #{report_path}"
      report_path
    end

    def generate_markdown_report(core_results, gem_results, testbed_results, total_duration, no_pam_dsl_results: [])
      core_passed = core_results.count { |r| r[:passed] }
      gem_passed = gem_results.count { |r| r[:passed] }
      testbed_passed = testbed_results.count { |r| r[:passed] }
      no_pam_passed = no_pam_dsl_results.count { |r| r[:passed] }
      all_passed = core_passed == core_results.size &&
                   gem_passed == gem_results.size &&
                   testbed_passed == testbed_results.size &&
                   (no_pam_dsl_results.empty? || no_pam_passed == no_pam_dsl_results.size)

      no_pam_dsl_section = if no_pam_dsl_results.any?
        <<~SECTION

          ## Phase 4: Lyra Core Tests Without PAM DSL (All Modes)

          | Mode | Tests | Assertions | Failures | Errors | Skips | Duration | Status |
          |------|-------|------------|----------|--------|-------|----------|--------|
          #{no_pam_dsl_results.map { |r| "| #{r[:name]} | #{r[:tests]} | #{r[:assertions]} | #{r[:failures]} | #{r[:errors]} | #{r[:skips]} | #{r[:duration].round(1)}s | #{r[:passed] ? "✅" : "❌"} |" }.join("\n")}
        SECTION
      else
        ""
      end

      no_pam_summary_row = if no_pam_dsl_results.any?
        "| Lyra (no PAM DSL) | #{no_pam_passed}/#{no_pam_dsl_results.size} | #{no_pam_dsl_results.sum { |r| r[:tests] }} | #{no_pam_dsl_results.sum { |r| r[:failures] }} | #{no_pam_dsl_results.sum { |r| r[:errors] }} | #{no_pam_dsl_results.sum { |r| r[:skips] }} |"
      else
        ""
      end

      <<~REPORT
        # Comprehensive Test Report

        **Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}
        **Status:** #{all_passed ? "✅ ALL PASSED" : "❌ FAILURES DETECTED"}
        **Total Duration:** #{total_duration.round(1)}s

        ## Summary

        | Phase | Components Passed | Total Tests | Failures | Errors | Skips |
        |-------|-------------------|-------------|----------|--------|-------|
        | Lyra Core | #{core_passed}/#{core_results.size} | #{core_results.sum { |r| r[:tests] }} | #{core_results.sum { |r| r[:failures] }} | #{core_results.sum { |r| r[:errors] }} | #{core_results.sum { |r| r[:skips] }} |
        | PAM DSL & PetriFlow | #{gem_passed}/#{gem_results.size} | #{gem_results.sum { |r| r[:tests] }} | #{gem_results.sum { |r| r[:failures] }} | #{gem_results.sum { |r| r[:errors] }} | #{gem_results.sum { |r| r[:skips] }} |
        | Testbed | #{testbed_passed}/#{testbed_results.size} | #{testbed_results.sum { |r| r[:tests] }} | #{testbed_results.sum { |r| r[:failures] }} | #{testbed_results.sum { |r| r[:errors] }} | #{testbed_results.sum { |r| r[:skips] }} |
        #{no_pam_summary_row}

        ## Phase 1: Lyra Core Tests (All Modes)

        | Mode | Tests | Assertions | Failures | Errors | Skips | Duration | Status |
        |------|-------|------------|----------|--------|-------|----------|--------|
        #{core_results.map { |r| "| #{r[:name]} | #{r[:tests]} | #{r[:assertions]} | #{r[:failures]} | #{r[:errors]} | #{r[:skips]} | #{r[:duration].round(1)}s | #{r[:passed] ? "✅" : "❌"} |" }.join("\n")}

        ## Phase 2: PAM DSL & PetriFlow Tests

        | Component | Tests | Assertions | Failures | Errors | Skips | Duration | Status |
        |-----------|-------|------------|----------|--------|-------|----------|--------|
        #{gem_results.map { |r| "| #{r[:name]} | #{r[:tests]} | #{r[:assertions]} | #{r[:failures]} | #{r[:errors]} | #{r[:skips]} | #{r[:duration].round(1)}s | #{r[:passed] ? "✅" : "❌"} |" }.join("\n")}

        ## Phase 3: Testbed Tests (All Modes)

        | Mode | Tests | Assertions | Failures | Errors | Skips | Duration | Status |
        |------|-------|------------|----------|--------|-------|----------|--------|
        #{testbed_results.map { |r| "| #{r[:name]} | #{r[:tests]} | #{r[:assertions]} | #{r[:failures]} | #{r[:errors]} | #{r[:skips]} | #{r[:duration].round(1)}s | #{r[:passed] ? "✅" : "❌"} |" }.join("\n")}
        #{no_pam_dsl_section}
        ## Environment

        - **Ruby:** #{RUBY_VERSION}
        - **Rails:** #{Rails::VERSION::STRING rescue "N/A"}
        - **Platform:** #{RUBY_PLATFORM}
        - **Git Branch:** #{`git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip rescue "unknown"}
        - **Git Commit:** #{`git rev-parse --short HEAD 2>/dev/null`.strip rescue "unknown"}
      REPORT
    end
  end
end

namespace :test do
  desc "Run Lyra core tests without PAM DSL (all 6 modes)"
  task :without_pam_dsl do
    puts "\n" + "=" * 80
    puts " LYRA CORE TESTS WITHOUT PAM DSL - ALL MODES"
    puts " Environment: LYRA_DISABLE_PAM_DSL=true"
    puts "=" * 80

    require "open3"
    results = []

    ComprehensiveTestRunner::LYRA_CORE_MODES.each_with_index do |config, index|
      puts "\n[#{index + 1}/#{ComprehensiveTestRunner::LYRA_CORE_MODES.size}] #{config[:name]} (no PAM DSL)"
      puts "-" * 60

      env = {
        "LYRA_MODE" => config[:lyra_mode],
        "LYRA_DISABLE_PAM_DSL" => "true"
      }
      env["LYRA_PROJECTION_MODE"] = config[:projection_mode] if config[:projection_mode]

      config_start = Time.now
      stdout, stderr, status = Open3.capture3(env, "bundle exec rake test")
      config_duration = Time.now - config_start

      result = ComprehensiveTestRunner.parse_test_output(stdout + stderr)
      result[:name] = config[:name]
      # Use parsed output for success (SimpleCov may return exit code 2)
      result[:passed] = result[:tests] > 0 && result[:failures] == 0 && result[:errors] == 0
      result[:duration] = config_duration
      results << result

      ComprehensiveTestRunner.print_result(result, config_duration)
    end

    passed = results.count { |r| r[:passed] }
    total_duration = results.sum { |r| r[:duration] }

    puts "\n" + "=" * 80
    puts " LYRA WITHOUT PAM DSL SUMMARY: #{passed}/#{results.size} modes passed"
    puts " Total Duration: #{total_duration.round(1)}s"
    puts "=" * 80

    exit 1 if results.any? { |r| !r[:passed] }
  end

  desc "Run Lyra core tests in all modes"
  task :all_modes do
    puts "\n" + "=" * 80
    puts " LYRA CORE TESTS - ALL MODES"
    puts "=" * 80

    start_time = Time.now
    results = ComprehensiveTestRunner.run_core_tests
    total_duration = Time.now - start_time

    passed = results.count { |r| r[:passed] }
    puts "\n" + "=" * 80
    puts " LYRA CORE TESTS SUMMARY: #{passed}/#{results.size} modes passed"
    puts " Total Duration: #{total_duration.round(1)}s"
    puts "=" * 80

    exit 1 if results.any? { |r| !r[:passed] }
  end

  desc "Run comprehensive test suite (Lyra core + PAM DSL + PetriFlow + Testbed + No PAM DSL) with report"
  task :comprehensive do
    puts "\n" + "=" * 80
    puts " COMPREHENSIVE TEST SUITE"
    puts " Running: Lyra core (all modes) + PAM DSL + PetriFlow + Testbed (all modes) + No PAM DSL"
    puts "=" * 80

    start_time = Time.now
    all_passed = true

    # Phase 1: Lyra core tests
    puts "\n" + "-" * 80
    puts " PHASE 1: Lyra Core Tests (All Modes)"
    puts "-" * 80
    core_results = ComprehensiveTestRunner.run_core_tests
    all_passed = false if core_results.any? { |r| !r[:passed] }

    # Phase 2: PAM DSL & PetriFlow tests
    puts "\n" + "-" * 80
    puts " PHASE 2: PAM DSL & PetriFlow Tests"
    puts "-" * 80
    gem_results = ComprehensiveTestRunner.run_gem_tests
    all_passed = false if gem_results.any? { |r| !r[:passed] }

    # Phase 3: Testbed tests
    puts "\n" + "-" * 80
    puts " PHASE 3: Testbed Tests (All Modes)"
    puts "-" * 80
    testbed_results = ComprehensiveTestRunner.run_testbed_tests
    all_passed = false if testbed_results.any? { |r| !r[:passed] }

    # Phase 4: Lyra core tests without PAM DSL
    puts "\n" + "-" * 80
    puts " PHASE 4: Lyra Core Tests Without PAM DSL (All Modes)"
    puts "-" * 80
    no_pam_dsl_results = ComprehensiveTestRunner.run_no_pam_dsl_tests
    all_passed = false if no_pam_dsl_results.any? { |r| !r[:passed] }

    total_duration = Time.now - start_time

    # Generate report
    puts "\n" + "-" * 80
    puts " GENERATING REPORT"
    puts "-" * 80
    report_path = ComprehensiveTestRunner.generate_report(
      core_results, gem_results, testbed_results, total_duration,
      no_pam_dsl_results: no_pam_dsl_results
    )

    # Final summary
    puts "\n" + "=" * 80
    if all_passed
      puts " \e[32m✓ COMPREHENSIVE TEST SUITE PASSED\e[0m"
    else
      puts " \e[31m✗ COMPREHENSIVE TEST SUITE FAILED\e[0m"
    end
    puts " Total Duration: #{total_duration.round(1)}s"
    puts " Report: #{report_path}"
    puts "=" * 80

    exit 1 unless all_passed
  end
end
