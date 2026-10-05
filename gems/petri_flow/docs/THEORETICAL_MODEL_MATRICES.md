# Complementary Model: Matrix Analysis for CRUD-Event System

## Overview

While **Colored Petri Nets** serve as the primary model for CRUD-event mapping and flow analysis, **matrices** provide complementary analytical tools for specific aspects of the system.

This document describes matrix-based models that work alongside the CPN model.

---

## 1. CRUD-to-Event Mapping Matrix (M_ce)

### Basic Mapping Matrix

```
           │ Created │ Updated │ Destroyed │
───────────┼─────────┼─────────┼───────────┤
CREATE     │    1    │    0    │     0     │
UPDATE     │    0    │    1    │     0     │
DELETE     │    0    │    0    │     1     │
```

**Mathematical Definition:**
```
M_ce[i][j] = 1  if CRUD operation i generates event type j
            0  otherwise

where i ∈ {CREATE, UPDATE, DELETE}
      j ∈ {Created, Updated, Destroyed}
```

### Extended Mapping Matrix (Multiple Events per CRUD)

Based on Lyra's architecture, one CRUD may generate multiple events:

```
         │ Primary │ Audit │ Notification │ StateChange │
─────────┼─────────┼───────┼──────────────┼─────────────┤
CREATE   │    1    │   1   │      1       │      1      │
UPDATE   │    1    │   1   │      0       │      1      │
DELETE   │    1    │   1   │      1       │      0      │
```

**Practical Example from Lyra:**
```ruby
# Order.create! stores one event of its own (OrderCreated, or the domain event a
# matching domain_events rule names). Further events come only from domain_events
# rules marked also: true, e.g. with such rules configured:
# - OrderCreated event (Primary)
# - AuditLogCreated event (Audit)
# - NotificationSent event (Notification)
# - InventoryStateChanged event (StateChange)
```

### Model-Specific Mapping Matrix

Different models may have different mapping patterns:

```
M_ce^Student:
         │ Created │ Updated │ Destroyed │ EmailChanged │ GradePosted │
─────────┼─────────┼─────────┼───────────┼──────────────┼─────────────┤
CREATE   │    1    │    0    │     0     │      0       │      0      │
UPDATE   │    0    │    1    │     0     │      α       │      β      │
DELETE   │    0    │    0    │     1     │      0       │      0      │

where α = 1 if email changed, 0 otherwise
      β = 1 if grade changed, 0 otherwise
```

### Computing Total Events

**Question:** How many events does a CRUD operation generate?

**Answer:** Sum row in mapping matrix
```
total_events(CREATE) = Σⱼ M_ce[CREATE][j]
```

**Implementation:**
```ruby
def total_events_for_operation(operation, model_class)
  mapping = Lyra::EventFlow.new.crud_to_event_mapping(model_class, operation)
  mapping[:generated_events].count
end
```

---

## 2. Event Correlation Matrix (C)

### Definition

```
C[e1][e2] = correlation_id  if events share correlation_id
           nil              otherwise
```

**Example:**
```
         │ Event1 │ Event2 │ Event3 │ Event4 │
─────────┼────────┼────────┼────────┼────────┤
Event1   │  uuid1 │  uuid1 │  nil   │  nil   │
Event2   │  uuid1 │  uuid1 │  nil   │  nil   │
Event3   │  nil   │  nil   │  uuid2 │  uuid2 │
Event4   │  nil   │  nil   │  uuid2 │  uuid2 │
```

Events 1 and 2 are correlated (same user action).
Events 3 and 4 are correlated (different user action).

### Finding Correlated Event Groups

**Algorithm:** Graph connected components on correlation matrix

```ruby
def find_correlated_groups(events)
  groups = {}
  events.each do |event|
    correlation_id = event.metadata[:correlation_id]
    groups[correlation_id] ||= []
    groups[correlation_id] << event
  end
  groups.values
end
```

**Lyra Implementation:**
```ruby
flow = Lyra::EventFlow.new
flows = flow.flow_data[:flows]  # Grouped by correlation_id
```

---

## 3. Event Causation Matrix (Cau)

### Direct Causation

