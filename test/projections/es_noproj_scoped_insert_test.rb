# frozen_string_literal: true

require "test_helper"
require_relative "es_noproj_relation_parity_test"

# Inserts inside where(...).scoping { } and on a relation take the scope's
# attributes in ES-NoProj as in Monitor (1.0.1): Active Record's InsertAll
# writes them over each row's own values. ES-NoProj wrote the rows without
# them, so the event store, which ES-NoProj reads, held records the scope
# never gave its values to.
class EsNoprojScopedInsertTest < EsNoprojRelationParityTest
  EsNoprojRelationParityTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  WRITES = {
    "class-level insert_all in scoping" => -> { PrItem.where(tag: "s", status: "draft").scoping { PrItem.insert_all([{ code: "c1", name: "n" }]) } },
    "class-level insert_all! in scoping" => -> { PrItem.where(tag: "s", status: "draft").scoping { PrItem.insert_all!([{ code: "c2", name: "n" }]) } },
    "class-level insert in scoping" => -> { PrItem.where(tag: "s", status: "draft").scoping { PrItem.insert({ code: "c3", name: "n" }) } },
    "a given value under the scope" => -> { PrItem.where(tag: "s").scoping { PrItem.insert_all([{ code: "c4", name: "n", tag: "own" }]) } },
    "insert_all on a relation" => -> { PrItem.where(tag: "s", status: "draft").insert_all([{ code: "c5", name: "n" }]) }
  }.freeze

  def test_scoped_inserts_write_the_scope_attributes_as_in_monitor
    results = %i[monitor es_noproj].to_h do |mode|
      clean
      use(mode)
      WRITES.each_value(&:call)
      [mode, PrItem.unscoped.order(:code).pluck(:code, :tag, :status)]
    end
    assert_equal results[:monitor], results[:es_noproj]
    assert_includes results[:es_noproj], ["c1", "s", "draft"]
    assert_includes results[:es_noproj], ["c4", "s", nil], "the scope over the row's own value, as Active Record writes it"
  end
end
