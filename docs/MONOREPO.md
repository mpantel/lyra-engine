# Lyra Monorepo Structure

This repository is organized as a monorepo containing Lyra and its associated gems.

## Repository Structure

```
lyra/
├── app/                      # Lyra Rails engine
├── lib/                      # Lyra core library
├── config/                   # Configuration files
│   └── privacy_policies.rb  # Privacy policy definitions
├── examples/                 # Example applications and usage
├── docs/                     # Documentation
├── gems/                     # Local gems (monorepo)
│   ├── pam_dsl/             # Privacy Attribute Matrix DSL
│   │   ├── lib/
│   │   ├── spec/
│   │   ├── docs/
│   │   └── README.md
│   └── petri_flow/          # Petri Net verification and analysis
│       ├── lib/
│       ├── spec/
│       ├── docs/
│       └── README.md
├── Gemfile                   # Monorepo Gemfile
├── lyra.gemspec             # Lyra gem specification
└── README.md                # Main README

```

## Gems in this Monorepo

### 1. Lyra (Main Gem)

**Location:** Root directory
**Purpose:** CRUD to Event Sourcing transformation engine
**Version:** See `lib/lyra/version.rb`

Lyra is a Rails engine that monitors CRUD operations and transforms them into event sourcing patterns.

### 2. PAM DSL (Privacy Attribute Matrix DSL)

**Location:** `gems/pam_dsl/`
**Purpose:** Declarative DSL for defining privacy policies using the Privacy Attribute Matrix (PAM) model
**Version:** 0.6.0

PAM DSL provides a fluent API for defining:
- PII field classifications
- Processing purposes with GDPR legal bases
- Retention policies with field-level granularity
- Consent management requirements

## Development Setup

### Installing Dependencies

```bash
# Install all dependencies including local gems
bundle install
```

The `Gemfile` automatically references the local `pam_dsl` gem:

```ruby
gem "pam_dsl", path: "gems/pam_dsl"
```

### Working with PAM DSL

When developing PAM DSL locally:

```bash
cd gems/pam_dsl

# Install dependencies
bundle install

# Run tests
bundle exec rspec

# Build gem
gem build pam_dsl.gemspec
```

### Using PAM DSL in Lyra

Lyra automatically loads PAM DSL. Define policies in `config/privacy_policies.rb`:

```ruby
PamDsl.define_policy :my_app do
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication
  end

  purpose :authentication do
    basis :contract
    requires :email
  end
end
```

Then use it in your models:

```ruby
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_app
end
```

## Testing

### Running All Tests

```bash
# From root directory
bundle exec rspec

# Run Lyra tests only
bundle exec rspec spec/

# Run PAM DSL tests only
cd gems/pam_dsl && bundle exec rspec
```

## Publishing Gems

### Publishing PAM DSL

```bash
cd gems/pam_dsl

# Update version in lib/pam_dsl/version.rb
# Update CHANGELOG.md

# Build and publish
gem build pam_dsl.gemspec
gem push pam_dsl-0.1.0.gem
```

### Publishing Lyra

```bash
# From root directory

# Update version in lib/lyra/version.rb
# Update CHANGELOG.md
# Update pam_dsl dependency version in lyra.gemspec if needed

# Build and publish
gem build lyra.gemspec
gem push lyra-X.Y.Z.gem
```

## Dependency Management

### Local Development

During local development, the `Gemfile` uses path dependencies:

```ruby
gem "pam_dsl", path: "gems/pam_dsl"
```

### Production/Published Gems

In `lyra.gemspec`, PAM DSL is referenced by version:

```ruby
spec.add_dependency "pam_dsl", "~> 0.6.0"
```

When publishing Lyra, ensure:
1. PAM DSL is published first
2. Lyra's gemspec references the correct PAM DSL version
3. Update the version constraint as needed

## Monorepo Benefits

### Advantages

1. **Atomic Changes:** Update both Lyra and PAM DSL in a single commit
2. **Simplified Development:** No need to publish PAM DSL to test Lyra changes
3. **Version Coordination:** Easy to keep dependencies in sync
4. **Shared Documentation:** All docs in one place
5. **Unified CI/CD:** Single pipeline for all gems

### Development Workflow

