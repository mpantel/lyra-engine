# frozen_string_literal: true

require "test_helper"
require "action_controller"

module Lyra
  # The dashboard reads under a purpose, as the application does: the one the
  # request names (?purpose=), else config.dashboard_purpose. A read the policy
  # refuses answers 403 and says how to name one.
  class DashboardPurposeTest < ActionController::TestCase
    tests DashboardController

    def setup
      skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
      skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

      PamDsl.reset!
      PamDsl.logger = Logger.new(nil)
      PamDsl.define_policy(:dashboard_policy) do
        field :email, type: :email
        field :name, type: :name
        purpose :oversight do
          basis :legal_obligation
          requires :name, :email
        end
        purpose :contact do
          basis :contract
          requires :email
        end
      end
      Object.send(:remove_const, :DashUser) if defined?(DashUser)
      Object.const_set(:DashUser, Class.new(ActiveRecord::Base) { self.table_name = "users" })
      DashUser.include(Lyra::Interceptors::CrudInterceptor)
      DashUser.monitor_with_lyra(privacy_policy: :dashboard_policy)
      Lyra.config.monitor_model(DashUser, privacy_policy: :dashboard_policy)
      Lyra.config.enable_monitor!
      ActiveRecord::Base.connection.execute("DELETE FROM users")
      @user = DashUser.create!(name: "Ann", email: "ann@example.com")
      Lyra.config.reads_without_purpose = :deny
    end

    def teardown
      return unless defined?(DashUser)

      Lyra.config.reads_without_purpose = :allow
      Lyra.config.dashboard_purpose = nil
      ActiveRecord::Base.connection.execute("DELETE FROM users")
      PamDsl.reset!
      PamDsl.logger = nil
    end

    def test_a_read_without_a_purpose_is_refused_and_says_how_to_name_one
      get :compare, params: { model_class: "DashUser", id: @user.id }, format: :json

      assert_response :forbidden
      assert_match(/purpose=/, JSON.parse(response.body)["error"])
    end

    def test_a_read_under_a_purpose_the_policy_allows_goes_ahead
      get :compare, params: { model_class: "DashUser", id: @user.id, purpose: "oversight" }, format: :json

      assert_response :success
      assert_equal({}, JSON.parse(response.body).dig("comparison", "differences"))
    end

    def test_a_purpose_that_does_not_cover_the_fields_is_refused
      get :compare, params: { model_class: "DashUser", id: @user.id, purpose: "contact" }, format: :json

      assert_response :forbidden
    end

    def test_the_configured_purpose_is_used_when_the_request_names_none
      Lyra.config.dashboard_purpose = :oversight

      get :compare, params: { model_class: "DashUser", id: @user.id }, format: :json

      assert_response :success
    end

    def test_the_discrepancies_page_reads_under_the_purpose_too
      get :discrepancies, params: { model_class: "DashUser" }, format: :json
      assert_response :forbidden

      get :discrepancies, params: { model_class: "DashUser", purpose: "oversight" }, format: :json
      assert_response :success
    end
  end
end
