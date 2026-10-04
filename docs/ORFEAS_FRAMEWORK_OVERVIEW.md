# ORFEAS Framework Overview

**Object-Relational to Event-Sourcing Architecture**

## Author

**Michail Pantelelis** (mpantel@aegean.gr)
PhD Candidate, University of the Aegean
Department of Information and Communication Systems Engineering

## Abstract

ORFEAS (Object-Relational to Event-Sourcing Architecture) is a framework for the gradual transformation of applications built on Object-Relational Mapping (ORM) into event-sourced applications, with privacy compliance built in. It addresses the gap between decades of ORM-based development and event-driven, GDPR-aware application architectures.

## Naming

The framework's name draws from Greek mythology. **Orpheus** (Ὀρφεύς, *Orfeas* in Modern Greek) was a legendary musician and poet whose music could charm all living things. His instrument was the **lyre** (λύρα), a stringed instrument that became the symbol of music and poetry.

In this framework:
- **ORFEAS** represents the overarching architecture that orchestrates the transformation
- **Lyra** is the core transformation engine, the instrument through which ORFEAS performs its work

Just as Orpheus used his lyre to bridge the world of the living and the underworld, ORFEAS uses Lyra to bridge traditional ORM architectures with event sourcing.

## Framework Vision

### The Problem

1. **Legacy ORM architecture**: decades of investment in ORM-based systems
2. **Event sourcing benefits**: audit trails, temporal queries, alignment with event-driven systems
3. **Privacy requirements**: GDPR asks for data lineage and transparency about processing
4. **Migration risk**: rewriting an application's architecture is costly and risky

### The ORFEAS Approach

ORFEAS provides a gradual transformation path that:

- Leaves the application's models and controllers unchanged
- Introduces event sourcing one checked step at a time, through seven configurations
- Integrates privacy policies with the events
- Verifies the CRUD-to-event mapping formally

## Framework Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ORFEAS Framework                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │     Lyra     │  │   PAM DSL    │  │  PetriFlow   │           │
│  │Transformation│  │Privacy Attr. │  │Formal Analysis│          │
│  │    Engine    │  │    Matrix    │  │& Verification│           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                  │                  │                 │
│         └──────────────────┼──────────────────┘                 │
│                            ▼                                    │
│              ┌──────────────────────────┐                       │
│              │   Application Layer      │                       │
│              │  (Rails/ORM/CRUD)        │                       │
│              └──────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

PAM DSL and PetriFlow are optional: Lyra works without either.

## Core Components

### 1. Lyra - The Transformation Engine

**Purpose**: CRUD-to-event-sourcing transformation (gem `orfeas_lyra`)

**Key features**:
- **Seven configurations**: the mode is application-wide, and event sourcing takes one of four projection modes:

| Configuration | Authoritative store | What a write does |
|---|---|---|
| Disabled | tables | plain ActiveRecord, no events |
| Monitor | tables | row written, then the event appended in the same transaction |
| Hijack | events | event appended, then the row written |
| ES-Sync | events | event appended; the row projected in the same transaction |
| ES-Async | events | event appended; the row projected later by a background job |
| ES-NoProj | events | event appended; no row (reads rebuild records from events) |
| ES-Lazy | events | event appended; tables brought up to date before each read |

- **Checked mode switches**: a switch that makes the events authoritative is checked first ([MODE_TRANSITIONS.md](MODE_TRANSITIONS.md))
- **Genesis**: rows that predate Lyra get Imported events
- **DualView**: compares each row with the state replayed from its events
- **Point-in-time state**: `Lyra.state_at(Order, 42, 3.days.ago)` and `Order.as_of(3.days.ago).find(42)`, in every mode that records events

**Technologies**:
- Rails engine
- RailsEventStore for event persistence
- ActiveRecord callbacks and relation overrides for interception

