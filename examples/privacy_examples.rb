# Lyra Privacy and GDPR Compliance Examples

# ============================================
# 1. TRACKING USER ACTIONS WITH CONTEXT
# ============================================

# Wrap user actions in context to track them through event flow
Lyra::UserActionContext.with_context(
  action_type: :web_request,
  user_id: current_user.id,
  controller: 'students',
  action_name: 'create',
  params: params
) do
  # All CRUD operations within this block will be correlated
  student = Student.create!(
    name: "John Doe",
    email: "john@example.com",
    student_id: "STU123"
  )

  # Enroll in course
  course = Course.find_by(code: "CS101")
  enrollment = course.enroll_student!(student)

  # All these operations will have the same correlation_id
  # and will be linked back to the user action
end

# ============================================
# 2. PII DETECTION AND INVENTORY
# ============================================

# Detect PII in specific attributes
attributes = { email: "john@example.com", name: "John Doe", age: 25 }
pii_fields = Lyra::Privacy::PIIDetector.detect(attributes)
# => {
#      email: { type: :email, value: "john@example.com", sensitive: false },
#      name: { type: :name, value: "John Doe", sensitive: false }
#    }

# Extract PII inventory from event stream
student = Student.find(123)
stream_name = "Student$#{student.id}"
events = Lyra.config.event_store.read.stream(stream_name).to_a
pii_inventory = Lyra::Privacy::PIIDetector.extract_from_event_stream(events)
# => {
#      email: [{ event_id: "...", field: :email, value: "...", timestamp: ... }],
#      name: [{ event_id: "...", field: :name, value: "...", timestamp: ... }],
#      phone: [...]
#    }

# Mask PII for display
masked_email = Lyra::Privacy::PIIDetector.mask("john@example.com", :email)
# => "j***@example.com"

# ============================================
# 3. GDPR RIGHT TO ACCESS (Article 15)
# ============================================

# Export all data about a subject
compliance = Lyra::Privacy::GDPRCompliance.new(
  subject_id: student.id,
  subject_type: 'Student'
)

data_export = compliance.data_export
# => {
#      subject: { id: 123, type: 'Student' },
#      generated_at: Time.current,
#      events: [...],  # All events related to the student
#      pii_inventory: {...},  # All PII fields
#      data_lineage: {...},  # How PII has changed over time
#      processing_activities: [...]  # What processing has been done
#    }

# ============================================
# 4. GDPR RIGHT TO BE FORGOTTEN (Article 17)
# ============================================

# Get report on what needs to be deleted
deletion_report = compliance.right_to_be_forgotten_report
# => {
#      subject: { id: 123, type: 'Student' },
#      total_events: 45,
#      events_with_pii: 30,
#      affected_streams: ["Student-123", "Enrollment-456", "Payment-789"],
#      affected_models: ["Student", "Enrollment", "Payment", "Invoice"],
#      deletion_strategy: :batch_deletion,
#      dependencies: [...]  # Other records that reference this student
#    }

# ============================================
# 5. GDPR RIGHT TO DATA PORTABILITY (Article 20)
# ============================================

# Export in JSON format
json_export = compliance.portable_export(format: :json)

# Export in CSV format
csv_export = compliance.portable_export(format: :csv)

# Export in XML format
xml_export = compliance.portable_export(format: :xml)

# API endpoint for portable export
# GET /lyra/privacy/portable_export/Student/123?format=json

# ============================================
# 6. RECTIFICATION HISTORY (Article 16)
# ============================================

# Track all corrections made to student data
rectification_history = compliance.rectification_history
# => [
#      {
#        timestamp: ...,
#        model: "Student",
#        record_id: 123,
#        changes: { email: ["old@example.com", "new@example.com"] },
#        corrected_fields: { email: { from: "old@example.com", to: "new@example.com" } },
#        metadata: { user_id: 1, ... }
#      },
#      ...
#    ]

# ============================================
# 7. PROCESSING ACTIVITIES RECORD (Article 30)
# ============================================

# Get record of all processing activities
processing_activities = compliance.processing_activities
# => [
#      {
#        source: "registration",
#        purpose: "Account creation and management",
#        legal_basis: "Consent",
#        data_categories: ["Email", "Name", "Phone"],
#        recipients: [],
#        retention_period: "7 years",
#        events_count: 15
#      },
#      ...
#    ]

# ============================================
# 8. DATA RETENTION COMPLIANCE
# ============================================

