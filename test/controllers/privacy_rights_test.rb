# frozen_string_literal: true

require "test_helper"
require "action_controller"

module Lyra
  # The dashboard's rights page (privacy/rights): the restrictions and
  # objections still open, oldest first, each with its age against the month
  # of Art. 12(3).
  class PrivacyRightsTest < ActionController::TestCase
    tests PrivacyController

    def setup
      skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
      skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

      PamDsl.reset!
      PamDsl.logger = Logger.new(nil)
      PamDsl.define_policy(:dash_rights_policy) do
        field :name, type: :name
        purpose :analytics do
          basis :legitimate_interests
          lia_documented!
          requires :name
        end
      end
      @old = PamDsl.rights.restrict!(subject: "Payer$7", ground: :accuracy_contested, requested_at: Time.now - (40 * 86_400))
      @objection = PamDsl.rights.object!(subject: "Payer$8", policy: :dash_rights_policy, purpose: :analytics,
                                         requested_at: Time.now - (3 * 86_400))
      @late = PamDsl.rights.object!(subject: "Payer$6", policy: :dash_rights_policy, purpose: :analytics,
                                    requested_at: Time.now - (45 * 86_400))
      lifted = PamDsl.rights.restrict!(subject: "Payer$9", ground: :accuracy_contested)
      PamDsl.rights.notify_lift!(lifted.id)
      PamDsl.rights.lift!(lifted.id, reason: :verified_accurate)
    end

    def teardown
      return unless defined?(PamDsl)

      PamDsl.reset!
      PamDsl.logger = nil
    end

    def test_the_open_requests_with_their_age_and_deadline
      get :rights, format: :json

      assert_response :success
      requests = JSON.parse(response.body)["open_requests"]
      assert_equal [@late.id, @old.id, @objection.id], requests.map { _1["id"] }, "oldest first; lifted ones are not open"
      late, old, objection = requests
      # A restriction in force is the controller's action already: no
      # deadline, never overdue, however old.
      assert_equal ["restriction", "Payer$7", "Art. 18(1)(a)", false, nil],
                   old.values_at("kind", "subject", "article", "overdue", "deadline")
      assert_equal 40, old["age_days"]
      # An objection awaiting a decision: a month from its receipt.
      assert_equal ["objection", "Payer$8", "Art. 21(1)", "pending", false],
                   objection.values_at("kind", "subject", "article", "state", "overdue")
      assert objection["deadline"]
      assert_equal [true, 45], late.values_at("overdue", "age_days")
    end

    def test_the_html_page_lists_them
      get :rights

      assert_response :success
      assert_includes response.body, "Payer$7"
      assert_includes response.body, "Art. 21(1)"
      assert_includes response.body, "overdue"
    end
  end
end