The modes are described in [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md#the-modes-at-a-glance) and [API_REFERENCE.md](API_REFERENCE.md).

**Research foundation**:
> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". *26th Pan-Hellenic Conference on Informatics (PCI 2022)*. DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)

### 2. PAM DSL - Privacy Attribute Matrix

**Purpose**: declarative privacy policy definition and enforcement using the Privacy Attribute Matrix (PAM) model (gem `orfeas_pam_dsl`)

**Key features**:
- **Field-level classification**: PII type and sensitivity level
- **Purpose-based access**: GDPR Article 6 legal bases
- **Consent requirements** per purpose
- **Retention policies** with field-level durations
- **GDPR reports**: access (Art. 15), erasure planning (Art. 17), portability (Art. 20)

**Research foundation**:
> Pantelelis, M., & Kalloniatis, C. (2024). "Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR". *19th International Conference on Availability, Reliability and Security (ARES 2024)*. DOI: [10.1145/3664476.3669932](https://doi.org/10.1145/3664476.3669932)

### 3. PetriFlow - Formal Verification

**Purpose**: modeling and formal verification of event flows (gem `orfeas_petri_flow`)

**Key features**:
- **Colored Petri nets**: typed tokens, guards, arc expressions
- **Matrix analysis**: CRUD-event mapping, correlation, causation, lineage
- **Verification**: reachability, boundedness, liveness (including deadlock-freedom except at terminal places), invariants
- **Simulation**: step-by-step and Monte Carlo, with traces
- **Visualization and export**: GraphViz, Mermaid; PNML, CPN Tools, JSON, YAML

**Research foundation**:
- Jensen & Kristensen (2009). *Coloured Petri Nets*
- Murata (1989). Petri nets: Properties, analysis and applications

## Framework Workflow

The full procedure, with every check, is in [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md). In outline:

### Phase 1: Observation (Monitor)

```ruby
# Gemfile
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"   # optional

# config/initializers/lyra.rb
Lyra.configure do |config|
  config.mode = :monitor
  config.models = %w[Student]
end

# The application runs unchanged
student = Student.create!(name: "Alice", email: "alice@uni.edu")
# → the row is written as before
# → a StudentCreated event is appended in the same transaction
```

### Phase 2: Verification

```ruby
Lyra::DualView.new(Student, student.id).compare[:differences]
# => { no_differences: true }

Lyra::DualView.find_discrepancies(Student)   # every row whose events disagree with it

Lyra.verify_mapping!   # PetriFlow nets for the mapping; raises Lyra::MappingVerificationError on failure
```

`bin/rails lyra:genesis` imports rows that predate Lyra, and `bin/rails lyra:repair` brings the event log back in line with the tables if Monitor lost events.

### Phase 3: Hijack

```bash
bin/rails lyra:mode:check TO=hijack   # check the switch and certify it
```

Then deploy with `config.mode = :hijack`. Application code is unchanged; each write becomes a command, its event is appended first, and the row is written from it.

### Phase 4: Event sourcing

```ruby
Lyra.configure do |config|
  config.mode = :event_sourcing
  config.projection_mode = :sync   # or :async, :disabled, :lazy
end
```

The event log is the source of truth; the tables are a projection of it (or, in ES-NoProj, absent).

## Privacy Compliance Features

Details: [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md) and [API_REFERENCE.md](API_REFERENCE.md#privacy).

### GDPR reports (needs PAM DSL)

```ruby
compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: student.id, subject_type: "Student")

compliance.data_export                    # Art. 15: events, PII inventory, data lineage, processing activities
compliance.right_to_be_forgotten_report   # Art. 17: affected events, streams and models, a recommended strategy
compliance.portable_export(format: :json) # Art. 20: :json, :csv, :xml or :hash
```

The Article 17 report plans an erasure; it changes nothing.

### Erasure (Art. 17)

```ruby
Lyra::Erasure.erase!(Student, student.id, reason: "Art. 17 request #12")
```

Erases the record's personal data from its row and from every event in its stream. The events are overwritten in place, and an `ErasureApplied` event records the fields erased (never a value), the reason and who erased them. The stream still replays to the row. Also `bin/rails lyra:erase`.

### Privacy by design

```ruby
# PII detection (PAM's name-based detector)
Lyra::Privacy::PIIDetector.detect(email: "a@example.com", count: 3)

# Purpose-bound reads: declared attributes are checked against the policy
Lyra.with_purpose(:enrollment) { Student.find(id) }

# Consent as a Petri net guard
guard = PetriFlow::Colored::Guards.has_consent(:email_marketing)
```

Opt-in features: privacy stamps on events (`config.annotate_privacy`), the access log (`config.record_access_events`: `Lyra::AccessLog` records each access the policy validates as an event in the subject's access stream), and retention (`config.retention_executor`, `Lyra::Retention.apply!`).

## Formal Verification Capabilities

### 1. CRUD-event mapping completeness

**Question**: does every CRUD operation produce an event?

`Lyra.verify_mapping!` runs PetriFlow nets for the CRUD lifecycle and for create, update and destroy across the modes, and checks that their terminal places are reachable, that they are safe (1-bounded), and that they are deadlock-free except at terminal places. See [WORKFLOW_GENERATOR.md](WORKFLOW_GENERATOR.md).

### 2. Writes that bypass callbacks

**Question**: can a write change the store without an event?

`Lyra::Verification::BypassWorkflow` models `update_column(s)`, `delete`, `touch`, `update_all`, `delete_all`, `insert_all`, `upsert_all` and `dependent: :nullify`; `BypassWorkflow.coverage` checks that every reachable end state is a rejection or a store change with an event logged.

### 3. Event-ORM consistency

**Question**: does replaying the events produce the row?

```ruby
comparison = Lyra::DualView.new(Student, student_id).compare
comparison[:differences] == { no_differences: true }
```

`config.dual_view_sample_rate` checks a share of committed writes as they happen (opt-in).

### 4. Data lineage and point-in-time state

**Question**: can every change to every field be traced, and the record's state at any time be recovered?

```ruby
Lyra::EventFlow.new(time_range: 1.year.ago..Time.current)
  .data_lineage("email", Student)               # every event in the range that set or changed the field (default range: 30 days)
Lyra.state_at(Student, student_id, 6.months.ago)       # attributes then, or nil
Student.as_of(6.months.ago).find(student_id)           # a read-only Student as it was
```

## Implementation Patterns

### Custom aggregate

A custom aggregate subclasses `Lyra::GenericAggregate` (`Lyra::Aggregate` is a minimal base class):

```ruby
class StudentAggregate < Lyra::GenericAggregate
  private

  def apply_updated(event)
    super
    # domain checks; raise to fail the write
  end
end

class Student < ApplicationRecord
  monitor_with_lyra aggregate_class: StudentAggregate, privacy_policy: :student_system
end
```

### Verifiable event flows

```ruby
class OrderFlow < PetriFlow::Workflow
  workflow_name "Order Flow"
  places :created, :paid, :shipped
  initial_place :created
  terminal_places :shipped

  transition :process_payment, from: :created, to: :paid
  transition :ship, from: :paid, to: :shipped
end

results = OrderFlow.new.verify!
results[:liveness][:terminates_properly]   # deadlock-free except at terminal places
results[:boundedness][:is_safe]
```

## Research Contributions

### 1. Gradual event sourcing migration

- Seven configurations, from Disabled through Monitor and Hijack to four event-sourcing projection modes
- Interception of ActiveRecord writes without changes to models or controllers
- Automatic event generation from CRUD
- State consistency checks (DualView) and checked mode switches

### 2. Privacy-aware event sourcing

- Declarative privacy policy DSL (PAM)
- PII detection and privacy stamps on events
- Purpose-bound reads and an access log
- Data lineage from events
- Erasure of personal data from rows and events

### 3. Formal verification of event flows

- Colored Petri net formalization of event flows
- Matrix-based causation and lineage analysis
- Automated property verification of the CRUD-to-event mapping, including writes that bypass callbacks
- Simulation and visualization tools

## Use Cases

Each of the evaluation applications in the monorepo exercises Lyra on a different domain: a university payment system (the Aegean e-Pay testbed), a loan-application process (the BPI Challenge 2017 replay), and an e-commerce platform (the Solidus case study with the Olist orders). Typical uses:

- **Audit trail without code changes**: Monitor mode records every write as an event.
- **Access accountability**: with `config.record_access_events`, who accessed which declared attributes, for which purpose, is recorded as events.
- **Temporal reconstruction**: `Lyra.state_at` and `Model.as_of` recover a record or a table as it was at a given time.
- **Data subject requests**: `GDPRCompliance` reports and `Lyra::Erasure`.

## Performance

The measured overhead of each configuration is in [PERFORMANCE.md](PERFORMANCE.md). Note that Monitor costs more throughput than Hijack there, for reasons explained in that document; the July 2026 baseline is being re-measured.

## Technology Stack

### Core technologies

- **Ruby**: 4.0 or later
- **Rails**: 8.0 or later
- **RailsEventStore**: `~> 3.0`
- **PostgreSQL**: the supported database (`pg` gem)

### Gems

1. **orfeas_lyra** (`lyra`): transformation engine
2. **orfeas_pam_dsl** (`pam_dsl`): privacy policy DSL, optional
3. **orfeas_petri_flow** (`petri_flow`): formal verification, optional

### Development tools

- **Minitest**, with minitest-reporters and Mocha: the gems' test suites
- **SimpleCov**: coverage
- **RuboCop**: code style
- **GraphViz** and **Mermaid**: diagram output formats

## Future Directions

### 1. Automated aggregate discovery

**Challenge**: aggregate design requires domain expertise
**Approach**: clustering of events to identify aggregate boundaries

### 2. Real-time verification

**Challenge**: verification runs on demand or at boot
**Approach**: streaming Petri net analysis, live invariant monitoring

### 3. Multi-system event correlation

**Challenge**: events span multiple services
**Approach**: distributed event sourcing with cross-boundary lineage

### 4. Schema evolution

**Challenge**: event schemas change over time
**Approach**: automated upcasting and version migration tools

### 5. Replay performance

**Challenge**: replaying long streams is slow
**Approach**: snapshotting, incremental materialization

### 6. Crypto-shredding

**Challenge**: erasure currently rewrites events in place
**Approach**: per-subject keys whose deletion makes the data unreadable while the log stays untouched

## Academic Context

### PhD Research

**Institution**: University of the Aegean
**Department**: Information and Communication Systems Engineering
**Candidate**: Michail Pantelelis
**Supervisor**: Prof. Christos Kalloniatis

**Thesis title**: "Objects or Events? A Methodology to Enable Different Views on the Same Software System"

### Research Questions

From the thesis:

1. **RQ1**: Can we model software systems using object-oriented tools but result in systems where events play the leading role?
2. **RQ2**: Can we automate the transformation from ORM to Event Sourcing?
3. **RQ3**: Can formal methods verify the correctness of such transformations?
4. **RQ4**: Can privacy regulations (GDPR) be enforced at the architectural level during migration?

### Publications

1. Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". *PCI 2022*. DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)
2. Pantelelis, M., & Kalloniatis, C. (2024). "Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR". *ARES 2024*. DOI: [10.1145/3664476.3669932](https://doi.org/10.1145/3664476.3669932)

The sources of the other papers, the thesis and the proposal are in the monorepo's `papers/` directory.

## Getting Started

See [GETTING_STARTED.md](GETTING_STARTED.md). In short:

```ruby
# Gemfile (the gems are named orfeas_*, their entry files are not)
gem "orfeas_lyra", path: "path/to/lyra", require: "lyra"
gem "orfeas_pam_dsl", path: "path/to/lyra/gems/pam_dsl", require: "pam_dsl"          # optional, privacy
gem "orfeas_petri_flow", path: "path/to/lyra/gems/petri_flow", require: "petri_flow"  # optional, verification
```

```ruby
# Privacy policy (optional)
PamDsl.define_policy :my_app do
  field :email, type: :email, sensitivity: :internal do
    allow_for :user_management
  end

  purpose :user_management do
    basis :contract
    requires :email
  end

  retention do
    default 7.years
  end
end

# Monitor a model
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_app
end

user = User.create!(email: "user@example.com")
# → a UserCreated event in the event store
```

### Documentation

- **Framework overview**: this document
- **Lyra**: [README.md](../README.md), [GETTING_STARTED.md](GETTING_STARTED.md), [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md), [API_REFERENCE.md](API_REFERENCE.md), [ARCHITECTURE.md](ARCHITECTURE.md)
- **PAM DSL**: [gems/pam_dsl/README.md](../gems/pam_dsl/README.md)
- **PetriFlow**: [gems/petri_flow/README.md](../gems/petri_flow/README.md)
- **Privacy**: [PRIVACY_COMPLIANCE.md](PRIVACY_COMPLIANCE.md)

## Contributing

This is academic research software. Contributions are welcome through:

1. **Issue reports**: bug reports, feature requests
2. **Pull requests**: code and documentation
3. **Research collaboration**: academic partnerships
4. **Case studies**: experience from real applications

## License

MIT License. See the LICENSE file. All gems in the ORFEAS framework are open source.

## Contact

**Michail Pantelelis**
Email: mpantel@aegean.gr
Institution: University of the Aegean
GitHub: https://github.com/mpantel/lyra-engine

## Citation

```bibtex
@software{orfeas2026,
  title={ORFEAS: Object-Relational to Event-Sourcing Architecture Framework},
  author={Pantelelis, Michail},
  year={2026},
  url={https://github.com/mpantel/lyra-engine},
  note={Includes Lyra, PAM DSL, and PetriFlow gems}
}
```

## Acknowledgments

- **Prof. Christos Kalloniatis**: PhD supervision and research guidance
- **University of the Aegean**: research support and resources
- **Open source community**: the tools and libraries this work builds on
- **Research community**: feedback on the approach
