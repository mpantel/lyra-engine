# frozen_string_literal: true

# Rake tasks for extracting public files to lyra-engine repo
#
# Usage:
#   rake public:build          # Build lyra-engine directory
#   rake public:sync           # Sync changes to existing lyra-engine
#   rake public:init           # Initialize lyra-engine as git repo
#   rake public:clean          # Remove lyra-engine directory
#   rake public:release[tag]   # Full release workflow

require "fileutils"

namespace :public do
  LYRA_ROOT = File.expand_path("../..", __dir__)
  PUBLIC_DIR = File.join(LYRA_ROOT, "lyra-engine")

  # Files and directories to include in public release
  PUBLIC_INCLUDES = %w[
    app/
    bin/
    config/
    docs/
    examples/blog_app/
    examples/privacy_examples.rb
    examples/privacy_policy_usage.rb
    examples/usage_examples.rb
    gems/
    lib/
    test/
    .gitignore
    .ruby-version
    docker-compose.yml
    Gemfile
    Gemfile.lock
    LICENSE
    lyra.gemspec
    Rakefile
    README.md
    CHANGELOG.md
  ].freeze

  # Patterns to exclude from public release (applied after includes)
  PUBLIC_EXCLUDES = %w[
    .DS_Store
    *.log
    /coverage/
    /tmp/
    /log/
    /vendor/bundle/
    /gems/*/.bundle/
    /gems/*/coverage/
    /test/dummy/db/*.sqlite3
    /test/reports/
  ].freeze

  # Files that need sanitization (remove internal references)
  SANITIZE_FILES = %w[
    README.md
  ].freeze

  desc "Build lyra-engine directory with public files"
  task :build => :clean do
    puts "=" * 60
    puts "Building lyra-engine public release"
    puts "=" * 60

    FileUtils.mkdir_p(PUBLIC_DIR)

    PUBLIC_INCLUDES.each do |item|
      src = File.join(LYRA_ROOT, item)
      next unless File.exist?(src)

      dest = File.join(PUBLIC_DIR, item)
      if File.directory?(src)
        sync_directory_public(src, dest)
        puts "  + #{item}"
      else
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)
        puts "  + #{item}"
      end
    end

    # Create public-specific files
    create_public_readme
    create_public_gemspec

    puts ""
    puts "=" * 60
    puts "lyra-engine built successfully!"
    puts "Location: #{PUBLIC_DIR}"
    puts "=" * 60
  end

  desc "Sync changes to existing lyra-engine directory"
  task :sync do
    unless File.directory?(PUBLIC_DIR)
      puts "lyra-engine directory not found. Run 'rake public:build' first."
      exit 1
    end

    puts "Syncing changes to lyra-engine..."
    Rake::Task["public:build"].invoke
  end

  desc "Initialize lyra-engine as a git repository"
  task :init => :build do
    Dir.chdir(PUBLIC_DIR) do
      unless File.directory?(".git")
        system("git init")
        system("git add .")
        system("git commit -m 'Initial commit - Lyra Engine v#{lyra_version}'")
        puts ""
        puts "Git repository initialized."
        puts "Add remote with: git remote add origin <url>"
      else
        puts "Git repository already initialized."
      end
    end
  end

  desc "Clean lyra-engine directory"
  task :clean do
    if File.directory?(PUBLIC_DIR)
      FileUtils.rm_rf(PUBLIC_DIR)
      puts "Removed lyra-engine directory"
    end
  end

  desc "Full release workflow: build, init, tag"
  task :release, [:tag] => :init do |t, args|
    tag = args[:tag] || "v#{lyra_version}"

    Dir.chdir(PUBLIC_DIR) do
      # Stage any new changes
      system("git add .")

      # Check if there are changes to commit
      changes = `git status --porcelain`.strip
      if changes.empty?
        puts "No changes to commit."
      else
        system("git commit -m 'Release #{tag}'")
      end

      # Create tag
      system("git tag -a #{tag} -m 'Release #{tag}'")
      puts ""
      puts "=" * 60
      puts "Release #{tag} prepared!"
      puts ""
      puts "To push to remote:"
      puts "  cd lyra-engine"
      puts "  git remote add origin git@github.com:mpantel/lyra-engine.git"
      puts "  git push -u origin main"
      puts "  git push origin #{tag}"
      puts "=" * 60
    end
  end

  desc "Show what would be included in public release"
  task :preview do
    puts "Files to be included in lyra-engine:"
    puts "-" * 40

    PUBLIC_INCLUDES.each do |item|
      src = File.join(LYRA_ROOT, item)
      if File.exist?(src)
        if File.directory?(src)
          count = Dir.glob("#{src}/**/*").count { |f| File.file?(f) }
          puts "  #{item} (#{count} files)"
        else
          puts "  #{item}"
        end
      else
        puts "  #{item} (not found)"
      end
    end

    puts ""
    puts "Excluded patterns:"
    PUBLIC_EXCLUDES.each { |p| puts "  - #{p}" }
  end

  # Helper methods

  def sync_directory_public(src, dest)
    FileUtils.mkdir_p(dest)

    Dir.glob("#{src}/**/*", File::FNM_DOTMATCH).each do |path|
      next if path.end_with?(".", "..")
      next if File.directory?(path)
      next if excluded_public?(path)

      rel_path = path.sub("#{src}/", "")
      dest_path = File.join(dest, rel_path)

      FileUtils.mkdir_p(File.dirname(dest_path))
      FileUtils.cp(path, dest_path)
    end
  end

  def excluded_public?(path)
    relative = path.sub(LYRA_ROOT, "")

    PUBLIC_EXCLUDES.any? do |pattern|
      if pattern.include?("*")
        File.fnmatch(pattern, relative, File::FNM_PATHNAME)
      else
        relative.include?(pattern)
      end
    end
  end

  def lyra_version
    # Extract version from lyra.gemspec or version file
    version_file = File.join(LYRA_ROOT, "lib/lyra/version.rb")
    if File.exist?(version_file)
      content = File.read(version_file)
      if content =~ /VERSION\s*=\s*["']([^"']+)["']/
        return $1
      end
    end
    "0.6.0"
  end

  def create_public_readme
    readme_path = File.join(PUBLIC_DIR, "README.md")
    original = File.read(readme_path)

    # Remove any internal/private sections if needed
    # For now, just use the original README
    File.write(readme_path, original)
  end

  def create_public_gemspec
    # The gemspec should work as-is, but we could modify if needed
    gemspec_path = File.join(PUBLIC_DIR, "lyra.gemspec")
    return unless File.exist?(gemspec_path)

    content = File.read(gemspec_path)

    # Update homepage to public repo
    content.gsub!(
      /spec\.homepage\s*=\s*["'][^"']*["']/,
      'spec.homepage = "https://github.com/mpantel/lyra-engine"'
    )

    # Update metadata URLs
    content.gsub!(
      /github\.com\/mpantel\/lyra(?!-engine)/,
      "github.com/mpantel/lyra-engine"
    )

    File.write(gemspec_path, content)
  end
end