# Check retention compliance
retention_check = compliance.retention_compliance_check
# => [
#      {
#        model_class: "Student",
#        total_events: 45,
#        expired_events: 5,
#        retention_period: 7 years,
#        compliance_status: :requires_action,
#        expired_event_ids: [...]
#      },
#      ...
#    ]

# Configure retention policies
Lyra.configure do |config|
  config.retention_policy = {
    'Student' => { duration: 10.years },
    'Payment' => { duration: 10.years },
    'Invoice' => { duration: 10.years },
    default: { duration: 7.years }
  }
end

# ============================================
# 9. CONSENT TRACKING
# ============================================

# Audit consent history
consent_audit = compliance.consent_audit
# => {
#      current_consents: {
#        "marketing_emails" => { granted: true, timestamp: ..., expires_at: ... },
#        "data_analytics" => { granted: false, timestamp: ..., expires_at: nil }
#      },
#      consent_history: [...],
#      processing_legitimacy: [...]  # Verify each processing has valid consent
#    }

# ============================================
# 10. EVENT FLOW VISUALIZATION
# ============================================

# Get complete event flow for a student
flow = Lyra::EventFlow.new(subject_id: student.id, subject_type: 'Student')
flow_data = flow.flow_data
# => {
#      timeline: [...],  # Chronological list of events
#      flows: [...],  # Grouped by correlation ID
#      statistics: {...},  # Event statistics
#      privacy_impact: {...}  # Privacy analysis
#    }

# Build timeline view
timeline = flow.build_timeline(events)
# => [
#      {
#        event_id: "...",
#        timestamp: ...,
#        operation: :created,
#        model_class: "Student",
#        model_id: 123,
#        correlation_id: "corr_...",
#        action_id: "action_...",
#        user_action: { type: :web_request, controller: "students", action: "create" },
#        changes: {...},
#        pii_fields: {...},
#        grouped_with: [...]  # Other events in same action
#      },
#      ...
#    ]

# ============================================
# 11. CRUD TO EVENT MAPPING
# ============================================

# See how a CRUD operation maps to events
flow = Lyra::EventFlow.new
mapping = flow.crud_to_event_mapping('Student', :created, student.id)
# => {
#      crud_operation: { model: 'Student', operation: :created, record_id: 123 },
#      generated_events: [...],
#      count: 3,  # One CRUD operation generated 3 events
#      timeline: [...]
#    }

# ============================================
# 12. STATE RECONSTRUCTION CHAIN
# ============================================

# Reconstruct how state evolved through events
state_chain = flow.reconstruct_state_chain('Student', student.id)
# => {
#      model: { class: 'Student', id: 123 },
#      initial_state: {},
#      final_state: { name: "John Updated", email: "john.new@example.com", ... },
#      events_count: 10,
#      state_evolution: [
#        {
#          event_id: "...",
#          timestamp: ...,
#          operation: :created,
#          previous_state: {},
#          changes: {},
#          new_state: { name: "John Doe", email: "john@example.com" },
#          pii_changed: {},
#          user_action: {...}
#        },
#        {
#          event_id: "...",
#          timestamp: ...,
#          operation: :updated,
#          previous_state: { name: "John Doe", ... },
#          changes: { email: ["john@example.com", "john.new@example.com"] },
#          new_state: { name: "John Doe", email: "john.new@example.com" },
#          pii_changed: { email: { from: "john@example.com", to: "john.new@example.com" } },
#          user_action: {...}
#        },
#        ...
#      ]
#    }

# ============================================
# 13. DATA LINEAGE TRACKING
# ============================================

# Track how a specific field has changed
lineage = flow.data_lineage('email', 'Student')
# => {
#      field: 'email',
#      model_class: 'Student',
#      total_modifications: 5,
#      first_seen: ...,
#      last_modified: ...,
#      lineage: [
#        {
#          timestamp: ...,
#          event_id: "...",
#          model: "Student",
#          record_id: 123,
#          operation: :created,
#          old_value: nil,
#          new_value: "john@example.com",
#          source: "registration",
#          user_id: nil,
#          action: {...}
#        },
#        {
#          timestamp: ...,
#          event_id: "...",
#          model: "Student",
#          record_id: 123,
#          operation: :updated,
#          old_value: "john@example.com",
#          new_value: "john.new@example.com",
#          source: "profile_update",
#          user_id: 123,
#          action: {...}
#        },
#        ...
#      ]
#    }

