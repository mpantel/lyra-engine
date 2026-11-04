# frozen_string_literal: true

require "test_helper"

# Where Lyra takes over a write (Hijack and the event-sourcing modes), it
# switches PaperTrail off for that model only. 0.9.2 and earlier set
# PaperTrail.request.enabled = false, which turned versioning off for every
# model for the rest of the request or job thread and never restored it.
class PaperTrailScopeTest < Minitest::Test
  # Stands in for PaperTrail's request store: records what Lyra asks of it.
  class FakeRequest
    attr_reader :disabled_models, :enabled_writes

    def initialize
      @disabled_models = []
      @enabled_writes = []
    end

    def disable_model(model_class) = @disabled_models << model_class
    def enabled=(value)
      @enabled_writes << value
    end
  end

  def setup
    skip "PaperTrail is loaded; this test stands in for it" if defined?(::PaperTrail)

    @request = FakeRequest.new
    request = @request
    Object.const_set(:PaperTrail, Module.new)
    ::PaperTrail.define_singleton_method(:request) { request }
  end

  def teardown
    Object.send(:remove_const, :PaperTrail) if @request && defined?(::PaperTrail)
  end

  def test_only_the_model_is_switched_off
    record = model_instance
    record.send(:lyra_disable_paper_trail!)

    assert_equal [record.class], @request.disabled_models
    assert_empty @request.enabled_writes, "the request-wide switch is left alone"
  end

  private

  # Any object with the interceptor's instance methods will do: the method
  # under test reads only self.class.
  def model_instance
    klass = Class.new do
      def self.name = "PaperTrailScopeRecord"
    end
    owner = Lyra::Interceptors::CrudInterceptor.instance_method(:lyra_disable_paper_trail!)
    klass.define_method(:lyra_disable_paper_trail!, owner)
    klass.new
  end
end
