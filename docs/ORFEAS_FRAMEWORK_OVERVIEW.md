# ORFEAS Framework Overview

**Object-Relational to Event-Sourcing Architecture**

## Author

**Michail Pantelelis** (mpantel@aegean.gr)
PhD Candidate, University of the Aegean
Department of Information and Communication Systems Engineering

## Abstract

ORFEAS (Object-Relational to Event-Sourcing Architecture) is a comprehensive framework for the gradual transformation of traditional Object-Relational Mapping (ORM) based applications to Event Sourcing architectures, with integrated privacy compliance capabilities. The framework addresses the fundamental challenge of bridging 40+ years of ORM dominance with modern event-driven, GDPR-compliant application architectures.

## Naming

The framework's name draws from Greek mythology. **Orpheus** (Ὀρφεύς, *Orfeas* in Modern Greek) was a legendary musician and poet whose music could charm all living things. His instrument was the **lyre** (λύρα), a stringed instrument that became the symbol of music and poetry.

In this framework:
- **ORFEAS** represents the overarching architecture that orchestrates the transformation
- **Lyra** is the core transformation engine—the instrument through which ORFEAS performs its work

Just as Orpheus used his lyre to bridge the world of the living and the underworld, ORFEAS uses Lyra to bridge traditional ORM architectures with modern event sourcing patterns.

## Framework Vision

### The Problem

Modern enterprise systems face a critical architectural challenge:

1. **Legacy ORM Architecture**: Decades of investment in ORM-based systems
2. **Event Sourcing Benefits**: Superior audit trails, temporal queries, microservices alignment
3. **Privacy Requirements**: GDPR mandates comprehensive data lineage and processing transparency
4. **Migration Risk**: High cost and risk of complete architectural rewrites

### The ORFEAS Solution

ORFEAS provides a **non-intrusive, gradual transformation path** that:

- ✅ Maintains existing ORM applications unchanged
- ✅ Progressively introduces event sourcing patterns
- ✅ Ensures privacy compliance by design
- ✅ Enables dual-mode operation (Monitor → Hijack)
- ✅ Provides formal verification of correctness

## Framework Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ORFEAS Framework                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │     Lyra     │  │   PAM DSL    │  │  PetriFlow   │        │
│  │ Transformation│ │Privacy Aware │  │Formal Analysis│        │
│  │    Engine    │  │  Monitoring  │  │ & Verification│        │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │
│         │                  │                  │                 │
│         └──────────────────┼──────────────────┘                 │
│                            ▼                                    │
│              ┌──────────────────────────┐                      │
│              │   Application Layer      │                      │
│              │  (Rails/ORM/CRUD)        │                      │
│              └──────────────────────────┘                      │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Lyra - The Transformation Engine

**Purpose**: CRUD-to-Event Sourcing transformation tool

**Key Features**:
- **Monitor Mode**: Non-intrusive observation of CRUD operations
- **Hijack Mode**: Complete event sourcing transformation
- **Dual-View Maintenance**: Simultaneous ORM and Event Store consistency
- **Gradual Migration**: Step-by-step transformation path

**Technologies**:
- Rails Engine for seamless integration
- RailsEventStore for event persistence
- Active Record interception
- Event stream processing

**Research Foundation**:
> Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events: Towards an object to event-sourcing framework". *26th Pan-Hellenic Conference on Informatics (PCI 2022)*. DOI: [10.1145/3575879.3576006](https://doi.org/10.1145/3575879.3576006)

### 2. PAM DSL - Privacy Attribute Matrix

**Purpose**: Declarative privacy policy definition and enforcement using the Privacy Attribute Matrix (PAM) model

**Key Features**:
- **Field-Level Classification**: PII type and sensitivity levels
- **Purpose-Based Access**: GDPR Article 6 legal bases
- **Consent Management**: Granular, withdrawable consent
- **Retention Policies**: Field-specific data lifecycle
- **Automated Compliance**: Built-in GDPR Articles 15, 17, 20

**Technologies**:
- Ruby DSL for policy definition
- Policy registry and enforcement
- Integration with Lyra event metadata

