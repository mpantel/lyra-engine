# Lyra Monorepo Structure

This repository is a monorepo: the Lyra engine, its two companion gems, the
example applications that evaluate it, the benchmark archive, and the papers
and thesis built on it.

## Repository Structure

```
lyra/
├── app/                        # Rails engine: controllers, views (dashboard), workflows (generated nets)
├── bin/                        # test (all suites), run_benchmarks, rake
├── config/
│   ├── routes.rb               # engine routes
│   └── privacy_policies.rb     # two example PAM policies (not loaded automatically)
├── lib/
│   ├── lyra.rb, lyra/          # Lyra core library
│   └── tasks/                  # rake tasks
├── test/                       # Lyra's Minitest suite
│   └── dummy/                  # minimal Rails application the tests load
├── gems/
│   ├── pam_dsl/                # orfeas_pam_dsl: Privacy Attribute Matrix DSL
│   │   ├── lib/  test/  docs/  benchmark/
│   │   └── pam_dsl.gemspec, Rakefile, README.md, CHANGELOG.md
│   └── petri_flow/             # orfeas_petri_flow: Petri nets and matrix analysis
│       ├── lib/  test/  docs/  examples/
│       └── petri_flow.gemspec, Rakefile, README.md, CHANGELOG.md
├── examples/
│   ├── aegean_epay_testbed/    # Rails testbed used for the multi-mode tests and benchmarks
│   ├── bpi2017_loan_app/       # BPI Challenge 2017 loan-process replay
│   ├── solidus_case_study/     # Solidus e-commerce case study (Olist replay)
│   ├── blog_app/               # small example application
│   └── privacy_examples.rb, privacy_policy_usage.rb, usage_examples.rb
├── benchmarks/
│   ├── baselines/m4-2026-07/   # frozen archive of the July 2026 Apple M4 runs (do not edit; figures withdrawn, see PERFORMANCE.md)
│   └── runs/                   # output of bin/run_benchmarks (gitignored)
├── docs/                       # documentation (this file)
├── papers/                     # papers, the PhD thesis (papers/thesis) and the proposal (papers/proposal)
├── lyra-engine/                # gitignored: checkout of the separate public lyra-engine repository
├── Gemfile, Gemfile.lock       # monorepo Gemfile
├── lyra.gemspec                # orfeas_lyra gem specification
├── Rakefile
├── docker-compose.yml          # PostgreSQL container for tests and benchmarks (port 5433)
├── README.md, CHANGELOG.md, LICENSE
└── *.md                        # working notes (benchmarking, findings, plans)
```

`papers/` holds `paperpci2022`, `paperegovis2022`, `paperares2024`,
`paperoem`, `paperre`, `paperpoemconf`, `papertse`, `papertune`,
`papercaise`, `thesis` and `proposal`.

`lyra-engine/` is the public repository (github.com/mpantel/lyra-engine),
built from a subset of this one by `rake public:build` / `rake public:sync`
(`lib/tasks/public_release.rake`). It is ignored here and committed
separately. It leaves out the testbed, the Solidus and BPI applications,
`papers/`, `benchmarks/`, and several monorepo-only rake task files.

## Gems in this Monorepo

| Gem | Location | Entry file | Version file |
|---|---|---|---|
| `orfeas_lyra` | root | `lyra` | `lib/lyra/version.rb` (0.9.0) |
| `orfeas_pam_dsl` | `gems/pam_dsl/` | `pam_dsl` | `gems/pam_dsl/lib/pam_dsl/version.rb` (0.9.0) |
| `orfeas_petri_flow` | `gems/petri_flow/` | `petri_flow` | `gems/petri_flow/lib/petri_flow/version.rb` (0.9.0) |

`bundle exec rake gems:version` prints the current versions.

### 1. Lyra

A Rails engine that records CRUD writes as events and can move an application,
one checked step at a time, from plain ActiveRecord to event sourcing. See
[ARCHITECTURE.md](ARCHITECTURE.md) and [API_REFERENCE.md](API_REFERENCE.md).

### 2. PAM DSL (Privacy Attribute Matrix DSL)

A declarative DSL for privacy policies using the Privacy Attribute Matrix
(PAM) model:
- PII field classifications
- Processing purposes with GDPR legal bases
- Retention policies with field-level granularity
- Consent requirements

### 3. PetriFlow

