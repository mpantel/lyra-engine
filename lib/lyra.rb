require "lyra/version"
require "rails_event_store"
require "lyra/optional_dependency"

# PAM DSL is optional - required for privacy features
# Set LYRA_DISABLE_PAM_DSL=true to test Lyra without PAM DSL
PAM_DSL_AVAILABLE = if ENV["LYRA_DISABLE_PAM_DSL"] == "true"
  false
else
  Lyra::OptionalDependency.load("pam_dsl")
end

# PetriFlow is optional - required for formal verification
PETRI_FLOW_AVAILABLE = Lyra::OptionalDependency.load("petri_flow")

# Only load engine when Rails is available
if defined?(Rails)
  require "lyra/engine"
end

# Core components
require "lyra/configuration"
require "lyra/correlation"
require "lyra/event"
require "lyra/event_store_adapter"
require "lyra/event_serializer"
require "lyra/event_mapper"
require "lyra/projection"
require "lyra/temporal"
require "lyra/domain_events"
require "lyra/command"
require "lyra/aggregate"
require "lyra/command_handler"
require "lyra/dual_view"
require "lyra/event_flow"
require "lyra/event_analyzer"
require "lyra/id_generator"

# Strict data access (prevents callback-bypassing operations)
# Loaded before projections because projections use bypass methods
require "lyra/bypass_events"
require "lyra/strict_data_access"

# Event sourcing projections
require "lyra/projections/model_projection"
require "lyra/projections/rebuild"
require "lyra/projections/async_projection_job"
require "lyra/projections/cached_projection"
require "lyra/projections/cached_joins"
require "lyra/projections/cached_relation"
require "lyra/projections/association_conditions"
require "lyra/projections/event_store_reader"
require "lyra/projections/lazy_projection"
require "lyra/genesis"

# Event-aware associations
require "lyra/associations/event_aware"

# Consistency helpers
require "lyra/consistency/read_your_writes"

# Privacy: the provider interface is always loaded and falls back to a null
# provider. PAM plugs in as a provider when the pam_dsl gem is present; the
# masker and GDPR compliance tools are PAM features.
require "lyra/privacy/interface"
require "lyra/privacy/pii_detector"
require "lyra/privacy/policy_integration"
if PAM_DSL_AVAILABLE
  require "lyra/privacy/adapters/pam"
  require "lyra/privacy/pii_masker"
  require "lyra/privacy/gdpr_compliance"
end

# Schema validation
require "lyra/schema/store"
require "lyra/schema/generator"
require "lyra/schema/diff"
require "lyra/schema/validator"
require "lyra/schema/reporter"
require "lyra/schema/event_class_registrar"

# Visualization
require "lyra/visualization/timeline"
require "lyra/visualization/event_graph"
require "lyra/visualization/activity_heatmap"

# Formal verification (requires PetriFlow)
if PETRI_FLOW_AVAILABLE
  require "lyra/verification/crud_lifecycle_workflow"
  require "lyra/verification/workflow_generator"
  require "lyra/verification/bypass_workflow"
end

module Lyra
  class Error < StandardError; end

  def self.configure
    yield config if block_given?
  end

  def self.monitor_mode?
    config.monitor_mode?
  end

  def self.hijack_mode?
    config.hijack_mode?
  end

  def self.event_sourcing_mode?
    config.event_sourcing_mode?
  end

  def self.disabled_mode?
    config.disabled_mode?
  end

  # Delegate event_store to configuration
  def self.event_store
    config.event_store
  end

  def self.event_store=(store)
    config.event_store = store
  end

  # Check if PAM DSL is available for privacy features
  def self.pam_dsl_available?
    PAM_DSL_AVAILABLE
  end

  # Check if a privacy provider is installed
  def self.privacy_features_available?
    Lyra::Privacy.provider.available?
  end

  # Check if PetriFlow is available for formal verification
  def self.petri_flow_available?
    PETRI_FLOW_AVAILABLE
  end

  # Check if formal verification features are available
  def self.verification_available?
    petri_flow_available?
  end

  class MappingVerificationError < StandardError; end

  # Whether the application has finished booting (set by the engine).
  def self.booted?
    @booted || false
  end

  def self.booted!
    @booted = true
  end

  # Verify the CRUD-to-event mapping and the monitored models; raise
  # MappingVerificationError naming every failed check. Runs the PetriFlow
  # nets (lifecycle, Create/Update/Destroy modes, bypass writes) through
  # CrudVerifier, and checks that each monitored model has a table and a
  # primary key. Returns the verifier's report.
  def self.verify_mapping!
    unless petri_flow_available?
      raise MappingVerificationError, "config.verify_mapping! needs the petri_flow gem, which is not installed"
    end

    report = verify_crud_mapping
    summary = report[:summary]
    failures = %i[lifecycle_valid modes_valid all_terminals_reachable deadlock_free bypass_covered]
               .reject { |check| summary[check] }
               .map { |check| "#{check} is false" }

    config.monitored_models.each do |model|
      unless model.table_exists?
        failures << "#{model.name}: table #{model.table_name} does not exist"
        next
      end
      failures << "#{model.name}: no primary key" if model.primary_key.blank?
    end

    raise MappingVerificationError, "Lyra mapping verification failed: #{failures.join('; ')}" if failures.any?

    report
  end

  # Run formal verification of CRUD→Event mapping
  # @return [Hash] Verification results
  # @raise [RuntimeError] if PetriFlow is not available
  def self.verify_crud_mapping
    raise "PetriFlow is required for formal verification" unless petri_flow_available?

    verifier = Verification::CrudVerifier.new
    verifier.verify_all
  end
end
