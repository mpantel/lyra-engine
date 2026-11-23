# frozen_string_literal: true

require "test_helper"
require_relative "es_noproj_relation_parity_test"

# A relation built before a write and read after it sees the write in
# ES-NoProj as in Monitor (1.0.1): Active Record runs its query at the first
# read, and ES-NoProj evaluated the relation when it was built. A loaded
# relation keeps its records until reset or reload, in both.
class EsNoprojRelationFreshnessTest < EsNoprojRelationParityTest
  EsNoprojRelationParityTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  def test_a_relation_built_before_a_write_reads_it_as_in_monitor
    results = %i[monitor es_noproj].to_h do |mode|
      clean
      use(mode)
      PrItem.create!(code: "p1", status: "active")
      built = PrItem.where(status: "active")
      scoped = PrItem.active.order(:code)
      loaded = PrItem.where(status: "active").load
      PrItem.create!(code: "p2", status: "active")
      PrItem.find_by(code: "p1").update!(status: "draft")
      seen = { built: built.map(&:code).sort, count: PrItem.where(status: "active").tap { PrItem.create!(code: "p3", status: "active") }.count,
               scoped: scoped.map(&:code), loaded: loaded.map(&:code), reset: loaded.reset.map(&:code).sort }
      PrItem.transaction do
        inside = PrItem.where(status: "active")
        PrItem.create!(code: "p4", status: "active")
        seen[:own_write] = inside.map(&:code).sort
      end
      [mode, seen]
    end
    assert_equal({ built: %w[p2], count: 2, scoped: %w[p2 p3], loaded: %w[p1], reset: %w[p2 p3], own_write: %w[p2 p3 p4] }, results[:monitor])
    assert_equal results[:monitor], results[:es_noproj]
  end
end
