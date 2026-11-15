require "test_helper"
require "action_controller"
require "rails_event_store"

module Lyra
  # The dashboard's JSON routes read the most recent events, at most
  # config.dashboard_max_events, and the subject timelines read one stream.
  # Before 1.0.0 they read the whole log on every request.
  class DashboardBoundedReadsTest < ActionController::TestCase
    tests FlowController

    class Reading < Lyra::Event; end

    def setup
      # In memory: nothing left in the database by other tests is in this log.
      @event_store = RailsEventStore::Client.new(repository: RubyEventStore::InMemoryRepository.new)
      Lyra.configure { |config| config.event_store = @event_store }
      Lyra.config.dashboard_max_events = 10
      @model = Class.new { def self.name = "TestModel" }
      Object.const_set(:TestModel, @model) unless Object.const_defined?(:TestModel)
      Lyra.config.stubs(:monitored_model_named).returns(nil)
      Lyra.config.stubs(:monitored_model_named).with("TestModel").returns(@model)
    end

    def teardown
      Lyra.config.dashboard_max_events = 10_000
    end

    def test_the_crud_summary_counts_only_the_window
      publish(25, operation: :created)

      get :crud_mapping, format: :json

      body = JSON.parse(response.body)
      assert_equal 10, body["total_events"], "25 events in the log, the 10 most recent read"
      assert_equal({ "limit" => 10, "returned" => 10, "truncated" => true }, body["window"].slice("limit", "returned", "truncated"))
    end

    def test_a_window_that_holds_the_whole_log_is_not_truncated_when_it_is_larger
      Lyra.config.dashboard_max_events = 50
      publish(25, operation: :created)

      get :crud_mapping, format: :json

      assert_equal 25, JSON.parse(response.body)["total_events"]
      refute JSON.parse(response.body)["window"]["truncated"]
    end

    def test_a_request_may_lower_the_limit_but_not_raise_it
      publish(25, operation: :created)

      get :crud_mapping, params: { limit: 3 }, format: :json
      assert_equal 3, JSON.parse(response.body)["total_events"]

      get :crud_mapping, params: { limit: 1_000_000 }, format: :json
      assert_equal 10, JSON.parse(response.body)["total_events"], "clamped to config.dashboard_max_events"
    end

    def test_a_correlation_older_than_the_window_is_not_found_and_the_window_says_so
      publish(1, operation: :created, metadata: { correlation_id: "old-chain" })
      publish(20, operation: :updated)

      get :correlation, params: { correlation_id: "old-chain" }

      body = JSON.parse(response.body)
      assert_equal 0, body["events_count"]
      assert body["window"]["truncated"], "the caller can tell it did not look back that far"
    end

    def test_a_recent_correlation_is_found
      publish(5, operation: :created, metadata: { correlation_id: "chain-1" })

      get :correlation, params: { correlation_id: "chain-1" }

      assert_equal 5, JSON.parse(response.body)["events_count"]
    end

    def test_user_actions_lists_at_most_the_requested_number_of_actions
      12.times { |i| publish(1, operation: :updated, metadata: { user_id: 7, action_id: "a#{i}" }) }
      Lyra.config.dashboard_max_events = 50

      get :user_actions, params: { user_id: 7, actions: 4 }

      body = JSON.parse(response.body)
      assert_equal 12, body["total_actions"]
      assert_equal 4, body["actions"].size
      assert_equal 4, body["actions_listed"]
    end

    # The timeline routes go through EventFlow: a subject's timeline is that
    # record's stream. Another record's event that names the subject as its
    # actor is not in it (what a user did is user_actions).
    def test_a_subject_timeline_reads_that_records_stream_and_no_other
      @event_store.publish(Reading.new(data: { model_class: "TestModel", model_id: 1, operation: :created }),
                           stream_name: Lyra.stream_name(@model, 1))
      @event_store.publish(Reading.new(data: { model_class: "TestModel", model_id: 2, operation: :updated }, metadata: { user_id: "1" }),
                           stream_name: Lyra.stream_name(@model, 2))

      flow = EventFlow.new(subject_id: "1", subject_type: "TestModel").flow_data

      assert_equal [1], flow[:timeline].map { |e| e[:model_id] }
      assert_equal({ limit: 10, returned: 1, truncated: false }, flow[:window].slice(:limit, :returned, :truncated))
    end

    def test_an_unmonitored_subject_type_reads_nothing
      publish(2, operation: :updated, metadata: { user_id: "1" })

      assert_empty EventFlow.new(subject_id: "1", subject_type: "Secret").flow_data[:timeline]
    end

    def test_a_flow_without_a_subject_reads_the_window
      publish(25, operation: :created)

      flow = EventFlow.new.flow_data

      assert_equal 10, flow[:timeline].size
      assert flow[:window][:truncated]
    end

    def test_a_window_exactly_as_large_as_the_log_is_not_truncated
      publish(10, operation: :created)

      get :crud_mapping, format: :json

      assert_equal 10, JSON.parse(response.body)["total_events"]
      refute JSON.parse(response.body)["window"]["truncated"], "nothing older was left out"
    end

    # With the access log on, every read adds an entry; entries do not fill the
    # window, or the data events would be pushed out of it.
    def test_access_log_entries_do_not_fill_the_window
      publish(5, operation: :created)
      20.times { @event_store.publish(Lyra::Events::DataAccessed.new(data: { purpose: "x" }), stream_name: "Lyra::DataAccess$TestModel$1") }

      get :crud_mapping, format: :json

      body = JSON.parse(response.body)
      assert_equal 5, body["total_events"]
      refute body["window"]["truncated"]
    end

    def test_a_dashboard_read_is_recorded_in_the_access_log_when_it_is_on
      Lyra.config.mode = :monitor
      Lyra.config.record_access_events = true
      publish(3, operation: :updated, metadata: { user_id: 7, action_id: "a1" })

      get :user_actions, params: { user_id: 7 }

      entry = @event_store.read.stream("Lyra::DataAccess$Dashboard").to_a.sole
      assert_kind_of Lyra::Events::DashboardRead, entry
      assert_equal "flow/user_actions", entry.data[:route]
      assert_equal({ "user_id" => "7" }, entry.data[:scope].transform_keys(&:to_s))
      assert_equal 3, entry.data[:returned]
      assert_equal "lyra_dashboard", entry.metadata[:source]
    ensure
      Lyra.config.record_access_events = false
    end

    def test_nothing_is_recorded_when_the_access_log_is_off
      publish(3, operation: :updated, metadata: { user_id: 7, action_id: "a1" })

      get :user_actions, params: { user_id: 7 }

      assert_empty @event_store.read.stream("Lyra::DataAccess$Dashboard").to_a
    end

    # The GDPR helpers read the log in batches, a batch at a time
    def test_every_event_is_read_once_whatever_the_batch_size
      publish(5, operation: :created)
      compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: 1, subject_type: "TestModel")

      seen = []
      compliance.send(:each_event, 2) { |event| seen << event.event_id }

      assert_equal 5, seen.size
      assert_equal seen.uniq, seen
    end

    private

    def publish(count, operation:, metadata: {})
      count.times do
        @event_store.publish(Reading.new(data: { model_class: "TestModel", model_id: 1, operation: operation }, metadata: metadata),
                             stream_name: "TestModel$1")
      end
    end
  end
end
