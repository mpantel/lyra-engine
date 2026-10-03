# frozen_string_literal: true

require "test_helper"

if defined?(ActiveRecord::Base)
  class InterfaceTestUser < ActiveRecord::Base
    self.table_name = "users"
    include Lyra::Interceptors::CrudInterceptor
    monitor_with_lyra privacy_policy: :interface_test_policy
  end
end

module Lyra
  module Privacy
    # Lyra's privacy layer talks only to the Policy/Detector interface; PAM
    # is one provider behind it. These tests pin the interface down without
    # PAM, with a stand-in provider, and through the PAM adapter.
    class InterfaceTest < Minitest::Test
      # A provider that isn't PAM: declares :email only, flags anything
      # ending in "_secret".
      class StubProvider < Provider
        class StubPolicy < Policy
          def name
            :stub
          end

          def loaded?
            true
          end

          def declared_fields
            [:email]
          end

          def annotation(field)
            return nil unless field.to_sym == :email

            Annotation.new(field: :email, type: :email, sensitivity: :confidential, sensitive: true,
                           purposes: [:billing], source: :policy)
          end

          def mask(_field, _value, _context = :display)
            "[stub]"
          end
        end

        class StubDetector < Detector
          def detect(attributes)
            attributes.select { |k, _| k.to_s.end_with?("_secret") }
                      .to_h { |k, v| [k, { type: :custom, value: v, sensitive: true }] }
          end
        end

        def name
          :stub
        end

        def available?
          true
        end

        def policy(_name)
          StubPolicy.new
        end

        def detector
          StubDetector.new
        end
      end

      def teardown
        Lyra::Privacy.provider = nil
        PamDsl.reset! if PAM_DSL_AVAILABLE
      end

      def test_null_provider_declares_nothing_and_allows_everything
        Lyra::Privacy.provider = Provider.new

        policy = Lyra::Privacy.policy(:anything)
        refute policy.loaded?
        assert_nil policy.annotation(:email)
        assert policy.allowed?(:email, :marketing)
        assert_nil policy.retention_for("User")
        assert_equal({}, Lyra::Privacy::PIIDetector.detect({ email: "a@example.com" }))
        refute Lyra.privacy_features_available?
      end

      def test_any_provider_plugs_into_the_same_hook
        Lyra::Privacy.provider = StubProvider.new

        integration = PolicyIntegration.new(:whatever)
        result = integration.detect_pii({ email: "a@example.com", api_secret: "x", name: "Ann" })

        assert_equal :policy, result[:email][:source]
        assert_equal :detector, result[:api_secret][:source]
        refute result.key?(:name), "the stub detector doesn't know names"
        assert_equal "[stub]", integration.mask_pii(:email, "a@example.com")
        assert Lyra.privacy_features_available?
      end

      def test_pam_adapter_annotation_mirrors_the_pam_field
        skip "requires PAM DSL" unless PAM_DSL_AVAILABLE
        define_pam_policy

        annotation = Lyra::Privacy.policy(:interface_test_policy).annotation(:email)

        assert_equal :email, annotation.type
        assert_equal :confidential, annotation.sensitivity
        assert annotation.sensitive
        assert_equal [:marketing], annotation.purposes
      end

      def test_annotations_are_recoverable_from_an_event
        skip "requires PAM DSL" unless PAM_DSL_AVAILABLE
        define_pam_policy
        event = Lyra::Event.new(data: {
          operation: :updated,
          model_class: "InterfaceTestUser",
          model_id: 1,
          attributes: { email: "a@example.com", created_at: Time.current },
          changes: { name: %w[Ann Anna] }
        })

        annotations = Lyra::Privacy.annotations_for(event)

        assert_equal %w[email name], annotations.keys.sort, "declared attributes only, from both attributes and changes"
        assert_equal :email, annotations["email"].type
      end

      def test_no_annotations_without_a_declared_policy
        Lyra::Privacy.provider = Provider.new
        event = Lyra::Event.new(data: {
          operation: :created, model_class: "InterfaceTestUser", model_id: 1,
          attributes: { email: "a@example.com" }, changes: {}
        })

        assert_equal({}, Lyra::Privacy.annotations_for(event))
      end

      private

      def define_pam_policy
        PamDsl.define_policy :interface_test_policy do
          field :email, type: :email, sensitivity: :confidential do
            allow_for :marketing
          end
          field :name, type: :name, sensitivity: :internal

          purpose :marketing do
            basis :consent
            requires :email
          end
        end
      end
    end
  end
end