```
Cau[e1][e2] = 1  if e1 directly causes e2
             0  otherwise
```

**Example:**
```
                │ OrderCreated │ PaymentProcessed │ EmailSent │ Shipped │
────────────────┼──────────────┼──────────────────┼───────────┼─────────┤
OrderCreated    │      0       │        1         │     1     │    0    │
PaymentProcessed│      0       │        0         │     0     │    1    │
EmailSent       │      0       │        0         │     0     │    0    │
Shipped         │      0       │        0         │     1     │    0    │
```

This shows:
- OrderCreated causes PaymentProcessed and EmailSent
- PaymentProcessed causes Shipped
- Shipped causes EmailSent

### Transitive Causation (Cau*)

Compute transitive closure: `Cau* = Cau ∪ Cau² ∪ Cau³ ∪ ...`

Using Warshall's algorithm:

```ruby
def transitive_closure(cau_matrix)
  n = cau_matrix.size
  closure = cau_matrix.dup

  n.times do |k|
    n.times do |i|
      n.times do |j|
        closure[i][j] ||= (closure[i][k] && closure[k][j])
      end
    end
  end

  closure
end
```

**Result:**
```
                │ OrderCreated │ PaymentProcessed │ EmailSent │ Shipped │
────────────────┼──────────────┼──────────────────┼───────────┼─────────┤
OrderCreated    │      0       │        1         │     1     │    1    │
PaymentProcessed│      0       │        0         │     1     │    1    │
EmailSent       │      0       │        0         │     0     │    0    │
Shipped         │      0       │        0         │     1     │    0    │
```

Now we see OrderCreated transitively causes Shipped (through PaymentProcessed).

### Lyra Implementation

```ruby
# Lyra writes the causing event's id to metadata[:causation_id]
# (Lyra::Causation.with_id sets it; an additional domain event carries the id of
# the write's own event)
Lyra::Causation.track(cause_event_id, effect_event_id)

# Build causation matrix from event store
def build_causation_matrix
  events = Lyra.event_store.read.to_a
  matrix = {}

  events.each do |effect|
    cause_id = effect.metadata[:causation_id]
    if cause_id
      matrix[cause_id] ||= []
      matrix[cause_id] << effect.event_id
    end
  end

  matrix
end
```

---

## 4. Data Lineage Matrix (L)

### Definition

```
L[field][event] = 1  if event modified field
                 0  otherwise
```

**Example for Student.email:**
```
             │ Event1 │ Event2 │ Event3 │ Event4 │
─────────────┼────────┼────────┼────────┼────────┤
email        │   1    │   0    │   1    │   0    │
name         │   1    │   1    │   0    │   0    │
grade        │   0    │   0    │   1    │   1    │
```

This shows:
- email was modified by Events 1 and 3
- name was modified by Events 1 and 2
- grade was modified by Events 3 and 4

### Temporal Lineage Vector

For a specific field, create a vector of (event, timestamp, value) tuples:

```
L_email = [
  (Event1, t1, "alice@old.com" → "alice@new.com"),
  (Event3, t3, "alice@new.com" → "alice@current.com")
]
```

### Lyra Implementation

```ruby
lineage = Lyra::EventFlow.new.data_lineage('email', 'Student')
# => {
#   field: "email",
#   model_class: "Student",
#   total_modifications: 3,
#   first_seen: ...,
#   last_modified: ...,
#   lineage: [
#     {
#       timestamp: "2025-01-15T10:30:00Z",
#       event_id: "...",
#       model: "Student",
#       record_id: 7,
#       operation: :updated,
#       old_value: "alice@old.com",
#       new_value: "alice@new.com",
#       source: "lyra_command_handler",
#       user_id: 42,
#       action: { controller: "students", action: "update" }
#     },
#     ...
#   ]
# }
```

**GDPR Article 15 Compliance:**
Use lineage matrix to provide complete access history to data subject.

---

## 5. PII Exposure Matrix (P)

### Definition

```
P[event][pii_type] = sensitivity_level  if event contains PII of type
                    0                  otherwise

where sensitivity_level ∈ {1: public, 2: internal, 3: confidential, 4: restricted}
```

