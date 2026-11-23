# frozen_string_literal: true

require "test_helper"
require_relative "es_modes_unique_writes_test"

# Partial unique indexes in the event-sourcing modes (1.0.1): a condition
# PostgreSQL writes back in the common forms (IS [NOT] NULL, a column = a
# literal, casts, AND) is compiled and enforced before the append, as Monitor's
# table enforces it: a record outside the index claims nothing, and a holder
# outside it holds nothing. Before, these indexes were skipped (ES-NoProj saved
# the duplicate; ES-Async and ES-Lazy appended it and its projection met the
# index). The indexes are the research apps' forms: a soft delete's
# (deleted_at IS NULL) and the testbed's typed legacy key.
class EsModesPartialUniqueTest < EsModesUniqueWritesTest
  EsModesUniqueWritesTest.instance_methods(false).grep(/^test_/).each { undef_method(_1) }

  PART = "lyra_um_parts"
  MODES = %i[monitor es_sync es_async es_lazy es_noproj].freeze
  def parse(sql) = Lyra::Projections::UniqueIndexes::Condition.parse(sql, UmPart)

  def setup
    super
    connection.create_table(PART, force: true) do |t|
      t.string :code
      t.datetime :deleted_at
      t.string :kind
      t.string :legacy_id
      t.boolean :active, default: true
    end
    connection.add_index(PART, :code, unique: true, where: "deleted_at IS NULL", name: "idx_um_parts_live_code")
    connection.add_index(PART, %i[kind legacy_id], unique: true, where: "kind = 'epos' AND legacy_id IS NOT NULL", name: "idx_um_parts_epos")
    define_model(:UmPart, PART)
  end

  def teardown
    connection.drop_table(PART, if_exists: true) if defined?(UmPart)
    Object.send(:remove_const, :UmPart) if Object.const_defined?(:UmPart)
    super
  end

  def test_the_research_apps_conditions_compile
    { "(deleted_at IS NULL)" => [[{ "deleted_at" => nil }, true], [{ "deleted_at" => Time.now }, false]],
      "(((kind)::text = 'epos'::text) AND (legacy_id IS NOT NULL))" =>
        [[{ "kind" => "epos", "legacy_id" => "L" }, true], [{ "kind" => "epos", "legacy_id" => nil }, false],
         [{ "kind" => "other", "legacy_id" => "L" }, false], [{ "kind" => nil, "legacy_id" => "L" }, false]],
      "(NOT active)" => [[{ "active" => false }, true], [{ "active" => true }, false]] }.each do |sql, cases|
      condition = parse(sql)
      refute_nil condition, sql
      cases.each { |values, expected| assert_equal expected, condition.call { values[_1] }, "#{sql} #{values}" }
    end
    ["kind = 'a' OR kind = 'b'", "lower(kind) = 'a'", "kind IN ('a', 'b')", "kind = legacy_id", "nope IS NULL"].each do |sql|
      assert_nil parse(sql), sql
    end
  end

  def test_every_mode_enforces_them_as_monitor
    steps = {
      "a duplicate live code" => -> { 2.times { UmPart.create!(code: "a") } },
      "a code a soft-deleted record held" => -> { UmPart.create!(code: "b").update!(deleted_at: STAMP); UmPart.create!(code: "b") },
      "restoring over a live holder" => -> { UmPart.create!(code: "c", deleted_at: STAMP).then { |r| UmPart.create!(code: "c"); r.update!(deleted_at: nil) } },
      "two epos records with one legacy id" => -> { 2.times { UmPart.create!(code: _1.to_s * 3, kind: "epos", legacy_id: "L1") } },
      "another kind with that legacy id" => -> { UmPart.create!(code: "e1", kind: "epos", legacy_id: "L2"); UmPart.create!(code: "e2", kind: "other", legacy_id: "L2") },
      "two epos records without a legacy id" => -> { 2.times { UmPart.create!(code: "n#{_1}", kind: "epos") } },
      "update_columns onto a live code" => -> { UmPart.create!(code: "u1"); UmPart.create!(code: "u2").update_columns(code: "u1") }
    }
    results = MODES.to_h do |mode|
      use(mode)
      [mode, steps.transform_values do |step|
        clean_parts
        begin
          step.call
          settle
          :saved
        rescue ActiveRecord::RecordNotUnique
          :not_unique
        end
      end]
    end
    expected = results.fetch(:monitor)
    assert_equal({ "a duplicate live code" => :not_unique, "a code a soft-deleted record held" => :saved,
                   "restoring over a live holder" => :not_unique, "two epos records with one legacy id" => :not_unique,
                   "another kind with that legacy id" => :saved, "two epos records without a legacy id" => :saved,
                   "update_columns onto a live code" => :not_unique }, expected)
    (MODES - [:monitor]).each { |mode| assert_equal expected, results[mode], mode }
  end

  private

  def use(mode)
    return super unless mode == :es_noproj

    clean
    @mode = mode
    Lyra.config.enable_event_sourcing!
    Lyra.config.projection_mode = :disabled
  end

  def clean_parts
    connection.execute("DELETE FROM #{PART}") if connection.table_exists?(PART)
    Lyra::Projections::CachedProjection.invalidate_all(UmPart) if defined?(UmPart)
  end
end
