require "bundler/setup"
require "rake/testtask"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
# load "rails/tasks/engine.rake" if File.exist?(APP_RAKEFILE)

# load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

# Load custom tasks
Dir.glob("lib/tasks/*.rake").each { |r| load r }

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end


namespace :test do
  desc "Run unit tests only (excludes controller tests)"
  Rake::TestTask.new(:unit) do |t|
    t.libs << "lib"
    t.libs << "test"
    t.test_files = FileList["test/**/*_test.rb"].exclude("test/controllers/**/*_test.rb")
    t.verbose = true
  end

  desc "Run controller tests only (requires dummy Rails app)"
  Rake::TestTask.new(:controllers) do |t|
    t.libs << "lib"
    t.libs << "test"
    t.test_files = FileList["test/controllers/**/*_test.rb"]
    t.verbose = true
  end

  desc "Run tests for all components (Lyra, PAM DSL, PetriFlow)"
  task :all do
    puts "\n=== Running Lyra tests ==="
    Rake::Task["test"].invoke

    puts "\n=== Running PAM DSL tests ==="
    Dir.chdir("gems/pam_dsl") { system("rake test") || raise("PAM DSL tests failed") }

    puts "\n=== Running PetriFlow tests ==="
    Dir.chdir("gems/petri_flow") { system("rake test") || raise("PetriFlow tests failed") }

    puts "\n=== All tests passed! ==="
  end
end

task default: :test

# =============================================================================
# Shared constants
# =============================================================================
TESTBED_DIR = File.expand_path("examples/aegean_epay_testbed", __dir__)

# =============================================================================
# Benchmark tasks
# =============================================================================
namespace :benchmark do

  desc "Run Lyra mode comparison benchmark (delegates to aegean_epay_testbed)"
  task :modes do
    # Collect all arguments after the task name
    # Usage: rake benchmark:modes -- --scales=1000,5000 --modes=disabled,monitor
    args = ARGV.drop_while { |a| a != "--" }.drop(1).join(" ")

    Dir.chdir(TESTBED_DIR) do
      # Use bundle exec with testbed's Gemfile to ensure correct dependencies
      cmd = "bundle exec ruby perf/run_mode_comparison_benchmark.rb #{args}"
      puts "Running: RAILS_ENV=test #{cmd}"
      puts "Working directory: #{TESTBED_DIR}"
      puts ""
      env = {
        "RAILS_ENV" => "test",
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }
      system(env, cmd) || exit(1)
    end

    # Prevent rake from trying to run arguments as tasks
    exit(0)
  end

  desc "Continue interrupted benchmark run"
  task :continue do
    Dir.chdir(TESTBED_DIR) do
      cmd = "bundle exec ruby perf/run_mode_comparison_benchmark.rb --continue"
      puts "Resuming benchmark from checkpoint..."
      puts "Working directory: #{TESTBED_DIR}"
      puts ""
      env = {
        "RAILS_ENV" => "test",
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }
      system(env, cmd) || exit(1)
    end
  end

  desc "Run concurrent operations benchmark (thread scaling)"
  task :concurrent do
    args = ARGV.drop_while { |a| a != "--" }.drop(1).join(" ")

    Dir.chdir(TESTBED_DIR) do
      cmd = "bundle exec ruby perf/run_concurrent_benchmark.rb #{args}"
      puts "Running: RAILS_ENV=test #{cmd}"
      puts "Working directory: #{TESTBED_DIR}"
      puts ""
      env = {
        "RAILS_ENV" => "test",
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }
      system(env, cmd) || exit(1)
    end

    exit(0)
  end

  desc "Show benchmark help"
  task :help do
    puts <<~HELP
      Lyra Benchmark Tasks
      ====================

      rake benchmark:modes      Run mode comparison benchmark (7 modes, 4 scenarios)
      rake benchmark:concurrent Run concurrent/thread scaling benchmark
      rake benchmark:continue   Resume interrupted mode comparison run
      rake benchmark:help       Show this help

      Mode Comparison (benchmark:modes):
        Compares all 7 Lyra modes across CRUD, batch, query, and mixed scenarios.
        Supports checkpoint/resume for long-running benchmarks.

        rake benchmark:modes -- --scales=1000,5000 --modes=disabled,monitor
        rake benchmark:modes -- --scenarios=crud,batch
        rake benchmark:modes -- --help

      Concurrent Benchmark (benchmark:concurrent):
        Tests throughput under concurrent load with multiple threads.

        rake benchmark:concurrent -- --threads=1,2,4,8 --operations=100
        rake benchmark:concurrent -- --modes=disabled,monitor,hijack

      Examples:
        # Quick mode comparison
        rake benchmark:modes -- --scales=100,500 --iterations=10

        # Full benchmark for paper
        rake benchmark:modes -- --scales=500,1000,5000,10000

        # Resume after interruption
        rake benchmark:continue

        # Concurrent scaling test
        rake benchmark:concurrent -- --threads=1,2,4,8,16

      Note: Ensure PostgreSQL is running before benchmarks (rake docker:start).
    HELP
  end
