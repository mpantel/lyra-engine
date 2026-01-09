# Privacy Policies Configuration for Lyra
# This file defines privacy policies using PAM DSL

# University System Privacy Policy
PamDsl.define_policy :university_system do
  meta :version, "1.0.0"
  meta :effective_date, "2025-01-01"
  meta :organization, "University Payment System"

  # Define PII fields
  field :email, type: :email, sensitivity: :internal do
    allow_for :authentication, :communication, :enrollment, :payment_processing
    transform :display do |value|
      local, domain = value.split('@')
      "#{local[0]}***@#{domain}"
    end
    transform :log do |value|
      "***EMAIL***"
    end
    meta :required, true
  end

  field :student_id, type: :identifier, sensitivity: :internal do
    allow_for :enrollment, :academic_records, :payment_processing
    transform :display do |value|
      "***#{value[-4..]}"
    end
    meta :unique, true
  end

  field :name, type: :name, sensitivity: :internal do
    allow_for :enrollment, :academic_records, :communication, :certificates
    transform :display do |value|
      parts = value.split(' ')
      "#{parts.first} ***"
    end
  end

  field :phone, type: :phone, sensitivity: :confidential do
    allow_for :emergency_contact, :communication
    transform :display do |value|
      "***-***-#{value[-4..]}"
    end
  end

  field :address, type: :address, sensitivity: :confidential do
    allow_for :enrollment, :correspondence, :legal_compliance
    transform :display do |value|
      "***REDACTED***"
    end
  end

  field :ssn, type: :ssn, sensitivity: :restricted do
    allow_for :legal_compliance, :financial_aid
    transform :display do |value|
      "***-**-#{value[-4..]}"
    end
    meta :encryption_required, true
  end

  field :date_of_birth, type: :date_of_birth, sensitivity: :confidential do
    allow_for :enrollment, :age_verification, :legal_compliance
  end

  field :payment_method, type: :financial, sensitivity: :restricted do
    allow_for :payment_processing
    transform :display do |value|
      "****-****-****-#{value[-4..]}"
    end
    meta :pci_dss_scope, true
  end

  field :bank_account, type: :financial, sensitivity: :restricted do
    allow_for :payment_processing, :refunds
    transform :display do |value|
      "***REDACTED***"
    end
    meta :encryption_required, true
  end

  field :academic_records, type: :custom, sensitivity: :confidential do
    allow_for :academic_records, :transcripts, :legal_compliance
    meta :ferpa_protected, true
  end

  # Define processing purposes
  purpose :enrollment do
    describe "Student enrollment and registration"
    basis :contract
    requires :email, :name, :student_id, :date_of_birth
    optionally :phone, :address
    meta :retention_reason, "Academic records requirement"
  end

  purpose :authentication do
    describe "User authentication and session management"
    basis :contract
    requires :email
    optionally :student_id
  end

  purpose :payment_processing do
    describe "Processing tuition and fee payments"
    basis :contract
    requires :email, :student_id, :payment_method
    optionally :bank_account
    meta :compliance, ["PCI-DSS", "SOX"]
  end

  purpose :communication do
    describe "Important academic and administrative communications"
    basis :legitimate_interests
    requires :email
    optionally :phone, :name
    meta :balancing_test_performed, true
  end

  purpose :academic_records do
    describe "Maintaining academic transcripts and records"
    basis :legal_obligation
    requires :student_id, :name, :academic_records
    meta :compliance, "FERPA"
  end

  purpose :legal_compliance do
    describe "Compliance with educational and tax regulations"
    basis :legal_obligation
    requires :student_id, :name
    optionally :ssn, :address, :date_of_birth
    meta :regulations, ["FERPA", "IRS", "State Education Laws"]
  end

  purpose :marketing do
    describe "Marketing communications about events and programs"
    basis :consent
    requires :email
    optionally :name, :phone
  end

  purpose :analytics do
    describe "Improving educational services and user experience"
    basis :legitimate_interests
    requires :student_id
    meta :anonymization_applied, true
  end

  # Configure retention policies
  retention do
    default 7.years

    for_model 'Student' do
      keep_for 10.years  # Educational records retention
      field :email, duration: 2.years
      field :academic_records, duration: 50.years  # Permanent academic record
      on_expiry :archive
    end

    for_model 'Enrollment' do
      keep_for 10.years
      on_expiry :archive
    end

    for_model 'Payment' do
      keep_for 10.years  # Financial records retention
      on_expiry :archive
    end

    for_model 'Invoice' do
      keep_for 10.years
      on_expiry :archive
    end

    for_model 'Course' do
      keep_for 20.years  # Course catalog history
      on_expiry :archive
    end
  end

  # Configure consent requirements
  consent do
    for_purpose :marketing do
      required!
      granular!
      withdrawable!
      expires_in 2.years
      describe "We'll send you information about upcoming events, programs, and opportunities"
    end

    for_purpose :analytics do
      required! false
      granular!
      withdrawable!
      describe "Help us improve our services by sharing anonymous usage data"
    end
  end
end

# E-commerce Privacy Policy Example
PamDsl.define_policy :ecommerce do
  meta :version, "1.0.0"
  meta :organization, "E-commerce Platform"

  # Customer fields
  field :email, type: :email, sensitivity: :internal do
    allow_for :account_management, :order_fulfillment, :marketing
    transform :display do |value|
      local, domain = value.split('@')
      "#{local[0..1]}***@#{domain}"
    end
  end

  field :shipping_address, type: :address, sensitivity: :confidential do
    allow_for :order_fulfillment, :shipping
  end

  field :credit_card, type: :credit_card, sensitivity: :restricted do
    allow_for :payment_processing
    transform :display do |value|
      "****-****-****-#{value[-4..]}"
    end
    meta :pci_dss_required, true
  end

  # Purposes
  purpose :account_management do
    describe "Customer account creation and management"
    basis :contract
    requires :email
  end

  purpose :order_fulfillment do
    describe "Processing and shipping customer orders"
    basis :contract
    requires :email, :shipping_address
  end

  purpose :payment_processing do
    describe "Processing customer payments"
    basis :contract
    requires :credit_card
  end

  purpose :marketing do
    describe "Marketing communications and promotions"
    basis :consent
    requires :email
  end

  # Retention
  retention do
    default 5.years

    for_model 'Order' do
      keep_for 7.years
      on_expiry :anonymize
    end

    for_model 'Payment' do
      keep_for 7.years
      on_expiry :archive
    end
  end

  # Consent
  consent do
    for_purpose :marketing do
      required!
      granular!
      withdrawable!
      expires_in 1.year
    end
  end
end
