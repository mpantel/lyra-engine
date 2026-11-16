# frozen_string_literal: true

require "test_helper"
require "action_controller"

# The dashboard's event routes and the subject's rights (Arts. 18 and 21):
# under the dashboard's purpose, a route about one record is refused (403)
# when a restriction covers it, and a route over many records leaves out the
# events of the restricted ones (X-Lyra-Rights-Withheld says how many).
module DashboardRightsSetup
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(:dash_rights) do
      field :title, type: :custom
      field :body, type: :custom
      purpose(:publishing) { basis :contract; requires :title, :body }
    end
    Object.send(:remove_const, :DrArticle) if Object.const_defined?(:DrArticle)
    Object.const_set(:DrArticle, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    DrArticle.include(Lyra::Interceptors::CrudInterceptor)
    DrArticle.monitor_with_lyra(privacy_policy: :dash_rights)
    Lyra.config.monitor_model(DrArticle, privacy_policy: :dash_rights)
    Lyra.config.enable_monitor!
    clean
    Lyra.config.dashboard_purpose = :publishing
    @secret = DrArticle.create!(title: "Secret title", body: "secret body")
    @plain = DrArticle.create!(title: "Plain title", body: "plain body")
    PamDsl.rights.restrict!(subject: "DrArticle$#{@secret.id}", ground: :accuracy_contested)
  end

  def teardown
    return unless defined?(DrArticle)

    Lyra.config.dashboard_purpose = nil
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  def clean
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    LyraRightsIsolation.purge!
  end

  def json = JSON.parse(response.body)
end

module Lyra
  class FlowRightsTest < ActionController::TestCase
    include DashboardRightsSetup
    tests FlowController

    def test_a_restricted_record_s_event_chain_and_timeline_are_refused
      get :event_chain, params: { model_class: "DrArticle", model_id: @secret.id }, format: :json
      assert_response :forbidden
      refute_includes response.body, "secret body"
      get :visualization, params: { model_class: "DrArticle", model_id: @secret.id }, format: :json
      assert_response :forbidden

      get :event_chain, params: { model_class: "DrArticle", model_id: @plain.id }, format: :json
      assert_response :success
      assert_includes response.body, "plain body"
    end

    def test_the_log_wide_routes_leave_the_restricted_record_s_events_out
      get :timeline, format: :json
      assert_response :success
      refute_includes response.body, "\"model_id\":#{@secret.id},"
      assert_includes response.body, "\"model_id\":#{@plain.id},"
      assert_equal "1", response.headers["X-Lyra-Rights-Withheld"]

      correlation = Lyra.config.event_store.read.stream("DrArticle$#{@secret.id}").to_a.first.metadata[:correlation_id]
      if correlation
        get :correlation, params: { correlation_id: correlation }, format: :json
        assert_response :success
        refute_includes response.body, "secret body"
      end
    end
  end

  class DashboardRightsTest < ActionController::TestCase
    include DashboardRightsSetup
    tests DashboardController

    def test_a_restricted_record_s_entity_graph_is_refused_and_lists_leave_it_out
      get :entity_graph, params: { model_class: "DrArticle", id: @secret.id }, format: :json
      assert_response :forbidden

      get :event_graph, format: :json
      assert_response :success
      refute_includes response.body, "DrArticle##{@secret.id}"
      assert_includes response.body, "DrArticle##{@plain.id}"

      get :event_list, format: :json
      assert_response :success
      assert_equal [@plain.id], json["entities"].map { _1["model_id"] }
    end
  end

  class PrivacyRouteRightsTest < ActionController::TestCase
    include DashboardRightsSetup
    tests PrivacyController

    def test_pii_routes_refuse_or_leave_out_the_restricted_record
      get :pii_inventory, params: { subject_type: "DrArticle", subject_id: @secret.id }, format: :json
      assert_response :forbidden

      get :data_lineage, params: { field_name: "body" }, format: :json
      assert_response :success
      refute_includes response.body, "secret body"
      assert_includes response.body, "plain body"

      get :pii_detection, format: :json
      assert_response :success
      assert_equal "1", response.headers["X-Lyra-Rights-Withheld"]
    end
  end
end
