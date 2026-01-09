module PamDsl
  # Represents a data retention rule
  class RetentionRule
    attr_reader :model_class, :duration, :field_overrides, :conditions, :deletion_strategy

    DELETION_STRATEGIES = [:hard_delete, :soft_delete, :anonymize, :archive].freeze

    def initialize(model_class)
      @model_class = model_class.to_s
      @duration = nil
      @field_overrides = {}
      @conditions = []
      @deletion_strategy = :soft_delete
    end

    # Set retention duration
    def keep_for(duration)
      @duration = duration
      self
    end

    # Override retention for specific fields
    def field(field_name, duration:)
      @field_overrides[field_name.to_sym] = duration
      self
    end

    # Add condition for retention
    def when(&block)
      @conditions << block
      self
    end

    # Set deletion strategy
    def on_expiry(strategy)
      strategy_sym = strategy.to_sym
      unless DELETION_STRATEGIES.include?(strategy_sym)
        raise Error, "Invalid deletion strategy: #{strategy}. Must be one of #{DELETION_STRATEGIES.join(', ')}"
      end
      @deletion_strategy = strategy_sym
      self
    end

    # Check if retention period has expired for a timestamp
    def expired?(timestamp)
      return false unless @duration
      timestamp < (Time.current - @duration)
    end

    # Get retention duration for a specific field
    def duration_for_field(field_name)
      @field_overrides[field_name.to_sym] || @duration
    end

    # Check if conditions match for given context
    def applies_to?(context)
      return true if @conditions.empty?
      @conditions.all? { |condition| condition.call(context) }
    end
  end

  # Container for retention rules
  class RetentionPolicy
    attr_reader :rules, :default_duration

    def initialize
      @rules = []
      @default_duration = 7.years
    end

    # Set default retention duration
    def default(duration)
      @default_duration = duration
      self
    end

    # Define retention rule for a model
    def for_model(model_class, &block)
      rule = RetentionRule.new(model_class)
      rule.instance_eval(&block) if block_given?
      @rules << rule
      rule
    end

    # Get retention rule for a model
    def rule_for(model_class)
      @rules.find { |rule| rule.model_class == model_class.to_s }
    end

    # Get retention duration for a model and field
    def duration_for(model_class, field_name: nil)
      rule = rule_for(model_class)
      return @default_duration unless rule

      if field_name
        rule.duration_for_field(field_name) || rule.duration || @default_duration
      else
        rule.duration || @default_duration
      end
    end
  end
end
