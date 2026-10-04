# Changelog

All notable changes to the PetriFlow gem will be documented in this file.

## [Unreleased]

### Added
- **Terminal-aware deadlock-freedom** — `PetriFlow.verify` and `Verification::LivenessChecker`
  take `terminal_places:`. The liveness report adds `terminal_places`, `terminates_properly`
  (no reachable dead marking outside the terminal places) and `improper_dead_markings` (the
  count of those that remain). The raw `deadlock_free`, which counts the intended end of a net
  as a deadlock, is unchanged. `Workflow#verify!` now passes the workflow's `terminal_places`.
  First liveness tests for the gem.

### Fixed
- **Undeclared `rexml` dependency** — the PNML and CPN Tools exporters `require "rexml/document"`,
  but the gemspec did not declare `rexml`, which has not been a default gem since Ruby 3.4.
  Requiring `petri_flow` then failed with a `LoadError` part-way through, which Lyra rescued
  as "PetriFlow not installed", leaving `PetriFlow` half-defined (no `PetriFlow::Workflow`);
  any app that eager-loads Lyra's `app/workflows` then failed to boot. `rexml` is now a
  runtime dependency.

## [0.6.0] - 2026-01-05

### Added

#### Workflow Generator
- **WorkflowGenerator** - Convert state machines to Petri nets
- **AASM Adapter** - Extract workflows from AASM gem state machines
- **StateMachines Adapter** - Extract workflows from state_machines gem
- Guard and action annotation support in visualizations
- Comprehensive rake tasks for workflow generation and verification

### Changed
- Enhanced Mermaid visualization with guard/action labels
- Improved GraphViz output formatting

#### Core Petri Net Components
- Place, Transition, Arc, Net, Token, Marking base classes
- Colored Petri net extensions (Color, Guard, ArcExpression, ColoredNet)

#### Matrix Analysis
- CRUD-Event mapping matrix
- Correlation matrix
- Causation matrix with transitive closure
- Data lineage matrix with temporal reconstruction
- Reachability matrix
- Matrix analyzer for comprehensive analysis

#### Formal Verification
- Reachability analysis with state space exploration
- Boundedness checking (k-bounded, safe, structural)
- Liveness checking (L0-L4 levels, deadlock detection)
- Invariant checking with custom property verification
- Terminal state reachability verification

#### Simulation Engine
- Step-by-step interactive simulation
- Monte Carlo simulation with multiple strategies
- Trace recording and analysis
- Transition firing statistics

#### Visualization
- GraphViz/DOT output for professional diagrams
- Mermaid diagram generation for Markdown
- ASCII text-based visualization

#### Workflow DSL for Rails Integration
- **WorkflowDSL** (`lib/petri_flow/workflow_dsl.rb`) - Declarative workflow definition
  - `place`, `transition`, `arc` DSL methods for net construction
  - `guard` blocks for transition conditions
  - `action` blocks for side effects on transition firing
  - Automatic net building from DSL specification
- **WorkflowRegistry** - Auto-discovers workflows from `app/workflows/` directory
- **WorkflowRunner** - Executes workflows with token management and action callbacks
- **Rails Railtie** integration with auto-loading and configuration

#### Verification Rake Tasks
- `rake petri_flow:verify` - Runs formal verification on all registered workflows
- `rake petri_flow:verify:workflow[name]` - Verify specific workflow
- `rake petri_flow:visualize` - Generate diagrams for all workflows
- `rake petri_flow:list` - List all registered workflows
- GDPR compliance verification for privacy-aware workflows

#### Lyra Framework Integration
- CRUD-to-Event mapping transformations
- Privacy policy guards (PAM integration)
- PII detection in arc expressions
- Consent and retention policy guards

### Features for Research
- Implementation of Colored Petri Net model from `THEORETICAL_MODEL_PETRI_NETS.md`
- Implementation of matrix analysis from `THEORETICAL_MODEL_MATRICES.md`
- Formal verification foundation for CRUD-to-Event mapping analysis
- Data lineage tracking for GDPR Article 15 compliance
- Privacy property verification support
