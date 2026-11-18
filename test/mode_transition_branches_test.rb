# frozen_string_literal: true

require "test_helper"

# Lyra::ModeTransition: the boot warning for a default scope ES-NoProj cannot
# evaluate (configured into ES-NoProj rather than switched), and the one-line
# summary of a transition report the rake task prints.
class ModeTransitionBranchesTest < Minitest::Test
  def setup
    skip "Requires ActiveRecord with a database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    Object.send(:remove_const, :MtbScoped) if Object.const_defined?(:MtbScoped)
    Object.send(:remove_const, :MtbPlain) if Object.const_defined?(:MtbPlain)
    Object.const_set(:MtbScoped, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      default_scope { where("LOWER(status) = 'published'") }
    end)
    Object.const_set(:MtbPlain, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      default_scope { where(status: "published").order(:title) }
    end)
  end

  def teardown
    Lyra.config.enable_monitor!
    Lyra.config.projection_mode = :sync
  end

  def test_booting_in_es_noproj_warns_of_a_default_scope_it_cannot_evaluate
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
    messages = []
    Kernel.stubs(:warn).with { |message| messages << message }
    Rails.stubs(:logger).returns(nil)

    warned = Lyra::ModeTransition.check_es_noproj!(models: [MtbScoped, MtbPlain])

    assert_equal 1, warned.size, "a default scope of hash conditions and orders is evaluated"
    assert_equal warned, messages
    assert_match(/every read of MtbScoped will be refused/, warned.first)
    assert_match(/Write the default scope as hash conditions/, warned.first)
  end

  def test_booting_in_another_mode_does_not_warn_of_default_scopes
    assert_empty Lyra::ModeTransition.check_es_noproj!(models: [MtbScoped])
  end

  def test_a_report_summary_counts_what_the_check_did
    discrepancy = Lyra::ModeTransition::Discrepancy.new(model: "Order", id: 4, problem: "row of a destroyed record")
    report = Lyra::ModeTransition::Report.new(from: "monitor", to: "event_sourcing/disabled", checked: 12, rechecked: 2,
                                              imported: 3, discrepancies: [discrepancy])

    assert_equal "monitor -> event_sourcing/disabled: 12 records checked, 2 re-checked, 3 imported, 1 discrepancies",
                 report.summary
    refute report.clean?
    assert_equal "Order 4: row of a destroyed record", discrepancy.to_s
  end
end
