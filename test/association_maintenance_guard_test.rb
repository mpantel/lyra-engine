# frozen_string_literal: true

require "test_helper"

# Lyra::Associations::Maintenance reproduces Active Record's
# HasManyThroughAssociation#delete_records to mark the one relation it
# writes. The copy is installed only for the Rails versions it was checked
# against; on any other, Rails' own method runs, with the through model
# marked for the whole of it, and a warning says once that the check is
# coarser there.
class AssociationMaintenanceGuardTest < Minitest::Test
  Maintenance = Lyra::Associations::Maintenance

  def test_the_copy_is_chosen_for_the_checked_versions_only
    %w[8.0.0 8.0.5.1 8.1.0 8.1.4.1 8.1.99].each do |version|
      assert_equal Maintenance::HasManyThroughAssociationPatch, Maintenance.through_patch(version), version
    end
    %w[7.2.2 8.2.0 8.2.0.beta1 9.0.0].each do |version|
      assert_equal Maintenance::HasManyThroughAssociationFallback, Maintenance.through_patch(version), version
    end
  end

  def test_this_rails_runs_the_copy
    assert_equal Maintenance::HasManyThroughAssociationPatch, Maintenance.through_patch
    assert_includes ActiveRecord::Associations::HasManyThroughAssociation.ancestors, Maintenance::HasManyThroughAssociationPatch
    refute_includes ActiveRecord::Associations::HasManyThroughAssociation.ancestors, Maintenance::HasManyThroughAssociationFallback
  end

  def test_the_copy_matches_this_rails_method_but_for_the_marks
    file, = ActiveRecord::Associations::HasManyThroughAssociation.instance_method(:delete_records).super_method.source_location
    rails = method_body(File.read(file))
    copy = method_body(File.read(Maintenance::HasManyThroughAssociationPatch.instance_method(:delete_records).source_location.first))
    unmarked = copy.map { _1.sub(/Maintenance\.marking\(:\w+, scope\) \{ (.*) \}\z/, '\1') }

    assert_equal rails, unmarked
  end

  def test_the_coarse_warning_is_said_once
    Maintenance.instance_variable_set(:@warned_coarse_through, nil)
    Rails.logger.expects(:warn).with(regexp_matches(/Active Record 9\.0\.0/)).once

    2.times { Maintenance.warn_coarse_through!("9.0.0") }
  ensure
    Maintenance.instance_variable_set(:@warned_coarse_through, nil)
  end

  # The fallback's mark is on the through model: the first write of its
  # records takes it, once; a write of another model does not.
  def test_a_class_mark_is_taken_by_a_write_of_that_model_once
    Maintenance.marking(:unlink, User) do
      refute Maintenance.claim(:unlink, TestModel.all), "another model"
      refute Maintenance.claim(:nullify, User.all), "another kind"
      assert Maintenance.claim(:unlink, User.where(id: 1))
      refute Maintenance.claim(:unlink, User.where(id: 1)), "taken"
    end
    assert_nil Thread.current[Maintenance::KEY]
  end

  def test_an_object_mark_is_taken_by_that_object_only
    relation = User.where(id: 1)
    Maintenance.marking(:nullify, relation) do
      refute Maintenance.claim(:nullify, User.where(id: 1)), "an equal relation, not the one marked"
      assert Maintenance.claim(:nullify, relation)
    end
  end

  private

  # The lines of delete_records, stripped, from its def to its end.
  def method_body(source)
    lines = source.lines.map(&:strip)
    start = lines.index("def delete_records(records, method)")
    finish = (start..).find { lines[_1] == "end" && lines[_1 - 1] == "count" }
    lines[start..finish].reject(&:empty?)
  end
end
