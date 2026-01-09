# frozen_string_literal: true

require "test_helper"

class TestExport < Minitest::Test
  def setup
    # Create a simple Petri net for testing
    @net = PetriFlow.create_net(name: "SimpleNet")
    @p1 = @net.add_place(id: :p1, name: "Place 1", initial_tokens: 2)
    @p2 = @net.add_place(id: :p2, name: "Place 2", initial_tokens: 0)
    @t1 = @net.add_transition(id: :t1, name: "Transition 1")
    @net.add_arc(source_id: :p1, target_id: :t1, weight: 1)
    @net.add_arc(source_id: :t1, target_id: :p2, weight: 1)

    # Create a colored Petri net for testing
    @colored_net = PetriFlow.create_colored_net(name: "ColoredNet")

    @colored_net.add_color(:event, attributes: {
      event_type: :string,
      user_id: :integer,
      data: :hash
    })

    @colored_net.add_colored_place(id: :event_place, name: "Events", color: :event)
    @colored_net.add_colored_transition(id: :process_event, name: "Process Event")
    @colored_net.add_colored_arc(source_id: :event_place, target_id: :process_event)
  end

  def test_export_formats_available
    formats = PetriFlow::Export.formats
    assert_includes formats, :pnml
    assert_includes formats, :cpn
    assert_includes formats, :json
    assert_includes formats, :yaml
  end

  def test_format_info
    info = PetriFlow::Export.format_info
    assert info[:pnml]
    assert info[:cpn]
    assert info[:json]
    assert info[:yaml]

    assert_equal '.pnml', info[:pnml][:extension]
    assert_equal '.cpn', info[:cpn][:extension]
    assert_equal '.json', info[:json][:extension]
    assert_equal '.yaml', info[:yaml][:extension]
  end

  def test_detect_format
    assert_equal :pnml, PetriFlow::Export.detect_format('net.pnml')
    assert_equal :pnml, PetriFlow::Export.detect_format('net.xml')
    assert_equal :cpn, PetriFlow::Export.detect_format('net_cpn.xml')
    assert_equal :cpn, PetriFlow::Export.detect_format('net.cpn')
    assert_equal :json, PetriFlow::Export.detect_format('net.json')
    assert_equal :yaml, PetriFlow::Export.detect_format('net.yaml')
    assert_equal :yaml, PetriFlow::Export.detect_format('net.yml')
  end

  def test_export_to_pnml
    pnml = PetriFlow::Export.export(@net, format: :pnml)

    assert_kind_of String, pnml
    assert pnml.include?('<?xml')
    assert pnml.include?('<pnml')
    assert pnml.include?('SimpleNet')
    assert pnml.include?('<place')
    assert pnml.include?('<transition')
    assert pnml.include?('<arc')
  end

  def test_export_colored_net_to_pnml
    pnml = PetriFlow::Export.export(@colored_net, format: :pnml)

    assert_kind_of String, pnml
    assert pnml.include?('ColoredNet')
    assert pnml.include?('highlevelnet'), "Should use high-level net type for colored nets"
  end

  def test_export_to_cpn_tools
    cpn = PetriFlow::Export.export(@net, format: :cpn)

    assert_kind_of String, cpn
    assert cpn.include?('<?xml')
    assert cpn.include?('<workspaceElements')
    assert cpn.include?('<cpnet')
    assert cpn.include?('SimpleNet')
  end

  def test_export_colored_net_to_cpn_tools
    cpn = PetriFlow::Export.export(@colored_net, format: :cpn)

    assert_kind_of String, cpn
    assert cpn.include?('ColoredNet')
    assert cpn.include?('<globbox'), "Should include global declarations"
    assert cpn.include?('<color'), "Should include color declarations"
  end

  def test_export_to_json
    json_str = PetriFlow::Export.export(@net, format: :json)

    assert_kind_of String, json_str

    # Parse to verify valid JSON
    data = JSON.parse(json_str)
    assert_equal 'SimpleNet', data['net']['name']
    assert_equal 2, data['net']['place_count']
    assert_equal 1, data['net']['transition_count']
    assert_equal 2, data['net']['arc_count']

    # Check places
    assert_equal 2, data['places'].size
    place1 = data['places'].find { |p| p['id'] == 'p1' }
    assert_equal 2, place1['tokens']
  end

  def test_export_to_json_not_pretty
    json_str = PetriFlow::Export.export(@net, format: :json, pretty: false)

    assert_kind_of String, json_str
    refute json_str.include?("\n  "), "Should not have indentation"
  end

  def test_export_colored_net_to_json
    json_str = PetriFlow::Export.export(@colored_net, format: :json)
    data = JSON.parse(json_str)

    assert_equal 'colored_petri_net', data['meta']['net_type']
    assert_equal 1, data['colors'].size
    assert_equal 'event', data['colors'][0]['name']
  end

  def test_export_to_yaml
    yaml_str = PetriFlow::Export.export(@net, format: :yaml)

    assert_kind_of String, yaml_str

    # Parse to verify valid YAML
    data = YAML.safe_load(yaml_str)
    assert_equal 'SimpleNet', data['net']['name']
    assert_equal 2, data['net']['place_count']
  end

  def test_export_colored_net_to_yaml
    yaml_str = PetriFlow::Export.export(@colored_net, format: :yaml)
    data = YAML.safe_load(yaml_str)

    assert_equal 'colored_petri_net', data['meta']['net_type']
    assert_equal 1, data['colors'].size
    assert_equal 'event', data['colors'][0]['name']
  end

  def test_export_to_hash
    hash = PetriFlow::Export.to_hash(@net)

    assert_kind_of Hash, hash
    assert hash[:meta]
    assert hash[:net]
    assert hash[:places]
    assert hash[:transitions]
    assert hash[:arcs]
  end

  def test_save_to_file
    require 'tempfile'

    Tempfile.create(['net', '.json']) do |file|
      result = PetriFlow::Export.save(@net, file.path, format: :json)

      assert_equal file.path, result
      assert File.exist?(file.path)

      # Verify content
      content = File.read(file.path)
      data = JSON.parse(content)
      assert_equal 'SimpleNet', data['net']['name']
    end
  end

  def test_save_with_auto_detect_format
    require 'tempfile'

    Tempfile.create(['net', '.yaml']) do |file|
      PetriFlow::Export.save(@net, file.path)

      content = File.read(file.path)
      data = YAML.safe_load(content)
      assert_equal 'SimpleNet', data['net']['name']
    end
  end

  def test_net_export_convenience_method
    # Test convenience methods on Net instance
    json = @net.export(format: :json)
    assert_kind_of String, json

    yaml = @net.export(format: :yaml)
    assert_kind_of String, yaml

    hash = @net.to_export_hash
    assert_kind_of Hash, hash
  end

  def test_colored_net_export_convenience_method
    # Test convenience methods on ColoredNet instance
    json = @colored_net.export(format: :json)
    assert_kind_of String, json

    pnml = @colored_net.export(format: :pnml)
    assert_kind_of String, pnml
  end

  def test_module_level_convenience_methods
    # Test PetriFlow.export
    json = PetriFlow.export(@net, format: :json)
    assert_kind_of String, json

    # Test PetriFlow.save
    require 'tempfile'
    Tempfile.create(['net', '.json']) do |file|
      PetriFlow.save(@net, file.path)
      assert File.exist?(file.path)
    end
  end

  def test_invalid_format_raises_error
    assert_raises(ArgumentError) do
      PetriFlow::Export.export(@net, format: :invalid)
    end
  end

  def test_unknown_extension_raises_error
    assert_raises(ArgumentError) do
      PetriFlow::Export.detect_format('net.unknown')
    end
  end
end
