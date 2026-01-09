# frozen_string_literal: true

require_relative 'export/pnml_exporter'
require_relative 'export/cpn_tools_exporter'
require_relative 'export/json_exporter'
require_relative 'export/yaml_exporter'

module PetriFlow
  # Export functionality for Petri nets and Colored Petri Nets
  # Supports multiple formats: PNML, CPN Tools XML, JSON, and YAML
  module Export
    # Export a net to the specified format
    # @param net [Core::Net, Colored::ColoredNet] The net to export
    # @param format [Symbol] The export format (:pnml, :cpn, :json, :yaml)
    # @param options [Hash] Format-specific options
    # @return [String] The exported representation
    def self.export(net, format:, **options)
      exporter = exporter_for(net, format)

      case format
      when :pnml
        exporter.to_pnml
      when :cpn, :cpn_tools
        exporter.to_cpn
      when :json
        exporter.to_json(**options)
      when :yaml, :yml
        exporter.to_yaml
      else
        raise ArgumentError, "Unknown export format: #{format}. Supported: :pnml, :cpn, :json, :yaml"
      end
    end

    # Save a net to a file in the specified format
    # @param net [Core::Net, Colored::ColoredNet] The net to export
    # @param filename [String] The output filename
    # @param format [Symbol] The export format (auto-detected from filename if not specified)
    # @param options [Hash] Format-specific options
    def self.save(net, filename, format: nil, **options)
      format ||= detect_format(filename)

      exporter = exporter_for(net, format)

      case format
      when :pnml
        exporter.save_pnml(filename)
      when :cpn, :cpn_tools
        exporter.save_cpn(filename)
      when :json
        exporter.save_json(filename, **options)
      when :yaml, :yml
        exporter.save_yaml(filename)
      else
        raise ArgumentError, "Unknown export format: #{format}"
      end

      filename
    end

    # Export a net to hash (useful for JSON/YAML serialization)
    # @param net [Core::Net, Colored::ColoredNet] The net to export
    # @return [Hash] Hash representation of the net
    def self.to_hash(net)
      JsonExporter.new(net).to_hash
    end

    # Detect format from filename extension
    # @param filename [String] The filename
    # @return [Symbol] The detected format
    def self.detect_format(filename)
      ext = File.extname(filename).downcase
      case ext
      when '.pnml', '.xml'
        # Check if filename suggests CPN Tools
        if filename.downcase.include?('cpn')
          :cpn
        else
          :pnml
        end
      when '.cpn'
        :cpn
      when '.json'
        :json
      when '.yaml', '.yml'
        :yaml
      else
        raise ArgumentError, "Cannot detect format from filename: #{filename}. " \
                             "Please specify format explicitly."
      end
    end

    # Get the appropriate exporter for a net and format
    # @param net [Core::Net, Colored::ColoredNet] The net
    # @param format [Symbol] The export format
    # @return [PnmlExporter, CpnToolsExporter, JsonExporter, YamlExporter]
    def self.exporter_for(net, format)
      case format
      when :pnml
        PnmlExporter.new(net)
      when :cpn, :cpn_tools
        CpnToolsExporter.new(net)
      when :json
        JsonExporter.new(net)
      when :yaml, :yml
        YamlExporter.new(net)
      else
        raise ArgumentError, "Unknown export format: #{format}"
      end
    end

    # List all available export formats
    # @return [Array<Symbol>] Available formats
    def self.formats
      [:pnml, :cpn, :json, :yaml]
    end

    # Get information about export formats
    # @return [Hash] Format information
    def self.format_info
      {
        pnml: {
          name: 'PNML (Petri Net Markup Language)',
          description: 'ISO/IEC 15909 standard format for Petri nets',
          extension: '.pnml',
          supports_colored: true,
          interoperability: 'High - works with many Petri net tools'
        },
        cpn: {
          name: 'CPN Tools XML',
          description: 'Native format for CPN Tools software',
          extension: '.cpn',
          supports_colored: true,
          interoperability: 'Medium - specific to CPN Tools'
        },
        json: {
          name: 'JSON',
          description: 'Human-readable, API-friendly JSON format',
          extension: '.json',
          supports_colored: true,
          interoperability: 'High - universal format'
        },
        yaml: {
          name: 'YAML',
          description: 'Most human-readable format, ideal for documentation',
          extension: '.yaml',
          supports_colored: true,
          interoperability: 'High - universal format'
        }
      }
    end
  end
end

# Convenience methods added to Net classes
module PetriFlow
  module Core
    class Net
      # Export this net to a string in the specified format
      def export(format:, **options)
        PetriFlow::Export.export(self, format: format, **options)
      end

      # Save this net to a file
      def export_to_file(filename, format: nil, **options)
        PetriFlow::Export.save(self, filename, format: format, **options)
      end

      # Export to hash
      def to_export_hash
        PetriFlow::Export.to_hash(self)
      end
    end
  end

  module Colored
    class ColoredNet
      # Export this colored net to a string in the specified format
      def export(format:, **options)
        PetriFlow::Export.export(self, format: format, **options)
      end

      # Save this colored net to a file
      def export_to_file(filename, format: nil, **options)
        PetriFlow::Export.save(self, filename, format: format, **options)
      end

      # Export to hash
      def to_export_hash
        PetriFlow::Export.to_hash(self)
      end
    end
  end
end