end

# =============================================================================
# Docker tasks for PostgreSQL container
# =============================================================================
namespace :docker do
  CONTAINER_NAME = "lyra_postgres"

  desc "Ensure PostgreSQL container is running (starts if needed)"
  task :ensure do
    running = `docker ps --filter "name=#{CONTAINER_NAME}" --format "{{.Names}}"`.strip
    if running != CONTAINER_NAME
      Rake::Task["docker:start"].invoke
    else
      # Verify it's healthy
      health = `docker inspect --format='{{.State.Health.Status}}' #{CONTAINER_NAME} 2>/dev/null`.strip
      if health != "healthy"
        print "Waiting for PostgreSQL to be healthy"
        30.times do
          health = `docker inspect --format='{{.State.Health.Status}}' #{CONTAINER_NAME} 2>/dev/null`.strip
          break if health == "healthy"
          print "."
          sleep 1
        end
        puts ""
      end
    end
  end

  desc "Start PostgreSQL container for testing and benchmarks"
  task :start do
    puts "Starting PostgreSQL container..."

    # Check if container already exists
    existing = `docker ps -a --filter "name=#{CONTAINER_NAME}" --format "{{.Names}}"`.strip

    if existing == CONTAINER_NAME
      # Container exists, check if it's running
      running = `docker ps --filter "name=#{CONTAINER_NAME}" --format "{{.Names}}"`.strip
      if running == CONTAINER_NAME
        puts "Container '#{CONTAINER_NAME}' is already running"
      else
        puts "Starting existing container..."
        system("docker start #{CONTAINER_NAME}")
        puts "Container started"
      end
    else
      # Start new container with docker-compose
      puts "Creating new container..."
      system("docker compose up -d")
    end

    # Wait for healthcheck
    print "Waiting for PostgreSQL to be ready"
    30.times do
      result = `docker inspect --format='{{.State.Health.Status}}' #{CONTAINER_NAME} 2>/dev/null`.strip
      if result == "healthy"
        puts "\nPostgreSQL is ready on port 5433"
        break
      end
      print "."
      sleep 1
    end
  end

  desc "Stop PostgreSQL container"
  task :stop do
    puts "Stopping PostgreSQL container..."
    system("docker compose down")
    puts "Container stopped"
  end

  desc "Show PostgreSQL container status"
  task :status do
    running = `docker ps --filter "name=#{CONTAINER_NAME}" --format "{{.Names}}"`.strip
    if running == CONTAINER_NAME
      puts "Container '#{CONTAINER_NAME}' is running"
      puts ""
      system("docker ps --filter 'name=#{CONTAINER_NAME}' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'")
    else
      existing = `docker ps -a --filter "name=#{CONTAINER_NAME}" --format "{{.Names}}"`.strip
      if existing == CONTAINER_NAME
        puts "Container '#{CONTAINER_NAME}' exists but is stopped"
        puts "  Run 'rake docker:start' to start it"
      else
        puts "Container '#{CONTAINER_NAME}' does not exist"
        puts "  Run 'rake docker:start' to create and start it"
      end
    end
  end

  desc "View PostgreSQL container logs"
  task :logs do
    system("docker logs #{CONTAINER_NAME} --tail 50")
  end

  desc "Remove PostgreSQL container and data volume"
  task :clean do
    puts "Stopping and removing container..."
    system("docker compose down -v")
    puts "Container and volume removed"
  end

  desc "Connect to PostgreSQL with psql"
  task :psql do
    system("docker", "exec", "-it", CONTAINER_NAME, "psql", "-U", "postgres")
  end