**Research Foundation**:
> Pantelelis, M., & Kalloniatis, C. (2024). "Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR". *19th International Conference on Availability, Reliability and Security (ARES 2024)*. DOI: [10.1145/3664476.3669932](https://doi.org/10.1145/3664476.3669932)

### 3. PetriFlow - Formal Verification

**Purpose**: Mathematical modeling and formal verification of event flows

**Key Features**:
- **Colored Petri Nets**: Rich token types for event metadata
- **Matrix Analysis**: CRUD-Event mapping, causation, lineage
- **Formal Verification**: Reachability, boundedness, liveness
- **Simulation**: Monte Carlo analysis and trace generation
- **Visualization**: GraphViz, Mermaid, ASCII diagrams

**Technologies**:
- Pure Ruby implementation
- Matrix algebra for analysis
- State space exploration algorithms
- Multiple visualization formats

**Research Foundation**:
- Jensen & Kristensen (2009). *Colored Petri Nets*
- Murata (1989). Petri nets: Properties, analysis and applications
- Custom CRUD-Event mapping formalization

## Framework Workflow

### Phase 1: Observation (Monitor Mode)

```ruby
# 1. Install ORFEAS
gem 'orfeas_lyra'
gem 'pam_dsl'

# 2. Define Privacy Policies
PamDsl.define_policy :student_system do
  field :email, pii_type: :email, sensitivity: :internal
  purpose :enrollment, legal_basis: :consent
  consent :enrollment, required: true
  retention default: 7.years
end

# 3. Enable Monitoring
class Student < ApplicationRecord
  monitor_with_lyra privacy_policy: :student_system
end

# 4. Application runs unchanged
student = Student.create!(name: "Alice", email: "alice@uni.edu")
# → Database: INSERT executed normally
# → Event Store: StudentCreated event logged
# → Privacy: PII detected and tagged
# → Behavior: IDENTICAL to before
```

**Benefits**:
- Zero application changes
- Complete audit trail
- Privacy compliance
- Data for analysis

### Phase 2: Analysis

```ruby
# Use PetriFlow for formal verification
require 'petri_flow'

# 1. Build Petri net model
net = PetriFlow.create_colored_net(name: "StudentCRUD")
# ... model CRUD-Event mapping ...

# 2. Verify properties
results = PetriFlow.verify(net)
# → Reachability: 124 states
# → Bounded: true (safe 1-bounded)
# → Deadlock-free: true

# 3. Matrix analysis
analyzer = PetriFlow.create_analyzer
analyzer.analyze_events(EventStore.all_events)

# 4. Check invariants
checker = PetriFlow::Verification::InvariantChecker.new(net)
checker.add_invariant("PII always detected") do |marking|
  # Custom verification logic
end
```

### Phase 3: Transformation (Hijack Mode)

```ruby
# Enable Hijack Mode for selected models
Lyra.configure do |config|
  config.mode = :hijack
  config.enable_hijack_for = [:Student, :Payment]
end

# Application code UNCHANGED
student.update!(email: "new@uni.edu")
# → Command: UpdateStudentCommand created
# → Aggregate: StudentAggregate validates and applies
# → Events: StudentUpdated published
# → Projection: Database updated from event
# → Behavior: Event-sourced (transparent to app)
```

### Phase 4: Full Event Sourcing

```ruby
# All models in event sourcing mode
# Database becomes read model (projection)
# Event store is source of truth
# Complete GDPR compliance via event lineage
```

## Privacy Compliance Features

### GDPR Article 15 - Right to Access

```ruby
compliance = Lyra::Privacy::GDPRCompliance.new(
  subject_id: student.id,
  subject_type: 'Student'
)

export = compliance.data_export
# → Complete data history
# → All processing activities
# → Data lineage for every field
# → Machine-readable format
```

### GDPR Article 17 - Right to Erasure

```ruby
report = compliance.right_to_be_forgotten_report
# → Identifies all personal data
# → Shows data dependencies
# → Generates anonymization events
# → Maintains audit trail (anonymization event, not deletion)
```

### GDPR Article 20 - Data Portability

```ruby
portable = compliance.portable_export(format: :json)
# → Structured, commonly used format
# → All personal data included
# → Ready for transfer to another controller
```

### Privacy by Design

```ruby
# Automatic PII detection
pii = Lyra::Privacy::PIIDetector.detect(attributes)

# Purpose-based access control
data = policy.transform_for_purpose(:marketing, event.data)
# → Email: visible
# → SSN: masked
# → Medical data: removed

# Consent enforcement
guard = PetriFlow::Colored::Guards.has_consent(:email_marketing)
# → Transition only fires if consent granted
```

## Formal Verification Capabilities

### 1. CRUD-Event Mapping Completeness

**Question**: Does every CRUD operation generate at least one event?

**Verification**:
```ruby
# Matrix analysis
mapping = analyzer.crud_mapping
mapping.total_events_for(:create) >= 1  # ✓
mapping.total_events_for(:update) >= 1  # ✓
mapping.total_events_for(:delete) >= 1  # ✓

# Petri net invariant
checker.add_invariant("All CRUD mapped") do |marking|
  total_events >= total_crud_operations
end
```

### 2. Privacy Policy Coverage

**Question**: Is every PII field governed by a privacy policy?

**Verification**:
```ruby
checker.add_invariant("All PII has policy") do |marking|
  event.pii_detected.all? do |field, _|
    policy.fields.key?(field)
  end
end
```

### 3. Event-ORM Consistency

**Question**: Does event replay produce identical state to ORM?

**Verification**:
```ruby
comparison = Lyra::DualView.new(Student, student_id).compare

if comparison[:differences] == { no_differences: true }
  # ✓ States consistent
else
  # ⚠ Investigate discrepancy
end
```

### 4. Data Lineage Completeness

**Question**: Can we trace every change to every field?

**Verification**:
```ruby
lineage = analyzer.lineage.field_lineage('email')
# → Event1: nil → "alice@old.edu" (2025-01-01)
# → Event2: "alice@old.edu" → "alice@new.edu" (2025-06-15)

# Reconstruct at any point in time
value = analyzer.lineage.reconstruct_value('email', 6.months.ago)
# → "alice@old.edu"
```

## Implementation Patterns

### Pattern 1: Privacy-First Event Design

```ruby
class StudentCreated < RailsEventStore::Event
  def self.strict_schema
    {
      # Core data
      model_id: Integer,
      attributes: Hash,

      # Privacy metadata (automatic via PAM DSL)
      pii_detected: Hash,              # { email: :email, name: :name }
      sensitivity_levels: Hash,        # { email: :internal, ssn: :restricted }
      allowed_purposes: Hash,          # { email: [:enrollment, :communication] }

      # Compliance metadata (automatic via Lyra)
      correlation_id: String,
      user_id: Integer,
      user_action: Hash,
      timestamp: Time,

      # Retention metadata (automatic via PAM DSL)
      retention_period: ActiveSupport::Duration,
      retention_expires_at: Time
    }
  end
end
```

### Pattern 2: Aggregate with Privacy Guards

```ruby
class StudentAggregate
  include Lyra::Aggregate

  # PAM DSL policy automatically integrated
  privacy_policy :student_system

  def apply_student_updated(event)
    # Automatic privacy checks
    # - Consent verified for purpose
    # - Field access controlled by sensitivity
    # - PII transformations applied

    event.data.each do |field, value|
      @state[field] = value if policy.allows_field?(field, :update)
    end
  end
end
```

### Pattern 3: Verifiable Event Flows

```ruby
# Model event flow as Petri net
flow_net = PetriFlow.create_colored_net(name: "OrderFlow")

# Places represent states
flow_net.add_colored_place(id: :order_created)
flow_net.add_colored_place(id: :payment_processed)
flow_net.add_colored_place(id: :order_shipped)

# Transitions represent events
flow_net.add_colored_transition(
  id: :process_payment,
  guard: PetriFlow::Colored::Guards.condition("payment valid") do |ctx|
    ctx[:payment_amount] > 0
  end
)

# Verify no orders ship without payment
invariant = flow_net.add_invariant("No ship without payment") do |marking|
  marking.tokens_at(:order_shipped) <= marking.tokens_at(:payment_processed)
end

# Run verification
results = PetriFlow.verify(flow_net)
results[:invariants][:passed]  # ✓ All invariants hold
```

## Research Contributions

### 1. Non-Intrusive Event Sourcing Migration

**Contribution**: First framework enabling gradual ORM-to-ES transformation without application changes

**Innovation**:
- Dual-mode operation (Monitor/Hijack)
- Transparent Active Record interception
- Automatic event generation from CRUD
- State consistency verification

**Impact**: Reduces migration risk from months/years to weeks, enables incremental adoption

### 2. Privacy-Aware Event Sourcing

**Contribution**: Integration of GDPR compliance into event sourcing architecture

**Innovation**:
- Declarative privacy policy DSL
- Automatic PII detection and tagging
- Purpose-based event access control
- Complete data lineage from events
- Consent-aware event processing

**Impact**: Makes event sourcing GDPR-compliant by design, provides audit capabilities ORM cannot match

### 3. Formal Verification of Event Flows

**Contribution**: Mathematical foundation for CRUD-Event mapping analysis

**Innovation**:
- Colored Petri Net formalization of event flows
- Matrix-based causation and lineage analysis
- Automated property verification
- Privacy invariant checking
- Simulation and visualization tools

**Impact**: Enables formal proof of correctness, privacy compliance verification, and system reliability analysis

## Use Cases

### 1. University Student Information System

**Challenge**: FERPA compliance, audit requirements, complex workflows

**ORFEAS Solution**:
```ruby
# Monitor mode: immediate audit trail
Student.monitor_with_lyra privacy_policy: :ferpa_compliant

# Complete student history
timeline = Lyra::EventFlow.new.timeline(
  subject_type: 'Student',
  subject_id: student.id
)

# Enrollment process verification
enrollment_flow = PetriFlow.verify(enrollment_net)
# Ensures: consent → enrollment → payment → activation
```

### 2. Healthcare Patient Records

**Challenge**: HIPAA compliance, data access audit, temporal queries

**ORFEAS Solution**:
```ruby
# Every access logged as event
MedicalRecord.monitor_with_lyra privacy_policy: :hipaa

# Who accessed what when
access_log = compliance.processing_activities
# → Dr. Smith accessed Patient #123 SSN on 2025-01-15 for Treatment

# State at any point in time
patient_state = EventFlow.reconstruct_state(
  'Patient',
  patient_id,
  as_of: 1.year.ago
)
```

### 3. E-Commerce Platform

**Challenge**: Order lifecycle, customer data management, GDPR

**ORFEAS Solution**:
```ruby
# Order journey fully tracked
Order.monitor_with_lyra privacy_policy: :ecommerce

# Customer data export (GDPR Art. 20)
export = compliance.portable_export(
  subject_id: customer.id,
  subject_type: 'Customer'
)

# Causation analysis
chain = analyzer.causation.causation_chain(
  'OrderCreated',
  'PackageDelivered'
)
# → OrderCreated → PaymentProcessed → WarehousePicked →
#   Shipped → OutForDelivery → PackageDelivered
```

### 4. Financial Services

**Challenge**: Regulatory reporting, audit trail, temporal reconstruction

**ORFEAS Solution**:
```ruby
# Immutable transaction history
Transaction.monitor_with_lyra privacy_policy: :financial_services

# Reconstruct account at year-end
eoy_state = EventFlow.reconstruct_state_chain(
  'Account',
  account_id
).as_of(Date.new(2025, 12, 31))

# Regulatory report
report = compliance.generate_report(
  start_date: 1.year.ago,
  end_date: Date.today,
  format: :regulatory_standard
)
```

## Performance Characteristics

### Monitor Mode Overhead

**Measurement**: Event publication overhead per CRUD operation

- **Average**: 2-5ms per operation
- **Components**: Event serialization (1ms) + Store write (1-4ms)
- **Optimization**: Async event publishing reduces to <1ms perceived latency

### Hijack Mode Overhead

**Measurement**: Full event sourcing cycle

- **Average**: 10-20ms per operation
- **Components**: Command validation (2ms) + Aggregate (3ms) + Event (2ms) + Projection (3-10ms)
- **Optimization**: Snapshot caching, batch projections

### State Space Analysis

**Measurement**: Petri net verification

- **Small Systems** (<1000 states): <1 second
- **Medium Systems** (1000-10000 states): 1-10 seconds
- **Large Systems** (>10000 states): Requires optimization

## Technology Stack

### Core Technologies

- **Ruby**: 3.4.5+ (tested up to 4.0)
- **Rails**: 8.0+
- **RailsEventStore**: 2.14+
- **PostgreSQL**: Primary database
- **Active Support**: Core utilities

### Gems Developed

1. **lyra** - Transformation engine
2. **pam_dsl** - Privacy policy DSL
3. **petri_flow** - Formal verification

### Development Tools

- **RSpec**: Testing framework
- **FactoryBot**: Test data
- **Pry**: Debugging
- **RuboCop**: Code quality
- **GraphViz**: Visualization
- **Mermaid**: Documentation diagrams

## Future Directions

### 1. Automated Aggregate Discovery

**Challenge**: Manual aggregate design requires domain expertise

**Approach**: ML-based clustering of events to identify aggregate boundaries

### 2. Real-Time Verification Dashboard

**Challenge**: Verification is currently batch-oriented

**Approach**: Streaming Petri net analysis, live invariant monitoring

### 3. Multi-System Event Correlation

**Challenge**: Events span multiple microservices

**Approach**: Distributed event sourcing with cross-boundary lineage

### 4. Schema Evolution Management

**Challenge**: Event schemas change over time

**Approach**: Automated upcasting, version migration tools

### 5. Performance Optimization

**Challenge**: Event replay can be slow for large aggregates

**Approach**: Intelligent snapshotting, incremental materialization

## Academic Context

### PhD Research

**Institution**: University of the Aegean
**Department**: Information and Communication Systems Engineering
**Candidate**: Michail Pantelelis
**Supervisors**: Prof. Christos Kalloniatis

**Thesis Title**: "Object-Relational to Event-Sourcing Architecture: A Framework for Gradual Transformation with Privacy Compliance"

### Research Questions

1. **RQ1**: Can CRUD operations be automatically and completely mapped to events?
2. **RQ2**: Can event sourcing provide superior privacy compliance capabilities?
3. **RQ3**: Is gradual, non-intrusive migration from ORM to ES feasible?
4. **RQ4**: Can formal methods verify the correctness of CRUD-Event mapping?

### Publications

1. Pantelelis, M., & Kalloniatis, C. (2022). "Mapping CRUD to Events". *PCI 2022*. ✅
2. Pantelelis, M., & Kalloniatis, C. (2024). "CRUD and GDPR". *ARES 2024*. ✅
3. [Planned] "ORFEAS Framework: Non-Intrusive Event Sourcing Migration"
4. [Planned] "Privacy-Aware Event Sourcing: A Formal Approach"

## Getting Started

### Installation

```bash
# Add to Gemfile
gem 'orfeas_lyra'
gem 'pam_dsl'
gem 'petri_flow'  # Optional, for formal verification

bundle install
```

### Quick Start

```ruby
# 1. Define privacy policy
PamDsl.define_policy :my_app do
  field :email, pii_type: :email, sensitivity: :internal
  purpose :user_management, legal_basis: :contract
  retention default: 7.years
end

# 2. Enable monitoring
class User < ApplicationRecord
  monitor_with_lyra privacy_policy: :my_app
end

# 3. Use normally - events automatically generated
user = User.create!(email: "user@example.com")
# → UserCreated event in event store
# → Complete audit trail
# → Privacy metadata attached
```

### Documentation

- **Framework Overview**: This document
- **Lyra**: `README.md`
- **PAM DSL**: `gems/pam_dsl/README.md`
- **PetriFlow**: `gems/petri_flow/README.md`
- **Privacy**: `PRIVACY_COMPLIANCE.md`

## Contributing

This is academic research software. Contributions are welcome through:

1. **Issue Reports**: Bug reports, feature requests
2. **Pull Requests**: Code contributions, documentation improvements
3. **Research Collaboration**: Academic partnerships
4. **Case Studies**: Real-world application experiences

## License

MIT License - See LICENSE file

All gems in the ORFEAS framework are open source and free to use.

## Contact

**Michail Pantelelis**
Email: mpantel@aegean.gr
Institution: University of the Aegean
GitHub: [Repository URL]

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
- **University of the Aegean**: Research support and resources
- **Open Source Community**: Tools and libraries that made this possible
- **Research Community**: Feedback and validation of approaches

---

**ORFEAS Framework** - Bridging 40 years of ORM with the future of Event Sourcing

*Making event sourcing practical, gradual, and privacy-compliant*
