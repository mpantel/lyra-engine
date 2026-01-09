# frozen_string_literal: true

namespace :lyra do
  desc "Display code statistics for Lyra and its components"
  task :stats do
    class CodeStats
      COMPONENTS = {
        "Lyra Core (lib/)" => "lib",
        "Controllers (app/)" => "app",
        "Tests (test/)" => "test",
        "PetriFlow Gem" => "gems/petri_flow",
        "PAM DSL Gem" => "gems/pam_dsl",
        "Examples" => "examples"
      }.freeze

      def initialize
        @stats = {}
      end

      def run
        print_header
        calculate_all_stats
        print_stats_table
        print_summary
      end

      private

      def print_header
        puts "\n" + "=" * 70
        puts "Lyra Code Statistics"
        puts "=" * 70
        puts "Generated: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        puts "=" * 70
      end

      def calculate_all_stats
        COMPONENTS.each do |name, path|
          next unless Dir.exist?(path)

          @stats[name] = calculate_stats(path)
        end
      end

      def calculate_stats(path)
        ruby_files = Dir.glob("#{path}/**/*.rb")

        total_lines = 0
        code_lines = 0
        comment_lines = 0
        blank_lines = 0

        ruby_files.each do |file|
          File.readlines(file).each do |line|
            total_lines += 1
            stripped = line.strip

            if stripped.empty?
              blank_lines += 1
            elsif stripped.start_with?("#")
              comment_lines += 1
            else
              code_lines += 1
            end
          end
        end

        {
          files: ruby_files.count,
          total_lines: total_lines,
          code_lines: code_lines,
          comment_lines: comment_lines,
          blank_lines: blank_lines
        }
      end

      def print_stats_table
        puts "\n%-25s %8s %10s %10s %10s %10s" % ["Component", "Files", "Total", "Code", "Comments", "Blank"]
        puts "-" * 75

        @stats.each do |name, data|
          puts "%-25s %8d %10d %10d %10d %10d" % [
            name,
            data[:files],
            data[:total_lines],
            data[:code_lines],
            data[:comment_lines],
            data[:blank_lines]
          ]
        end

        puts "-" * 75
      end

      def print_summary
        totals = @stats.values.reduce({
          files: 0, total_lines: 0, code_lines: 0, comment_lines: 0, blank_lines: 0
        }) do |sum, data|
          sum.each_key { |k| sum[k] += data[k] }
          sum
        end

        puts "%-25s %8d %10d %10d %10d %10d" % [
          "TOTAL",
          totals[:files],
          totals[:total_lines],
          totals[:code_lines],
          totals[:comment_lines],
          totals[:blank_lines]
        ]

        # Additional metrics
        puts "\n" + "=" * 70
        puts "Summary Metrics"
        puts "=" * 70

        lib_stats = @stats["Lyra Core (lib/)"] || { code_lines: 0 }
        test_stats = @stats["Tests (test/)"] || { code_lines: 0 }

        if lib_stats[:code_lines] > 0
          ratio = (test_stats[:code_lines].to_f / lib_stats[:code_lines]).round(2)
          puts "Test to Code Ratio: #{ratio}:1"
        end

        if totals[:code_lines] > 0
          comment_ratio = ((totals[:comment_lines].to_f / totals[:code_lines]) * 100).round(1)
          puts "Comment Density: #{comment_ratio}%"
        end

        puts "Total Ruby Files: #{totals[:files]}"
        puts "Total Lines of Code: #{totals[:code_lines]}"
        puts "=" * 70 + "\n\n"
      end
    end

    CodeStats.new.run
  end

  desc "Display detailed stats for a specific component"
  task :stats_detail, [:component] do |_t, args|
    component = args[:component] || "lib"

    puts "\n" + "=" * 70
    puts "Detailed Stats for: #{component}"
    puts "=" * 70

    ruby_files = Dir.glob("#{component}/**/*.rb").sort

    if ruby_files.empty?
      puts "No Ruby files found in #{component}"
      next
    end

    puts "\n%-60s %8s" % ["File", "Lines"]
    puts "-" * 70

    total = 0
    ruby_files.each do |file|
      lines = File.readlines(file).count
      total += lines
      relative_path = file.sub("#{component}/", "")
      puts "%-60s %8d" % [relative_path.truncate(60), lines]
    end

    puts "-" * 70
    puts "%-60s %8d" % ["TOTAL (#{ruby_files.count} files)", total]
    puts "=" * 70 + "\n\n"
  end
end

class String
  def truncate(max)
    length > max ? "...#{self[-(max-3)..]}" : self
  end
end
