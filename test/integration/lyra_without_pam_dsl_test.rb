require "test_helper"

class LyraWithoutPamDslTest < Minitest::Test
  # This test verifies that Lyra's code paths handle PAM DSL absence correctly.
  # When LYRA_DISABLE_PAM_DSL=true, privacy modules are not loaded.
  # When PAM DSL is available, we test fallback behavior with nonexistent policies.

  def test_lyra_core_components_always_available
    # Verify core Lyra components work regardless of PAM DSL
    assert defined?(Lyra::Event), "Event should be defined"
    assert defined?(Lyra::EventFlow), "EventFlow should be defined"
    assert defined?(Lyra::Configuration), "Configuration should be defined"
    assert defined?(Lyra::Aggregate), "Aggregate should be defined"
    assert defined?(Lyra::Command), "Command should be defined"
    assert defined?(Lyra::Schema::Generator), "Schema::Generator should be defined"
    assert defined?(Lyra::Visualization::Timeline), "Visualization::Timeline should be defined"

    # Create an event without PAM DSL involvement
    event = Lyra::Event.new(
      data: {
        operation: :created,
        model_class: "TestModel",
        model_id: 1,
        attributes: { name: "Test" },
        changes: {}
      }
    )

    assert_equal :created, event.operation
    assert_equal "TestModel", event.model_class
  end

  def test_pam_dsl_available_matches_environment
    assert defined?(PAM_DSL_AVAILABLE), "PAM_DSL_AVAILABLE should be defined"

    if ENV["LYRA_DISABLE_PAM_DSL"] == "true"
      refute PAM_DSL_AVAILABLE, "PAM_DSL_AVAILABLE should be false when LYRA_DISABLE_PAM_DSL=true"
      refute defined?(Lyra::Privacy::PIIDetector), "Privacy modules should not be loaded"
    else
      assert PAM_DSL_AVAILABLE, "PAM_DSL_AVAILABLE should be true in normal test environment"
      assert defined?(Lyra::Privacy::PIIDetector), "PIIDetector should be loaded"
    end
  end

  def test_lyra_pam_dsl_available_helper
    assert_equal PAM_DSL_AVAILABLE, Lyra.pam_dsl_available?
    assert_equal PAM_DSL_AVAILABLE, Lyra.privacy_features_available?
  end

  # The following tests require PAM DSL to test fallback behavior
  def test_policy_integration_handles_missing_policy_with_detector
    skip "Requires PAM DSL to test fallback behavior" unless PAM_DSL_AVAILABLE

    # With no policy but use_detector: true (default), detector still works
    integration = Lyra::Privacy::PolicyIntegration.new(:nonexistent_policy_xyz)

    # Detector should still find PII
    result = integration.detect_pii({ email: "test@example.com", status: "active" })
    assert result.key?(:email), "Detector should find email"
    assert_equal :detector, result[:email][:source]
    refute result.key?(:status), "status is not PII"

    # Masking should work via detector
    masked = integration.mask_pii(:email, "test@example.com")
    assert_includes masked, "***", "Should be masked by detector"

    # Policy-specific features return safe defaults
    assert_nil integration.retention_duration('User')
    refute integration.consent_required?(:marketing)
    assert integration.allowed?(:email, :any_purpose)
    assert_equal [], integration.sensitive_fields
    assert_equal [], integration.restricted_fields
  end

  def test_policy_integration_use_detector_false_without_policy
    skip "Requires PAM DSL to test fallback behavior" unless PAM_DSL_AVAILABLE

    # With use_detector: false and no policy, should return empty/unchanged
    integration = Lyra::Privacy::PolicyIntegration.new(:nonexistent_xyz, use_detector: false)

    result = integration.detect_pii({ email: "test@example.com", phone: "555-1234" })
    assert_equal({}, result)

    masked = integration.mask_pii(:email, "secret@example.com")
    assert_equal "secret@example.com", masked
  end

  def test_policy_integration_to_h_without_policy
    skip "Requires PAM DSL to test fallback behavior" unless PAM_DSL_AVAILABLE

    integration = Lyra::Privacy::PolicyIntegration.new(:nonexistent_xyz)

    info = integration.to_h

    assert info[:pam_dsl_available]
    refute info[:policy_loaded]
    assert info[:use_detector]
    refute info.key?(:policy_name)
  end

  def test_pam_dsl_constant_matches_reality
    # This test works in both modes - verifies Lyra's privacy modules match PAM_DSL_AVAILABLE
    # Note: PamDsl gem may be loaded by bundler regardless, but Lyra's privacy modules
    # are only loaded when PAM_DSL_AVAILABLE is true
    if PAM_DSL_AVAILABLE
      assert defined?(PamDsl), "PamDsl should be defined when PAM_DSL_AVAILABLE is true"
      assert defined?(PamDsl::PIIDetector), "PamDsl::PIIDetector should be defined"
      assert defined?(Lyra::Privacy::PolicyIntegration), "PolicyIntegration should be defined"
      assert defined?(Lyra::Privacy::PIIDetector), "Lyra::Privacy::PIIDetector should be defined"
    else
      # Lyra's privacy modules should NOT be loaded when PAM_DSL_AVAILABLE is false
      refute defined?(Lyra::Privacy::PIIDetector), "Lyra::Privacy::PIIDetector should NOT be defined"
      refute defined?(Lyra::Privacy::PolicyIntegration), "PolicyIntegration should NOT be defined"
      refute defined?(Lyra::Privacy::PIIMasker), "Lyra::Privacy::PIIMasker should NOT be defined"
    end
  end

  # Tests that verify Lyra works correctly WITHOUT PAM DSL
  def test_event_flow_works_without_pam_dsl
    # EventFlow should work regardless of PAM DSL availability
    flow = Lyra::EventFlow.new
    assert_respond_to flow, :flow_data
    assert_respond_to flow, :build_timeline
    assert_respond_to flow, :reconstruct_state_chain
  end

  def test_schema_generator_works_without_pam_dsl
    # Schema generator should work without PAM DSL
    assert defined?(Lyra::Schema::Generator), "Schema::Generator should be defined"

    # Generate schema - should not require PAM DSL
    schema = Lyra::Schema::Generator.generate
    assert schema.is_a?(Hash), "Schema should be a hash"
    assert schema.key?(:version), "Schema should have version"
    assert schema.key?(:configuration), "Schema should have configuration"
  end

  def test_visualization_works_without_pam_dsl
    # Visualization should work without PAM DSL
    timeline = Lyra::Visualization::Timeline.new([])
    assert_respond_to timeline, :to_html
    assert_respond_to timeline, :to_mermaid
    assert_respond_to timeline, :to_ascii
  end

  def test_configuration_works_without_pam_dsl
    # Configuration should work without PAM DSL
    Lyra.configure do |config|
      config.mode = :monitor
    end
    assert_equal :monitor, Lyra.config.mode
    assert Lyra.monitor_mode?
  end
end
