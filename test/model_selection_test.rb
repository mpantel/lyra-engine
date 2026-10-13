# frozen_string_literal: true

require "test_helper"

# config.models: names, namespace patterns, :all and except (Lyra::ModelSelection).
class ModelSelectionTest < Minitest::Test
  module Sel; end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)

    %i[User Article Draft Abstract Tableless Cache].each { |c| Sel.send(:remove_const, c) if Sel.const_defined?(c, false) }
    Sel.const_set(:User, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Sel.const_set(:Article, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    Sel.const_set(:Draft, Class.new(Sel::Article))                 # STI-style subclass of Article
    Sel.const_set(:Abstract, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    Sel.const_set(:Tableless, Class.new(ActiveRecord::Base) { self.table_name = "no_such_table" })
    Sel.const_set(:Cache, Class.new(ActiveRecord::Base) { self.table_name = "solid_cache_entries" })
    @candidates = [Sel::User, Sel::Article]
    Lyra.config.enable_monitor!
  end

  def teardown
    Lyra::ModelSelection.singleton_class.send(:remove_method, :eligible_models) if @stubbed
  end

  def test_the_forms_parse
    assert_equal({ "A" => {}, "B::*" => {} }, parse(%w[A B::*]).entries)
    assert parse(:all).all
    spec = parse([:all, { except: %w[X Y::*] }])
    assert spec.all
    assert_equal %w[X Y::*], spec.except
    assert_equal({ "A" => { event_prefix: "Z" } }, parse({ "A" => { event_prefix: "Z" } }).entries)
  end

  def test_the_comma_form_of_all_with_except_reaches_the_setter_as_an_array
    Lyra.config.models = :all, { except: %w[ModelSelectionTest::Sel::Article] }
    stub_candidates
    assert_equal [Sel::User], Lyra.config.apply_declared_models!
  end

  def test_only_concrete_base_classes_with_a_table_and_a_key_are_eligible
    assert Lyra::ModelSelection.eligible?(Sel::User)
    assert Lyra::ModelSelection.eligible?(Sel::Article)
    refute Lyra::ModelSelection.eligible?(Sel::Draft), "a subclass follows its base class"
    refute Lyra::ModelSelection.eligible?(Sel::Abstract)
    refute Lyra::ModelSelection.eligible?(Sel::Tableless)
    refute Lyra::ModelSelection.eligible?(Sel::Cache), "a framework's own records"
  end

  def test_the_event_store_and_framework_records_are_never_eligible
    events = Class.new(ActiveRecord::Base) { self.table_name = "event_store_events" }
    assert Lyra::ModelSelection.excluded?(events), "the event store's table"
    assert Lyra::ModelSelection.excluded?(Sel::Cache)
    refute Lyra::ModelSelection.excluded?(Sel::User)
  end

  def test_all_enrols_every_eligible_model_except_those_excepted
    Lyra.config.models = [:all, { except: %w[ModelSelectionTest::Sel::Article] }]
    stub_candidates

    enrolled = Lyra.config.apply_declared_models!

    assert_equal [Sel::User], enrolled
    assert Sel::User.lyra_monitored
    refute Sel::Article.lyra_monitored
  end

  def test_a_namespace_pattern_enrols_the_matching_models
    Lyra.config.models = %w[ModelSelectionTest::Sel::*]
    stub_candidates

    assert_equal [Sel::User, Sel::Article], Lyra.config.apply_declared_models!.sort_by(&:name).reverse
  end

  def test_a_pattern_matching_nothing_warns
    Lyra.config.models = %w[Nothing::*]
    stub_candidates
    logged = capture_rails_log { assert_empty Lyra.config.apply_declared_models! }

    assert_match(/"Nothing::\*" matches no model/, logged)
  end

  def test_naming_an_excluded_model_fails
    Lyra.config.models = %w[ModelSelectionTest::Sel::Cache]
    error = assert_raises(ArgumentError) { Lyra.config.apply_declared_models! }
    assert_match(/never enrols/, error.message)
  end

  def test_all_outside_monitor_mode_warns
    Lyra.config.enable_hijack!
    Lyra.config.models = :all
    stub_candidates
    logged = capture_rails_log { Lyra.config.apply_declared_models! }

    assert_match(/:all enrols 2 models in hijack mode/, logged)
  end

  private

  def parse(models) = Lyra::ModelSelection.parse(models)

  # :all and patterns choose among these two, not every model of the test
  # application, so no other test's models are enrolled.
  def stub_candidates
    candidates = @candidates
    Lyra::ModelSelection.singleton_class.send(:define_method, :eligible_models) { candidates }
    @stubbed = true
  end

  def capture_rails_log
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    Lyra::ModelSelection.instance_variable_set(:@warned, {})
    yield
    io.string
  ensure
    Rails.logger = previous
  end
end
