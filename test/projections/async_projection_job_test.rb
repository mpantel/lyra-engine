# frozen_string_literal: true

require "test_helper"

module Lyra
  module Projections
    # The async projection job must not run before the transaction that stored
    # its event commits. It is enqueued from the model's callbacks, inside that
    # transaction; a worker that picks it up early cannot see the event yet,
    # finds nothing, finishes "successfully" and the projection is lost for good.
    class AsyncProjectionJobTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        skip "Requires ActiveRecord with a database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

        @previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
      end

      teardown do
        ActiveJob::Base.queue_adapter = @previous_adapter if @previous_adapter
      end

      test "is configured to enqueue after the transaction commits" do
        assert AsyncProjectionJob.enqueue_after_transaction_commit
      end

      test "is not enqueued while the writing transaction is open" do
        ActiveRecord::Base.transaction do
          AsyncProjectionJob.perform_later("event-id", "Article", "create")
          assert_no_enqueued_jobs only: AsyncProjectionJob
        end
        assert_enqueued_jobs 1, only: AsyncProjectionJob
      end

      test "is never enqueued when the writing transaction rolls back" do
        ActiveRecord::Base.transaction do
          AsyncProjectionJob.perform_later("event-id", "Article", "create")
          raise ActiveRecord::Rollback
        end
        assert_no_enqueued_jobs only: AsyncProjectionJob
      end
    end
  end
end
