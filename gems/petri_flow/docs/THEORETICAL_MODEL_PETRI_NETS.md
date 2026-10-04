# Theoretical Model: Colored Petri Nets for CRUD-to-Event Mapping

## Overview

This document describes the formal mathematical model for analyzing the Lyra framework's CRUD-to-event mapping and event flow using **Colored Petri Nets (CPNs)**.

## Why Colored Petri Nets?

Colored Petri Nets extend basic Petri nets with:
- **Colored tokens**: Carry data (event metadata, correlation IDs, PII fields)
- **Guards**: Enable/disable transitions based on conditions (PAM policies)
- **Arc expressions**: Transform token values during transition
- **Hierarchical composition**: Model complex systems at multiple abstraction levels

These features directly align with Lyra's architecture:
- Events carry rich metadata (colors)
- Privacy policies guard operations (guards)
- Event mapping transforms data (arc expressions)
- Multi-layer architecture (hierarchical nets)

---

## 1. Core CRUD-to-Event Mapping Model

### Places (P)

```
P₁: CRUD_Initiated         - A CRUD operation has been invoked
P₂: Event_Generated        - Event(s) created from CRUD operation
P₃: PII_Detected          - PII analysis completed
P₄: Policy_Evaluated      - Privacy policy checked
P₅: Event_Published       - Event stored in event store
P₆: Aggregate_Updated     - Aggregate state modified (Hijack mode)
P₇: ORM_Updated           - Database state modified (Monitor mode)
P₈: Correlation_Grouped   - Events grouped by correlation_id
```

### Transitions (T)

```
T_CREATE:  Create operation → CreatedEvent
T_UPDATE:  Update operation → UpdatedEvent
T_DELETE:  Delete operation → DestroyedEvent
T_DETECT:  Analyze event data → Identify PII
T_ENFORCE: Apply privacy policy → Mask/transform data
T_PUBLISH: Validated event → Event store
T_APPLY:   Event → Update aggregate state
T_SYNC:    Aggregate → Update ORM (Hijack mode)
```

### Token Colors (Data Carried by Tokens)

```haskell
-- Token color definition
colset CrudToken = record {
  operation: CrudOp,        -- CREATE | UPDATE | DELETE
  model_class: String,      -- "Student", "Order", etc.
  model_id: Int,           -- Record ID
  attributes: Map<String, Value>,
  changes: Map<String, (Value, Value)>,  -- (old, new)
  correlation_id: UUID,
  action_id: UUID,
  user_id: Int
}

colset EventToken = record {
  event_type: String,       -- "StudentCreated", etc.
  event_id: UUID,
  data: Map<String, Value>,
  metadata: EventMetadata,
  pii_detected: Map<String, PIIInfo>,
  timestamp: Time
}

colset PIIInfo = record {
  pii_type: PIIType,        -- EMAIL | SSN | CREDIT_CARD, etc.
  sensitivity: SensitivityLevel,  -- PUBLIC | INTERNAL | CONFIDENTIAL | RESTRICTED
  allowed_purposes: Set<Purpose>,
  retention_period: Duration
}

colset AggregateToken = record {
  aggregate_id: String,
  aggregate_type: String,
  state: Map<String, Value>,
  version: Int,
  pending_events: Seq<EventToken>
}
```

### Arc Expressions and Guards

**T_CREATE Transition:**
```haskell
-- Input arc from P₁ (CRUD_Initiated)
input_arc: CrudToken

-- Guard (when transition can fire)
guard: input_arc.operation = CREATE

-- Output arc to P₂ (Event_Generated)
output_arc: EventToken {
  event_type = input_arc.model_class + "Created",
  event_id = newUUID(),
  data = input_arc.attributes,
  metadata = {
    user_id = input_arc.user_id,
    correlation_id = input_arc.correlation_id,
    action_id = input_arc.action_id
  },
  pii_detected = {},  -- Filled by T_DETECT
  timestamp = now()
}
```

