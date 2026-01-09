# PetriFlow Export Documentation

Complete guide to exporting Petri nets and Colored Petri Nets in multiple formats.

## Table of Contents

- [Overview](#overview)
- [Supported Formats](#supported-formats)
- [Quick Start](#quick-start)
- [Export Methods](#export-methods)
- [Format Details](#format-details)
- [Examples](#examples)
- [API Reference](#api-reference)
- [Integration Guide](#integration-guide)

---

## Overview

The PetriFlow export functionality allows you to export both basic Petri nets and Colored Petri Nets (CPNs) to multiple standard and custom formats. This enables:

- **Interoperability** with other Petri net tools (PNML, CPN Tools)
- **API integration** via JSON format
- **Documentation** with human-readable YAML
- **Analysis** in external tools
- **Persistence** and version control

All export functionality is located in: `gems/petri_flow/lib/petri_flow/export/`

---

## Supported Formats

| Format | Standard | Extension | Use Case | Colored Nets |
|--------|----------|-----------|----------|--------------|
| **PNML** | ISO/IEC 15909 | `.pnml` | Interoperability with Petri net tools | ✅ Full support |
| **CPN Tools** | CPN Tools native | `.cpn` | Import into CPN Tools software | ✅ Full support |
| **JSON** | RFC 8259 | `.json` | Web APIs, data exchange | ✅ Full support |
| **YAML** | YAML 1.2 | `.yaml`, `.yml` | Human-readable documentation | ✅ Full support |

All formats support:
- Basic Petri nets (places, transitions, arcs, tokens)
- Colored Petri nets (colors, guards, arc expressions)
- Initial markings
- Metadata and statistics

---

## Quick Start

### Export to String

```ruby
require 'petri_flow'

# Create a net
net = PetriFlow.create_net(name: "MyNet")
net.add_place(id: :p1, initial_tokens: 1)
net.add_transition(id: :t1)
net.add_arc(source_id: :p1, target_id: :t1)

# Export to different formats
pnml = net.export(format: :pnml)
json = net.export(format: :json)
yaml = net.export(format: :yaml)
cpn  = net.export(format: :cpn)
```

### Save to File

```ruby
# Auto-detect format from extension
net.export_to_file('mynet.json')
net.export_to_file('mynet.yaml')
net.export_to_file('mynet.pnml')

# Or specify format explicitly
net.export_to_file('mynet.xml', format: :pnml)
net.export_to_file('mynet.xml', format: :cpn)
```

### Module-Level API

```ruby
# Alternative: use module-level methods
PetriFlow.export(net, format: :json)
PetriFlow.save(net, 'mynet.yaml')
```

---

## Export Methods

### Instance Methods (on Net objects)

```ruby
# Available on both Core::Net and Colored::ColoredNet

# Export to string
net.export(format: :json, **options)
# => String

# Save to file
net.export_to_file(filename, format: nil, **options)
# => filename (String)

# Export to hash
net.to_export_hash
# => Hash
```

### Module-Level Methods

```ruby
# PetriFlow::Export module methods

# Export to string
PetriFlow::Export.export(net, format: :json, **options)
# => String

# Save to file
PetriFlow::Export.save(net, filename, format: nil, **options)
# => filename (String)

# Export to hash
PetriFlow::Export.to_hash(net)
# => Hash

# Get format information
PetriFlow::Export.formats
# => [:pnml, :cpn, :json, :yaml]

PetriFlow::Export.format_info
# => Hash with details about each format

# Auto-detect format from filename
PetriFlow::Export.detect_format('mynet.json')
# => :json
```

### Convenience Methods

```ruby
# PetriFlow top-level convenience methods

PetriFlow.export(net, format: :json)
PetriFlow.save(net, 'mynet.yaml')
```

---

## Format Details

### PNML (Petri Net Markup Language)

**Standard:** ISO/IEC 15909
**File:** `pnml_exporter.rb`
**Best For:** Interoperability with academic and commercial Petri net tools

```ruby
pnml = net.export(format: :pnml)
net.export_to_file('model.pnml')
```

**Features:**
- Standard XML format recognized by most Petri net tools
- Two net types:
  - `ptnet` - Place/Transition nets (basic)
  - `highlevelnet` - Colored Petri nets
- Includes:
  - Places with initial markings
  - Transitions with guards
  - Arcs with weights and expressions
  - Color declarations (for CPNs)
  - Graphics positions (for layout)

**Example Output:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<pnml xmlns="http://www.pnml.org/version-2009/grammar/pnml">
  <net id="mynet" type="http://www.pnml.org/version-2009/grammar/ptnet">
    <name><text>MyNet</text></name>
    <page id="page1">
      <place id="p1">
        <name><text>Place 1</text></name>
        <initialMarking><text>2</text></initialMarking>
      </place>
      <transition id="t1">
        <name><text>Transition 1</text></name>
      </transition>
      <arc id="arc_0" source="p1" target="t1">
        <inscription><text>1</text></inscription>
      </arc>
    </page>
  </net>
</pnml>
```

**Compatible Tools:**
- GreatSPN
- Snoopy
- WoPeD
- Platform Independent Petri net Editor (PIPE)
- Many academic tools

---

### CPN Tools XML

**Standard:** CPN Tools native format
**File:** `cpn_tools_exporter.rb`
**Best For:** Analysis and simulation in CPN Tools software

```ruby
cpn = net.export(format: :cpn)
net.export_to_file('model.cpn')
```

**Features:**
- Native format for CPN Tools (University of Aarhus)
- Full support for colored Petri nets
- Includes:
  - Global color declarations (`globbox`)
  - Places with color types
  - Transitions with guard conditions
  - Arc inscriptions (expressions)
  - Graphical layout information
  - Initial markings with colored tokens

**Example Output:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<workspaceElements>
  <generator tool="PetriFlow" version="1.0" format="CPN"/>
  <cpnet>
    <globbox>
      <block id="id1">
        <color id="id2">
          <id>INT</id>
          <int/>
        </color>
      </block>
    </globbox>
    <page id="page1">
      <pageattr name="MyNet"/>
      <place id="place_1">
        <text>Place 1</text>
        <type><text>INT</text></type>
        <initmark><text>2</text></initmark>
      </place>
      <!-- ... -->
    </page>
  </cpnet>
</workspaceElements>
```

**Usage with CPN Tools:**
1. Export your net to `.cpn` format
2. Open CPN Tools
3. File → Import → Select your `.cpn` file
4. Analyze, simulate, and verify

---

### JSON

**Standard:** RFC 8259
**File:** `json_exporter.rb`
**Best For:** Web APIs, data exchange, modern applications

```ruby
# Pretty-printed (default)
json = net.export(format: :json, pretty: true)

# Compact
json = net.export(format: :json, pretty: false)

# Save
net.export_to_file('model.json')
```

**Features:**
- Clean, structured JSON format
- Human-readable when pretty-printed
- Compact option for APIs
- Full metadata included
- Statistics and analysis data
- Guard and expression metadata (names/types)

**Structure:**
```json
{
  "meta": {
    "format": "PetriFlow JSON Export",
    "version": "1.0",
    "exported_at": "2025-11-05T10:30:00Z",
    "net_type": "petri_net"
  },
  "net": {
    "name": "MyNet",
    "type": "PetriNet",
    "place_count": 2,
    "transition_count": 1,
    "arc_count": 2
  },
  "places": [
    {
      "id": "p1",
      "name": "Place 1",
      "tokens": 2,
      "capacity": "infinite"
    }
  ],
  "transitions": [
    {
      "id": "t1",
      "name": "Transition 1",
      "input_arcs": 1,
      "output_arcs": 1,
      "enabled": true
    }
  ],
  "arcs": [
    {
      "id": "arc_0",
      "source": {"id": "p1", "name": "Place 1", "type": "Place"},
      "target": {"id": "t1", "name": "Transition 1", "type": "Transition"},
      "weight": 1,
      "direction": "place_to_transition"
    }
  ],
  "marking": {
    "tokens_by_place": {"p1": 2, "p2": 0},
    "total_tokens": 2
  },
  "statistics": {
    "places": 2,
    "transitions": 1,
    "arcs": 2,
    "total_tokens": 2,
    "enabled_transitions": 1,
    "enabled_transitions_list": ["t1"],
    "deadlocked": false
  }
}
```

**Use Cases:**
- REST API responses
- Web application state
- Data exchange with JavaScript
- NoSQL database storage
- Configuration files

---

### YAML

**Standard:** YAML 1.2
**File:** `yaml_exporter.rb`
**Best For:** Human-readable documentation, configuration, version control

```ruby
yaml = net.export(format: :yaml)
net.export_to_file('model.yaml')
```

**Features:**
- Most human-readable format
- Excellent for documentation
- Git-friendly (clean diffs)
- Same structure as JSON
- Supports comments (add manually after export)

**Example Output:**
```yaml
meta:
  format: PetriFlow YAML Export
  version: '1.0'
  exported_at: '2025-11-05T10:30:00Z'
  net_type: petri_net
net:
  name: MyNet
  type: PetriNet
  place_count: 2
  transition_count: 1
  arc_count: 2
places:
  - id: p1
    name: Place 1
    tokens: 2
    capacity: infinite
transitions:
  - id: t1
    name: Transition 1
    input_arcs: 1
    output_arcs: 1
    enabled: true
arcs:
  - id: arc_0
    source:
      id: p1
      name: Place 1
      type: Place
    target:
      id: t1
      name: Transition 1
      type: Transition
    weight: 1
    direction: place_to_transition
marking:
  tokens_by_place:
    p1: 2
    p2: 0
  total_tokens: 2
statistics:
  places: 2
  transitions: 1
  arcs: 2
  total_tokens: 2
  enabled_transitions: 1
  enabled_transitions_list:
    - t1
  deadlocked: false
```

**Use Cases:**
- Documentation
- Configuration files
- Version control
- Reports
- Educational materials

---

## Examples

### Basic Petri Net

```ruby
require 'petri_flow'

# Create net
net = PetriFlow.create_net(name: "OrderProcessing")
net.add_place(id: :order_received, initial_tokens: 1)
net.add_place(id: :order_shipped, initial_tokens: 0)
net.add_transition(id: :ship_order)
net.add_arc(source_id: :order_received, target_id: :ship_order)
net.add_arc(source_id: :ship_order, target_id: :order_shipped)

# Export all formats
net.export_to_file('order.pnml')
net.export_to_file('order.cpn')
net.export_to_file('order.json')
net.export_to_file('order.yaml')
```

### Colored Petri Net

```ruby
# Create colored net
cpn = PetriFlow.create_colored_net(name: "StudentCRUD")

# Define color
cpn.add_color(:student, attributes: {
  id: :integer,
  name: :string,
  email: :string
})

# Add colored place
cpn.add_colored_place(id: :students, color: :student)

# Add transition with guard
guard = PetriFlow::Colored::Guards.field_matches(:email, /@university\.edu$/)
cpn.add_colored_transition(id: :validate_student, guard: guard)

# Add arc with expression
expr = PetriFlow::Colored::ArcExpressions.detect_pii
cpn.add_colored_arc(source_id: :students, target_id: :validate_student, expression: expr)

# Export (includes colors, guards, expressions)
cpn.export_to_file('student_crud.pnml')
cpn.export_to_file('student_crud.json')
```

### Export to Hash for API

```ruby
# Export to hash (useful for JSON API responses)
hash = net.to_export_hash

# Send as JSON API response (Rails/Sinatra/etc)
render json: hash

# Or serialize manually
json_string = JSON.generate(hash)
yaml_string = hash.to_yaml
```

### Batch Export

```ruby
# Export multiple nets
nets = [net1, net2, net3]

nets.each_with_index do |net, i|
  PetriFlow.save(net, "net_#{i}.pnml", format: :pnml)
  PetriFlow.save(net, "net_#{i}.json", format: :json)
end
```

---

## API Reference

### PetriFlow::Export Module

```ruby
module PetriFlow::Export
  # Export net to string
  def self.export(net, format:, **options)
    # Returns: String

  # Save net to file
  def self.save(net, filename, format: nil, **options)
    # Returns: filename (String)

  # Convert net to hash
  def self.to_hash(net)
    # Returns: Hash

  # List available formats
  def self.formats
    # Returns: [:pnml, :cpn, :json, :yaml]

  # Get format information
  def self.format_info
    # Returns: Hash

  # Detect format from filename
  def self.detect_format(filename)
    # Returns: Symbol (:pnml, :cpn, :json, :yaml)

  # Get exporter for format
  def self.exporter_for(net, format)
    # Returns: Exporter instance
end
```

### Net Instance Methods

```ruby
class PetriFlow::Core::Net
  # Export to string
  def export(format:, **options)
    # Returns: String

  # Save to file
  def export_to_file(filename, format: nil, **options)
    # Returns: filename

  # Export to hash
  def to_export_hash
    # Returns: Hash
end

# Same methods available on Colored::ColoredNet
```

### Options

#### JSON Export Options

```ruby
# Pretty-printed (default)
net.export(format: :json, pretty: true)

# Compact (smaller size)
net.export(format: :json, pretty: false)
```

---

## Integration Guide

### Rails Integration

```ruby
# In a controller
class PetriNetsController < ApplicationController
  def export
    @net = build_net_from_params

    respond_to do |format|
      format.json { render json: @net.to_export_hash }
      format.yaml { render plain: @net.export(format: :yaml) }
      format.xml  { render xml: @net.export(format: :pnml) }
    end
  end

  def download
    @net = build_net_from_params
    format = params[:format] || 'json'

    filename = "petri_net_#{Time.now.to_i}.#{format}"
    content = @net.export(format: format.to_sym)

    send_data content, filename: filename
  end
end
```

### Sinatra Integration

```ruby
get '/nets/:id/export.:format' do
  net = load_net(params[:id])
  format = params[:format].to_sym

  content_type format_to_mime_type(format)
  net.export(format: format)
end

def format_to_mime_type(format)
  {
    json: 'application/json',
    yaml: 'application/x-yaml',
    pnml: 'application/xml',
    cpn: 'application/xml'
  }[format]
end
```

### Background Jobs

```ruby
class ExportNetJob < ApplicationJob
  def perform(net_id, format, user_id)
    net = PetriNet.find(net_id)
    content = net.export(format: format.to_sym)

    # Save to S3, send email, etc.
    upload_to_s3("nets/#{net_id}.#{format}", content)
    notify_user(user_id, "Export complete")
  end
end
```

### Testing

```ruby
require 'minitest/autorun'
require 'petri_flow'

class TestNetExport < Minitest::Test
  def setup
    @net = PetriFlow.create_net(name: "TestNet")
    @net.add_place(id: :p1, initial_tokens: 1)
  end

  def test_export_json
    json = @net.export(format: :json)
    data = JSON.parse(json)

    assert_equal 'TestNet', data['net']['name']
    assert_equal 1, data['places'].size
  end

  def test_export_to_file
    require 'tempfile'

    Tempfile.create(['net', '.json']) do |file|
      @net.export_to_file(file.path)
      assert File.exist?(file.path)

      data = JSON.parse(File.read(file.path))
      assert_equal 'TestNet', data['net']['name']
    end
  end
end
```

---

## Running Examples

```bash
# Run the export examples
cd gems/petri_flow
ruby examples/export_example.rb

# Output will be in examples/output/
ls examples/output/
# order_processing.pnml
# order_processing.cpn
# order_processing.json
# order_processing.yaml
# student_crud.pnml
# student_crud.cpn
# student_crud.json
# student_crud.yaml
```

---

## Implementation Files

All export functionality is in: `gems/petri_flow/lib/petri_flow/export/`

| File | Class | Responsibility |
|------|-------|----------------|
| `export.rb` | `Export` (module) | Main API, format detection, convenience methods |
| `pnml_exporter.rb` | `PnmlExporter` | PNML (ISO/IEC 15909) export |
| `cpn_tools_exporter.rb` | `CpnToolsExporter` | CPN Tools XML export |
| `json_exporter.rb` | `JsonExporter` | JSON export with options |
| `yaml_exporter.rb` | `YamlExporter` | YAML export |

Tests: `gems/petri_flow/test/export/test_export.rb`

---

## Future Enhancements

Potential future additions:

1. **Import functionality** - Load nets from PNML/JSON/YAML
2. **LoLA format** - Export to LoLA low-level net analyzer format
3. **BPMN export** - Convert Petri nets to BPMN diagrams
4. **SVG export** - Direct SVG generation without GraphViz
5. **Custom templates** - User-defined export templates
6. **Streaming export** - For very large nets
7. **Compression** - Gzip/zip support for large exports

---

## Troubleshooting

### Issue: "Unknown export format"

```ruby
# Wrong:
net.export(format: :pdf)  # Not supported

# Correct:
net.export(format: :json)  # Use supported format
PetriFlow::Export.formats  # List available formats
```

### Issue: "Cannot detect format from filename"

```ruby
# Wrong:
net.export_to_file('mynet.txt')  # Unknown extension

# Correct:
net.export_to_file('mynet.txt', format: :json)  # Explicit format
net.export_to_file('mynet.json')                # Known extension
```

### Issue: Guard/Expression not exported

Guards and expressions are exported as metadata (name/type), but the actual Proc/Lambda code cannot be serialized. For import/reconstruction, you'll need to rebuild these programmatically.

---

## License

Part of the PetriFlow gem. See main LICENSE file.

## Contributing

See main CONTRIBUTING.md for guidelines.
