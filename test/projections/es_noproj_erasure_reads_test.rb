# frozen_string_literal: true

require "test_helper"

# An erasure in another process, seen by a process whose ES-NoProj reads are
# warm. Lyra::Erasure rewrites the record's events in place and appends an
# ErasureApplied. The eraser drops its own cache entries; another process
# kept its entry, stamped with the event before the ErasureApplied, and
# brought it up to date by replaying only the events after the stamp: the
# ErasureApplied, which changes no attribute. Its reads (find_by, where, a
# uniqueness check) kept answering with the erased values.
class EsNoprojErasureReadsTest < Minitest::Test
  def setup
    skip "Requires PAM DSL" unless Lyra.pam_dsl_available?
    skip "Requires fork" unless Process.respond_to?(:fork)

    PamDsl.reset!
    PamDsl.define_policy(:lyra_erasure_reads_policy) do
      field :email, type: :email, sensitivity: :confidential
      field :name, type: :name
      purpose :contact do
        basis :contract
        requires :email
      end
    end
    Object.send(:remove_const, :ErasureReadUser) if Object.const_defined?(:ErasureReadUser)
    Object.const_set(:ErasureReadUser, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      validates :email, uniqueness: true
    end)
    ErasureReadUser.include(Lyra::Interceptors::CrudInterceptor)
    ErasureReadUser.monitor_with_lyra(privacy_policy: :lyra_erasure_reads_policy)
    Lyra.config.monitor_model(ErasureReadUser, privacy_policy: :lyra_erasure_reads_policy)
    clean
  end

  def teardown
    return unless defined?(PamDsl)

    Lyra.config.projection_mode = :sync
    Lyra.config.enable_monitor!
    clean
    PamDsl.reset!
  end

  def test_an_erasure_in_another_process_reaches_warm_reads_in_es_noproj
    %i[monitor es_noproj].each do |mode|
      clean
      use(mode)
      ann = ErasureReadUser.create!(name: "Ann", email: "ann@example.com")
      ErasureReadUser.create!(name: "Bob", email: "bob@example.com")
      # Warm: the record's entry, the collection, the uniqueness copy.
      assert_equal "ann@example.com", ErasureReadUser.find_by(id: ann.id).email
      assert_equal [ann.id], ErasureReadUser.where(email: "ann@example.com").map(&:id)
      assert taken?("ann@example.com")

      in_another_process { Lyra::Erasure.erase!(ErasureReadUser, ann.id, reason: "test") }

      erased = "erased:#{ann.id}"
      assert_equal erased, ErasureReadUser.find_by(id: ann.id).email, mode
      assert_empty ErasureReadUser.where(email: "ann@example.com").to_a, mode
      assert_equal [ann.id], ErasureReadUser.where(email: erased).map(&:id), mode
      refute taken?("ann@example.com"), mode
    end
  end

  private

  def taken?(email)
    record = ErasureReadUser.new(name: "Z", email: email)
    record.valid?
    record.errors.of_kind?(:email, :taken)
  end

  def in_another_process
    pid = fork do
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all) rescue nil
      yield
      exit!(0)
    rescue StandardError => e
      warn "child: #{e.class}: #{e.message}"
      exit!(1)
    end
    Process.wait(pid)
    raise "the erasure failed in the other process" unless $?.success?
  end

  def use(mode)
    if mode == :es_noproj
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = :disabled
    else
      Lyra.config.enable_monitor!
      Lyra.config.projection_mode = :sync
    end
  end

  def clean
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    Rails.cache.clear
    Lyra::Projections::CachedProjection.send(:memory_cache).clear
  end
end