**T_DETECT Transition (PII Detection):**
```haskell
-- Input: EventToken from P₂
-- Output: Same EventToken with pii_detected populated

guard: true  -- Always fires

output: input_event with {
  pii_detected = detectPII(input_event.data)
}

-- Function detectPII
function detectPII(data: Map<String, Value>): Map<String, PIIInfo>
  result = {}
  for (field, value) in data:
    if matches(field, PII_PATTERNS.email):
      result[field] = PIIInfo{EMAIL, INTERNAL, {...}, 7.years}
    if matches(field, PII_PATTERNS.ssn):
      result[field] = PIIInfo{SSN, RESTRICTED, {...}, 10.years}
    ...
  return result
```

**T_ENFORCE Transition (Privacy Policy Application):**
```haskell
-- Guard: Check if policy exists and consent required
guard:
  hasPolicy(input_event.metadata.model_class) AND
  (NOT requiresConsent(input_event.pii_detected) OR
   hasConsent(input_event.metadata.user_id, purposes))

-- Output: Event with masked/transformed PII if needed
output: applyPolicyTransforms(input_event, policy)
```

---

## 2. Monitor Mode vs Hijack Mode

### Monitor Mode Net

```
           ┌─────────────────────┐
           │  CRUD_Initiated     │ (P₁)
           └──────────┬──────────┘
                      │
          ┌───────────┴──────────┐
          │                      │
          ▼                      ▼
   ┌──────────┐           ┌──────────────┐
   │   ORM    │           │  Event Gen   │ (T_CREATE/UPDATE/DELETE)
   │  Updated │           │              │
   └─────┬────┘           └──────┬───────┘
         │                       │
         │                       ▼
         │                ┌──────────────┐
         │                │Event_Generated│ (P₂)
         │                └──────┬────────┘
         │                       │
         │                   [PII Detection & Policy paths...]
         │                       │
         │                       ▼
         │                ┌──────────────┐
         │                │Event_Published│ (P₅)
         │                └──────────────┘
         │
         └───── Both complete independently ─────┘
```

**Key Property**: Two parallel paths - ORM and Event Store are independent

### Hijack Mode Net

```
           ┌─────────────────────┐
           │  CRUD_Initiated     │ (P₁)
           └──────────┬──────────┘
                      │
                      ▼
              ┌───────────────┐
              │Command_Created│ (T_CMD)
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │Event_Generated│ (P₂)
              └───────┬───────┘
                      │
              [PII Detection & Policy paths...]
                      │
                      ▼
              ┌───────────────┐
              │Event_Published│ (P₅)
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │  Apply Event  │ (T_APPLY)
              │ to Aggregate  │
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │Aggregate_State│ (P₆)
              │   Updated     │
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │  Sync to ORM  │ (T_SYNC)
              └───────┬───────┘
                      │
                      ▼
              ┌───────────────┐
              │  ORM_Updated  │ (P₇)
              └───────────────┘
```

**Key Property**: Sequential flow - Event sourcing is source of truth, ORM synchronized

### Fork and Join Patterns

Petri nets naturally model **concurrent** and **parallel** behavior through Fork (parallel split) and Join (synchronization) patterns.

#### Fork Pattern (AND-split)

A fork occurs when one transition produces tokens in multiple output places simultaneously:

```
               ┌─────────────────┐
               │ Events_Stored   │ (P)
               └────────┬────────┘
                        │
                        ▼
               ┌────────────────┐
               │   async_fork   │ (T) ← Single transition
               └───────┬────────┘
                       │
         ┌─────────────┴─────────────┐
         │                           │
         ▼                           ▼
┌─────────────────┐       ┌─────────────────┐
│ Response_Sent   │       │ Job_Processing  │
│   (terminal)    │       │  (continues)    │
└─────────────────┘       └─────────────────┘
```

**Formal Definition:**
- Let T be a transition with output arcs to places P₁, P₂, ..., Pₙ
- When T fires, it produces tokens in ALL output places simultaneously
- This models **parallel execution** (AND semantics)

**PetriFlow DSL:**
```ruby
# Fork: one transition → multiple output places
transition :async_fork, from: :events_stored, to: [:response_sent, :job_processing]
```

