module PamDsl
  # Represents a consent requirement
  class ConsentRequirement
    attr_reader :purpose, :required, :granular, :withdrawable, :description, :expires_after

    def initialize(purpose)
      @purpose = purpose.to_sym
      @required = true
      @granular = false
      @withdrawable = true
      @description = ""
      @expires_after = nil
    end

    # Set if consent is required
    def required!(value = true)
      @required = value
      self
    end

    # Enable granular consent
    def granular!(value = true)
      @granular = value
      self
    end

    # Set if consent is withdrawable
    def withdrawable!(value = true)
      @withdrawable = value
      self
    end

    # Set description
    def describe(text)
      @description = text
      self
    end

    # Set expiration duration
    def expires_in(duration)
      @expires_after = duration
      self
    end

    # Check if consent is required
    def required?
      @required
    end

    # Check if consent is granular
    def granular?
      @granular
    end

    # Check if consent is withdrawable
    def withdrawable?
      @withdrawable
    end

    # Check if consent has expired
    def expired?(granted_at)
      return false unless @expires_after
      granted_at < (Time.current - @expires_after)
    end
  end

  # Container for consent requirements
  class ConsentPolicy
    attr_reader :requirements

    def initialize
      @requirements = []
    end

    # Define consent requirement for a purpose
    def for_purpose(purpose, &block)
      requirement = ConsentRequirement.new(purpose)
      requirement.instance_eval(&block) if block_given?
      @requirements << requirement
      requirement
    end

    # Get consent requirement for a purpose
    def requirement_for(purpose)
      @requirements.find { |req| req.purpose == purpose.to_sym }
    end

    # Check if consent is required for a purpose
    def required_for?(purpose)
      requirement = requirement_for(purpose)
      requirement ? requirement.required? : false
    end

    # Validate consent for a purpose
    def validate!(purpose, granted_at: nil, granted: false)
      requirement = requirement_for(purpose)
      return true unless requirement&.required?

      unless granted
        raise ConsentRequiredError, "Consent required for purpose: #{purpose}"
      end

      if granted_at && requirement.expired?(granted_at)
        raise ConsentRequiredError, "Consent expired for purpose: #{purpose}"
      end

      true
    end
  end
end
