# Example: Using PAM DSL with Lyra
# This file demonstrates how to use privacy policies defined with PAM DSL

require 'lyra'
require_relative '../config/privacy_policies'

# Example 1: Basic Policy Usage
puts "=" * 80
puts "Example 1: Basic Policy Usage"
puts "=" * 80

policy = PamDsl.policy(:university_system)

puts "\nPolicy: #{policy.name}"
puts "Fields defined: #{policy.fields.count}"
puts "Purposes defined: #{policy.purposes.count}"

# Example 2: Field Access Control
puts "\n" + "=" * 80
puts "Example 2: Field Access Control"
puts "=" * 80

# Check if email is allowed for enrollment
allowed = policy.allowed?(:email, :enrollment)
puts "\nIs email allowed for enrollment? #{allowed}"

# Check if SSN is allowed for marketing (should be false)
allowed = policy.allowed?(:ssn, :marketing)
puts "Is SSN allowed for marketing? #{allowed}"

# Example 3: Data Transformation
puts "\n" + "=" * 80
puts "Example 3: Data Transformation"
puts "=" * 80

email_field = policy.get_field(:email)
original_email = "john.doe@university.edu"
masked_email = email_field.apply_transformation(:display, original_email)

puts "\nOriginal email: #{original_email}"
puts "Masked email: #{masked_email}"

# Example 4: Validate Data Access
puts "\n" + "=" * 80
puts "Example 4: Validate Data Access"
puts "=" * 80

subject_id = 42

begin
  policy.validate_access!([:email, :name, :student_id], :enrollment, subject: subject_id)
  puts "\n✓ Access granted for enrollment with email, name, student_id"
rescue PamDsl::Error => e
  puts "\n✗ Access denied: #{e.message}"
end

begin
  # This should fail (SSN not allowed for marketing)
  policy.validate_access!([:email, :ssn], :marketing, subject: subject_id)
  puts "✓ Access granted for marketing with email, SSN"
rescue PamDsl::Error => e
  puts "✗ Access denied: #{e.message}"
end

# Example 5: Consent Management
puts "\n" + "=" * 80
puts "Example 5: Consent Management"
puts "=" * 80

marketing_purpose = policy.get_purpose(:marketing)
puts "\nMarketing purpose requires consent? #{marketing_purpose.requires_consent?}"

enrollment_purpose = policy.get_purpose(:enrollment)
puts "Enrollment purpose requires consent? #{enrollment_purpose.requires_consent?}"

# Example 6: Retention Policies
puts "\n" + "=" * 80
puts "Example 6: Retention Policies"
puts "=" * 80

student_retention = policy.retention_for('Student')
puts "\nStudent records retention: #{student_retention / 1.year} years"

email_retention = policy.retention_for('Student', field_name: :email)
puts "Student email retention: #{email_retention / 1.year} years"

academic_retention = policy.retention_for('Student', field_name: :academic_records)
puts "Academic records retention: #{academic_retention / 1.year} years"

# Example 7: Integration with Lyra
puts "\n" + "=" * 80
puts "Example 7: Integration with Lyra"
puts "=" * 80

# Create policy integration
integration = Lyra::Privacy::PolicyIntegration.new(:university_system)

puts "\nPolicy loaded? #{integration.policy_loaded?}"
puts "Sensitive fields: #{integration.sensitive_fields.join(', ')}"
puts "Restricted fields: #{integration.restricted_fields.join(', ')}"

# Detect PII using policy
student_data = {
  email: "student@university.edu",
  name: "Jane Smith",
  student_id: "STU123456",
  age: 20  # Not defined in policy
}

pii_detected = integration.detect_pii(student_data)
puts "\nPII detected:"
pii_detected.each do |field, info|
  puts "  #{field}: type=#{info[:type]}, sensitive=#{info[:sensitive]}"
end

# Mask PII using policy
masked = integration.mask_pii(:email, "student@university.edu", :display)
puts "\nMasked email: #{masked}"

# Check consent requirements
marketing_consent_required = integration.consent_required?(:marketing)
puts "\nMarketing requires consent? #{marketing_consent_required}"

enrollment_consent_required = integration.consent_required?(:enrollment)
puts "Enrollment requires consent? #{enrollment_consent_required}"

# Example 8: Using with ActiveRecord Models
puts "\n" + "=" * 80
puts "Example 8: Using with ActiveRecord Models (Conceptual)"
puts "=" * 80

puts <<~RUBY

  # In your Rails application:
  class Student < ApplicationRecord
    monitor_with_lyra privacy_policy: :university_system
  end

  # Lyra will now use the privacy policy to:
  # 1. Detect PII fields automatically
  # 2. Apply transformations when logging events
  # 3. Validate data access for different purposes
  # 4. Enforce retention policies
  # 5. Check consent requirements

  # Example usage:
  student = Student.create!(
    email: "john@university.edu",
    name: "John Doe",
    student_id: "STU789012"
  )
  # => Lyra logs event with PII detected from policy
  # => Applies masking for sensitive fields in event metadata
RUBY

# Example 9: Export Policy Information
puts "=" * 80
puts "Example 9: Export Policy Information"
puts "=" * 80

integration_info = integration.to_h
puts "\nIntegration Info:"
puts "  Policy loaded: #{integration_info[:policy_loaded]}"
puts "  Policy name: #{integration_info[:policy_name]}"
puts "  Fields count: #{integration_info[:fields_count]}"
puts "  Purposes count: #{integration_info[:purposes_count]}"
puts "  Sensitive fields: #{integration_info[:sensitive_fields].join(', ')}"
puts "  Restricted fields: #{integration_info[:restricted_fields].join(', ')}"

# Example 10: Multiple Policies
puts "\n" + "=" * 80
puts "Example 10: Multiple Policies"
puts "=" * 80

ecommerce_policy = PamDsl.policy(:ecommerce)
puts "\nE-commerce policy fields: #{ecommerce_policy.fields.keys.join(', ')}"
puts "E-commerce policy purposes: #{ecommerce_policy.purposes.keys.join(', ')}"

# List all registered policies
puts "\nAll registered policies:"
PamDsl.registry.names.each do |policy_name|
  puts "  - #{policy_name}"
end

puts "\n" + "=" * 80
puts "Examples completed!"
puts "=" * 80
