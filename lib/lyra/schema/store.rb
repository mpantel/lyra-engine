# frozen_string_literal: true

module Lyra
  module Schema
    # Handles schema file persistence and versioning
    # Schemas are stored in db/lyra_schemas/ (like AR migrations)
    class Store
      DEFAULT_PATH = "db/lyra_schemas"

      class << self
        def schema_path
          return @schema_path if @schema_path

          custom_path = Lyra.config.schema_path
          base_path = custom_path || DEFAULT_PATH

          if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
            Rails.root.join(base_path)
          else
            Pathname.new(base_path)
          end
        end

        def schema_path=(path)
          @schema_path = path ? Pathname.new(path) : nil
        end

        def reset_path!
          @schema_path = nil
        end

        def ensure_directory!
          FileUtils.mkdir_p(schema_path)
        end

        # Load the current (latest) schema
        def load_current
          current_file = schema_path.join("current.yml")
          return nil unless current_file.exist?

          load_yaml(current_file)
        end

        # Load a specific version
        def load_version(version)
          file = find_version_file(version)
          return nil unless file&.exist?

          load_yaml(file)
        end

        # Save a new schema version
        def save(schema)
          ensure_directory!

          version = schema[:version]
          timestamp = Time.current.strftime("%Y%m%d%H%M%S")
          filename = "v#{version}_#{timestamp}.yml"

          file_path = schema_path.join(filename)
          file_path.write(schema.deep_stringify_keys.to_yaml)

          # Update current.yml
          update_current(filename)

          file_path
        end

        # List all schema versions
        def versions
          return [] unless schema_path.exist?

          schema_path.glob("v*.yml")
            .reject { |f| f.basename.to_s == "current.yml" }
            .map { |f| extract_version(f) }
            .compact
            .sort
        end

        def latest_version
          versions.max || 0
        end

        # Get version history with metadata
        def history
          return [] unless schema_path.exist?

          schema_path.glob("v*.yml")
            .reject { |f| f.basename.to_s == "current.yml" }
            .map do |file|
              schema = load_yaml(file)
              next nil unless schema

              {
                version: schema[:version],
                created_at: schema[:created_at],
                lyra_version: schema[:lyra_version],
                fingerprint: schema[:fingerprint],
                file: file.basename.to_s,
                models_count: schema.dig(:summary, :models_count)
              }
            end
            .compact
            .sort_by { |h| h[:version] }
        end

        # Check if any schema exists
        def exists?
          schema_path.exist? && schema_path.join("current.yml").exist?
        end

        private

        def find_version_file(version)
          return nil unless schema_path.exist?

          schema_path.glob("v#{version}_*.yml").first
        end

        def extract_version(file)
          match = file.basename.to_s.match(/^v(\d+)_/)
          match ? match[1].to_i : nil
        end

        def update_current(filename)
          current_path = schema_path.join("current.yml")
          source_path = schema_path.join(filename)

          # Use copy instead of symlink for Windows compatibility
          FileUtils.cp(source_path, current_path)
        end

        def load_yaml(file)
          YAML.safe_load(
            file.read,
            permitted_classes: [Time, Date, DateTime, Symbol, ActiveSupport::Duration],
            symbolize_names: true
          )
        rescue Psych::DisallowedClass => e
          # Fallback: try loading with unsafe_load for schema files only
          # This handles custom classes like ActiveSupport::Duration in retention_policy
          Rails.logger.debug("Lyra: Schema file contains unknown class, using unsafe load: #{e.message}") if defined?(Rails)
          begin
            YAML.unsafe_load(file.read, symbolize_names: true)
          rescue => inner_e
            Rails.logger.warn("Lyra: Failed to load schema file #{file}: #{inner_e.message}") if defined?(Rails)
            nil
          end
        rescue => e
          Rails.logger.warn("Lyra: Failed to load schema file #{file}: #{e.message}") if defined?(Rails)
          nil
        end
      end
    end
  end
end
