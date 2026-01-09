# frozen_string_literal: true

namespace :lyra do
  VERSION_FILES = {
    lyra: "lib/lyra/version.rb",
    petri_flow: "gems/petri_flow/lib/petri_flow/version.rb",
    pam_dsl: "gems/pam_dsl/lib/pam_dsl/version.rb"
  }.freeze

  desc "Show current versions of all components"
  task :version do
    puts "\n" + "=" * 50
    puts "Lyra/ORFEAS Component Versions"
    puts "=" * 50

    versions = {}
    VERSION_FILES.each do |name, file|
      versions[name] = extract_version(file)
      puts "%-15s %s" % [name, versions[name]]
    end

    puts "-" * 50
    lyra_v = Gem::Version.new(versions[:lyra])
    all_valid = [:petri_flow, :pam_dsl].all? do |gem|
      Gem::Version.new(versions[gem]) <= lyra_v
    end

    if all_valid
      puts "Status: OK (Lyra >= all gem versions)"
    else
      puts "Status: WARNING (Lyra should be >= all gem versions)"
    end
    puts "=" * 50 + "\n"
  end

  desc "Set version for components. Scope: all (default), lyra, petri_flow, pam_dsl, gems"
  task :set_version, [:version, :scope] do |_t, args|
    unless args[:version]
      puts "Usage:"
      puts "  rake lyra:set_version[1.0.0]              # All components"
      puts "  rake lyra:set_version[1.0.0,lyra]         # Lyra only"
      puts "  rake lyra:set_version[1.0.0,petri_flow]   # PetriFlow + Lyra"
      puts "  rake lyra:set_version[1.0.0,pam_dsl]      # PAM DSL + Lyra"
      puts "  rake lyra:set_version[1.0.0,gems]         # Both gems + Lyra"
      exit 1
    end

    new_version = args[:version]
    scope = (args[:scope] || "all").to_sym

    unless new_version.match?(/^\d+\.\d+\.\d+$/)
      puts "Error: Version must be in format X.Y.Z (e.g., 1.0.0)"
      exit 1
    end

    # Determine which components to update
    components = case scope
                 when :all
                   [:lyra, :petri_flow, :pam_dsl]
                 when :lyra
                   [:lyra]
                 when :petri_flow
                   [:lyra, :petri_flow]
                 when :pam_dsl
                   [:lyra, :pam_dsl]
                 when :gems
                   [:lyra, :petri_flow, :pam_dsl]
                 else
                   puts "Unknown scope: #{scope}"
                   puts "Valid scopes: all, lyra, petri_flow, pam_dsl, gems"
                   exit 1
                 end

    puts "\n" + "=" * 50
    puts "Setting Version to #{new_version}"
    puts "Scope: #{scope}"
    puts "=" * 50

    # Validate: Lyra must be >= gem versions
    new_v = Gem::Version.new(new_version)
    VERSION_FILES.each do |name, file|
      next if components.include?(name)
      current_v = Gem::Version.new(extract_version(file))
      if current_v > new_v && name != :lyra
        puts "Error: Cannot set Lyra to #{new_version} - #{name} is at #{current_v}"
        puts "Lyra version must be >= all gem versions"
        exit 1
      end
    end

    components.each do |name|
      file = VERSION_FILES[name]
      old_version = extract_version(file)
      update_version_file(file, new_version)
      puts "#{name}: #{old_version} -> #{new_version}"
    end

    # Show final state
    puts "-" * 50
    puts "Final versions:"
    VERSION_FILES.each do |name, file|
      puts "  %-15s %s" % [name, extract_version(file)]
    end
    puts "=" * 50 + "\n"
  end

  desc "Bump version (major/minor/patch). Scope: all (default), lyra, petri_flow, pam_dsl, gems"
  task :bump, [:type, :scope] do |_t, args|
    type = args[:type] || "patch"
    scope = args[:scope] || "all"

    # Calculate new version based on Lyra's current version
    current = extract_version(VERSION_FILES[:lyra])
    new_version = calculate_new_version(current, type)

    # Invoke set_version with the calculated version
    Rake::Task["lyra:set_version"].invoke(new_version, scope)
  end

  private

  def extract_version(file)
    return "0.0.0" unless File.exist?(file)

    content = File.read(file)
    match = content.match(/VERSION\s*=\s*["']([^"']+)["']/)
    match ? match[1] : "0.0.0"
  end

  def calculate_new_version(current, type)
    parts = current.split(".").map(&:to_i)
    parts = [0, 0, 0] if parts.length < 3

    case type.to_s.downcase
    when "major"
      "#{parts[0] + 1}.0.0"
    when "minor"
      "#{parts[0]}.#{parts[1] + 1}.0"
    when "patch"
      "#{parts[0]}.#{parts[1]}.#{parts[2] + 1}"
    else
      if type.match?(/^\d+\.\d+\.\d+$/)
        type
      else
        puts "Unknown version type: #{type}"
        puts "Use: major, minor, patch, or a specific version (e.g., 1.0.0)"
        exit 1
      end
    end
  end

  def update_version_file(file, new_version)
    return unless File.exist?(file)

    content = File.read(file)
    updated = content.gsub(/VERSION\s*=\s*["'][^"']+["']/, "VERSION = \"#{new_version}\"")
    File.write(file, updated)
  end
end