end

# =============================================================================
# Statistics tasks
# =============================================================================
namespace :stats do
  desc "Generate comprehensive code statistics for all components"
  task :all do
    require "json"

    puts "=" * 70
    puts "LYRA PROJECT CODE STATISTICS"
    puts "=" * 70
    puts "Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    puts "=" * 70
    puts ""

    results = {}

    # Lyra core
    puts "Analyzing Lyra core..."
    results[:lyra] = analyze_directory("lib", "test", "Lyra Core")

    # PAM DSL
    puts "Analyzing PAM DSL..."
    results[:pam_dsl] = analyze_directory("gems/pam_dsl/lib", "gems/pam_dsl/test", "PAM DSL")

    # PetriFlow
    puts "Analyzing PetriFlow..."
    results[:petri_flow] = analyze_directory("gems/petri_flow/lib", "gems/petri_flow/test", "PetriFlow")

    # Aegean E-Pay Testbed
    puts "Analyzing Aegean E-Pay Testbed..."
    results[:testbed] = analyze_rails_app("examples/aegean_epay_testbed", "Aegean E-Pay Testbed")

    puts ""

    # Print individual reports
    results.each do |key, data|
      print_component_report(data)
    end

    # Print summary
    print_summary(results)

    # Save to file
    save_report(results)
  end

  desc "Generate statistics for Lyra core only"
  task :lyra do
    result = analyze_directory("lib", "test", "Lyra Core")
    print_component_report(result)
  end

  desc "Generate statistics for PAM DSL"
  task :pam_dsl do
    result = analyze_directory("gems/pam_dsl/lib", "gems/pam_dsl/test", "PAM DSL")
    print_component_report(result)
  end

  desc "Generate statistics for PetriFlow"
  task :petri_flow do
    result = analyze_directory("gems/petri_flow/lib", "gems/petri_flow/test", "PetriFlow")
    print_component_report(result)
  end

  desc "Generate statistics for Aegean E-Pay Testbed"
  task :testbed do
    result = analyze_rails_app("examples/aegean_epay_testbed", "Aegean E-Pay Testbed")
    print_component_report(result)
  end

  # Helper methods
  def analyze_directory(lib_path, test_path, name)
    lib_stats = count_ruby_files(lib_path)
    test_stats = count_ruby_files(test_path)

    {
      name: name,
      lib_path: lib_path,
      test_path: test_path,
      code: lib_stats,
      test: test_stats,
      total_files: lib_stats[:files] + test_stats[:files],
      total_lines: lib_stats[:lines] + test_stats[:lines],
      total_loc: lib_stats[:loc] + test_stats[:loc],
      total_classes: lib_stats[:classes] + test_stats[:classes],
      total_methods: lib_stats[:methods] + test_stats[:methods],
      code_to_test_ratio: lib_stats[:loc] > 0 ? (test_stats[:loc].to_f / lib_stats[:loc]).round(2) : 0
    }
  end

  def analyze_rails_app(app_path, name)
    # Analyze different parts of the Rails app
    categories = {
      "Controllers" => "#{app_path}/app/controllers",
      "Models" => "#{app_path}/app/models",
      "Views" => "#{app_path}/app/views",
      "Helpers" => "#{app_path}/app/helpers",
      "Jobs" => "#{app_path}/app/jobs",
      "Mailers" => "#{app_path}/app/mailers",
      "Services" => "#{app_path}/app/services",
      "Repositories" => "#{app_path}/app/repositories",
      "Workflows" => "#{app_path}/app/workflows",
      "Libraries" => "#{app_path}/lib"
    }

    test_categories = {
      "Controller tests" => "#{app_path}/test/controllers",
      "Model tests" => "#{app_path}/test/models",
      "Integration tests" => "#{app_path}/test/integration",
      "System tests" => "#{app_path}/test/system",
      "Other tests" => "#{app_path}/test"
    }

    code_stats = { files: 0, lines: 0, loc: 0, classes: 0, methods: 0 }
    test_stats = { files: 0, lines: 0, loc: 0, classes: 0, methods: 0 }
    breakdown = {}

    categories.each do |category, path|
      if Dir.exist?(path)
        stats = count_ruby_files(path)
        if stats[:files] > 0
          breakdown[category] = stats
          code_stats[:files] += stats[:files]
          code_stats[:lines] += stats[:lines]
          code_stats[:loc] += stats[:loc]
          code_stats[:classes] += stats[:classes]
          code_stats[:methods] += stats[:methods]
        end
      end
    end

    test_categories.each do |category, path|
      if Dir.exist?(path)
        stats = count_ruby_files(path)
        if stats[:files] > 0
          # Avoid double-counting for "Other tests"
          if category == "Other tests"
            other_files = Dir.glob("#{path}/*_test.rb")
            stats = count_files(other_files)
          end
          if stats[:files] > 0
            breakdown[category] = stats
            test_stats[:files] += stats[:files]
            test_stats[:lines] += stats[:lines]
            test_stats[:loc] += stats[:loc]
            test_stats[:classes] += stats[:classes]
            test_stats[:methods] += stats[:methods]
          end
        end
      end
    end

    {
      name: name,
      lib_path: app_path,
      test_path: "#{app_path}/test",
      code: code_stats,
      test: test_stats,
      breakdown: breakdown,
      total_files: code_stats[:files] + test_stats[:files],
      total_lines: code_stats[:lines] + test_stats[:lines],
      total_loc: code_stats[:loc] + test_stats[:loc],
      total_classes: code_stats[:classes] + test_stats[:classes],
      total_methods: code_stats[:methods] + test_stats[:methods],
      code_to_test_ratio: code_stats[:loc] > 0 ? (test_stats[:loc].to_f / code_stats[:loc]).round(2) : 0
    }
  end

  def count_ruby_files(path)
    return { files: 0, lines: 0, loc: 0, classes: 0, methods: 0 } unless Dir.exist?(path)

    files = Dir.glob("#{path}/**/*.rb")
    count_files(files)
  end

  def count_files(files)
    stats = { files: 0, lines: 0, loc: 0, classes: 0, methods: 0 }

    files.each do |file|
      next unless File.file?(file)

      stats[:files] += 1
      content = File.read(file)
      lines = content.lines

      stats[:lines] += lines.size
      stats[:loc] += lines.count { |l| l.strip.length > 0 && !l.strip.start_with?("#") }
      stats[:classes] += content.scan(/^\s*(class|module)\s+\w+/).size
      stats[:methods] += content.scan(/^\s*def\s+\w+/).size
    end

    stats
  end

  def print_component_report(data)
    puts "-" * 70
    puts data[:name].upcase
    puts "-" * 70
    puts ""

    if data[:breakdown]
      puts "+----------------------+--------+--------+---------+---------+"
      puts "| Category             |  Files |    LOC | Classes | Methods |"
      puts "+----------------------+--------+--------+---------+---------+"

      data[:breakdown].each do |category, stats|
        printf "| %-20s | %6d | %6d | %7d | %7d |\n",
               category, stats[:files], stats[:loc], stats[:classes], stats[:methods]
      end

      puts "+----------------------+--------+--------+---------+---------+"
    end

    puts ""
    puts "  Code:  #{data[:code][:files]} files, #{data[:code][:loc]} LOC, #{data[:code][:classes]} classes, #{data[:code][:methods]} methods"
    puts "  Tests: #{data[:test][:files]} files, #{data[:test][:loc]} LOC, #{data[:test][:classes]} classes, #{data[:test][:methods]} methods"
    puts "  Total: #{data[:total_files]} files, #{data[:total_loc]} LOC"
    puts "  Code to Test Ratio: 1:#{data[:code_to_test_ratio]}"
    puts ""
  end

  def print_summary(results)
    puts "=" * 70
    puts "COMBINED SUMMARY"
    puts "=" * 70
    puts ""

    total = {
      code_files: 0, code_loc: 0, code_classes: 0, code_methods: 0,
      test_files: 0, test_loc: 0, test_classes: 0, test_methods: 0
    }

    puts "+----------------------+--------+--------+---------+---------+--------+--------+"
    puts "| Component            | C.Files| C.LOC  | Classes | Methods | T.Files| T.LOC  |"
    puts "+----------------------+--------+--------+---------+---------+--------+--------+"

    results.each do |key, data|
      printf "| %-20s | %6d | %6d | %7d | %7d | %6d | %6d |\n",
             data[:name], data[:code][:files], data[:code][:loc],
             data[:code][:classes], data[:code][:methods],
             data[:test][:files], data[:test][:loc]

      total[:code_files] += data[:code][:files]
      total[:code_loc] += data[:code][:loc]
      total[:code_classes] += data[:code][:classes]
      total[:code_methods] += data[:code][:methods]
      total[:test_files] += data[:test][:files]
      total[:test_loc] += data[:test][:loc]
    end

    puts "+----------------------+--------+--------+---------+---------+--------+--------+"
    printf "| %-20s | %6d | %6d | %7d | %7d | %6d | %6d |\n",
           "TOTAL", total[:code_files], total[:code_loc],
           total[:code_classes], total[:code_methods],
           total[:test_files], total[:test_loc]
    puts "+----------------------+--------+--------+---------+---------+--------+--------+"

    puts ""
    puts "Grand Total: #{total[:code_files] + total[:test_files]} files, #{total[:code_loc] + total[:test_loc]} LOC"
    puts "Code to Test Ratio: 1:#{(total[:test_loc].to_f / total[:code_loc]).round(2)}"
    puts ""
  end

  def save_report(results)
    require "json"
    require "fileutils"

    report_dir = "examples/aegean_epay_testbed/reports"
    FileUtils.mkdir_p(report_dir)

    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")

    # Calculate totals
    total = {
      code_files: 0, code_loc: 0, code_classes: 0, code_methods: 0,
      test_files: 0, test_loc: 0, test_classes: 0, test_methods: 0
    }
    results.each do |_, data|
      total[:code_files] += data[:code][:files]
      total[:code_loc] += data[:code][:loc]
      total[:code_classes] += data[:code][:classes]
      total[:code_methods] += data[:code][:methods]
      total[:test_files] += data[:test][:files]
      total[:test_loc] += data[:test][:loc]
    end

    # Save JSON
    json_file = "#{report_dir}/stats_#{timestamp}.json"
    File.write(json_file, JSON.pretty_generate({
      generated_at: Time.now.iso8601,
      components: results,
      totals: total
    }))

    # Save Markdown
    md_file = "#{report_dir}/stats_#{timestamp}.md"
    File.open(md_file, "w") do |f|
      f.puts "# Lyra Project Code Statistics"
      f.puts ""
      f.puts "Generated: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
      f.puts ""
      f.puts "## Summary"
      f.puts ""
      f.puts "| Component | Code Files | Code LOC | Classes | Methods | Test Files | Test LOC | Ratio |"
      f.puts "|-----------|------------|----------|---------|---------|------------|----------|-------|"

      results.each do |_, data|
        f.puts "| #{data[:name]} | #{data[:code][:files]} | #{data[:code][:loc]} | #{data[:code][:classes]} | #{data[:code][:methods]} | #{data[:test][:files]} | #{data[:test][:loc]} | 1:#{data[:code_to_test_ratio]} |"
      end

      f.puts "| **TOTAL** | **#{total[:code_files]}** | **#{total[:code_loc]}** | **#{total[:code_classes]}** | **#{total[:code_methods]}** | **#{total[:test_files]}** | **#{total[:test_loc]}** | **1:#{(total[:test_loc].to_f / total[:code_loc]).round(2)}** |"
      f.puts ""
      f.puts "## Component Details"
      f.puts ""

      results.each do |_, data|
        f.puts "### #{data[:name]}"
        f.puts ""
        f.puts "- **Code:** #{data[:code][:files]} files, #{data[:code][:loc]} LOC, #{data[:code][:classes]} classes, #{data[:code][:methods]} methods"
        f.puts "- **Tests:** #{data[:test][:files]} files, #{data[:test][:loc]} LOC"
        f.puts "- **Path:** `#{data[:lib_path]}`"
        f.puts ""

        if data[:breakdown]
          f.puts "| Category | Files | LOC | Classes | Methods |"
          f.puts "|----------|-------|-----|---------|---------|"
          data[:breakdown].each do |category, stats|
            f.puts "| #{category} | #{stats[:files]} | #{stats[:loc]} | #{stats[:classes]} | #{stats[:methods]} |"
          end
          f.puts ""
        end
      end
    end

    puts "Reports saved to:"
    puts "  - #{json_file}"
    puts "  - #{md_file}"
  end
