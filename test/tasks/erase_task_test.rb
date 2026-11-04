# frozen_string_literal: true

require "test_helper"
require "rake"

# lyra:erase passes MAX_COPIES through to Lyra::Erasure.erase! and refuses
# anything but a positive integer.
class EraseTaskTest < Minitest::Test
  ENV_KEYS = %w[MODEL ID REASON FIELDS EVERYWHERE MAX_COPIES OPERATOR ANY_FIELDS LYRA_OPERATOR].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/lyra_mode.rake", __dir__)
    ENV.update("MODEL" => "String", "ID" => "5", "REASON" => "Art. 17", "EVERYWHERE" => "1")
    ENV.delete("FIELDS")
    ENV.delete("MAX_COPIES")
    %w[OPERATOR ANY_FIELDS LYRA_OPERATOR].each { ENV.delete(_1) }
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rake.application = nil
  end

  def run_erase(shared: 0)
    calls = []
    fake = lambda do |model, id, **kwargs|
      calls << kwargs.merge(model: model, id: id)
      Lyra::Erasure::Result.new(model: model.name, id: id, fields: ["email"], events_rewritten: 1,
                                row_erased: true, copies: [], shared_values: shared)
    end
    out, = capture_io { Lyra::Erasure.stub(:erase!, fake) { @rake["lyra:erase"].invoke } }
    [calls.first, out]
  end

  # From 0.9.3 the task names who erased (before: nobody) and keeps FIELDS
  # to declared personal fields unless ANY_FIELDS is set.
  def test_the_operator_is_recorded
    ENV["OPERATOR"] = "jdoe"
    call, = run_erase

    assert_equal "jdoe", call[:erased_by]
    refute call[:any_fields]
  end

  def test_without_an_operator_the_process_is_recorded
    call, = run_erase

    assert_match(/\Aprocess:/, call[:erased_by])
  end

  def test_any_fields_is_passed_through
    ENV["ANY_FIELDS"] = "1"
    call, = run_erase

    assert call[:any_fields]
  end

  def test_default_max_copies
    call, = run_erase

    assert_equal Lyra::Erasure::MAX_COPIES, call[:max_copies]
    assert call[:everywhere]
  end

  def test_max_copies_from_env
    ENV["MAX_COPIES"] = "3"
    call, out = run_erase(shared: 2)

    assert_equal 3, call[:max_copies]
    assert_match(/Values left as shared \(held by more than 3 other records\): 2/, out)
  end

  def test_rejects_a_max_copies_that_is_not_a_positive_integer
    %w[0 -1 abc 2.5].each do |bad|
      @rake["lyra:erase"].reenable
      ENV["MAX_COPIES"] = bad
      error = assert_raises(SystemExit) { capture_io { run_erase } }
      refute error.success?, "MAX_COPIES=#{bad} must abort"
    end
  end
end