# ============================================
# 14. PRIVACY IMPACT ANALYSIS
# ============================================

# Analyze privacy impact of all events
privacy_analysis = flow.privacy_impact_analysis
# => {
#      total_events: 100,
#      events_with_pii: 65,
#      pii_categories: [:email, :name, :phone, :address],
#      pii_fields_count: 150,
#      sensitive_operations: [...],  # Updates/deletes of PII
#      data_flows: {...},  # How PII flows between models
#      risk_assessment: {
#        overall_risk: :medium,
#        factors: [
#          { level: :high, reason: "Contains highly sensitive PII" },
#          { level: :medium, reason: "Frequent PII modifications" }
#        ],
#        recommendations: [
#          "Implement field-level encryption for sensitive PII",
#          "Enable audit logging for all sensitive data access",
#          "Regular GDPR compliance audits recommended"
#        ]
#      }
#    }

# ============================================
# 15. VISUALIZATION ENDPOINTS
# ============================================

# HTML timeline visualization
# GET /lyra/flow/timeline?subject_id=123&subject_type=Student&format=html

# JSON timeline data
# GET /lyra/flow/timeline?subject_id=123&subject_type=Student

# Event chain for a specific record
# GET /lyra/flow/event_chain/Student/123

# CRUD to event mapping
# GET /lyra/flow/crud_mapping?model_class=Student&operation=created&model_id=123

# Mermaid diagram
# GET /lyra/flow/visualization/Student/123?format=mermaid

# D3.js data
# GET /lyra/flow/visualization/Student/123?format=d3

# ASCII timeline
# GET /lyra/flow/visualization/Student/123?format=ascii

# Correlation group
# GET /lyra/flow/correlation/corr_1234567890_abc123

# User actions
# GET /lyra/flow/user_actions/123

# ============================================
# 16. GDPR API ENDPOINTS
# ============================================

# Complete data export for a subject
# GET /lyra/privacy/subject/Student/123

# Full GDPR compliance report
# GET /lyra/privacy/gdpr_report/Student/123

# Portable export (JSON, CSV, XML)
# GET /lyra/privacy/portable_export/Student/123?format=json
# GET /lyra/privacy/portable_export/Student/123?format=csv
# GET /lyra/privacy/portable_export/Student/123?format=xml

# PII inventory
# GET /lyra/privacy/pii_inventory/Student/123

# Data lineage for a field
# GET /lyra/privacy/data_lineage/email?model_class=Student

# System-wide PII detection
# GET /lyra/privacy/pii_detection

# ============================================
# 17. INTEGRATION WITH CONTROLLERS
# ============================================

# In your Rails controllers, wrap actions in UserActionContext
class StudentsController < ApplicationController
  def create
    Lyra::UserActionContext.with_context(
      action_type: :web_request,
      user_id: current_user&.id,
      controller: controller_name,
      action_name: action_name,
      params: params.except(:password)
    ) do
      @student = Student.create!(student_params)
      # All CRUD operations will be tracked
    end

    redirect_to @student
  end
end

# In background jobs
class StudentEmailJob < ApplicationJob
  def perform(student_id)
    Lyra::UserActionContext.with_context(
      action_type: :background_job,
      params: { job: self.class.name, student_id: student_id }
    ) do
      student = Student.find(student_id)
      StudentMailer.welcome(student).deliver_now
      student.update!(email_sent: true)
      # Operations tracked as background job
    end
  end
end

# ============================================
# 18. CORRELATION GROUPING
# ============================================

# Manually group operations
Lyra::Correlation.with_id do |correlation_id|
  # All operations share the same correlation ID
  student = Student.create!(name: "Jane Doe", email: "jane@example.com")
  course = Course.find_by(code: "MATH201")
  enrollment = course.enroll_student!(student)

  # Later, retrieve all events from this group
  # GET /lyra/flow/correlation/#{correlation_id}
end

puts "Privacy and GDPR compliance examples completed!"
puts ""
puts "Key Privacy Features:"
puts "✓ PII Detection across all events"
puts "✓ GDPR Rights (Access, Erasure, Portability, Rectification)"
puts "✓ Data Lineage Tracking"
puts "✓ Consent Management and Audit"
puts "✓ Processing Activities Record"
puts "✓ Data Retention Compliance"
puts "✓ Privacy Impact Analysis"
puts "✓ Event Flow Visualization"
puts "✓ User Action Tracking"
puts "✓ Correlation Grouping"