1. **Feature Development:**
   ```bash
   # Make changes to PAM DSL
   cd gems/pam_dsl
   # Edit files...

   # Make changes to Lyra to use new PAM DSL features
   cd ../..
   # Edit files...

   # Test integration
   bundle exec rspec
   ```

2. **Releasing:**
   ```bash
   # Release PAM DSL first if it has changes
   cd gems/pam_dsl
   # Update version, build, publish

   # Then release Lyra
   cd ../..
   # Update pam_dsl dependency version in gemspec
   # Update version, build, publish
   ```

## Examples and Documentation

### Privacy Policy Examples

See `config/privacy_policies.rb` for complete examples:
- University system policy
- E-commerce policy

### Usage Examples

See `examples/privacy_policy_usage.rb` for:
- Field access control
- Data transformation
- Consent management
- Retention policies
- Lyra integration

### Documentation

- **PAM DSL:** `gems/pam_dsl/README.md`
- **PetriFlow:** `gems/petri_flow/README.md`
- **Lyra:** `README.md`
- **Privacy Compliance:** `PRIVACY_COMPLIANCE.md`
- **Architecture:** `ARCHITECTURE.md`

## CI/CD Considerations

### Testing Strategy

```yaml
# Example .github/workflows/test.yml
jobs:
  test-pam-dsl:
    steps:
      - run: cd gems/pam_dsl && bundle exec rspec

  test-lyra:
    needs: test-pam-dsl
    steps:
      - run: bundle exec rspec
```

### Publishing Strategy

1. Publish PAM DSL when its version changes
2. Wait for it to be available on RubyGems
3. Update Lyra's dependency
4. Publish Lyra

## Contributing

When contributing to this monorepo:

1. **Make changes in appropriate gem directory**
2. **Update relevant documentation**
3. **Add/update tests**
4. **Update CHANGELOG.md in affected gems**
5. **Test integration between gems**
6. **Submit PR with all changes together**

## Troubleshooting

### PAM DSL not loading

```bash
# Ensure bundle install was run
bundle install

# Check Gemfile.lock references local path
grep pam_dsl Gemfile.lock
```

### Version conflicts

```bash
# Clear bundler cache
bundle clean --force

# Reinstall
rm Gemfile.lock
bundle install
```

### Testing integration

```bash
# From root directory
bundle exec ruby -e "require 'lyra'; require 'pam_dsl'; puts 'Success!'"
```

## License

All gems in this monorepo are released under the MIT License.

## Research Context

This monorepo is part of the ORFEAS PhD thesis on CRUD to Event Sourcing transformations and the Privacy Attribute Matrix (PAM) for privacy-aware monitoring.

## Contact

For questions or issues, please open a GitHub issue or contact the research team.

## PetriFlow Gem (`gems/petri_flow/`)

### Overview

PetriFlow is a comprehensive Petri Net and Matrix Analysis gem designed for formal modeling, analysis, visualization, and verification of event sourcing systems. It implements the theoretical models described in the research documentation.

**Location:** `gems/petri_flow/`
**Version:** 0.6.0
**Purpose:** Formal verification and analysis foundation for CRUD-to-Event mapping

### Key Features

#### Core Petri Nets
- Places, Transitions, Arcs, Tokens, Markings
- Complete Petri net execution engine
- State management and transition firing

#### Colored Petri Nets (CPNs)
- Typed tokens with structured data
- Guards for conditional transitions (privacy policies)
- Arc expressions for data transformations (CRUD-to-Event)
- Hierarchical net composition

#### Matrix Analysis
- **CRUD-Event Mapping Matrix**: Track operation-to-event mappings
- **Correlation Matrix**: Group related events by correlation ID
- **Causation Matrix**: Event causality with transitive closure
- **Data Lineage Matrix**: Field modification history (GDPR Article 15)
- **Reachability Matrix**: State space analysis

#### Formal Verification
- **Reachability Analysis**: BFS state space exploration
- **Boundedness Checking**: Token count bounds (k-bounded, safe)
- **Liveness Checking**: Deadlock detection, transition liveness levels
- **Invariant Checking**: Custom property verification