Petri nets, colored Petri nets, matrix analysis, verification, simulation and
visualization; see [PetriFlow](#petriflow-gem-gemspetri_flow) below.

## Development Setup

### Installing dependencies

```bash
bundle install
```

The root `Gemfile` references the local gems by path:

```ruby
gem "orfeas_pam_dsl", path: "gems/pam_dsl"
gem "orfeas_petri_flow", path: "gems/petri_flow"
```

The gems have no Gemfile of their own; commands run inside `gems/pam_dsl` or
`gems/petri_flow` use the root bundle. An application outside this repository
names the entry files explicitly, since the gem names and entry files differ:

```ruby
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"
```

### PAM DSL and PetriFlow are optional

`lyra.gemspec` depends on neither. Lyra loads each one if it is installed
(`Lyra.pam_dsl_available?`, `Lyra.petri_flow_available?`); without PAM DSL
the privacy layer uses a null provider. `LYRA_DISABLE_PAM_DSL=true` loads Lyra
without PAM DSL even when it is installed.

### Working with PAM DSL

```bash
cd gems/pam_dsl
bundle exec rake test        # run its tests
gem build pam_dsl.gemspec    # builds orfeas_pam_dsl-<version>.gem
```

### Using PAM DSL with Lyra

Define a policy in a file the application loads at boot, such as an
initializer (`config/privacy_policies.rb` in this repository holds two
example policies, `:university_system` and `:ecommerce`; Lyra does not load
it):

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

Then attach it to models:

```ruby
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_app
end
```

The full DSL is in [gems/pam_dsl/README.md](../gems/pam_dsl/README.md); its
use in Lyra is in [API_REFERENCE.md](API_REFERENCE.md#privacy).

## Testing

Every gem uses Minitest and a `Rake::TestTask` named `test`.

```bash
bundle exec rake test:all                     # Lyra, PAM DSL, PetriFlow
bundle exec rake test                         # Lyra only (needs PostgreSQL: rake docker:start)
cd gems/pam_dsl && bundle exec rake test      # PAM DSL only
cd gems/petri_flow && bundle exec rake test   # PetriFlow only
```

See [TESTING.md](TESTING.md) for the database setup, the multi-configuration
tasks and the example application suites.

## Publishing Gems

The tasks are in `lib/tasks/gems.rake`:

```bash
bundle exec rake gems:build                      # build all three
bundle exec rake gems:build:orfeas_pam_dsl       # build one
bundle exec rake gems:push:orfeas_pam_dsl        # push one to RubyGems
bundle exec rake gems:release                    # build and push all three
bundle exec rake gems:bump:orfeas_pam_dsl:patch  # bump one gem's version
bundle exec rake gems:clean                      # remove built .gem files
```

Or by hand:

```bash
cd gems/pam_dsl
# update lib/pam_dsl/version.rb and CHANGELOG.md
gem build pam_dsl.gemspec
gem push orfeas_pam_dsl-X.Y.Z.gem

cd ../..
# update lib/lyra/version.rb and CHANGELOG.md
gem build lyra.gemspec
gem push orfeas_lyra-X.Y.Z.gem
```

Since Lyra does not depend on PAM DSL or PetriFlow, the gems can be published
in any order.

## Monorepo Benefits

1. **Atomic changes:** Lyra and the gems change in one commit
2. **Simple development:** no need to publish a gem to test Lyra against it
3. **Shared documentation and CI:** one `docs/` and one workflow
   (`.github/workflows/test.yml` runs `bundle exec rake test:all`)

### Development workflow

```bash
# change PAM DSL
cd gems/pam_dsl
# edit, then
bundle exec rake test

# change Lyra to use it
cd ../..
# edit, then
bundle exec rake test:all
```

## Examples and Documentation

### Privacy policy examples

`config/privacy_policies.rb`: a university payment system policy and an
e-commerce policy.

### Usage examples

`examples/privacy_policy_usage.rb`: field access control, transformations,
consent, retention and Lyra integration.

### Documentation

- **PAM DSL:** [gems/pam_dsl/README.md](../gems/pam_dsl/README.md)
- **PetriFlow:** [gems/petri_flow/README.md](../gems/petri_flow/README.md)
- **Lyra:** [README.md](../README.md)
- **Privacy compliance:** [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md)
- **Architecture:** [ARCHITECTURE.md](ARCHITECTURE.md)

## Contributing

1. Make changes in the appropriate gem directory
2. Update the relevant documentation
3. Add or update tests
4. Update the CHANGELOG.md of each affected gem
5. Run `bundle exec rake test:all`
6. Submit the changes together

## Troubleshooting

### PAM DSL not loading

```bash
bundle install
grep -A2 "remote: gems/pam_dsl" Gemfile.lock   # the PATH entry for orfeas_pam_dsl
```

Check also that `LYRA_DISABLE_PAM_DSL` is not set to `true`.

### Testing integration

```bash
bundle exec ruby -e "require 'lyra'; require 'pam_dsl'; puts 'Success!'"
```

## License

All gems in this monorepo are released under the MIT License.

## Research Context

This monorepo is part of the PhD thesis on CRUD to Event Sourcing
transformations and the Privacy Attribute Matrix (PAM) for privacy-aware
monitoring (`papers/thesis`). See
[ARCHITECTURE.md, About ORFEAS](ARCHITECTURE.md#about-orfeas).

## PetriFlow Gem (`gems/petri_flow/`)

### Overview

PetriFlow is a Petri net and matrix analysis gem for modeling, analyzing,
visualizing and verifying event sourcing systems.

**Location:** `gems/petri_flow/`
**Version:** 0.9.0
**Purpose:** Formal verification and analysis of the CRUD-to-event mapping

### Key Features

#### Core Petri nets
- Places, transitions, arcs, tokens, markings
- Transition firing and state management

#### Colored Petri nets
- Typed tokens with structured data
- Guards for conditional transitions (privacy policies)
- Arc expressions for data transformations (CRUD to event)

#### Matrix analysis
- **CRUD-event mapping matrix**: operation-to-event mappings
- **Correlation matrix**: events grouped by correlation id
- **Causation matrix**: event causality with transitive closure
- **Data lineage matrix**: field modification history
- **Reachability matrix**: state space analysis

#### Verification
- **Reachability analysis**: breadth-first state space exploration
- **Boundedness checking**: token bounds (k-bounded, safe)
- **Liveness checking**: deadlocks (raw, and except at terminal places), transition liveness levels
- **Invariant checking**: custom properties

#### Simulation, visualization and export
- Step-by-step and Monte Carlo simulation, trace recording
- GraphViz/DOT and Mermaid visualization
- PNML, CPN Tools, JSON and YAML export
- `PetriFlow::Workflow`, a class-level DSL for workflow nets (used by Lyra's
  verification nets)

### Usage Example

```ruby
require 'petri_flow'

# Colored Petri net
net = PetriFlow.create_colored_net(name: "StudentCRUD")

net.add_colored_place(id: :crud_initiated, color: :crud_operation)
net.add_colored_place(id: :event_generated, color: :event)

# Transition with a privacy guard
consent_guard = PetriFlow::Colored::Guards.has_consent(:enrollment)
net.add_colored_transition(id: :generate_event, name: "Generate Event", guard: consent_guard)

# Arc with a CRUD-to-event transformation
crud_to_event = PetriFlow::Colored::ArcExpressions.crud_to_event(:created)
net.add_colored_arc(source_id: :crud_initiated, target_id: :generate_event, expression: crud_to_event)

# Verification
results = PetriFlow.verify(net)
puts "Reachable states: #{results[:reachability][:total_reachable_states]}"
puts "Bounded: #{results[:boundedness][:is_bounded]}"
puts "Deadlock-free: #{results[:liveness][:deadlock_free]}"

# Matrix analysis
analyzer = PetriFlow.create_analyzer
analyzer.analyze_events(events)
report = analyzer.generate_report

# Visualization
File.write("net.md", PetriFlow.visualize(net, format: :mermaid))
```

`PetriFlow.verify(net, terminal_places: [...])` also reports
`results[:liveness][:terminates_properly]`, deadlock-freedom except at
markings that mark a terminal place.

### Research Foundation

PetriFlow implements the models described in:
- [THEORETICAL_MODEL_PETRI_NETS.md](../gems/petri_flow/docs/THEORETICAL_MODEL_PETRI_NETS.md): colored Petri net formalization
- [THEORETICAL_MODEL_MATRICES.md](../gems/petri_flow/docs/THEORETICAL_MODEL_MATRICES.md): matrix analysis

It provides formal verification for the CRUD-to-event mapping framework:
> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". PCI 2022.

### Integration with Lyra

Lyra's verification nets (`lib/lyra/verification/`) are PetriFlow workflows:
the CRUD lifecycle, one net per operation across the modes, and the
callback-bypassing writes. `Lyra.verify_mapping!` runs them, and the
dashboard's verification page shows them. See
[WORKFLOW_GENERATOR.md](WORKFLOW_GENERATOR.md).

### Example: privacy policy invariant

```ruby
net = PetriFlow.create_colored_net(name: "PrivacyCheck")

net.add_colored_place(id: :pii_collected, color: :event)
net.add_colored_place(id: :consent_granted, color: :consent)
net.add_colored_place(id: :pii_processed, color: :event)

# Only process PII if consent was granted
guard = PetriFlow::Colored::Guard.new do |context|
  context.dig(:consent_status) == :granted
end
net.add_colored_transition(id: :process_pii, guard: guard)

# Invariant: PII is never processed without consent
checker = PetriFlow::Verification::InvariantChecker.new(net)
checker.add_invariant("No PII without consent") do |marking|
  marking.tokens_at(:pii_processed) <= marking.tokens_at(:consent_granted)
end

puts checker.report[:summary]
```

### Running Examples

```bash
bundle exec ruby gems/petri_flow/examples/crud_mapping_example.rb
bundle exec ruby gems/petri_flow/examples/export_example.rb
```

### Development

```bash
cd gems/petri_flow
bundle exec rake test       # run its tests
bundle exec rake console    # IRB with petri_flow loaded
bundle exec rake examples   # run every file in examples/
```
