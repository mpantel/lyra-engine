# frozen_string_literal: true

require "test_helper"
require "action_controller"
require "rails_event_store"

module Lyra
  # config.dashboard_authorization: every engine action is authorized first,
  # and with nothing configured the dashboard is open only in development and
  # test, since its routes expose a data subject's personal data.
  class DashboardAuthorizationTest < ActionController::TestCase
    tests DashboardController

    def setup
      Lyra.reset_config!
      Lyra.configure do |config|
        config.event_store = RailsEventStore::Client.new
        config.mode = :monitor
      end
    end

    def teardown
      Lyra.reset_config!
    end

    def test_unset_is_allowed_in_the_test_environment
      assert_nil Lyra.config.dashboard_authorization
      get :index
      assert_response :success
    end

    def test_unset_is_refused_outside_development_and_test
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
      Rails.logger.expects(:warn).with(regexp_matches(/config\.dashboard_authorization/))

      get :index

      assert_response :forbidden
    end

    def test_unset_is_refused_in_staging_too
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("staging"))
      get :index
      assert_response :forbidden
    end

    def test_a_proc_returning_false_refuses
      Lyra.config.dashboard_authorization = ->(_controller) { false }
      get :index
      assert_response :forbidden
    end

    def test_a_proc_returning_nil_refuses
      Lyra.config.dashboard_authorization = ->(_controller) { nil }
      get :index
      assert_response :forbidden
    end

    def test_a_proc_returning_true_allows
      Lyra.config.dashboard_authorization = ->(_controller) { true }
      get :index
      assert_response :success
    end

    def test_a_configured_proc_allows_outside_development_and_test
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
      Lyra.config.dashboard_authorization = ->(_controller) { true }
      get :index
      assert_response :success
    end

    def test_the_proc_is_given_the_controller
      seen = nil
      Lyra.config.dashboard_authorization = ->(controller) { seen = controller; true }
      get :index
      assert_kind_of DashboardController, seen
    end

    def test_a_proc_without_arguments_runs_on_the_controller
      Lyra.config.dashboard_authorization = -> { session[:lyra_admin] == true }

      get :index
      assert_response :forbidden

      get :index, session: { lyra_admin: true }
      assert_response :success
    end

    def test_the_request_is_reachable
      Lyra.config.dashboard_authorization = ->(c) { c.request.headers["X-Admin"] == "yes" }

      get :index
      assert_response :forbidden

      request.headers["X-Admin"] = "yes"
      get :index
      assert_response :success
    end
  end

  class PrivacyAuthorizationTest < ActionController::TestCase
    tests PrivacyController

    def teardown
      Lyra.reset_config!
    end

    def test_a_data_subjects_data_is_refused_when_not_authorized
      Lyra.config.dashboard_authorization = ->(_controller) { false }
      get :subject_data, params: { subject_type: "User", subject_id: "1" }, format: :json
      assert_response :forbidden
    end
  end

  # The engine's root redirects to its dashboard wherever it is mounted.
  class EngineRootRedirectTest < Minitest::Test
    def redirect_from(script_name)
      env = Rack::MockRequest.env_for("/", "SCRIPT_NAME" => script_name)
      status, headers, = Lyra::Engine.call(env)
      [status, headers["Location"] || headers["location"]]
    end

    def test_root_redirects_to_the_dashboard_at_the_default_mount
      status, location = redirect_from("/lyra")
      assert_equal 301, status
      assert_match %r{\A(http://[^/]+)?/lyra/dashboard\z}, location
    end

    def test_root_redirects_to_the_dashboard_at_another_mount
      _, location = redirect_from("/admin/audit")
      assert_match %r{\A(http://[^/]+)?/admin/audit/dashboard\z}, location
    end
  end
end
