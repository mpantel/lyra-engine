# frozen_string_literal: true

module PamDsl
  # Detects personally identifiable information (PII) in data
  # This is the canonical PII detection implementation used by both PAM DSL and Lyra
  #
  # Supports two matching modes:
  # - **Partial matching (default)**: Matches field names containing PII keywords
  #   e.g., `primary_email`, `customer_phone` are detected
  # - **Exact matching**: Only matches specific known field names
  #   e.g., only `email`, `user_email` etc. are matched
  #
  # @example Basic usage
  #   PamDsl::PIIDetector.detect({ email: "test@example.com", name: "John" })
  #   # => { email: { type: :email, ... }, name: { type: :name, ... } }
  #
  # @example Check single field
  #   PamDsl::PIIDetector.contains_pii?(:email)  # => true
  #   PamDsl::PIIDetector.contains_pii?(:count)  # => false
  #
  # @example Configure matching mode
  #   PamDsl::PIIDetector.partial_match = false  # Use exact matching
  #
  class PIIDetector
    # Boundary patterns for partial matching
    # Start: beginning of string or after underscore
    # End: end of string, underscore, or followed by uppercase (camelCase)
    START_BOUNDARY = '(?:^|_)'
    END_BOUNDARY = '(?:$|_|(?=[A-Z]))'

    # Sensitivity levels for different PII types
    SENSITIVITY_LEVELS = {
      internal: 1,      # Low sensitivity - internal use
      confidential: 2,  # Medium sensitivity - requires protection
      restricted: 3     # High sensitivity - requires encryption/special handling
    }.freeze

    # Fields matching these patterns are NOT PII (timestamps, counters, flags, amounts)
    # These are checked BEFORE PII patterns to avoid false positives
    EXCLUSION_PATTERNS = [
      /_at\z/i,           # Timestamps: created_at, email_sent_at, verified_at
      /_on\z/i,           # Date fields: published_on, sent_on
      /_date\z/i,         # Date fields: send_date (but birth_date is handled separately)
      /_time\z/i,         # Time fields: start_time, end_time
      /_count\z/i,        # Counters: email_count, login_count
      /_amount\z/i,       # Amounts: vat_amount, total_amount
      /_total\z/i,        # Totals: grand_total
      /_enabled\z/i,      # Flags: email_enabled, phone_verified
      /_verified\z/i,     # Verification flags
      /_confirmed\z/i,    # Confirmation flags
      /_sent\z/i,         # Status flags: email_sent
      /_notified\z/i,     # Notification flags
      /_status\z/i,       # Status fields: payment_status
      /_type\z/i,         # Type fields: user_type
      /_uuid\z/i,         # UUIDs
      /_code\z/i,         # Codes: country_code, currency_code (but postal_code handled separately)
      /\A(id|uuid)\z/i,   # Primary keys
      /\Ais_/i,           # Boolean flags: is_active
      /\Ahas_/i,          # Boolean flags: has_consent
      /encrypted_/i,      # Already encrypted (but see PERSONAL_DESPITE_EXCLUSION)
      /_digest\z/i,       # Hashes: file_digest
      /_token\z/i,        # Tokens: csrf_token
      /_hash\z/i,         # Hashes: content_hash
      /_ids?\z/i,         # Foreign keys: user_id, bill_address_id, country_id
      /_iso\d?\z/i,       # ISO codes: country_iso, currency_iso3
      /_message\z/i,      # Gateway and system messages: cvv_response_message
      /_reason\z/i,       # Reason text: cancellation_reason
      /_notes?\z/i,       # Free-text notes
      /\A(created|updated|deleted|sent|received)_/i  # Prefixed timestamps
    ].freeze

    # Personal data that an exclusion pattern above would otherwise drop:
    # identifiers stored as *_id, credentials and the tokens that stand for a
    # person's session or account. Credentials are personal data too: a
    # password hash belongs to one person, and its exposure is a breach.
    PERSONAL_DESPITE_EXCLUSION = /\A(
      postal_code|zip_code|postcode|birth_date|dob_date|health_status|
      (?:\w+_)?(?:face|national|vat|tax|passport)_id|
      gateway_customer_profile_id|gateway_payment_profile_id|stripe_customer_id|paypal_account_id|
      encrypted_password|password_digest|password_hash|password_salt|
      (reset_password|remember|confirmation|unlock|authentication|auth|session|
       guest|persistence|perishable)_token
    )\z/ix

    # Exact match PII patterns (used when partial_match = false)
    # These are specific known field names for each PII type
    EXACT_PII_PATTERNS = {
      email: {
        pattern: /\A(email|e_mail|mail_address|user_email|contact_email|billing_email)\z/i,
        sensitivity: :confidential
      },
      name: {
        pattern: /\A(first_?name|given_?name|fname|last_?name|surname|family_?name|lname|full_?name|display_?name|father_?name|fathername|mother_?name|parent_?name|name|firstname|lastname)\z/i,
        sensitivity: :internal
      },
      phone: {
        pattern: /\A(phone|telephone|mobile|cell|fax|phone_number|mobile_number|cell_phone)\z/i,
        sensitivity: :confidential
      },
      ip_address: {
        pattern: /\A(ip|ip_address|remote_ip|client_ip|source_ip|last_ip_address|current_sign_in_ip|last_sign_in_ip|sign_in_ip)\z/i,
        sensitivity: :internal
      },
      address: {
        pattern: /\A(address|address\d|street|city|state_name|province|country|postal|zip|zipcode|postcode|postal_code|zip_code|address_line_?\d?|street_address|billing_address|shipping_address|home_address|work_address)\z/i,
        sensitivity: :confidential
      },
      online_identifier: {
        pattern: /\A(login|username|user_?name|screen_?name|nickname)\z/i,
        sensitivity: :internal,
        type: :identifier
      },
      identifier: {
        pattern: /\A(vat_number|vat_id|tax_id|tin|tax_number|vat_reg_number|afm|passport|passport_number|driver_license|drivers_license|license_number|id_number)\z/i,
        sensitivity: :restricted
      },
      ssn: {
        pattern: /\A(ssn|social_security|social_security_number|national_id)\z/i,
        sensitivity: :restricted
      },
      date_of_birth: {
        pattern: /\A(dob|date_of_birth|birth_date|birthday|birthdate)\z/i,
        sensitivity: :confidential
      },
      credit_card: {
        pattern: /\A(credit_card|card_number|card_number_first\d|card_number_last\d|cc_number|cvv|cvc|ccn|last_digits|last4|last_four|card_last4)\z/i,
        sensitivity: :restricted
      },
      financial: {
        pattern: /\A(iban|swift|bic|bank_account|account_number|routing_number|salary|income)\z/i,
        sensitivity: :restricted
      },
      health: {
        pattern: /\A(health_condition|medical_record|diagnosis|prescription|medical_history|medical|health)\z/i,
        sensitivity: :restricted
      },
      biometric: {
        pattern: /\A(fingerprint|face_id|biometric|biometric_data|retina_scan|retina|face)\z/i,
        sensitivity: :restricted
      },
      location: {
        pattern: /\A(latitude|longitude|lat|lng|geo_location|gps_coordinates|gps|location)\z/i,
        sensitivity: :confidential
      },
      credential: {
        pattern: /\A(encrypted_password|password_salt|password_digest|password_hash|api_key|spree_api_key|secret_key|access_key)\z/i,
        sensitivity: :restricted
      },
      token: {
        pattern: /\A(reset_password_token|remember_token|confirmation_token|unlock_token|authentication_token|auth_token|session_token|bearer_token|guest_token|persistence_token|perishable_token|access_token|refresh_token)\z/i,
        sensitivity: :restricted
      },
      payment_token: {
        pattern: /\A(gateway_customer_profile_id|gateway_payment_profile_id|stripe_customer_id|paypal_account_id|payment_token)\z/i,
        sensitivity: :restricted
      }
    }.freeze

    # Partial match PII patterns (used when partial_match = true)
    # These use boundary patterns to match field names containing PII keywords
    # NOTE: Order matters - the first pattern that matches wins. IP addresses
    # come before addresses (last_ip_address), addresses and online identifiers
    # before names (state_name is an address), and tokens before credentials
    # (reset_password_token is a token).
    PARTIAL_PII_PATTERNS = {
      email: {
        pattern: /#{START_BOUNDARY}(e_?mail|mail_?(?:from_?)?address)#{END_BOUNDARY}/i,
        sensitivity: :confidential
      },
      ip_address: {
        # Any column ending in _ip (current_sign_in_ip, last_sign_in_ip).
        pattern: /#{START_BOUNDARY}(ip_?[Aa]ddress|[Ii]p)#{END_BOUNDARY}/,
        sensitivity: :internal
      },
      address: {
        # address1/address2 and zipcode/postcode were missed (Solidus); a bare
        # "state" is not matched (an order's state machine), "state_name" is.
        pattern: /#{START_BOUNDARY}([Aa]ddress\d?|address_?[Ll]ine_?\d?|[Ss]treet|[Cc]ity|[Zz]ip(?:_?[Cc]ode)?|[Pp]ost_?[Cc]ode|[Pp]ostal(?:_?[Cc]ode)?|[Cc]ountry|[Pp]rovince|state_?[Nn]ame)#{END_BOUNDARY}/,
        sensitivity: :confidential
      },
      online_identifier: {
        # A login or username identifies a person online (Art. 4(1)).
        pattern: /\A(login|username|user_?name|screen_?name|nickname)\z/i,
        sensitivity: :internal,
        type: :identifier
      },
      name: {
        # Name forms, and the names of people in a role; not every *_name
        # (api_name, bank_name, file_name, product_name are not people's).
        pattern: /#{START_BOUNDARY}((?:[Ff]irst|[Ll]ast|[Ff]ull|[Gg]iven|[Ff]amily|[Mm]iddle|[Mm]aiden|[Dd]isplay|[Ff]ather|[Mm]other|[Pp]arent|[Gg]uardian|[Ss]pouse|[Cc]ustomer|[Uu]ser|[Hh]older|card_?[Hh]older|account_?[Hh]older|[Oo]wner|[Cc]ontact|[Cc]reditor|[Dd]ebtor|[Rr]ecipient|[Ss]ender|[Pp]ayer|[Pp]ayee|[Bb]eneficiary|[Aa]pprover|[Aa]dmin|[Dd]eposit|[Ll]egal)_?[Nn]ame|[Ss]urname)#{END_BOUNDARY}|\A[Nn]ame#{END_BOUNDARY}/,
        sensitivity: :internal
      },
      phone: {
        pattern: /#{START_BOUNDARY}([Pp]hone|[Tt]elephone|[Mm]obile|[Cc]ell)#{END_BOUNDARY}/,
        sensitivity: :confidential
      },
      identifier: {
        pattern: /#{START_BOUNDARY}([Pp]assport|[Ll]icense|id_?[Nn]umber|tax_?[Ii]d|tax_?[Nn]umber|[Tt]in|national_?[Ii]d_?[Nn]umber|[Vv]at|[Vv]at_?[Nn]umber|[Aa]fm)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      ssn: {
        pattern: /#{START_BOUNDARY}([Ss]sn|social_?[Ss]ecurity|national_?[Ii]d)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      date_of_birth: {
        pattern: /#{START_BOUNDARY}([Bb]irth|[Dd]ob|[Bb]irthday|[Bb]irth_?[Dd]ate|date_?[Oo]f_?[Bb]irth)#{END_BOUNDARY}/,
        sensitivity: :confidential
      },
      credit_card: {
        pattern: /#{START_BOUNDARY}(credit_?[Cc]ard|card_?[Nn]umber|cc_?[Nn]umber|[Cc]cn|[Cc]vv|[Cc]vc|last_?(?:[Dd]igits|4|[Ff]our)|card_?[Ll]ast_?4)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      financial: {
        # salary and income only as a whole name or its end (rest_income_budget
        # is a budget).
        pattern: /#{START_BOUNDARY}(bank_?[Aa]ccount(?:_?[Nn]umber)?|account_?[Nn]umber|routing_?[Nn]umber|[Ii]ban|[Bb]ic|[Ss]wift)#{END_BOUNDARY}|#{START_BOUNDARY}([Ss]alary|[Ii]ncome)\z/,
        sensitivity: :restricted
      },
      health: {
        pattern: /#{START_BOUNDARY}([Mm]edical|[Hh]ealth|[Dd]iagnosis|[Pp]rescription)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      biometric: {
        pattern: /#{START_BOUNDARY}([Ff]ingerprint|[Ff]ace|[Rr]etina|[Bb]iometric)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      location: {
        pattern: /#{START_BOUNDARY}([Ll]atitude|[Ll]ongitude|[Ll]ocation|[Gg]ps)#{END_BOUNDARY}/,
        sensitivity: :confidential
      },
      token: {
        # A person's account and session tokens; access, refresh and bearer tokens
        # are a service's credentials.
        pattern: /#{START_BOUNDARY}((?:[Aa]uth|[Aa]uthentication|[Ss]ession|[Rr]emember|[Cc]onfirmation|[Uu]nlock|reset_?[Pp]assword|[Gg]uest|[Pp]ersistence|[Pp]erishable)_?[Tt]oken)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      credential: {
        pattern: /#{START_BOUNDARY}([Pp]assword|[Ss]ecret|api_?[Kk]ey)#{END_BOUNDARY}/,
        sensitivity: :restricted
      },
      payment_token: {
        pattern: /#{START_BOUNDARY}([Gg]ateway.*[Pp]rofile|[Ss]tripe.*[Ii]d|[Pp]aypal.*[Ii]d|[Pp]ayment_?[Tt]oken)#{END_BOUNDARY}/,
        sensitivity: :restricted
      }
    }.freeze

    # Sensitive PII types that require extra protection
    SENSITIVE_TYPES = %i[ssn credit_card financial health biometric identifier credential token payment_token].freeze

    class << self
      # Enable or disable partial matching (default: true)
      # When true, matches field names containing PII keywords (e.g., primary_email, customer_phone)
      # When false, only matches specific known field names (e.g., email, phone)
      attr_writer :partial_match

      def partial_match
        @partial_match.nil? ? true : @partial_match
      end

      # Reset to default settings
      def reset!
        @partial_match = true
      end

      # Get the current PII patterns based on matching mode
      def pii_patterns
        partial_match ? PARTIAL_PII_PATTERNS : EXACT_PII_PATTERNS
      end

      # Detect PII in a hash of attributes
      #
      # @param attributes [Hash] Key-value pairs to check for PII
      # @return [Hash] Keys that contain PII, with their type, value, and sensitivity
      #
      def detect(attributes)
        pii_fields = {}

        attributes.each do |key, value|
          pii_info = detect_field(key.to_s)
          if pii_info
            pii_fields[key] = {
              type: pii_info[:type],
              value: value,
              sensitive: sensitive?(pii_info[:type]),
              sensitivity: pii_info[:sensitivity]
            }
          end
        end

        pii_fields
      end

      # Check if a field name contains PII
      #
      # @param field_name [String, Symbol] Field name to check
      # @return [Boolean] true if field contains PII
      #
      def contains_pii?(field_name)
        !detect_field(field_name.to_s).nil?
      end

      # Get the PII type for a field
      #
      # @param field_name [String, Symbol] Field name to check
      # @return [Symbol, nil] PII type or nil if not PII
      #
      def pii_type(field_name)
        info = detect_field(field_name.to_s)
        info&.dig(:type)
      end

      # Get the sensitivity level for a field
      #
      # @param field_name [String, Symbol] Field name to check
      # @return [Symbol, nil] Sensitivity level or nil if not PII
      #
      def sensitivity(field_name)
        info = detect_field(field_name.to_s)
        info&.dig(:sensitivity)
      end

      # Check if a PII type is considered sensitive (requires extra protection)
      #
      # @param pii_type [Symbol] The PII type
      # @return [Boolean]
      #
      def sensitive?(pii_type)
        SENSITIVE_TYPES.include?(pii_type)
      end

      # Extract PII from a collection of records (events, database rows, etc.)
      #
      # This is a generic method that works with any record type by using blocks
      # to extract the relevant data. This allows PAM DSL to work with Lyra events,
      # RubyEventStore events, ActiveRecord models, or any other data source.
      #
      # @param records [Enumerable] Collection of records to scan
      # @param attribute_extractor [Proc] Block that extracts attributes hash from a record
      # @param metadata_extractor [Proc, nil] Optional block that extracts metadata from a record
      #   Should return a hash with keys like :id, :timestamp, :type, :record_id
      # @return [Hash] PII inventory grouped by PII type
      #
      # @example With Lyra events
      #   PamDsl::PIIDetector.extract_pii_from_records(
      #     events,
      #     attribute_extractor: ->(e) { e.attributes },
      #     metadata_extractor: ->(e) { { id: e.event_id, timestamp: e.timestamp, type: e.model_class, record_id: e.model_id } }
      #   )
      #
      # @example With RubyEventStore events
      #   PamDsl::PIIDetector.extract_pii_from_records(
      #     events,
      #     attribute_extractor: ->(e) { e.data[:attributes] || {} },
      #     metadata_extractor: ->(e) { { id: e.event_id, timestamp: e.metadata[:timestamp] } }
      #   )
      #
      # @example With ActiveRecord models
      #   PamDsl::PIIDetector.extract_pii_from_records(
      #     User.all,
      #     attribute_extractor: ->(u) { u.attributes },
      #     metadata_extractor: ->(u) { { id: u.id, type: u.class.name } }
      #   )
      #
      # @example Simple usage (no metadata)
      #   PamDsl::PIIDetector.extract_pii_from_records(
      #     data_rows,
      #     attribute_extractor: ->(row) { row }
      #   )
      #
      def extract_pii_from_records(records, attribute_extractor:, metadata_extractor: nil)
        pii_inventory = Hash.new { |h, k| h[k] = [] }

        records.each do |record|
          attributes = attribute_extractor.call(record)
          next if attributes.nil? || attributes.empty?

          pii_fields = detect(attributes)
          next if pii_fields.empty?

          metadata = metadata_extractor ? metadata_extractor.call(record) : {}

          pii_fields.each do |field, info|
            entry = {
              field: field,
              value: info[:value],
              pii_type: info[:type],
              sensitivity: info[:sensitivity]
            }
            entry.merge!(metadata) if metadata.is_a?(Hash)

            pii_inventory[info[:type]] << entry
          end
        end

        pii_inventory
      end

      # Mask a PII value for safe display
      #
      # @param value [Object] The value to mask
      # @param pii_type [Symbol] The type of PII
      # @return [String] Masked value
      #
      def mask(value, pii_type)
        return value if value.nil?

        case pii_type
        when :email
          mask_email(value)
        when :phone
          mask_phone(value)
        when :ssn, :credit_card, :identifier, :financial
          "***REDACTED***"
        when :credential
          "[HIDDEN]"
        when :token, :payment_token
          mask_token(value)
        when :name
          mask_name(value)
        else
          mask_generic(value)
        end
      end

      private

      def detect_field(field_name)
        # Check exclusion patterns first to avoid false positives
        return nil if excluded_field?(field_name)

        # Check each PII pattern
        pii_patterns.each do |type, config|
          if field_name.match?(config[:pattern])
            return { type: config[:type] || type, sensitivity: config[:sensitivity] }
          end
        end

        nil
      end

      def excluded_field?(field_name)
        return false if field_name.match?(PERSONAL_DESPITE_EXCLUSION)

        EXCLUSION_PATTERNS.any? { |pattern| field_name.match?(pattern) }
      end

      def mask_email(email)
        return email unless email.to_s.include?('@')
        local, domain = email.to_s.split('@')
        "#{local[0]}***@#{domain}"
      end

      def mask_phone(phone)
        digits = phone.to_s.gsub(/\D/, '')
        return phone if digits.length < 4
        "***-***-#{digits[-4..]}"
      end

      def mask_name(name)
        parts = name.to_s.split(' ')
        return name if parts.empty?
        "#{parts.first} ***"
      end

      def mask_generic(value)
        str = value.to_s
        return str if str.length <= 4
        "#{str[0..1]}***#{str[-2..]}"
      end

      def mask_token(value)
        str = value.to_s
        return "[TOKEN]" if str.length <= 8
        "#{str[0..3]}...#{str[-4..]}"
      end
    end
  end
end