**Example:**
```
         │ Email │ SSN │ CreditCard │ Name │ Phone │
─────────┼───────┼─────┼────────────┼──────┼───────┤
Event1   │   2   │  0  │     0      │  2   │  2    │
Event2   │   0   │  4  │     4      │  2   │  0    │
Event3   │   2   │  0  │     0      │  0   │  2    │
```

Event2 has highest privacy risk (contains SSN and CreditCard at level 4).

### Privacy Risk Score

**Compute aggregate risk per event:**
```
risk_score(event) = Σ_pii P[event][pii] × weight[pii]

where weight[pii] = sensitivity level
```

**Example:**
```
risk_score(Event1) = 2×1 + 2×1 + 2×1 = 6
risk_score(Event2) = 2×1 + 4×5 + 4×5 = 42  ← High risk!
risk_score(Event3) = 2×1 + 2×1 = 4
```

### Lyra Implementation

```ruby
# Assumes a per-event metadata[:pii_detected] hash, which Lyra does not write
# (its opt-in privacy stamp is metadata[:privacy])
def compute_privacy_risk(event)
  pii = event.metadata[:pii_detected] || {}
  risk = 0

  pii.each do |field, info|
    sensitivity = info[:sensitivity]  # :public, :internal, :confidential, :restricted
    risk += sensitivity_score(sensitivity)
  end

  risk
end

def sensitivity_score(level)
  { public: 1, internal: 2, confidential: 3, restricted: 4 }[level]
end
```

---

## 6. State Transition Matrix (T)

### Definition

For aggregates/models, track state transitions via events:

```
T[state_i][state_j] = count of events transitioning from state_i to state_j
```

**Example for Order states:**
```
            │ pending │ paid │ shipped │ delivered │ cancelled │
────────────┼─────────┼──────┼─────────┼───────────┼───────────┤
pending     │    0    │  45  │    0    │     0     │    12     │
paid        │    0    │   0  │   43    │     0     │     2     │
shipped     │    0    │   0  │    0    │    40     │     3     │
delivered   │    0    │   0  │    0    │     0     │     0     │
cancelled   │    0    │   0  │    0    │     0     │     0     │
```

This shows:
- 45 orders transitioned from pending → paid
- 12 orders were cancelled from pending
- Most common path: pending → paid → shipped → delivered

### Compute State Transition Probabilities

```
P_transition[i][j] = T[i][j] / Σⱼ T[i][j]
```

**Example:**
```
P_transition[pending][paid] = 45 / (45+12) = 0.79 (79% probability)
P_transition[pending][cancelled] = 12 / (45+12) = 0.21 (21% probability)
```

### Lyra Implementation

```ruby
def build_state_transition_matrix(model_class, state_field)
  events = Lyra.event_store.read.of_type("#{model_class}Updated")
  transitions = Hash.new { |h, k| h[k] = Hash.new(0) }

  events.each do |event|
    changes = event.data[:changes]
    if changes[state_field]
      old_state, new_state = changes[state_field]
      transitions[old_state][new_state] += 1
    end
  end

  transitions
end
```

---

## 7. Reachability Matrix (R)

### Definition

From Petri net analysis, compute reachability:

```
R[marking_i][marking_j] = 1  if marking j is reachable from marking i
                         0  otherwise
```

**Use Case:** Privacy violation detection

**Example:**
```
Define markings:
M₀: Initial state (no PII collected)
M₁: PII collected with consent
M₂: PII collected without consent (VIOLATION)
M₃: PII deleted

Reachability matrix:
       │ M₀ │ M₁ │ M₂ │ M₃ │
───────┼────┼────┼────┼────┤
M₀     │ 1  │ 1  │ 0  │ 0  │
M₁     │ 0  │ 1  │ 0  │ 1  │
M₂     │ 0  │ 0  │ 1  │ 0  │  ← Isolated (good!)
M₃     │ 0  │ 0  │ 0  │ 1  │
```

If R[M₀][M₂] = 1, then privacy violation is possible → Fix required!

### Computing Reachability

Use BFS/DFS on state space graph generated from Petri net.

