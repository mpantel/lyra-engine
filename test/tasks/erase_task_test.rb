# frozen_string_literal: true

require "test_helper"
require "rake"

# lyra:erase passes MAX_COPIES through to Lyra::Erasure.erase! and refuses
# anything but a positive integer.
class EraseTaskTest < Minitest::Test
  ENV_KEYS = %w[MODEL ID REASON FIELDS EVERYWHERE MAX_COPIES OPERATOR ANY_FIELDS LYRA_OPERATOR ACCESS_LOG ACCESS_LOG_SUBJECTS DRY_RUN].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/lyra_mode.rake", __dir__)
    ENV.update("MODEL" => "String", "ID" => "5", "REASON" => "Art. 17", "EVERYWHERE" => "1")
    ENV.delete("FIELDS")
    ENV.delete("MAX_COPIES")
    %w[OPERATOR ANY_FIELDS LYRA_OPERATOR ACCESS_LOG ACCESS_LOG_SUBJECTS DRY_RUN].each { ENV.delete(_1) }
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rake.application = nil
  end

  def run_erase(shared: 0, left_behind: nil, not_searched: nil, key_withheld: nil, shared_list: nil, rows_without_events: nil,
                restricted_copies: nil, lifting: nil)
    calls = []
    fake = lambda do |model, id, **kwargs|
      calls << kwargs.merge(model: model, id: id)
      Lyra::Erasure::Result.new(model: model.name, id: id, fields: ["email"], events_rewritten: 1,
                                row_erased: true, copies: [], shared_values: shared, left_behind: left_behind,
                                not_searched: not_searched, key_withheld: key_withheld,
                                access_log: kwargs[:access_log] ? "erased" : "kept", access_log_entries: 3,
                                **{ shared: shared_list, rows_without_events: rows_without_events,
                                    restricted_copies: restricted_copies, lifting: lifting }.compact)
    end
    out, = capture_io { Lyra::Erasure.stub(:erase!, fake) { @rake["lyra:erase"].invoke } }
    [calls.first, out]
  end

  # 0.16 (from 1.0.0): ACCESS_LOG decides for this erasure; unset, the
  # configuration does.
  def test_access_log_is_passed_through_and_reported
    call, out = run_erase
    assert_nil call[:access_log]
    assert_match(/Access log kept: 3 entries/, out)

    { "1" => true, "erase" => true, "0" => false, "keep" => false }.each do |value, expected|
      @rake["lyra:erase"].reenable
      ENV["ACCESS_LOG"] = value
      call, out = run_erase
      assert_equal expected, call[:access_log], value
      assert_match(/Access log #{expected ? 'erased' : 'kept'}: 3 entries/, out)
    end
  end

  # With the subject's rights (from 1.0.0): LIFTING= is passed, what was
  # lifted is printed, and copies kept under a restriction are named with
  # their columns, never a value.
  def test_lifting_and_copies_kept_under_a_restriction_are_reported
    ENV["LIFTING"] = "r-1, r-2"
    call, out = run_erase(lifting: %w[r-1 r-2], restricted_copies: [{ record: "Article 7", columns: ["body"] }])
    assert_equal %w[r-1 r-2], call[:lifting]
    assert_match(/Restrictions lifted \(Art\. 18\(3\) notice recorded\): r-1, r-2/, out)
    assert_match(/Copies kept under a restriction of processing \(Art\. 18\).*Article 7 \(body\)/m, out)
    assert_match(/until its holder's restriction is lifted/, out)
  ensure
    ENV.delete("LIFTING")
  end

  def test_access_log_subjects_are_passed_through
    call, = run_erase
    assert_equal [], call[:access_log_subjects]

    @rake["lyra:erase"].reenable
    ENV["ACCESS_LOG_SUBJECTS"] = "user-7, 42,"
    call, = run_erase
    assert_equal %w[user-7 42], call[:access_log_subjects]
  end

  def test_rejects_an_access_log_that_is_not_one_or_zero
    ENV["ACCESS_LOG"] = "maybe"
    never = ->(*, **) { flunk "erase! must not run" }
    _, err = capture_io do
      assert_raises(SystemExit) { Lyra::Erasure.stub(:erase!, never) { @rake["lyra:erase"].invoke } }
    end
    assert_match(/ACCESS_LOG must be 1/, err)
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

  # Unset, MAX_COPIES is config.erasure_max_copies (1.0.0; 10 by default).
  def test_default_max_copies
    call, = run_erase

    assert_equal 10, call[:max_copies]
    assert call[:everywhere]

    Lyra.config.erasure_max_copies = 4
    @rake["lyra:erase"].reenable
    call, = run_erase
    assert_equal 4, call[:max_copies]
  ensure
    Lyra.config.erasure_max_copies = 10 if Lyra.config.respond_to?(:erasure_max_copies=)
  end

  # A value left as shared after a real erasure cannot be found again (the
  # person's own values are gone): the hint says to choose MAX_COPIES with a
  # dry run first. After a dry run it says to erase with MAX_COPIES=n.
  def test_shared_values_are_listed_with_a_hint
    _, out = run_erase(shared: 1, shared_list: [{ field: "email", type: :email, holders: 12 }])

    assert_match(/email \(email\): held by 12 other records/, out)
    assert_match(/DRY_RUN=1/, out)
    refute_match(/rerun with MAX_COPIES/, out)

    @rake["lyra:erase"].reenable
    ENV["DRY_RUN"] = "1"
    _, out = run_erase(shared: 1, shared_list: [{ field: "email", type: :email, holders: 12 }])
    assert_match(/MAX_COPIES=12/, out)
  end

  def test_dry_run_is_passed_through_and_said
    ENV["DRY_RUN"] = "1"
    call, out = run_erase

    assert call[:dry_run]
    assert_match(/Dry run: nothing was written/, out)

    @rake["lyra:erase"].reenable
    ENV.delete("DRY_RUN")
    call, out = run_erase
    refute call[:dry_run]
    refute_match(/Dry run/, out)
  end

  # Records whose row held the value without events are named, with what
  # brings their stream in line in this mode.
  def test_rows_without_events_are_listed_with_the_remedy_for_the_mode
    _, out = run_erase(rows_without_events: ["Payment 7"])
    assert_match(/Rows without events \(erased in the row only\): Payment 7/, out)
    assert_match(/lyra:repair/, out)

    @rake["lyra:erase"].reenable
    Lyra.config.enable_hijack!
    _, out = run_erase(rows_without_events: ["Payment 7"])
    assert_match(/lyra:projections:rebuild/, out)
    refute_match(/lyra:repair/, out)
  ensure
    Lyra.config.enable_monitor!
  end

  def test_max_copies_from_env
    ENV["MAX_COPIES"] = "3"
    call, out = run_erase(shared: 2)

    assert_equal 3, call[:max_copies]
    assert_match(/Values left as shared \(held by more than 3 other records\): 2/, out)
  end

# Records whose row still holds an erased value are named with their
# columns, never the value.
  def test_records_left_behind_are_listed
    _, out = run_erase(left_behind: [{ record: "Payment 7", columns: %w[payload notes] }])
    assert_match(/Left behind \(the value is still in these columns, as a JSON key, inside a longer string or in a key\): Payment 7 \(payload, notes\)/, out)

    @rake["lyra:erase"].reenable
    _, out = run_erase
    refute_match(/Left behind/, out)
  end

  # The columns a search of the log cannot read are named; a key that holds
  # an erased value is never printed.
  def test_columns_not_searched_and_a_withheld_key
    ENV["ID"] = "ann@example.com"
    _, out = run_erase(not_searched: ["Payment.username"], key_withheld: true)
    assert_match(/Not searched \(encrypted, the log holds their ciphertext\): Payment\.username/, out)
    assert_match(/of String <key withheld>/, out)
    refute_match(/ann@example/, out)
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
