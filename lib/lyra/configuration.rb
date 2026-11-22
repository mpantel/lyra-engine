module Lyra
  class Configuration
    # Valid modes for Lyra operation
    MODES = [:disabled, :monitor, :hijack, :event_sourcing].freeze
    # Valid projection modes (event sourcing): :disabled is ES-NoProj, :lazy
    # is ES-Lazy (project on read).
    PROJECTION_MODES = [:sync, :async, :disabled, :lazy].freeze
    RIGHTS_REFRESH_MODES = %i[scope interval].freeze

    attr_reader :mode, :projection_mode
    attr_accessor :event_store, :retention_policy
    attr_reader :hijack_enabled
    attr_accessor :strict_projections, :projection_error_handler, :async_projections_inline
    attr_accessor :strict_schema, :schema_path
    attr_accessor :strict_data_access  # Raise on callback-bypassing operations
    attr_accessor :metadata_proc  # Custom metadata proc for events
    attr_accessor :genesis  # Imported events for pre-existing rows (see Lyra::Genesis)
    # What Genesis does with a row holding a value its model cannot represent
    # (an enum value outside the mapping, ...): :refuse (default) refuses the
    # model's import, listing the rows; :skip leaves them without a stream
    # and imports the rest. Lyra::Repair follows it for what it would write.
    # See Lyra::Genesis.
    GENESIS_UNREPRESENTABLE = %i[refuse skip].freeze
    attr_reader :genesis_unrepresentable
    attr_accessor :reference_links  # Foreign-key links for ES-NoProj lookups (see Lyra::Projections::ReferenceLinks)
    # The secret the value streams of ES-NoProj's unique-index check and the
    # value locks are keyed with (Lyra::Projections::ValueDigest): nil
    # (default) derives one from the application's secret_key_base. Changing
    # it relinks the value streams on their next use.
    attr_accessor :value_digest_key
    # Seconds after which a process reads a monitored model's unique indexes
    # again (Lyra::Projections::UniqueIndexes), so an index added by a
    # migration while it runs is enforced and its earlier writes linked:
    # 60 (default), nil never (only reset_column_information does).
    attr_accessor :unique_index_refresh
    attr_reader :monitored_models
    # Default privacy policy for monitored models that name none of their
    # own (monitor_with_lyra privacy_policy: ...). See Lyra::Privacy.policy_for.
    attr_accessor :privacy_policy
    # Models declared by name (config.models=), instrumented once the
    # application's code has loaded. { "Name" => options }.
    attr_reader :declared_models
    # Mode Transition Safety (Lyra::ModeTransition): nil (default) gates mode
    # switches everywhere but the test environment; true always; false never.
    attr_accessor :mode_transition_gate
    # How long a clean check (rake lyra:mode:check) certifies a switch.
    attr_accessor :mode_transition_certificate_ttl
    # Share of writes checked by DualView after commit (0.0, the default, is
    # off; the thesis suggests 0.01-0.05), and what to call on a discrepancy.
    attr_accessor :dual_view_sample_rate, :dual_view_discrepancy_handler
    # Keep every process in the application-wide mode (Lyra::ModeSync): nil
    # (default) follows mode_transition_gate; true; false. Checked at most
    # every mode_sync_interval seconds.
    attr_accessor :mode_sync, :mode_sync_interval
    # Group writes into causal chains (Lyra::Correlation): the writes of one
    # HTTP request share a correlation (the request id); a write made inside
    # another write's callbacks records that write's event as its cause; the
    # outermost write opens the correlation when none is in scope. On by
    # default; false leaves both to the application's own with_id calls.
    attr_accessor :correlate_writes
    # Stamp each event's metadata with the privacy annotation of the personal
    # data it carries (Lyra::Privacy.stamp). Off by default: it adds work to
    # every write, measured separately.
    attr_accessor :annotate_privacy
    # Record every access the privacy policy validates as an event
    # (Lyra::AccessLog). Off by default: reads can outnumber writes by orders
    # of magnitude, so its cost is measured separately.
    attr_accessor :record_access_events
    # Extra metadata for each recorded access, from a proc given the
    # PamDsl::Enforcement::Access: who accessed, where Current does not say.
    attr_accessor :access_metadata_proc
    # Whether Lyra::Erasure.erase! also deletes the subject's access log
    # (Lyra::DataAccess$<Model>$<id>), unless the call says (access_log:).
    # Off by default: the log may be evidence the application must keep.
    attr_accessor :erase_access_log
    # How long, in seconds, a process answers the checks of the data subject's
    # restrictions, objections (Condition 6) and consent from what it last read
    # (Lyra::Rights). A right or consent recorded in this process is seen at
    # once; one recorded in another process within this interval. Default 1.
    attr_accessor :rights_refresh_interval
    # When a process reads the rights and consent afresh (from 1.0.0):
    # :scope (the default) at the first check of each checking scope (a
    # Lyra.with_purpose block, a web request, a job, a batch of a batch loop:
    # Lyra::Rights.scope), and otherwise after rights_refresh_interval;
    # :interval only after rights_refresh_interval, so a right recorded in
    # another process may apply up to that long later, in the middle of a
    # request, and no scope costs a query of its own. Scopes open either way.
    attr_reader :rights_refresh
    # With Lyra::Erasure.erase!(…, everywhere: true): a value held by more
    # other records than this (default 10) is taken to be shared by many people
    # (a placeholder, a city) and left, and reported in Result#shared. The
    # person's linked records (belongs_to the erased record) do not count. The
    # call's max_copies: and the task's MAX_COPIES= override it. From 1.0.0.
    attr_reader :erasure_max_copies
    # Record each explicit Art. 15 copy (GDPRCompliance#data_export, not
    # record: false) as an event in Lyra::SubjectAccessExports$<subject>, which
    # access-log erasure leaves: who exported, when, which sections, never
    # values (Lyra::AccessLog.record_export). On by default (accountability,
    # Art. 5(2), and evidence the request was answered); false turns it off.
    attr_accessor :record_subject_access_exports
    # What a read of a model with a privacy policy does when no purpose is
    # declared (Lyra::PurposeBoundReads): :allow (default), :audit or :deny.
    attr_reader :reads_without_purpose, :unrecorded_writes
    # What Monitor does when a write's event cannot be stored: :log (default)
    # lets the write stand and logs the failure, the stream falling behind its
    # row until lyra:repair; :fail_write fails the write and rolls it back, as
    # Hijack and the event-sourcing modes always do. Row and event commit
    # together either way; this decides only what a failed append does.
    MONITOR_APPEND_FAILURES = %i[log fail_write].freeze
    attr_reader :monitor_append_failure
    # Take a lock on the aggregate before appending its event, in Hijack,
    # ES-Sync and ES-Async (assumption L of Theorem 5;
    # Lyra::Interceptors::CrudInterceptor#lyra_lock_aggregate!). On (default):
    # in Hijack and ES-Sync the record's row lock, so two writers of one record
    # append and write its row in the same order; in ES-Async, whose writers do
    # not write the row, an advisory lock on the stream, so a record's events
    # commit in the order they were appended and the projection job applies
    # only those after its checkpoint (AsyncProjectionJob). An update or a
    # destroy also checks, under the lock, that the stream does not end in a
    # Destroyed event, taking the advisory lock for that in ES-NoProj and
    # ES-Lazy too (#lyra_lock_aggregate_unless_destroyed!). The price is one
    # lock statement per update or destroy, which also makes the append nest
    # in a savepoint. Off: the order these modes had before, with a divergence
    # between row and log possible under same-record races in Hijack and
    # ES-Sync (DualView detects it), no destroyed check, and ES-Async's job
    # replaying the whole stream every time.
    attr_accessor :lock_aggregate_before_append
    # The most records a bulk write may lock: in ES-NoProj update_all,
    # delete_all, touch_all, update_counters, a dependent: :delete_all or
    # :nullify, and a destroy_all inside a transaction already open; in
    # ES-Async and ES-Lazy update_all, delete_all, touch_all, upsert_all and
    # a dependent: :nullify (BypassEvents.checks_streams?). It holds one
    # aggregate lock per record until its
    # transaction ends, and PostgreSQL's lock table, shared by every session,
    # holds about max_locks_per_transaction × (max_connections + background
    # processes) locks (about 12,800 with the defaults). Past it every
    # session's writes fail ("out of shared memory"). A larger write raises
    # Lyra::BulkWriteLockLimitError before it locks or writes anything. nil:
    # no limit. Only with lock_aggregate_before_append on. At least 1, so a
    # write of one record is never refused (bulk_write_lock_limit=).
    attr_reader :bulk_write_lock_limit
    # Apply the privacy policy's retention rules (Lyra::Retention). Off by
    # default: deleting data on a timer is the deployment's decision.
    attr_accessor :retention_executor
    # The column each model's retention period runs from, by model name;
    # created_at when not named.
    attr_accessor :retention_anchors
    # Who may use the dashboard (Lyra::ApplicationController): a proc run
    # before every engine action, instance_exec'd on the controller (and
    # given it as its argument when it takes one). Truthy allows; falsy
    # answers 403. nil (default): allowed in development and test only,
    # refused everywhere else, since the routes expose personal data.
    #   config.dashboard_authorization = ->(controller) { controller.current_user&.admin? }
    attr_accessor :dashboard_authorization

    # The purpose the dashboard reads under when a request names none
    # (?purpose=): one the policy declares for oversight. nil (default): such a
    # request reads without a purpose, as reads_without_purpose decides.
    #   config.dashboard_purpose = :oversight
    attr_accessor :dashboard_purpose
    # The most events a dashboard page or JSON route reads from the log in one
    # request (default 10,000); a request's ?limit= may only lower it. The routes
    # that look across the log (the CRUD summary, a correlation, a user's
    # actions, PII detection) read the most recent events up to it and say so
    # (window: { limit:, returned:, truncated: }); before 1.0.0 they read the whole log.
    attr_reader :dashboard_max_events
    # Whether a touch whose only change is the model's update timestamp
    # (updated_at, updated_on) is recorded as an event: an instance touch, a
    # touch_all and a belongs_to ... touch: true cascade. True (the default)
    # records every one, as before. False leaves those out of the log, in
    # Monitor only, where the table is authoritative and the event a copy; a
    # touch that also changes another column (touch(:completed_at), a
    # lock_version) is recorded in full. DualView then ignores a difference
    # confined to those columns. Refused with Hijack and event sourcing, whose
    # log is the record of every change and is replayed to rebuild the rows: a
    # missing touch would rebuild a stale updated_at. A process with it off
    # registers (Lyra::TouchRegistry), and no process escalates while one is
    # registered. Before escalating, restart every process with it true and
    # run lyra:repair, which records the timestamps the log missed. From 1.0.0.
    attr_reader :record_touches

    def initialize
      @mode = :monitor
      @hijack_enabled = false
      @monitored_models = []
      @model_configs = {}
      @retention_policy = nil
      # Event sourcing specific options
      @projection_mode = :sync  # :sync, :async, :disabled (ES-NoProj) or :lazy (ES-Lazy: project on read)
      @strict_projections = false  # Raise on projection errors if true
      @projection_error_handler = nil  # Custom error handler proc
      # Run :async projections inline: nil (default) = only in the test
      # environment; true = always; false = never, so tests can exercise the
      # real background path with an :async job adapter.
      @async_projections_inline = nil
      # Schema validation options
      @strict_schema = false  # Fail on startup if schema changes detected
      @schema_path = nil  # Custom path for schema files (defaults to db/lyra_schemas/)
      # Strict data access - raise on operations that bypass callbacks
      @strict_data_access = false
      # User tracking - custom metadata proc called for every event
      # Signature: ->(record, operation) { { user_id: ..., ... } }
      @metadata_proc = nil
      # Genesis: :auto (event-sourcing mode only), true (every event-producing
      # mode) or false. See Lyra::Genesis.
      @genesis = :auto
      @genesis_unrepresentable = :refuse
      # Reference links: :auto (ES-NoProj only), true (every event-producing
      # mode) or false. See Lyra::Projections::ReferenceLinks.
      @reference_links = :auto
      @value_digest_key = nil
      @unique_index_refresh = 60
      @mode_transition_gate = nil
      @mode_transition_certificate_ttl = 3600
      @dual_view_sample_rate = 0.0
      @dual_view_discrepancy_handler = nil
      @mode_sync = nil
      @mode_sync_interval = 5
      @correlate_writes = true
      @annotate_privacy = false
      @record_access_events = false
      @access_metadata_proc = nil
      @erase_access_log = false
      @rights_refresh_interval = 1
      @rights_refresh = :scope
      @erasure_max_copies = 10 # Lyra::Erasure::MAX_COPIES
      @record_subject_access_exports = true
      @reads_without_purpose = :allow
      @unrecorded_writes = :allow
      @monitor_append_failure = :log
      @lock_aggregate_before_append = true
      @bulk_write_lock_limit = 5_000
      @retention_executor = false
      @retention_anchors = {}
      @dashboard_authorization = nil
      @dashboard_purpose = nil
      @dashboard_max_events = 10_000
      @record_touches = true
    end

    # One of MODES; a string (from ENV, say) is taken as its symbol.
    def mode=(mode)
      mode = validate_choice!(:mode, mode, MODES)
      refuse_unrecorded_touches!(mode)
      @mode = mode
    end

    # One of PROJECTION_MODES; a string is taken as its symbol.
    def projection_mode=(mode)
      @projection_mode = validate_choice!(:projection_mode, mode, PROJECTION_MODES)
    end

    # One of GENESIS_UNREPRESENTABLE; a string is taken as its symbol.
    def genesis_unrepresentable=(choice)
      @genesis_unrepresentable = validate_choice!(:genesis_unrepresentable, choice, GENESIS_UNREPRESENTABLE)
    end

    def rights_refresh=(mode)
      @rights_refresh = validate_choice!(:rights_refresh, mode, RIGHTS_REFRESH_MODES)
    end

    def erasure_max_copies=(value)
      count = value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)
      raise ArgumentError, "erasure_max_copies must be a positive integer (got #{value.inspect})" unless count&.positive?

      @erasure_max_copies = count
    end

    def dashboard_max_events=(value)
      value = Integer(value)
      raise ArgumentError, "dashboard_max_events must be positive" unless value.positive?

      @dashboard_max_events = value
    end

    def reads_without_purpose=(mode)
      @reads_without_purpose = Lyra::PurposeBoundReads.validate_mode!(mode)
    end

    # Whether application code may write without events through
    # Lyra.unrecorded_write: :allow (default; each use is recorded with its
    # reason) or :deny (it raises: production hardening).
    def unrecorded_writes=(mode)
      mode = mode.to_sym
      raise ArgumentError, "unrecorded_writes must be :allow or :deny, not #{mode.inspect}" unless %i[allow deny].include?(mode)

      @unrecorded_writes = mode
    end

    # true or false (a string "true" or "false", from ENV, is taken as its
    # value). False is refused outside Monitor and Disabled (touch_refusal).
    def record_touches=(value)
      value = { "true" => true, "false" => false }.fetch(value.strip.downcase, value) if value.is_a?(String)
      raise ArgumentError, "record_touches must be true or false (got #{value.inspect})" unless [true, false].include?(value)

      previous = @record_touches
      @record_touches = value
      refusal = touch_refusal(hijack_mode? ? :hijack : @mode)
      if refusal
        @record_touches = previous
        raise ArgumentError, refusal
      end
      # This process registers as one that leaves touches out (after boot;
      # at boot, Lyra::TouchRegistry.boot!), which is refused in an application
      # whose latest applied mode is Hijack or event sourcing, and ends its
      # entry when set back to true.
      return unless defined?(Lyra::TouchRegistry) && value != previous
      return Lyra::TouchRegistry.option_on! if value

      begin
        Lyra::TouchRegistry.option_off!
      rescue StandardError
        @record_touches = previous
        raise
      end
    end

    # Set by the mode helpers. Refused, like mode=, while record_touches is
    # false: hijack_mode? is true whatever mode says.
    def hijack_enabled=(value)
      refuse_unrecorded_touches!(:hijack) if value
      @hijack_enabled = value
    end

    # Why +mode+ (a mode, or a ModeTransition label such as
    # "event_sourcing/lazy") cannot run with record_touches false, or nil when
    # it can. Hijack and the event-sourcing modes take the log as the record of
    # every change: the rows are rebuilt from it (a switch into event
    # sourcing, which Hijack passes without a check, a Rebuild, ES-NoProj's
    # reads). An unrecorded touch there would rebuild a stale updated_at.
    def touch_refusal(mode)
      return nil unless @record_touches == false
      return nil if %w[disabled monitor].include?(mode.to_s.split("/").first)

      "config.record_touches = false is refused in #{mode}: there the event log is the record of every change, " \
        "and a touch left out of it would rebuild a stale updated_at. To escalate: restart every process with " \
        "record_touches on, run `rake lyra:repair` in Monitor, then switch."
    end

    # Whether a touch whose only change is the update timestamp is left out
    # of the log now: record_touches false, in Monitor.
    def skip_touches?
      @record_touches == false && monitor_mode? && !hijack_mode?
    end

    # nil (no limit) or a whole number of at least 1; a string (from ENV,
    # say) is taken as its number. 0 refused every write that locks a
    # record, update_columns, touch and delete included.
    def bulk_write_lock_limit=(limit)
      limit = Integer(limit, exception: false) || limit if limit.is_a?(String)
      unless limit.nil? || (limit.is_a?(Integer) && limit >= 1)
        raise ArgumentError, "bulk_write_lock_limit must be nil (no limit) or a whole number of at least 1, got #{limit.inspect}"
      end

      @bulk_write_lock_limit = limit
    end

    # One of MONITOR_APPEND_FAILURES; a string (from ENV, say) is taken as its symbol.
    def monitor_append_failure=(policy)
      policy = policy.to_sym if policy.is_a?(String)
      unless MONITOR_APPEND_FAILURES.include?(policy)
        raise ArgumentError, "monitor_append_failure must be one of #{MONITOR_APPEND_FAILURES.join(', ')}, got #{policy.inspect}"
      end

      @monitor_append_failure = policy
    end

    # Whether a write whose event cannot be stored must fail: always in Hijack
    # and the event-sourcing modes, in Monitor when monitor_append_failure is
    # :fail_write.
    def events_required?
      Lyra.hijack_mode? || Lyra.event_sourcing_mode? ||
        (Lyra.monitor_mode? && monitor_append_failure == :fail_write)
    end

    # Declare the models to monitor in the initializer, before they are
    # loaded:
    #
    #   config.models = %w[Order Payment]                        # by name
    #   config.models = { "Order" => { event_prefix: "Shop" }, "Payment" => {} }
    #   config.models = %w[Spree::* Order]                       # a namespace pattern
    #   config.models = :all                                     # every eligible model
    #   config.models = :all, except: %w[Session Spree::LogEntry]
    #
    # Each is given monitor_with_lyra (with its options) once the
    # application's code has loaded (Lyra::Engine, to_prepare): no model
    # file is edited. A name that does not resolve fails the boot. Patterns
    # and :all enrol only eligible models, and never the event store's,
    # Lyra's or the Rails frameworks' own (Lyra::ModelSelection).
    def models=(models)
      @declared_models = ModelSelection.parse(models)
    end

    # Instrument the declared models now. Called by the engine; call it
    # yourself outside Rails. Returns the model classes.
    def apply_declared_models!
      ModelSelection.apply(@declared_models)
    end

    # Verify the CRUD-to-event mapping with PetriFlow (Lyra.verify_mapping!).
    # In the initializer it runs at boot, after the declared models are
    # instrumented, and a failure stops the boot; called later, it runs now.
    def verify_mapping!
      return Lyra.verify_mapping! if Lyra.booted?

      @verify_mapping_at_boot = true
    end

    def gated_switch?
      defined?(Lyra::ModeTransition) && Lyra.booted? && Lyra::ModeTransition.gate_enabled?
    end

    def verify_mapping_at_boot?
      @verify_mapping_at_boot || false
    end

    # Register a model for monitoring/hijacking
    def monitor_model(model_class, options = {})
      # Check by name to handle Rails development reloading (class objects change on reload)
      model_name = begin
        model_class.name
      rescue StandardError
        model_class.object_id.to_s
      end

      unless @monitored_models.any? { |m| (m.name rescue m.object_id.to_s) == model_name }
        @monitored_models << model_class
      else
        # Update the reference to the new class object (after reload)
        @monitored_models.map! { |m| (m.name rescue m.object_id.to_s) == model_name ? model_class : m }
      end
      @model_configs[model_class] = ModelConfiguration.new(model_class, options)
      # The join tables of the monitored models' has_and_belongs_to_many may
      # have changed (a new model, or a class reloaded).
      Lyra::Associations::HabtmLinks.reset_join_models! if defined?(Lyra::Associations::HabtmLinks)
    end

    # The monitored model an event's model_class names: a monitored model, or
    # a single-table-inheritance subclass of one (enrolling the base class
    # covers its subclasses, which events name as their concrete class). Nil
    # for anything else.
    def monitored_model_named(name)
      return nil if name.nil? || name.to_s.empty?

      found = @monitored_models.find { |m| m.name == name.to_s }
      return found if found

      model = name.to_s.safe_constantize
      return nil unless model.is_a?(Class) && model.respond_to?(:base_class)

      owner = model.base_class
      @monitored_models.any? { |m| m == owner || (m.respond_to?(:base_class) && m.base_class == owner) } ? model : nil
    end

    def model_config(model_class)
      @model_configs[model_class] || ModelConfiguration.new(model_class)
    end

    # Whether :async projection mode projects inline instead of enqueueing
    # AsyncProjectionJob. Unset, it does so in the test environment only.
    # Before, the test environment always projected inline, whatever this
    # said, so no test could run ES-Async as it runs in production.
    def async_projections_inline?
      return @async_projections_inline unless @async_projections_inline.nil?

      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test? ? true : false
    end

    def monitor_mode?
      @mode == :monitor
    end

    def hijack_mode?
      @mode == :hijack || @hijack_enabled
    end

    def event_sourcing_mode?
      @mode == :event_sourcing
    end

    def disabled_mode?
      @mode == :disabled
    end

    # Enable hijack mode (can override CRUD operations)
    # After boot, the enable_*! helpers switch through the Mode Transition
    # Safety gate (Lyra::ModeTransition.to!) when it is enabled.
    def enable_hijack!
      return Lyra::ModeTransition.to!(:hijack) if gated_switch?

      refuse_unrecorded_touches!(:hijack)
      @hijack_enabled = true
      @mode = :hijack
    end

    # Enable monitor mode (only log events, don't override)
    def enable_monitor!
      return Lyra::ModeTransition.to!(:monitor) if gated_switch?

      @hijack_enabled = false
      @mode = :monitor
    end

    # Enable event sourcing mode (events as source of truth, no direct DB writes)
    def enable_event_sourcing!
      return Lyra::ModeTransition.to!(:event_sourcing) if gated_switch?

      refuse_unrecorded_touches!(:event_sourcing)
      @mode = :event_sourcing
      @hijack_enabled = false
    end

    # Disable Lyra completely
    def disable!
      @mode = :disabled
      @hijack_enabled = false
    end

    private

    def refuse_unrecorded_touches!(mode)
      refusal = touch_refusal(mode)
      raise ArgumentError, refusal if refusal
    end

    def validate_choice!(name, value, valid)
      choice = value.is_a?(String) ? value.strip.to_sym : value
      return choice if valid.include?(choice)

      raise ArgumentError,
            "config.#{name} must be one of #{valid.map(&:inspect).join(', ')} (got #{value.inspect})"
    end
  end

  class ModelConfiguration
    attr_accessor :event_prefix, :aggregate_class, :privacy_policy
    # The model's domain event rules (Lyra::DomainEvents), from its
    # domain_events option.
    attr_reader :model_class, :domain_events

    def initialize(model_class, options = {})
      @model_class = model_class
      @event_prefix = options[:event_prefix] || model_class.name
      @aggregate_class = options[:aggregate_class]
      @custom_event_mapping = options[:event_mapping] || {}
      # Names Lyra keeps for its events that are never replayed (Lyra::StreamTail).
      @custom_event_mapping.each_value do |name|
        raise ArgumentError, "event_mapping: #{name} is reserved for Lyra's own events" if Lyra::StreamTail.reserved_name?(name)
      end
      @privacy_policy = options[:privacy_policy]
      @domain_events = Lyra::DomainEvents.rules(options[:domain_events])
    end

    def event_name_for(operation)
      @custom_event_mapping[operation] || "#{event_prefix}#{operation.to_s.camelize}"
    end
  end

  def self.config
    @config ||= Configuration.new
  end

  # Reset configuration (useful for testing)
  def self.reset_config!
    @config = Configuration.new
  end
end