```ruby
def compute_reachability(net, initial_marking)
  reachable = { initial_marking => true }
  queue = [initial_marking]

  while queue.any?
    current = queue.shift

    # Find enabled transitions
    net.transitions.each do |transition|
      if transition.enabled?(current)
        next_marking = transition.fire(current)

        unless reachable[next_marking]
          reachable[next_marking] = true
          queue << next_marking
        end
      end
    end
  end

  reachable.keys
end
```

---

## 8. Policy Compliance Matrix (Pol)

### Definition

Track which events comply with which privacy policies:

```
Pol[event][requirement] = 1  if event satisfies requirement
                         0  otherwise
```

**Example:**
```
         │ Consent │ Purpose │ Minimization │ Retention │ Security │
─────────┼─────────┼─────────┼──────────────┼───────────┼──────────┤
Event1   │    1    │    1    │      1       │     1     │    1     │
Event2   │    0    │    1    │      1       │     1     │    1     │  ← Missing consent!
Event3   │    1    │    1    │      0       │     1     │    1     │  ← Collects too much!
```

### Compliance Score

```
compliance_score(event) = Σ_req Pol[event][req] / total_requirements
```

**Example:**
```
compliance_score(Event1) = 5/5 = 100%
compliance_score(Event2) = 4/5 = 80%  ← Investigate!
compliance_score(Event3) = 4/5 = 80%  ← Investigate!
```

### Lyra Implementation

```ruby
def check_policy_compliance(event, policy)
  requirements = {
    consent: check_consent(event, policy),
    purpose: check_purpose(event, policy),
    minimization: check_minimization(event, policy),
    retention: check_retention(event, policy),
    security: check_security(event, policy)
  }

  score = requirements.values.count(true).to_f / requirements.size

  {
    score: score,
    requirements: requirements,
    violations: requirements.select { |k, v| !v }.keys
  }
end
```

---

## 9. Aggregate Incidence Matrix (A)

### Definition

Track which events affect which aggregates/models:

```
A[event][aggregate] = 1  if event modifies aggregate
                     0  otherwise
```

**Example:**
```
                 │ Student#1 │ Student#2 │ Course#1 │ Enrollment#1 │
─────────────────┼───────────┼───────────┼──────────┼──────────────┤
StudentCreated#1 │     1     │     0     │    0     │      0       │
StudentUpdated#1 │     1     │     0     │    0     │      0       │
CourseCreated#1  │     0     │     0     │    1     │      0       │
EnrollmentCreated│     1     │     0     │    1     │      1       │
```

This shows EnrollmentCreated affects multiple aggregates (Student, Course, Enrollment).

### Cross-Aggregate Impact Analysis

**Question:** Which events have widest impact?

**Answer:** Sum rows to find events affecting most aggregates

```
impact(EnrollmentCreated) = 3  ← Affects 3 aggregates
impact(StudentCreated) = 1      ← Affects 1 aggregate
```

### Lyra Implementation

```ruby
def analyze_aggregate_impact(event)
  affected = []

  # Direct aggregate
  affected << { type: event.data[:model_class], id: event.data[:model_id] }

  # Related aggregates via associations
  model = event.data[:model_class].constantize
  record = model.find(event.data[:model_id])

  model.reflect_on_all_associations.each do |assoc|
    related = record.send(assoc.name)
    affected << { type: assoc.class_name, id: related.id } if related
  end

  affected
end
```

---

## 10. Integration: Matrices + Petri Nets

### Workflow

```
1. Model system with Colored Petri Nets (structural model)
2. Simulate CPN to generate execution traces
3. Build matrices from trace data:
   - CRUD-Event mapping matrix from transition firings
   - Correlation matrix from token colors
   - Causation matrix from token flows
   - Lineage matrix from data transformations
4. Analyze matrices for specific properties:
   - Reachability analysis
   - Impact analysis
   - Compliance scoring
5. Feed insights back to CPN refinement
```

### Example: Privacy Violation Detection

**Step 1: Model in CPN**
```
Places: [PII_Collected, Consent_Granted, PII_Processed]
Transitions: [Collect_PII, Grant_Consent, Process_PII]
Guards: T_Process_PII requires token in Consent_Granted
```