#### Join Pattern (AND-join / Synchronization)

A join occurs when one transition consumes tokens from multiple input places:

```
┌─────────────────┐       ┌─────────────────┐
│    Task_A       │       │    Task_B       │
│  (completed)    │       │  (completed)    │
└────────┬────────┘       └────────┬────────┘
         │                         │
         └───────────┬─────────────┘
                     │
                     ▼
            ┌────────────────┐
            │  synchronize   │ (T) ← Waits for BOTH tokens
            └───────┬────────┘
                    │
                    ▼
            ┌────────────────┐
            │  Synchronized  │ (P)
            └────────────────┘
```

**Formal Definition:**
- Let T be a transition with input arcs from places P₁, P₂, ..., Pₙ
- T is enabled only when ALL input places have tokens
- When T fires, it consumes tokens from ALL input places
- This models **synchronization** (wait for all)

**PetriFlow DSL:**
```ruby
# Join: multiple input places → one transition
transition :synchronize, from: [:task_a, :task_b], to: :synchronized
```

#### Choice Pattern (XOR-split) vs Fork

It's important to distinguish **Fork** (AND-split) from **Choice** (XOR-split):

| Pattern | Petri Net Structure | Semantics |
|---------|---------------------|-----------|
| **Choice** | Multiple transitions from one place | Pick ONE path (exclusive OR) |
| **Fork** | One transition to multiple places | ALL paths execute (parallel AND) |

```
CHOICE (XOR-split):           FORK (AND-split):
       ┌── T1 ── P1              P0 ── T ──┬── P1
  P0 ──┤                                   │
       └── T2 ── P2                        └── P2

Only T1 OR T2 fires            T fires, both P1 AND P2 get tokens
```

#### Application in Lyra: ES Async Mode

The Event Sourcing Async Mode uses a **fork pattern** to model true async behavior:

```ruby
# After events are stored, response returns AND background job starts simultaneously
transition :async_fork, from: :events_stored,
           to: [:response_returned, :job_processing],
           trigger: "Enqueue job & return response (parallel)"
```

This correctly models that:
1. **Response returns immediately** to the caller (non-blocking)
2. **Background job starts** processing independently
3. Both happen **simultaneously** after the fork fires

---

## 3. Incorporating PAM (Privacy Attribute Matrix)

### Privacy Policy as Guards on Transitions

PAM policies are modeled as **guards** that enable/disable transitions based on:
- Field sensitivity levels
- Purpose requirements
- Consent status
- Retention policies

### Extended Token Color for PAM

```haskell
colset PolicyToken = record {
  policy_name: String,
  fields: Map<String, FieldPolicy>,
  purposes: Map<String, Purpose>,
  retention_rules: Map<String, RetentionRule>,
  consent_rules: Map<String, ConsentRule>
}

colset FieldPolicy = record {
  field_name: String,
  pii_type: PIIType,
  sensitivity: SensitivityLevel,
  allowed_purposes: Set<Purpose>,
  transformations: Map<Context, Transform>
}

colset Purpose = record {
  name: String,
  legal_basis: LegalBasis,  -- CONSENT | CONTRACT | LEGAL_OBLIGATION, etc.
  required_fields: Set<String>,
  optional_fields: Set<String>
}

colset ConsentRule = record {
  purpose: String,
  required: Bool,
  granular: Bool,
  withdrawable: Bool,
  expires_in: Duration
}
```

### Privacy-Enhanced Transitions

**T_ENFORCE with PAM:**
```haskell
-- Input: EventToken + PolicyToken
input: (event: EventToken, policy: PolicyToken)

-- Guard: Check all privacy constraints
guard:
  -- 1. All PII fields have policy definitions
  forall field in event.pii_detected.keys:
    exists field_policy in policy.fields where field_policy.field_name = field

  AND

  -- 2. If consent required, check it's granted and valid
  forall field in event.pii_detected.keys:
    let field_policy = policy.fields[field]
    forall purpose in field_policy.allowed_purposes:
      if policy.consent_rules[purpose].required:
        hasValidConsent(event.metadata.user_id, purpose)

  AND

  -- 3. Processing has legal basis
  hasLegalBasis(event.metadata.action_type, policy)

-- Output: Event with policy enforcement applied
output: event with {
  data = applyTransformations(event.data, policy, context=STORAGE),
  metadata = event.metadata + {
    policy_applied: policy.policy_name,
    consent_verified: checkConsentStatus(...),
    retention_period: calculateRetention(event, policy)
  }
}
```