end

# =============================================================================
# Demo tasks for running the testbed with sample data
# =============================================================================
namespace :demo do
  desc "Start demo server with sample data (seeds DB and starts Rails)"
  task :start do
    mode = ENV.fetch("LYRA_MODE", "monitor")
    port = ENV.fetch("PORT", "3000")

    Dir.chdir(TESTBED_DIR) do
      env = {
        "RAILS_ENV" => "development",
        "LYRA_MODE" => mode,
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }

      puts "=" * 60
      puts "LYRA DEMO SERVER"
      puts "=" * 60
      puts ""
      puts "Mode: #{mode}"
      puts "Port: #{port}"
      puts ""

      # Run seed script
      puts "Seeding demo data..."
      seed_script = File.join(TESTBED_DIR, "db/seeds/demo.rb")
      if File.exist?(seed_script)
        system(env, "bundle exec rails runner #{seed_script}")
        puts ""
      end

      puts "Starting server..."
      puts ""
      puts "Dashboard:   http://localhost:#{port}/lyra/dashboard"
      puts "Dual View:   http://localhost:#{port}/lyra/dashboard/compare/Registration/1"
      puts "Timeline:    http://localhost:#{port}/lyra/flow/timeline"
      puts ""
      puts "Press Ctrl+C to stop"
      puts "-" * 60

      exec(env, "bundle exec rails server -p #{port}")
    end
  end

  desc "Seed demo data only (without starting server)"
  task :seed do
    Dir.chdir(TESTBED_DIR) do
      env = {
        "RAILS_ENV" => "development",
        "LYRA_MODE" => ENV.fetch("LYRA_MODE", "monitor"),
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }

      seed_script = File.join(TESTBED_DIR, "db/seeds/demo.rb")
      if File.exist?(seed_script)
        puts "Seeding demo data..."
        system(env, "bundle exec rails runner #{seed_script}")
      else
        puts "Error: Seed script not found at #{seed_script}"
        exit 1
      end
    end
  end

  desc "Reset demo database and reseed"
  task :reset do
    Dir.chdir(TESTBED_DIR) do
      env = {
        "RAILS_ENV" => "development",
        "BUNDLE_GEMFILE" => File.join(TESTBED_DIR, "Gemfile")
      }

      puts "Resetting database..."
      system(env, "bundle exec rails db:reset")

      puts ""
      Rake::Task["demo:seed"].invoke
    end
  end

  desc "Show demo help"
  task :help do
    puts <<~HELP
      Lyra Demo Tasks
      ===============

      rake demo:start   Start demo server with sample data
      rake demo:seed    Seed demo data only
      rake demo:reset   Reset database and reseed
      rake demo:help    Show this help

      Environment Variables:
        LYRA_MODE   Set Lyra mode (default: monitor)
                    Options: disabled, monitor, hijack, es_sync, es_async, es_disabled
        PORT        Server port (default: 3000)

      Examples:
        # Start in monitor mode (default)
        rake demo:start

        # Start in event sourcing mode
        LYRA_MODE=es_sync rake demo:start

        # Start on different port
        PORT=4000 rake demo:start

      Dashboard URLs:
        http://localhost:3000/lyra/dashboard
        http://localhost:3000/lyra/dashboard/model/Registration
        http://localhost:3000/lyra/dashboard/compare/Registration/1
        http://localhost:3000/lyra/flow/timeline
    HELP
  end
end