**Step 2: Simulate and extract trace**
```ruby
trace = cpn_simulator.run(steps: 1000)
```

**Step 3: Build reachability matrix**
```ruby
R = build_reachability_matrix(trace)
```

**Step 4: Check for violations**
```ruby
violation_marking = { PII_Processed: 1, Consent_Granted: 0 }
if R[initial_marking][violation_marking] == 1
  puts "PRIVACY VIOLATION POSSIBLE!"
end
```

---

## 11. Matrix Operations for Analysis

### Matrix Multiplication for Multi-Hop Causation

```
Cau² = Cau × Cau  (2-hop causation)
Cau³ = Cau² × Cau (3-hop causation)
```

**Example:**
If Event A causes Event B (Cau[A][B]=1)
And Event B causes Event C (Cau[B][C]=1)
Then Cau²[A][C]=1 (A transitively causes C in 2 hops)

### Matrix Addition for Aggregate Analysis

```
Total_Impact = M_ce + Cau + L + P
```

Combine multiple matrices to get holistic impact score.

### Eigenvalue Analysis for Critical Events

Compute eigenvector centrality on causation matrix to find most influential events:

```ruby
require 'matrix'

def compute_centrality(cau_matrix)
  m = Matrix[*cau_matrix]
  eigenvalues = m.eigenvectors
  eigenvalues.first  # Dominant eigenvector = centrality scores
end
```

Events with high centrality are "hubs" in causation graph.

---

## 12. Practical Implementation in Lyra

### What the gem provides

PetriFlow ships `PetriFlow::Matrix::Analyzer` (also returned by
`PetriFlow.create_analyzer`). It does not read an event store; you feed it
event hashes and it fills the CRUD-mapping, correlation, causation and lineage
matrices (`PetriFlow::Matrix::CrudEventMapping`, `Correlation`, `Causation`,
`Lineage`), plus a reachability matrix computed from a net:

```ruby
analyzer = PetriFlow::Matrix::Analyzer.new
analyzer.analyze_events([
  { event_id: "e1", operation: :create, event_type: "StudentCreated",
    changes: { "email" => [nil, "a@example.org"] }, timestamp: t1 },
  { event_id: "e2", operation: :update, event_type: "StudentUpdated",
    caused_by_event_id: "e1",
    changes: { "email" => ["a@example.org", "b@example.org"] }, timestamp: t2 }
])

analyzer.find_causation_chain("e1", "e2")  # => ["e1", "e2"]
analyzer.field_history("email")            # => [{event_id: "e1", old_value: nil, ...}, ...]
analyzer.flow_completeness                 # => {crud_operations: 2, events_generated: 2, ...}
analyzer.privacy_impact_analysis           # => {fields_tracked: 1, ...}
analyzer.compute_reachability(net, net.current_marking)
analyzer.generate_report                   # => {crud_mapping:, correlation:, causation:, lineage:, reachability:}
```

`generate_report` omits `reachability` until `compute_reachability` has been called.

### Illustrative sketch: matrices straight from the event store

The class below is a hypothetical sketch, not part of PetriFlow or Lyra. It
shows how the matrices of this document could be built directly from Rails
Event Store events. Its `pii_exposure_matrix` assumes a per-event
`metadata[:pii_detected]` hash that Lyra does not write; Lyra's opt-in privacy
stamp is `metadata[:privacy]`.