#### Simulation & Visualization
- Step-by-step and Monte Carlo simulation
- Trace recording and analysis
- GraphViz/DOT, Mermaid, and ASCII visualization

### Usage Example

```ruby
require 'petri_flow'

# Create Colored Petri Net
net = PetriFlow.create_colored_net(name: "StudentCRUD")

# Add places with token colors
net.add_colored_place(id: :crud_initiated, color: :crud_operation)
net.add_colored_place(id: :event_generated, color: :event)

# Add transition with privacy guard
consent_guard = PetriFlow::Colored::Guards.has_consent(:enrollment)
net.add_colored_transition(
  id: :generate_event,
  name: "Generate Event",
  guard: consent_guard
)

# Add arc with CRUD-to-Event transformation
crud_to_event = PetriFlow::Colored::ArcExpressions.crud_to_event(:created)
net.add_colored_arc(
  source_id: :crud_initiated,
  target_id: :generate_event,
  expression: crud_to_event
)

# Formal verification
results = PetriFlow.verify(net)
puts "Reachable states: #{results[:reachability][:total_reachable_states]}"
puts "Bounded: #{results[:boundedness][:is_bounded]}"
puts "Deadlock-free: #{results[:liveness][:deadlock_free]}"

# Matrix analysis
analyzer = PetriFlow.create_analyzer
analyzer.analyze_events(events)
report = analyzer.generate_report

# Visualization
mermaid = PetriFlow.visualize(net, format: :mermaid)
File.write("net.md", mermaid)
```

### Research Foundation

PetriFlow implements the formal models described in:
- `gems/petri_flow/docs/THEORETICAL_MODEL_PETRI_NETS.md` - Colored Petri Net formalization
- `gems/petri_flow/docs/THEORETICAL_MODEL_MATRICES.md` - Matrix analysis techniques

It provides formal verification for the CRUD-to-Event mapping framework:
> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". PCI 2022.

### Integration with Lyra

PetriFlow integrates with Lyra at multiple levels:

1. **CRUD-to-Event Mapping Verification**
   - Verify mapping completeness using matrix analysis
   - Ensure every CRUD operation generates appropriate events

2. **Privacy Policy Verification**
   - Model PAM DSL policies as Petri net guards
   - Verify no PII is processed without consent
   - Check retention policy compliance

3. **Event Flow Analysis**
   - Analyze event causality and correlation
   - Track data lineage for GDPR compliance
   - Visualize event flows

4. **State Consistency Verification**
   - Verify Event-ORM consistency in Monitor mode
   - Detect potential deadlocks in Hijack mode
   - Check custom invariants

### Example: Privacy Policy Verification

```ruby
# Model privacy policy as Petri net
net = PetriFlow.create_colored_net(name: "PrivacyCheck")

# Places
net.add_colored_place(id: :pii_collected, color: :event)
net.add_colored_place(id: :consent_granted, color: :consent)
net.add_colored_place(id: :pii_processed, color: :event)

# Transition with guard: only process PII if consent granted
guard = PetriFlow::Colored::Guard.new do |context|
  context.dig(:consent_status) == :granted
end

net.add_colored_transition(id: :process_pii, guard: guard)

# Verify invariant: PII never processed without consent
checker = PetriFlow::Verification::InvariantChecker.new(net)
checker.add_invariant("No PII without consent") do |marking|
  marking.tokens_at(:pii_processed) <= marking.tokens_at(:consent_granted)
end

results = checker.report
puts results[:summary]  # "✓ All 1 invariants hold"
```

### Running Examples

```bash
# Run CRUD mapping example
ruby gems/petri_flow/examples/crud_mapping_example.rb

# Expected output:
# - Token color definitions
# - Place and transition creation
# - CRUD-Event mapping matrix
# - ASCII and Mermaid visualizations
# - Formal verification results
# - Simulation traces
```

### Development

```bash
cd gems/petri_flow

# Install dependencies
bundle install

# Run tests (when implemented)
bundle exec rspec

# Interactive console
bundle exec rake console

# Run examples
bundle exec rake examples
```

### Future Enhancements

- Integration with Rails Event Store for live analysis
- Real-time visualization dashboard
- Performance optimizations for large state spaces
- Extended examples for different domains
- Benchmark suite for verification algorithms