**T_ACCESS (new transition for data access):**
```haskell
-- Models reading event data for specific purpose
transition T_ACCESS:
  input: (event: EventToken, purpose: Purpose, policy: PolicyToken)

  guard:
    -- Check purpose is allowed for all PII fields
    forall field in event.pii_detected.keys:
      purpose in policy.fields[field].allowed_purposes

    AND

    -- Check consent if required
    if policy.consent_rules[purpose.name].required:
      hasValidConsent(event.data.user_id, purpose.name)

  output: event with {
    data = applyTransformations(
      event.data,
      policy,
      context=PURPOSE_CONTEXT[purpose.name]
    )
  }
```

### Privacy Places

Add places to track privacy state:

```
P_CONSENT_GRANTED:   User has granted consent for purpose
P_CONSENT_EXPIRED:   Consent has expired
P_RETENTION_ACTIVE:  Data within retention period
P_RETENTION_EXPIRED: Data should be deleted/anonymized
P_ACCESS_LOGGED:     Access to PII has been logged
```

### Privacy Transitions

```
T_GRANT_CONSENT:   User action → P_CONSENT_GRANTED
T_EXPIRE_CONSENT:  Time passes → P_CONSENT_EXPIRED
T_CHECK_RETENTION: Timer → Evaluate retention rules
T_ANONYMIZE:       Retention expired → Anonymize data
T_LOG_ACCESS:      Data read → P_ACCESS_LOGGED
```

---

## 4. Event Flow Analysis with Petri Nets

### Correlation Flow Net

Models how multiple events are grouped by `correlation_id`:

```
                    User Action
                         │
                         ▼
              ┌──────────────────┐
              │ Correlation ID   │
              │   Generated      │
              └────────┬─────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ Event 1 │  │ Event 2 │  │ Event 3 │
   └────┬────┘  └────┬────┘  └────┬────┘
        │            │            │
        └────────────┼────────────┘
                     │
                     ▼
              ┌─────────────┐
              │ Correlation │
              │   Group     │
              └─────────────┘
```

**Token Color:**
```haskell
colset CorrelationToken = record {
  correlation_id: UUID,
  user_action: UserAction,
  events: Seq<EventToken>,
  started_at: Time,
  completed_at: Option<Time>
}
```

### Causation Net

Models how Event A causes Event B:

```
   ┌─────────────┐
   │  Event A    │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐
   │ Causation   │ (records: A causes B)
   │  Tracked    │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐
   │  Event B    │
   │ (caused by A)│
   └─────────────┘
```

---

## 5. State Reconstruction Model

### Aggregate State Evolution Net

```
        Initial State (P₀)
              │
              ▼
        ┌──────────┐
        │  Event 1 │ → Apply → State₁
        └──────────┘
              │
              ▼
        ┌──────────┐
        │  Event 2 │ → Apply → State₂
        └──────────┘
              │
              ▼
             ...
              │
              ▼
        ┌──────────┐
        │  Event N │ → Apply → State_N (Current)
        └──────────┘
```

**Mathematical Property:**
```
State_current = State₀ ⊕ Event₁ ⊕ Event₂ ⊕ ... ⊕ Event_N

where ⊕ is the event application operator
```

**In CPN:**
```haskell
transition T_APPLY_EVENT:
  input: (state: AggregateToken, event: EventToken)

  output: state with {
    state = applyEvent(state.state, event),
    version = state.version + 1
  }

function applyEvent(current_state, event):
  case event.operation:
    CREATED:
      return event.data
    UPDATED:
      new_state = current_state
      for (field, [old, new]) in event.changes:
        new_state[field] = new
      return new_state
    DESTROYED:
      return current_state + {_deleted: true}
```

