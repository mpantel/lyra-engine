require "test_helper"
require "stringio"

module PamDsl
  # A retention period may be given as a plain number of seconds (keep_for 86400,
  # or an Integer read from configuration) as well as an ActiveSupport::Duration
  # (1.day, 7.years). Plain seconds carry no calendar, so they are worded with the
  # fixed-length units of the polyfill (lib/pam_dsl/core_ext.rb): 1 month = 30
  # days, 1 year = 365 days. The wording must be the same with and without
  # ActiveSupport; this suite runs in both modes (rake test:both).
  class DurationFormatTest < Minitest::Test
    DAY = 86_400

    SECONDS_WORDING = {
      1 => "1 second",
      59 => "59 seconds",
      60 => "1 minute",
      90 => "1 minute",
      3_600 => "1 hour",
      2 * 3_600 => "2 hours",
      DAY => "1 day",
      7 * DAY => "7 days",
      30 * DAY => "1 month",
      90 * DAY => "3 months",
      365 * DAY => "1 year",
      7 * 365 * DAY => "7 years",
      10 * 365 * DAY => "10 years"
    }.freeze

    def setup
      PamDsl.reset!
    end

    def teardown
      PamDsl.reset!
    end

    def test_reporter_words_plain_seconds_the_same_in_both_modes
      reporter = Reporter.allocate
      SECONDS_WORDING.each do |seconds, wording|
        assert_equal wording, reporter.send(:format_duration, seconds), "#{seconds} s"
      end
    end

    def test_comparator_words_plain_seconds_the_same_in_both_modes
      comparator = PolicyComparator.allocate
      SECONDS_WORDING.each do |seconds, wording|
        assert_equal wording, comparator.send(:format_duration, seconds), "#{seconds} s"
      end
    end

    def test_a_float_number_of_seconds_is_floored_like_an_integer
      assert_equal "1 day", Reporter.allocate.send(:format_duration, 86_400.5)
    end

    def test_non_durations_still_print_as_text
      assert_equal "N/A", Reporter.allocate.send(:format_duration, nil)
      assert_equal "Not specified", Reporter.allocate.send(:format_duration, "Not specified")
      assert_equal "N/A", PolicyComparator.allocate.send(:format_duration, nil)
    end

    # ActiveSupport::Duration values keep their calendar-aware wording.
    def test_durations_print_as_before_under_active_support
      skip "ActiveSupport not loaded (polyfill pass)" unless defined?(ActiveSupport::Duration)

      reporter = Reporter.allocate
      {
        1.hour => "3600 seconds", 1.day => "1 day", 7.days => "7 days", 30.days => "30 days",
        1.month => "1 month", 2.months => "2 months", 365.days => "11 months",
        1.year => "1 year", 7.years => "7 years", 10.years => "10 years"
      }.each { |duration, wording| assert_equal wording, reporter.send(:format_duration, duration), duration.inspect }

      comparator = PolicyComparator.allocate
      {
        1.hour => "3600 seconds", 1.day => "1 day", 30.days => "30 days", 2.months => "60 days",
        365.days => "365 days", 1.year => "1 year", 7.years => "7 years"
      }.each { |duration, wording| assert_equal wording, comparator.send(:format_duration, duration), duration.inspect }
    end

    def test_article_30_register_shows_a_retention_given_in_seconds
      PamDsl.define_policy :seconds_policy do
        field :email, type: :email
        field :ip_address, type: :ip_address
        retention do
          default 7 * 365 * 86_400
          for_model "Session" do
            keep_for 86_400
            field :ip_address, duration: 3_600
          end
        end
      end

      output = StringIO.new
      Reporter.new(:seconds_policy, output: output).article_30_report

      assert_includes output.string, "Default:          7 years"
      assert_includes output.string, "Session: 1 day, then soft_delete (ip_address 1 hour)"
      refute_includes output.string, "0 years"
    end

    def test_policy_summary_shows_a_retention_given_in_seconds
      PamDsl.define_policy :seconds_summary do
        field :email, type: :email
        retention do
          for_model("Session") { keep_for 30 * 86_400 }
        end
      end

      output = StringIO.new
      Reporter.new(:seconds_summary, output: output).policy_summary

      assert_includes output.string, "Session: 1 month"
    end

    def test_comparator_report_shows_a_default_given_in_seconds
      PamDsl.define_policy(:secs_a) { retention { default 365 * 86_400 } }
      PamDsl.define_policy(:secs_b) { retention { default 86_400 } }

      report = PolicyComparator.new(:secs_a, :secs_b).generate_report

      assert_includes report, "| secs_a | 1 year |"
      assert_includes report, "| secs_b | 1 day |"
    end

    # Enforcement reads plain seconds as seconds in both modes.
    def test_retention_given_in_seconds_expires_after_that_many_seconds
      rule = RetentionRule.new("Session").keep_for(86_400)

      assert rule.expired?(Time.current - (2 * 86_400))
      refute rule.expired?(Time.current - 3_600)
    end

    def test_retention_check_applies_a_period_given_in_seconds
      PamDsl.define_policy :seconds_check do
        retention do
          for_model("Session") { keep_for 86_400 }
        end
      end
      reporter = Reporter.new(:seconds_check)
      events = [
        Struct.new(:event_type, :data, :metadata, :timestamp).new(
          "SessionCreated", {}, { model_class: "Session" }, Time.current - (2 * 86_400)
        ),
        Struct.new(:event_type, :data, :metadata, :timestamp).new(
          "SessionCreated", {}, { model_class: "Session" }, Time.current - 3_600
        )
      ]

      status = reporter.send(:check_retention, events)

      assert_equal 1, status["Session"][:expired]
      assert_equal 86_400, status["Session"][:retention_period]
    end
  end
end
