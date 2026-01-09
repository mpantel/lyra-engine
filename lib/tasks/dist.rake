# frozen_string_literal: true

namespace :lyra do
  desc "Create distribution zip for open science evaluation"
  task :dist do
    require "fileutils"
    require "date"

    # Read version from Lyra version file
    version = extract_lyra_version
    date_stamp = Date.today.strftime("%Y%m%d")
    dist_name = "lyra-orfeas-v#{version}-#{date_stamp}"
    dist_dir = "dist/#{dist_name}"
    zip_file = "dist/#{dist_name}.zip"

    puts "\n" + "=" * 70
    puts "Creating Lyra/ORFEAS Distribution Package"
    puts "=" * 70
    puts "Version: #{version}"
    puts "Output: #{zip_file}"
    puts "=" * 70

    # Clean previous builds
    FileUtils.rm_rf("dist")
    FileUtils.mkdir_p(dist_dir)

    # Define what to include
    includes = [
      # Core framework
      "lib",
      "app",
      "config",
      "db",

      # Gems
      "gems/petri_flow",
      "gems/pam_dsl",

      # Tests
      "test",

      # Examples (excluding aegean_epay_testbed which is large and has sensitive config)
      "examples/blog_app",
      "examples/privacy_examples.rb",

      # Documentation (markdown files only, not Jekyll site)
      "docs",

      # Root files
      "Gemfile",
      "Gemfile.lock",
      "lyra.gemspec",
      "Rakefile",
      "docker-compose.yml",
      "README.md",
      "LICENSE",
      "docs/ARCHITECTURE.md",
      "docs/GETTING_STARTED.md",
      "docs/MONOREPO.md",
      "CHANGELOG.md"
    ]

    # Define exclusions (patterns)
    exclusions = [
      # Dependency directories
      "**/vendor/**",
      "**/.bundle/**",
      "**/node_modules/**",

      # Git
      "**/.git/**",

      # Generated/temp files
      "**/tmp/**",
      "**/log/**",
      "**/coverage/**",
      "**/_site/**",
      "**/.jekyll-cache/**",
      "**/.sass-cache/**",

      # Database files
      "**/*.sqlite3",
      "**/*.sqlite3-*",

      # Log files
      "**/*.log",

      # OS files
      "**/.DS_Store",

      # Editor/debug files
      "**/.byebug_history",
      "**/.ruby-version",

      # Test outputs
      "**/test/dummy/tmp/**",
      "**/test/dummy/log/**",
      "**/test/reports/**",
      "**/test_results/**",
      "**/examples/**/tmp/**",
      "**/examples/**/log/**",
      "**/examples/**/reports/**",

      # Sensitive/internal directories
      "**/webbank_guide/**",
      "**/research/papers/**",
      "**/images/programs/**",
      "proposal/**",
      "thesis/**",
      "paper/**",
      "papertse/**"
    ]

    puts "\nCopying files..."

    includes.each do |item|
      next unless File.exist?(item)

      dest = "#{dist_dir}/#{item}"

      if File.directory?(item)
        copy_directory(item, dest, exclusions)
      else
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(item, dest)
        puts "  + #{item}"
      end
    end

    # Generate MANIFEST.txt
    puts "\nGenerating MANIFEST.txt..."
    generate_manifest(dist_dir)

    # Generate INSTALL.md
    File.write("#{dist_dir}/INSTALL.md", <<~INSTALL)
      # Lyra/ORFEAS Installation Guide

      ## Prerequisites

      - Ruby 4.0+
      - Rails 8.0+
      - Bundler
      - PostgreSQL 14+ (required for event sourcing features)

      ## Quick Start

      ```bash
      # Install dependencies
      bundle install

      # Start PostgreSQL (via Docker)
      rake docker:start

      # Run Lyra core tests
      bundle exec rake test
      ```

      ## Running Tests

      ```bash
      # Lyra core tests only
      bundle exec rake test

      # All component tests (Lyra + PetriFlow + PAM DSL)
      bundle exec rake test:all

      # Unit tests only (excludes controller tests)
      bundle exec rake test:unit

      # Controller tests only (requires Rails dummy app)
      bundle exec rake test:controllers

      # Individual gem tests
      cd gems/petri_flow && bundle exec rake test
      cd gems/pam_dsl && bundle exec rake test
      ```

      ## Running Example Application

      ### Blog App (Simple Example)

      ```bash
      cd examples/blog_app
      bundle install
      rails db:create db:migrate db:seed
      rails console
      ```

      ## Documentation

      Documentation is available in the `docs/` directory as Markdown files:

      - `docs/API_REFERENCE.md` - API documentation
      - `gems/petri_flow/docs/PETRIFLOW_EXPORT.md` - PetriFlow export formats
      - `docs/PRIVACY_COMPLIANCE_VALIDATION.md` - Privacy compliance

      ## Gem Dependencies

      If you need to rebuild gem dependencies:

      ```bash
      # Main project
      bundle install

      # PetriFlow gem
      cd gems/petri_flow && bundle install

      # PAM DSL gem
      cd gems/pam_dsl && bundle install
      ```

      ## PostgreSQL Setup

      The project includes a Docker Compose file for PostgreSQL:

      ```bash
      # Start PostgreSQL container (port 5433)
      rake docker:start

      # Check status
      rake docker:status

      # Stop container
      rake docker:stop
      ```

      Or install PostgreSQL natively and configure `config/database.yml`.

      ## Troubleshooting

      ### Native extension errors
      Some gems require native extensions. On macOS:
      ```bash
      xcode-select --install
      ```

      ### PostgreSQL connection errors
      Ensure PostgreSQL is running on port 5433 (Docker) or 5432 (native).

      ## License

      MIT License - see LICENSE file.
    INSTALL
    puts "  + INSTALL.md"

    # Generate VERSION.txt
    File.write("#{dist_dir}/VERSION.txt", <<~VERSION)
      Lyra/ORFEAS Framework
      Version: #{version}
      Date: #{Date.today}

      CRUD to Event Sourcing Transformation Engine
      Part of the ORFEAS (Object-Relational to Event-Sourcing Architecture) Framework

      Author: Michail Pantelelis (mpantel@aegean.gr)
      Institution: University of the Aegean

      License: MIT
    VERSION
    puts "  + VERSION.txt"

    # Create zip
    puts "\nCreating zip archive..."
    Dir.chdir("dist") do
      system("zip -rq #{dist_name}.zip #{dist_name}")
    end

    # Calculate size
    zip_size = File.size(zip_file)
    zip_size_mb = (zip_size / 1024.0 / 1024.0).round(2)

    # Count files
    file_count = Dir.glob("#{dist_dir}/**/*", File::FNM_DOTMATCH).count { |f| File.file?(f) }

    puts "\n" + "=" * 70
    puts "Distribution Package Created Successfully"
    puts "=" * 70
    puts "Output: #{zip_file}"
    puts "Size: #{zip_size_mb} MB"
    puts "Files: #{file_count}"
    puts "=" * 70
    puts "\nTo extract: unzip #{zip_file}"
    puts "=" * 70 + "\n\n"
  end

  desc "List contents of distribution (dry run)"
  task :dist_list do
    includes = %w[lib app config db gems/petri_flow gems/pam_dsl test examples/blog_app docs]

    exclusions = %w[vendor .bundle .git node_modules tmp log coverage _site .jekyll-cache reports]

    puts "\n" + "=" * 70
    puts "Distribution Contents (Dry Run)"
    puts "=" * 70

    total_files = 0
    total_size = 0

    includes.each do |dir|
      next unless Dir.exist?(dir)

      files = Dir.glob("#{dir}/**/*").select do |f|
        File.file?(f) && exclusions.none? { |ex| f.include?("/#{ex}/") }
      end

      size = files.sum { |f| File.size(f) }
      total_files += files.count
      total_size += size

      puts "%-30s %6d files  %8.2f MB" % [dir, files.count, size / 1024.0 / 1024.0]
    end

    puts "-" * 70
    puts "%-30s %6d files  %8.2f MB" % ["TOTAL", total_files, total_size / 1024.0 / 1024.0]
    puts "=" * 70 + "\n\n"
  end

  private

  def extract_lyra_version
    version_file = "lib/lyra/version.rb"
    return "0.0.0" unless File.exist?(version_file)

    content = File.read(version_file)
    match = content.match(/VERSION\s*=\s*["']([^"']+)["']/)
    match ? match[1] : "0.0.0"
  end

  def copy_directory(src, dest, exclusions)
    Dir.glob("#{src}/**/*", File::FNM_DOTMATCH).each do |file|
      next if File.directory?(file)
      next if file.end_with?("/.", "/..")

      # Check exclusions - match against full path and path segments
      excluded = exclusions.any? do |pattern|
        File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          file.include?("/_site/") ||
          file.include?("/vendor/") ||
          file.include?("/.bundle/") ||
          file.include?("/node_modules/") ||
          file.include?("/tmp/") ||
          file.include?("/log/") ||
          file.include?("/coverage/") ||
          file.include?("/.git/") ||
          file.include?("/.jekyll-cache/") ||
          file.include?("/.sass-cache/") ||
          file.include?("/test/reports/") ||
          file.include?("/test_results/") ||
          file.include?("/reports/") ||
          file.include?("/webbank_guide/") ||
          file.include?("/research/papers/") ||
          file.include?("/images/programs/") ||
          file.start_with?("proposal/") ||
          file.start_with?("thesis/") ||
          file.start_with?("paper/") ||
          file.start_with?("papertse/") ||
          file.end_with?(".sqlite3") ||
          file.end_with?(".log")
      end
      next if excluded

      relative = file.sub("#{src}/", "")
      dest_file = "#{dest}/#{relative}"

      FileUtils.mkdir_p(File.dirname(dest_file))
      FileUtils.cp(file, dest_file)
    end
    puts "  + #{src}/"
  end

  def generate_manifest(dist_dir)
    files = Dir.glob("#{dist_dir}/**/*", File::FNM_DOTMATCH)
               .select { |f| File.file?(f) }
               .map { |f| f.sub("#{dist_dir}/", "") }
               .sort

    manifest_content = <<~HEADER
      LYRA/ORFEAS DISTRIBUTION MANIFEST
      ==================================
      Generated: #{Time.now}
      Total Files: #{files.count}

      FILES:
      ------
    HEADER

    manifest_content += files.join("\n")

    File.write("#{dist_dir}/MANIFEST.txt", manifest_content)
  end
end