---

## 6. Formal Analysis Capabilities

### 6.1 Reachability Analysis

**Question:** Can we reach a state where PII is stored without consent?

**CPN Analysis:**
- Check if marking `M_unauthorized = {P_EVENT_PUBLISHED with pii AND P_CONSENT_EXPIRED}` is reachable
- If reachable → Privacy violation possible
- If not reachable → Guard enforcement is correct

### 6.2 Boundedness Analysis

**Question:** Can the system accumulate unbounded events?

**CPN Analysis:**
- Check if `P_EVENT_GENERATED` is bounded
- If unbounded → Memory leak risk
- Helps validate retention policy enforcement

### 6.3 Liveness Analysis

**Question:** Can the system deadlock?

**CPN Analysis:**
- Check if all transitions can eventually fire
- Ensures event processing doesn't stall
- Validates monitor/hijack mode correctness

### 6.4 Invariant Checking

**Invariant 1: Event-ORM Consistency**
```
∀t: State_ORM(t) = State_EventSourced(t)
```

**Invariant 2: PII Always Detected**
```
∀event ∈ P_EVENT_PUBLISHED:
  event.pii_detected ≠ {} OR containsNoPII(event.data)
```

**Invariant 3: Privacy Policy Always Applied**
```
∀event ∈ P_EVENT_PUBLISHED:
  hasPolicy(event.model_class) ⟹ event.metadata.policy_applied ≠ null
```

---

## 7. Hierarchical Model Structure

### Top Level: System Architecture

```
┌────────────────────────────────────────────────────┐
│              Lyra System CPN                       │
│                                                    │
│   ┌──────────────┐       ┌──────────────┐        │
│   │ CRUD Layer   │───────│ Event Layer  │        │
│   │     Net      │       │     Net      │        │
│   └──────────────┘       └──────────────┘        │
│                                                    │
│   ┌──────────────┐       ┌──────────────┐        │
│   │ Privacy      │───────│  Aggregate   │        │
│   │  Layer Net   │       │  Layer Net   │        │
│   └──────────────┘       └──────────────┘        │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Mid Level: Privacy Layer Detail

```
┌────────────────────────────────────────────────────┐
│            Privacy Layer CPN                       │
│                                                    │
│   ┌──────────────┐  ┌──────────────┐            │
│   │ PII          │──│ Policy       │            │
│   │ Detection    │  │ Enforcement  │            │
│   └──────────────┘  └──────────────┘            │
│                                                    │
│   ┌──────────────┐  ┌──────────────┐            │
│   │ Consent      │──│ Retention    │            │
│   │ Management   │  │ Management   │            │
│   └──────────────┘  └──────────────┘            │
│                                                    │
└────────────────────────────────────────────────────┘
```

### Low Level: Consent Management Detail

```
[Detailed transitions for consent granting, expiry, withdrawal, etc.]
```

---

## 8. Complementary Use of Matrices

While CPNs are the primary model, matrices are useful for:

### 8.1 CRUD-Event Mapping Matrix

```
         │ Created │ Updated │ Destroyed │
─────────┼─────────┼─────────┼───────────┤
CREATE   │    1    │    0    │     0     │
UPDATE   │    0    │    1    │     0     │
DELETE   │    0    │    0    │     1     │
```

Extended for multiple event generation:
```
         │ Primary │ Audit │ Notification │
─────────┼─────────┼───────┼──────────────┤
CREATE   │    1    │   1   │      1       │
UPDATE   │    1    │   1   │      0       │
DELETE   │    1    │   1   │      1       │
```

### 8.2 Reachability Matrix

Computed from Petri net structure:
```
R[i][j] = 1 if state j is reachable from state i
         0 otherwise
```

Use for: Verifying privacy property reachability

### 8.3 Causation Matrix

```
C[e1][e2] = 1 if event e1 causes event e2
           0 otherwise
```

Compute transitive closure: `C* = C ∪ C² ∪ C³ ∪ ...`

### 8.4 Data Lineage Matrix

```
L[field][event] = 1 if event modified field
                 0 otherwise