```ruby
class MatrixAnalyzerSketch  # hypothetical
  def initialize(model_class = nil, time_range = nil)
    @model_class = model_class
    @time_range = time_range
    @events = load_events
  end

  def crud_event_mapping_matrix
    matrix = Hash.new { |h, k| h[k] = Hash.new(0) }

    @events.each do |event|
      operation = event.data[:operation]
      event_type = event.event_type
      matrix[operation][event_type] += 1
    end

    matrix
  end

  def correlation_matrix
    matrix = {}

    @events.each do |e1|
      matrix[e1.event_id] = {}
      @events.each do |e2|
        if e1.metadata[:correlation_id] == e2.metadata[:correlation_id]
          matrix[e1.event_id][e2.event_id] = e1.metadata[:correlation_id]
        else
          matrix[e1.event_id][e2.event_id] = nil
        end
      end
    end

    matrix
  end

  def causation_matrix
    matrix = Hash.new { |h, k| h[k] = Hash.new(0) }

    @events.each do |event|
      cause_id = event.metadata[:causation_id]
      if cause_id
        matrix[cause_id][event.event_id] = 1
      end
    end

    matrix
  end

  def lineage_matrix(field_name)
    matrix = Hash.new { |h, k| h[k] = Hash.new(0) }

    @events.each do |event|
      changes = event.data[:changes] || {}
      attributes = event.data[:attributes] || {}

      if changes[field_name] || attributes[field_name]
        matrix[field_name][event.event_id] = 1
      end
    end

    matrix
  end

  def pii_exposure_matrix
    matrix = {}

    @events.each do |event|
      matrix[event.event_id] = {}
      pii = event.metadata[:pii_detected] || {}

      pii.each do |field, info|
        matrix[event.event_id][info[:pii_type]] = sensitivity_score(info[:sensitivity])
      end
    end

    matrix
  end

  def generate_report
    {
      crud_event_mapping: crud_event_mapping_matrix,
      correlation: correlation_matrix,
      causation: causation_matrix,
      pii_exposure: pii_exposure_matrix,
      statistics: compute_statistics
    }
  end

  private

  def load_events
    scope = Lyra.event_store.read
    scope = scope.of_type(@model_class) if @model_class
    scope = scope.between(@time_range) if @time_range
    scope.to_a
  end

  def sensitivity_score(level)
    { public: 1, internal: 2, confidential: 3, restricted: 4 }[level] || 0
  end

  def compute_statistics
    {
      total_events: @events.count,
      unique_correlations: @events.map { |e| e.metadata[:correlation_id] }.uniq.count,
      pii_events: @events.count { |e| e.metadata[:pii_detected]&.any? },
      average_events_per_crud: @events.count / @events.map { |e| e.metadata[:correlation_id] }.uniq.count.to_f
    }
  end
end
```

### Usage of the sketch:

```ruby
analyzer = MatrixAnalyzerSketch.new('Student', 1.week.ago..Time.current)

# Generate all matrices
report = analyzer.generate_report

# Specific analyses
mapping = analyzer.crud_event_mapping_matrix
# => { CREATE => { "StudentCreated" => 45, "AuditLogCreated" => 45 }, ... }

correlation = analyzer.correlation_matrix
# => { "event1_id" => { "event2_id" => "uuid", ... }, ... }

pii = analyzer.pii_exposure_matrix
# => { "event1_id" => { EMAIL => 2, SSN => 4 }, ... }
```

---

## Summary

**Matrices are ideal for:**
- ✅ Representing static relationships (CRUD→Event mapping)
- ✅ Computing reachability and transitive properties
- ✅ Quantitative analysis (risk scores, compliance scores)
- ✅ Linear algebra operations (centrality, eigenvalues)
- ✅ Efficient storage and querying of relationships

**Use matrices when you need to:**
1. Compute transitive closures (causation chains)
2. Analyze aggregate impact (which events affect which models)
3. Score privacy risk (PII exposure levels)
4. Track data lineage (field modification history)
5. Measure compliance (event-by-requirement matrix)

**Integration with CPN:**
- CPN provides structural model and simulation
- Matrices provide quantitative analysis of simulation results
- Together they give complete picture: structure + metrics

---

## References

1. Cormen, T. H., Leiserson, C. E., Rivest, R. L., & Stein, C. (2009). *Introduction to Algorithms* (3rd ed.). MIT Press. (Chapters on graph algorithms and matrix operations)

2. Newman, M. E. (2010). *Networks: An Introduction*. Oxford University Press. (Matrix representations of networks)

3. Kemeny, J. G., & Snell, J. L. (1976). *Finite Markov Chains*. Springer. (State transition matrices)

4. Pantelelis, M., & Kalloniatis, C. (2024). Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR. *ARES 2024*. (Privacy properties requiring matrix analysis)
