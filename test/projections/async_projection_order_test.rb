# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # ES-Async projects each event in its own job, and a job pool runs them
    # concurrently, so a record's jobs can finish in any order. The Olist replay
    # through Solidus caught it: two orders whose events end in "complete" kept
    # rows at "confirm", because the earlier update's job landed last.
    #
    # Each job must therefore converge: whatever order the jobs run in, the row
    # ends as the record's latest event says.
    class AsyncProjectionOrderTest < ActiveSupport::TestCase
      setup do
        skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)

        @event_store = Lyra.config.event_store || RailsEventStore::Client.new(
          repository: RubyEventStore::ActiveRecord::EventRepository.new(serializer: RubyEventStore::Serializers::YAML)
        )
        Object.send(:remove_const, :OrderedArticle) if defined?(OrderedArticle)
        Object.const_set(:OrderedArticle, Class.new(ActiveRecord::Base) do
          self.table_name = "articles"
          include Lyra::Interceptors::CrudInterceptor
          monitor_with_lyra
        end)
        clean

        # Store the events without projecting them (ES-NoProj), so each test
        # can run the projection jobs itself, in the order it chooses.
        Lyra.reset_config!
        Lyra.config.event_store = @event_store
        Lyra.config.enable_event_sourcing!
        Lyra.config.projection_mode = :disabled
        Lyra.config.monitor_model(OrderedArticle)
      end

      teardown do
        clean if defined?(OrderedArticle)
        Lyra.reset_config!
        Lyra.config.event_store = @event_store if @event_store
      end

      test "jobs run newest first still leave the row at the latest state" do
        id = write_history(%w[draft review published])

        jobs_for(id).reverse_each { |event| run_job(event) }

        assert_equal "published", row(id)&.fetch("status")
      end

      test "an old job running after the newest one does not roll the row back" do
        id = write_history(%w[draft review published])
        created, review, published = jobs_for(id)

        run_job(created)
        run_job(published)
        run_job(review)

        assert_equal "published", row(id)&.fetch("status")
      end

      test "a destroy stays a destroy even if the create job runs last" do
        id = write_history(%w[draft review], destroy: true)

        jobs_for(id).reverse_each { |event| run_job(event) }

        assert_nil row(id)
      end

      private

      # Create a record and update its status through each value, in ES-NoProj
      # mode: events are stored, no row is written.
      def write_history(statuses, destroy: false)
        article = OrderedArticle.create!(title: "Ordered", body: "Body", status: statuses.first)
        statuses.drop(1).each { |s| article.update!(status: s) }
        article.destroy! if destroy
        article.id
      end

      def jobs_for(id) = @event_store.read.stream("OrderedArticle$#{id}").to_a

      def run_job(event)
        operation = event.event_type.to_s[/(Created|Updated|Destroyed)\z/, 1]
        operation = { "Created" => "create", "Updated" => "update", "Destroyed" => "destroy" }.fetch(operation)
        AsyncProjectionJob.perform_now(event.event_id, "OrderedArticle", operation)
      end

      def row(id)
        ActiveRecord::Base.connection.select_one("SELECT * FROM articles WHERE id = #{Integer(id)}")
      end

      def clean
        ActiveRecord::Base.connection.execute("DELETE FROM articles")
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events_in_streams")
        ActiveRecord::Base.connection.execute("DELETE FROM event_store_events")
        Rails.cache.clear if defined?(Rails.cache)
      end
    end
  end
end