```

Use for: Tracing field history, GDPR Article 15 compliance

### 8.5 Adjacency Matrix (Event Flow Graph)

```
A[e1][e2] = weight if e1 → e2 in event flow
           0 otherwise
```

Use for: Graph algorithms (shortest path, betweenness centrality)

---

## 9. Practical Implementation with CPN Tools

### Recommended Tools

1. **CPN Tools** (http://cpntools.org/)
   - Industry-standard CPN modeling
   - Simulation and state-space analysis
   - ML-based color definitions

2. **GreatSPN** (https://github.com/greatspn/SOURCES)
   - Performance analysis
   - Stochastic Petri nets support

3. **PIPE** (Platform Independent Petri net Editor)
   - Open source, Java-based
   - Good for teaching/prototyping

### Example CPN Tools Declaration

```sml
(* Color definitions *)
colset CrudOp = with CREATE | UPDATE | DELETE;
colset String = string;
colset Int = int;
colset UUID = string;
colset Attributes = list (String * String);
colset Changes = list (String * (String * String));

colset CrudToken = record {
  operation: CrudOp,
  model_class: String,
  model_id: Int,
  attributes: Attributes,
  changes: Changes,
  correlation_id: UUID,
  user_id: Int
};

(* Places *)
place CRUD_Initiated: CrudToken;
place Event_Generated: EventToken;

(* Transition *)
trans T_CREATE
  in: CRUD_Initiated
  out: Event_Generated
  guard: #operation in = CREATE
  arc_expr: {
    event_type = #model_class in ^ "Created",
    ...
  };
```

---

## 10. Analysis Workflow

### Step 1: Model Construction
1. Define token colors (event metadata, PII info, policy rules)
2. Define places (states in CRUD-event pipeline)
3. Define transitions (mapping operations, privacy checks)
4. Add guards (PAM policy constraints)
5. Define arc expressions (data transformations)

### Step 2: Static Analysis
1. **Structural analysis:** Check for syntactic correctness
2. **Boundedness:** Ensure no unbounded token accumulation
3. **Liveness:** Verify no deadlocks
4. **Conservation:** Check token count properties

### Step 3: State-Space Analysis
1. Generate reachability graph
2. Check privacy invariants
3. Verify GDPR compliance properties
4. Identify potential violations

### Step 4: Simulation
1. Inject realistic CRUD operations
2. Observe event generation patterns
3. Validate correlation grouping
4. Test policy enforcement

### Step 5: Performance Analysis
1. Add timing information (Timed CPNs)
2. Measure event processing latency
3. Identify bottlenecks
4. Optimize transition ordering

---

## 11. Research Questions Addressable with This Model

### RQ1: CRUD-Event Mapping Completeness
**Question:** Does every CRUD operation generate at least one event?

**CPN Analysis:** Check if ∀ CRUD token in P₁, ∃ Event token in P₅

### RQ2: Privacy Policy Coverage
**Question:** Is every PII field governed by a policy?

**CPN Analysis:** Check guard on T_ENFORCE always satisfied

### RQ3: Event Flow Consistency
**Question:** Are correlated events always processed in logical order?

**CPN Analysis:** Analyze token timestamps in correlation groups

### RQ4: State Reconstruction Accuracy
**Question:** Does event replay produce identical state to ORM?

**CPN Analysis:** Compare tokens in P₆ (Aggregate) vs P₇ (ORM)

### RQ5: Retention Compliance
**Question:** Are retention policies enforced automatically?

**CPN Analysis:** Check T_ANONYMIZE fires for expired retention

---

## 12. Integration with Lyra Codebase

### Mapping Code to CPN Elements

| Code Element | CPN Element | Description |
|--------------|-------------|-------------|
| `Lyra::Interceptors::CrudInterceptor#lyra_intercept_*` | Transition T_CREATE/UPDATE/DELETE | CRUD operation detection |
| `Lyra::EventMapper.map_operation` | Arc expression | CRUD → Event transformation |
| `Lyra::Event` | Token color EventToken | Event data structure |
| `Lyra::Privacy::PIIDetector.detect` | Transition T_DETECT | PII identification |
| `Lyra::Privacy::PolicyIntegration` | Guard on T_ENFORCE | Privacy policy application |
| `Lyra::Aggregate#apply` | Transition T_APPLY | Event → State transformation |
| `Lyra::CommandHandler.handle` | Place P₁ → T_CMD → P₂ | Hijack mode command flow |
| `Lyra::Correlation.with_id` | Token color CorrelationToken | Event grouping |
| `PamDsl::Field` | PolicyToken.fields[field] | Field-level policy |
| `PamDsl::Purpose` | PolicyToken.purposes[purpose] | Purpose definition |
| `PamDsl::ConsentPolicy`, `ConsentRequirement`, `ConsentStore`, `ConsentRecord` | Guard on T_ACCESS | Consent requirement and per-subject consent state |

### Validation Strategy

The sketch below is illustrative pseudocode. `Lyra::ExecutionTrace` and
`CPNSimulator` are hypothetical names that exist in neither Lyra nor
PetriFlow; the closest real pieces are the events Lyra publishes to Rails
Event Store and `PetriFlow::Simulation::Simulator`, whose `Trace` records the
firing sequence.

```ruby
# Illustrative pseudocode: test that the CPN model matches actual behavior

# 1. Record actual execution trace (hypothetical API)
trace = Lyra::ExecutionTrace.record do
  student = Student.create!(name: "Alice", email: "alice@example.com")
end

# 2. Simulate in CPN model (hypothetical API)
cpn_trace = CPNSimulator.simulate(
  initial_token: CrudToken{CREATE, "Student", ...}
)

# 3. Compare traces
assert trace.events.count == cpn_trace.fired_transitions.count
assert trace.final_state == cpn_trace.final_marking
```

---

## 13. Future Extensions

### Extension 1: Timed Colored Petri Nets (TCPNs)
- Add time delays to transitions
- Model retention expiry timing
- Analyze performance metrics
- Simulate real-world timing behavior

### Extension 2: Stochastic Colored Petri Nets (SCPNs)
- Add probabilistic transition firing
- Model failure scenarios (network, database)
- Reliability analysis
- Performance prediction

### Extension 3: Hierarchical CPNs
- Multi-level decomposition
- Microservices architecture modeling
- Distributed event sourcing
- Cross-system data flows

---

## Summary

**Primary Model:** Colored Petri Nets (CPNs)
- Best for concurrent event generation
- Natural representation of event flows
- Privacy policies as guards
- Formal analysis capabilities

**Complementary Models:** Matrices
- CRUD-Event mapping matrix
- Reachability matrix
- Data lineage matrix
- Causation matrix

**PAM Integration:**
- Policies as guards on transitions
- Consent as place predicates
- Retention as timed transitions
- Purpose as arc expression context

This model provides:
✅ Formal semantics for CRUD-event mapping
✅ Privacy policy enforcement verification
✅ Event flow analysis
✅ State consistency validation
✅ GDPR compliance checking
✅ Performance analysis foundation

---

## References

1. Jensen, K., & Kristensen, L. M. (2009). *Colored Petri Nets: Modelling and Validation of Concurrent Systems*. Springer.

2. Reisig, W. (2013). *Understanding Petri Nets: Modeling Techniques, Analysis Methods, Case Studies*. Springer.

3. Murata, T. (1989). Petri nets: Properties, analysis and applications. *Proceedings of the IEEE*, 77(4), 541-580.

4. van der Aalst, W. M. (1998). The application of Petri nets to workflow management. *Journal of circuits, systems, and computers*, 8(01), 21-66.

5. Pantelelis, M., & Kalloniatis, C. (2022). Mapping CRUD to Events: Towards an object to event-sourcing framework. *PCI 2022*.

6. Pantelelis, M., & Kalloniatis, C. (2024). Create, Read, Update, Delete: Implications on Security and Privacy Principles regarding GDPR. *ARES 2024*.
