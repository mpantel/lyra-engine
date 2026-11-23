# frozen_string_literal: true

require "test_helper"

# A write's callbacks run in its write scope, and the writes they make name
# the write as their cause (WriteCorrelationTest). From 1.0.0 a save that
# changes nothing records no event, yet its id was the cause in scope from
# the start: the writes its callbacks made (Solidus's Order#save updating
# line items through autosave) named an event that never existed.
#
# Every causation_id must name an event in the store. A write is the cause
# of the writes in its after_* callbacks once it has built its event, and
# when it records none they take the cause in scope when it began. The
# writes in its before_* callbacks come before anyone knows: they name the
# write, and a write that then records nothing appends a SaveWithoutEffect
# marker with its id in Lyra's own stream (Lyra::SavesWithoutEffect).
class DanglingCausationTest < Minitest::Test
  ROOTS = "lyra_dc_roots"
  PARENTS = "lyra_dc_parents"
  CHILDREN = "lyra_dc_children"
  MODES = %i[monitor hijack es_sync es_async es_noproj es_lazy].freeze
  MARKERS = Lyra::SavesWithoutEffect::STREAM

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    connection.create_table(ROOTS, force: true, &:timestamps)
    connection.create_table(PARENTS, force: true) { |t| t.string :label; t.timestamps }
    connection.create_table(CHILDREN, force: true) do |t|
      t.bigint :dc_parent_id
      t.string :label
      t.timestamps
    end
    define_models
    clean
  end

  def teardown
    return unless defined?(DcParent)

    Lyra.reset_config!
    Lyra::Genesis.reset!
    clean
    [ROOTS, PARENTS, CHILDREN].each { |table| connection.drop_table(table, if_exists: true) }
  end

  MODES.each do |mode|
    # The Solidus case: a save with nothing to change updates another record
    # in its after_update callbacks. That update's cause is the one in scope
    # when the save began, here none; and no marker is needed.
    define_method("test_a_save_that_changes_nothing_is_no_one_s_cause_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child

      parent.child_label = "c1"
      parent.save!

      refute stream(DcParent, parent.id).any? { own_update?(_1) }, "the save records nothing"
      updated = stream(DcChild, child.id).last
      assert_equal "c1", (updated.data[:changes] || updated.data["changes"])["label"].last
      assert_nil updated.metadata[:causation_id], "no cause was in scope"
      assert_empty markers, "the save's id was handed to no one"
      assert_no_dangling_causation
    end

    # Inside another write the cause in scope is that write's event, and the
    # update made by the save that changes nothing names it. belongs_to ...
    # touch: true touches the parent when the transaction commits, outside
    # every write scope.
    define_method("test_a_save_that_changes_nothing_passes_on_the_cause_in_scope_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label = "c1"

      root = DcRoot.create!(parent_to_save: parent)

      root_event = stream(DcRoot, root.id).first
      assert_equal root_event.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      touch = stream(DcParent, parent.id).last
      assert touch?(touch), "the cascade touched the parent: #{stream(DcParent, parent.id).map(&:event_type)}"
      assert_nil touch.metadata[:causation_id], "the cascade runs at the commit, after every write scope"
      assert_empty markers
      assert_no_dangling_causation
    end

    # touch inside a save that changes nothing (a bypass event, BypassEvents).
    define_method("test_a_touch_inside_a_save_that_changes_nothing_has_an_existing_cause_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.touch_child = true

      root = DcRoot.create!(parent_to_save: parent)

      touched = stream(DcChild, child.id).last
      assert touch?(touched), stream(DcChild, child.id).map(&:event_type).inspect
      assert_equal stream(DcRoot, root.id).first.event_id, touched.metadata[:causation_id]
      assert_empty markers
      assert_no_dangling_causation
    end

    # A save that records an update is the cause of the writes its after_*
    # callbacks make, as before.
    define_method("test_a_save_that_records_an_update_is_the_cause_of_its_callbacks_writes_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label = "c1"

      parent.update!(label: "renamed")

      own = stream(DcParent, parent.id).find { own_update?(_1) }
      assert own, "the save records its update"
      assert_equal own.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_empty markers
      assert_no_dangling_causation
    end

    # A write in a before_save callback comes before the save's event and
    # names the save; the save records its update, which has that id.
    define_method("test_a_write_before_a_save_that_records_names_its_event_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_before = "b"

      DcRoot.create!(parent_to_save: parent.tap { _1.label = "renamed" })

      own = stream(DcParent, parent.id).find { own_update?(_1) }
      assert own, "the save records its update"
      assert_equal own.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_empty markers, "the save's own event is the cause"
      assert_no_dangling_causation
    end

    # ... and when the save then changes nothing, it appends a marker with
    # the id the write named, in Lyra's own stream; the record's stream stays
    # as 1.0.0 records it.
    define_method("test_a_write_before_a_save_that_changes_nothing_names_its_marker_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_before = "b"
      before = stream(DcParent, parent.id).map(&:event_id)

      root = DcRoot.create!(parent_to_save: parent)

      cause = stream(DcChild, child.id).last.metadata[:causation_id]
      marker = markers.sole
      assert_equal cause, marker.event_id
      assert_equal "Lyra::Events::SaveWithoutEffect", marker.event_type
      assert_equal({ model: "DcParent", record_id: parent.id, operation: "update", reason: "no change", replay: false },
                   marker.data.transform_keys(&:to_sym))
      root_event = stream(DcRoot, root.id).first
      assert_equal root_event.event_id, marker.metadata[:causation_id], "the marker's cause is the one in scope"
      assert_equal root_event.metadata[:correlation_id], marker.metadata[:correlation_id]
      assert_equal "lyra_save_without_effect", marker.metadata[:source]
      own = stream(DcParent, parent.id).map(&:event_id) - before
      assert(own.all? { |id| touch?(Lyra.config.event_store.read.event(id)) }, "only the commit's touch was added")
      assert_no_dangling_causation
    end

    # A destroy that deletes nothing (a record never saved) records nothing;
    # a write its before_destroy made names it, and a marker exists.
    define_method("test_a_destroy_that_deletes_nothing_leaves_a_marker_for_its_before_destroy_write_in_#{mode}") do
      use(mode)
      _, child = parent_with_child

      DcParent.new(label: "never saved", child_label: "c-destroy", child_id: child.id).destroy

      updated = stream(DcChild, child.id).last
      assert_equal "c-destroy", (updated.data[:changes] || {})["label"]&.last
      marker = markers.sole
      assert_equal updated.metadata[:causation_id], marker.event_id
      assert_equal %w[destroy no\ row], [marker.data[:operation], marker.data[:reason]]
      assert_nil marker.metadata[:causation_id]
      assert_no_dangling_causation
    end

    # The marker is no change. The readers of the whole log pass it over:
    # ES-Lazy's catch-up (from the start of the log here), the dashboard's
    # window and the subject reports; and the record reads as before
    # (DualView, ES-NoProj's reads rebuilt from the record's stream).
    define_method("test_the_marker_is_ignored_by_the_readers_of_the_log_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_before = "b"
      parent.save!
      assert_equal 1, markers.size

      if mode == :es_lazy
        Lyra::Projections::LazyProjection.reset!
        assert_operator Lyra::Projections::LazyProjection.catch_up!, :>, 0, "the catch-up read the log from its first event, the marker among them"
      end
      assert_equal "p", DcParent.find(parent.id).label
      assert_equal "b", DcChild.find(child.id).label
      assert_equal({}, Lyra::DualView.new(DcParent, parent.id).calculate_differences)
      assert_equal({}, Lyra::DualView.new(DcChild, child.id).calculate_differences)
      events, window = Lyra::EventWindow.recent(100)
      refute(events.any? { Lyra::SavesWithoutEffect.marker?(_1) })
      assert_equal 1, window[:skipped]
      seen = []
      Lyra::Privacy::GDPRCompliance.allocate.send(:each_event) { seen << _1 } if defined?(Lyra::Privacy::GDPRCompliance)
      refute(seen.any? { Lyra::SavesWithoutEffect.marker?(_1) })
      assert_no_dangling_causation
    end
    # A model's own after_save and after_destroy run in the write scope too
    # (CrudInterceptor::WriteScopeHooks): their writes name the write.
    define_method("test_an_after_save_write_names_the_save_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_after_save = "as"

      parent.update!(label: "renamed")

      own = stream(DcParent, parent.id).find { own_update?(_1) }
      written = stream(DcChild, child.id).last
      assert_equal "as", DcChild.find(child.id).label
      assert_equal own.event_id, written.metadata[:causation_id]
      assert_equal own.metadata[:correlation_id], written.metadata[:correlation_id], "one correlation"
      assert_empty markers
      assert_no_dangling_causation
    end

    define_method("test_an_after_destroy_write_names_the_destroy_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_after_destroy = "ad"

      parent.destroy!

      destroyed = stream(DcParent, parent.id).reverse.find { operation(_1) == "destroyed" }
      assert destroyed, stream(DcParent, parent.id).map(&:event_type).inspect
      assert_equal destroyed.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_empty markers
      assert_no_dangling_causation
    end

    # An after_save write of a save that changes nothing is decided lazily:
    # it takes the cause in scope, and no marker is needed.
    define_method("test_an_after_save_write_of_a_save_that_changes_nothing_takes_the_outer_cause_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      parent.child_label_after_save = "as"

      root = DcRoot.create!(parent_to_save: parent)

      assert_equal stream(DcRoot, root.id).first.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_empty markers
      assert_no_dangling_causation
    end

    # A soft delete runs the destroy callbacks itself, without destroy
    # (paranoia's paranoia_destroy): it gets a write scope too, and a normal
    # destroy gets one scope, not two (the outermost write's correlation is
    # its own event id). From 1.0.1 a soft delete records no Destroyed, only
    # the update it makes (the row stays, and so does the record's stream), so
    # its scope's event id, which the writes in its before_destroy callbacks
    # name, is a SaveWithoutEffect marker, as for any write that records no
    # event of its own; nothing dangles.
    define_method("test_a_soft_delete_running_the_destroy_callbacks_itself_has_a_write_scope_in_#{mode}") do
      use(mode)
      DcParent.class_eval do
        def soft_destroy = with_transaction_returning_status { run_callbacks(:destroy) { update_column(:label, "deleted"); true } }
      end
      parent, child = parent_with_child
      parent.child_label = "cd"
      parent.child_label_after_destroy = "ad"

      parent.soft_destroy

      parent_events = stream(DcParent, parent.id)
      assert_empty parent_events.select { operation(_1) == "destroyed" }, "a soft delete records no Destroyed"
      child_events = stream(DcChild, child.id).last(2)
      scope = child_events.first.metadata[:causation_id]
      refute_nil scope, "the before_destroy write names the soft delete"
      assert_equal [scope], markers.map(&:event_id), "the soft delete's scope, which recorded no event, is a marker"
      deleted = parent_events.find { operation(_1) == "updated" && _1.metadata[:causation_id] == scope }
      assert deleted, "the update the soft delete made is recorded, in its scope: #{parent_events.map { operation(_1) }.inspect}"
      assert_equal [scope] * 2, child_events.map { _1.metadata[:correlation_id] }, "one correlation, the delete's"
      assert_no_dangling_causation

      other, other_child = parent_with_child
      other.child_label = "cd2"
      other.destroy!
      gone = stream(DcParent, other.id).find { operation(_1) == "destroyed" }
      assert_equal gone.event_id, gone.metadata[:correlation_id], "a normal destroy opens one scope"
      assert_equal gone.event_id, stream(DcChild, other_child.id).last.metadata[:causation_id]
      assert_no_dangling_causation
    end

    # A save that raises after a write in its before_* callbacks, rescued by
    # the caller inside an enclosing transaction (no savepoint: nothing rolls
    # back). The write stays, and so does its cause, a marker.
    define_method("test_a_save_that_raises_after_a_before_write_rescued_inside_a_transaction_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      DcParent.class_eval { attr_accessor :boom; before_save { raise ArgumentError, "boom" if boom } }
      parent.child_label_before = "b"
      parent.boom = true

      ActiveRecord::Base.transaction do
        parent.save!
      rescue ArgumentError
        nil
      end

      assert_equal "b", DcChild.find(child.id).label, "the before write committed"
      marker = markers.sole
      assert_equal marker.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_equal %w[update not\ saved], [marker.data[:operation], marker.data[:reason]]
      assert_no_dangling_causation
    end

    # ... and when the enclosing transaction rolls back, the marker goes with
    # the write that named it.
    define_method("test_the_marker_of_a_save_that_raised_rolls_back_with_its_transaction_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      DcParent.class_eval { attr_accessor :boom; before_save { raise ArgumentError, "boom" if boom } }
      parent.child_label_before = "b"
      parent.boom = true

      assert_raises(ArgumentError) { ActiveRecord::Base.transaction { parent.save! } }

      assert_equal "c0", DcChild.find(child.id).label
      assert_empty markers
      assert_no_dangling_causation
    end

    # A create aborted (throw :abort) after a write in its before_save, inside
    # an enclosing transaction: save returns false, the write stays.
    define_method("test_an_aborted_create_after_a_before_write_leaves_a_marker_in_#{mode}") do
      use(mode)
      _, child = parent_with_child
      DcParent.class_eval { attr_accessor :abort_save; before_save { throw :abort if abort_save } }
      record = DcParent.new(label: "n", child_id: child.id, child_label_before: "bb", abort_save: true)

      ActiveRecord::Base.transaction { refute record.save }

      assert_equal %w[create not\ saved], [markers.sole.data[:operation], markers.sole.data[:reason]]
      assert_no_dangling_causation
    end

    # A destroy aborted after its dependent: :destroy children (before_destroy).
    define_method("test_a_destroy_aborted_after_its_dependent_destroys_leaves_a_marker_in_#{mode}") do
      use(mode)
      DcParent.class_eval do
        has_many :dc_children, class_name: "DcChild", foreign_key: :dc_parent_id, dependent: :destroy
        attr_accessor :abort_destroy

        before_destroy { throw :abort if abort_destroy }
      end
      parent, child = parent_with_child
      parent.abort_destroy = true

      ActiveRecord::Base.transaction { refute parent.destroy }

      assert_equal "destroyed", operation(stream(DcChild, child.id).last)
      assert_equal markers.sole.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_equal "not saved", markers.sole.data[:reason]
      assert_no_dangling_causation
    end

    # Nested saves that both change nothing, the inner one in the outer's
    # before_save: two markers, chained to the cause in scope.
    define_method("test_nested_saves_that_change_nothing_chain_their_markers_in_#{mode}") do
      use(mode)
      DcParent.class_eval { attr_accessor :inner_to_save; before_save { inner_to_save&.save! } }
      outer = DcParent.find(DcParent.create!(label: "a").id)
      inner, child = parent_with_child
      inner.child_label_before = "deep"
      outer.inner_to_save = inner

      root = DcRoot.create!(parent_to_save: outer)

      inner_marker = markers.find { _1.data[:record_id] == inner.id }
      outer_marker = markers.find { _1.data[:record_id] == outer.id }
      assert_equal 2, markers.size
      assert_equal inner_marker.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_equal outer_marker.event_id, inner_marker.metadata[:causation_id]
      assert_equal stream(DcRoot, root.id).first.event_id, outer_marker.metadata[:causation_id]
      assert_no_dangling_causation
    end

    # ... and when the outer save records, the inner marker names its event.
    define_method("test_a_nested_marker_names_the_outer_save_that_records_in_#{mode}") do
      use(mode)
      DcParent.class_eval { attr_accessor :inner_to_save; before_save { inner_to_save&.save! } }
      outer = DcParent.find(DcParent.create!(label: "a").id)
      inner, = parent_with_child
      inner.child_label_before = "deep"
      outer.inner_to_save = inner

      outer.update!(label: "a2")

      assert_equal stream(DcParent, outer.id).find { own_update?(_1) }.event_id, markers.sole.metadata[:causation_id]
      assert_no_dangling_causation
    end

    # A job created in the before phase carries the id as a String: the
    # marker's when the save changes nothing, the update's when it records.
    define_method("test_a_job_created_before_the_save_s_event_carries_an_existing_cause_in_#{mode}") do
      use(mode)
      jobs = []
      DcParent.class_eval { attr_accessor :jobs; before_save { self.jobs&.push(ActiveJob::Base.new) } }
      parent, = parent_with_child
      parent.jobs = jobs

      parent.save!
      before = jobs.dup
      jobs.clear
      parent.update!(label: "x")

      assert_equal [String], before.map { _1.lyra_causation_id.class }
      assert_equal markers.sole.event_id, before.sole.lyra_causation_id
      assert_equal stream(DcParent, parent.id).find { own_update?(_1) }.event_id, jobs.first.lyra_causation_id
      assert_no_dangling_causation
    end
  end

  %i[monitor hijack es_sync].each do |mode|
    # Optimistic locking: the version moved on after a before_save write, and
    # the caller rescues StaleObjectError inside its transaction.
    define_method("test_a_stale_object_error_after_a_before_write_rescued_inside_a_transaction_in_#{mode}") do
      use(mode)
      define_locked_model
      _, child = parent_with_child
      record = DcLocked.create!(label: "a")
      stale = DcLocked.find(record.id)
      DcLocked.find(record.id).update!(label: "b")
      stale.child_id = child.id
      stale.label = "c"

      ActiveRecord::Base.transaction do
        stale.save!
      rescue ActiveRecord::StaleObjectError
        nil
      end

      assert_equal "touched-by-c", DcChild.find(child.id).label
      assert_equal markers.sole.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
      assert_no_dangling_causation
    ensure
      connection.drop_table(LOCKED, if_exists: true)
    end
  end

  # Hijack appends before the row write. A row write that raises
  # (StaleObjectError) takes the event with it, so the log never holds an
  # update that did not happen, even when the caller rescues and commits.
  def test_hijack_s_event_does_not_outlive_a_failed_row_write
    use(:hijack)
    define_locked_model
    record = DcLocked.create!(label: "a")
    stale = DcLocked.find(record.id)
    DcLocked.find(record.id).update!(label: "b")
    stale.label = "c"

    ActiveRecord::Base.transaction do
      stale.save!
    rescue ActiveRecord::StaleObjectError
      nil
    end

    labels = stream(DcLocked, record.id).filter_map { (_1.data[:changes] || {})["label"]&.last }
    assert_equal %w[b], labels, "no event for the update that failed"
    assert_equal "b", DcLocked.find(record.id).label
    assert_equal({}, Lyra::DualView.new(DcLocked, record.id).calculate_differences)
    Lyra::Projections::Rebuild.rebuild(DcLocked)
    assert_equal ["b", 1], DcLocked.where(id: record.id).pick(:label, :lock_version)

    stale.reload.update!(label: "d")
    assert_equal %w[b d], stream(DcLocked, record.id).filter_map { (_1.data[:changes] || {})["label"]&.last }
  ensure
    connection.drop_table(LOCKED, if_exists: true)
  end

  # ... and a destroy.
  def test_hijack_s_destroy_event_does_not_outlive_a_failed_row_write
    use(:hijack)
    define_locked_model
    record = DcLocked.create!(label: "a")
    stale = DcLocked.find(record.id)
    DcLocked.find(record.id).update!(label: "b")

    ActiveRecord::Base.transaction do
      stale.destroy!
    rescue ActiveRecord::StaleObjectError
      nil
    end

    refute(stream(DcLocked, record.id).any? { operation(_1) == "destroyed" })
    assert DcLocked.exists?(record.id)
    assert_equal({}, Lyra::DualView.new(DcLocked, record.id).calculate_differences)
  ensure
    connection.drop_table(LOCKED, if_exists: true)
  end

  # Fails Hijack's and event sourcing's command for DcParent's updates
  # (a domain check of the aggregate), while +on+.
  module RefusingAggregate
    class << self
      attr_accessor :on
    end

    def apply_updated(event)
      raise "domain refused" if RefusingAggregate.on && (event.data[:model_class] || event.data["model_class"]).to_s == "DcParent"

      super
    end
  end

  %i[hijack es_sync es_async es_noproj es_lazy].each do |mode|
    # The command is refused after the write's id was taken, so its event
    # never reaches the log; save returns false inside an enclosing
    # transaction, which keeps the before write: a marker is owed.
    define_method("test_a_refused_command_after_a_before_write_leaves_a_marker_in_#{mode}") do
      use(mode)
      parent, child = parent_with_child
      Lyra::GenericAggregate.prepend(RefusingAggregate) unless Lyra::GenericAggregate.include?(RefusingAggregate)
      RefusingAggregate.on = true
      parent.child_label_before = "b"
      parent.label = "renamed"

      ActiveRecord::Base.transaction { refute parent.save, "the command was refused" }

      assert_equal "b", DcChild.find(child.id).label
      refute stream(DcParent, parent.id).any? { own_update?(_1) }
      assert_equal %w[update not\ saved], [markers.sole.data[:operation], markers.sole.data[:reason]]
      assert_no_dangling_causation
    ensure
      RefusingAggregate.on = false
    end
  end

  # Monitor with monitor_append_failure :fail_write: the append fails, save!
  # raises, the caller rescues inside its transaction.
  def test_a_monitor_fail_write_append_failure_rescued_inside_a_transaction_leaves_a_marker
    use(:monitor)
    Lyra.config.monitor_append_failure = :fail_write
    parent, child = parent_with_child
    parent.child_label_before = "b"
    parent.label = "renamed"
    Lyra.singleton_class.prepend(FailingAppend) unless Lyra.singleton_class.include?(FailingAppend)
    FailingAppend.stream = Lyra.stream_name(DcParent, parent.id)

    ActiveRecord::Base.transaction do
      begin
        parent.save!
      rescue Lyra::EventStoreUnavailableError
        nil
      end
      FailingAppend.stream = nil # the child's touch of the parent, at the commit, is appended
    end

    assert_equal "b", DcChild.find(child.id).label
    assert_equal "append failed", markers.sole.data[:reason]
    assert_no_dangling_causation
  ensure
    FailingAppend.stream = nil
  end

  # The access log commits on a connection of its own and stays when the
  # write in scope rolls back: it names no write in scope as its cause, only
  # the cause outside them, and keeps the correlation.
  def test_an_access_log_entry_names_no_write_in_scope
    use(:monitor)
    Lyra.config.record_access_events = true
    parent, child = parent_with_child
    access = Struct.new(:policy, :purpose, :legal_basis, :fields, :outcome, :at, :violations, :subject, keyword_init: true)
                   .new(policy: "P", purpose: :x, legal_basis: nil, fields: [:label], outcome: :granted, at: Time.current,
                        violations: [], subject: child)
    DcParent.class_eval { attr_accessor :access; after_update { Lyra::AccessLog.call(access) if access } }
    parent.access = access
    parent.label = "renamed"

    Lyra::Causation.with_id("job-cause") do
      ActiveRecord::Base.transaction do
        parent.save!
        raise ActiveRecord::Rollback
      end
    end

    assert_equal "p", DcParent.find(parent.id).label
    entry = Lyra::AccessLog.for(child).sole
    assert_equal "job-cause", entry.metadata[:causation_id], "the cause from outside the write scopes"
    assert entry.metadata[:correlation_id]
    assert_equal ["job-cause"], Lyra::Causation.integrity[:dangling].map { _1[:causation_id] },
                 "only the application's own cause, which names no event here"
  ensure
    Lyra::AccessLog.delete_stream!(Lyra::AccessLog.stream_for(Lyra::AccessLog.subject_key(child))) if child
  end

  # Monitor's stale copy: its DELETE reaches no row, as another copy deleted
  # it. Nothing follows the Destroyed in the record's stream; the write its
  # before_destroy made names a marker.
  def test_a_stale_destroy_that_reaches_no_row_leaves_a_marker
    use(:monitor)
    parent, child = parent_with_child
    stale = DcParent.find(parent.id)
    stale.child_id = child.id
    stale.child_label = "c-stale"
    DcParent.find(parent.id).destroy!

    stale.destroy

    assert_equal %w[DcParentCreated DcParentDestroyed],
                 stream(DcParent, parent.id).reject { touch?(_1) }.map { _1.event_type.delete_prefix("Lyra::Events::") }
    assert_equal Lyra::Events::DcParentDestroyed, stream(DcParent, parent.id).last.class
    marker = markers.sole
    assert_equal stream(DcChild, child.id).last.metadata[:causation_id], marker.event_id
    assert_equal %w[destroy no\ row], [marker.data[:operation], marker.data[:reason]]
    assert_no_dangling_causation
  end

  # Disabled records nothing, markers included.
  def test_no_marker_in_disabled_mode
    use(:monitor)
    parent, child = parent_with_child
    Lyra.config.disable!
    parent.child_label_before = "b"
    clean_events

    parent.save!

    assert_equal "b", DcChild.find(child.id).label
    assert_equal 0, Lyra::Causation.integrity[:events]
  end

  # The check itself: a cause the store lacks is reported; a marker counts
  # as an event.
  def test_integrity_reports_a_cause_the_store_lacks_and_counts_markers
    use(:monitor)
    Lyra::Causation.with_id("00000000-0000-0000-0000-000000000000") { DcParent.create!(label: "orphan") }

    check = Lyra::Causation.integrity

    assert_equal 1, check[:caused]
    assert_equal ["00000000-0000-0000-0000-000000000000"], check[:dangling].map { _1[:causation_id] }

    parent, child = parent_with_child
    parent.child_label_before = "b"
    parent.save!

    assert_equal markers.sole.event_id, stream(DcChild, child.id).last.metadata[:causation_id]
    assert_equal ["00000000-0000-0000-0000-000000000000"], Lyra::Causation.integrity[:dangling].map { _1[:causation_id] },
                 "the child's cause, the marker, is in the store"
  end

  # Monitor's default policy keeps a write whose append failed (logged);
  # its event is not in the log. The writes its after_* callbacks make take
  # the cause in scope, and one its before_save made names a marker.
  def test_a_monitor_write_whose_append_failed_is_no_one_s_cause
    use(:monitor)
    refute Lyra.config.events_required?, "Monitor's default: log and continue"
    parent, child = parent_with_child
    parent.child_label = "c1"
    Lyra.singleton_class.prepend(FailingAppend) unless Lyra.singleton_class.include?(FailingAppend)
    FailingAppend.stream = Lyra.stream_name(DcParent, parent.id)

    parent.update!(label: "renamed")

    assert_equal "renamed", DcParent.find(parent.id).label, "the write stands"
    assert_nil stream(DcChild, child.id).last.metadata[:causation_id]
    assert_empty markers

    parent.child_label = nil
    parent.child_label_before = "b"
    parent.update!(label: "renamed again")

    marker = markers.sole
    assert_equal stream(DcChild, child.id).last.metadata[:causation_id], marker.event_id
    assert_equal "append failed", marker.data[:reason]
    assert_no_dangling_causation
  ensure
    FailingAppend.stream = nil
  end

  # Fails the appends to one stream (none when stream is nil).
  module FailingAppend
    class << self
      attr_accessor :stream
    end

    def append_events(events, stream_name:, **)
      raise Lyra::EventStoreUnavailableError, "store down" if stream_name == FailingAppend.stream

      super
    end
  end

  private

  def parent_with_child
    parent = DcParent.create!(label: "p")
    child = DcChild.create!(dc_parent_id: parent.id, label: "c0")
    parent = DcParent.find(parent.id)
    parent.child_id = child.id
    [parent, child]
  end

  def define_models
    %i[DcRoot DcParent DcChild].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Object.const_set(:DcChild, Class.new(ActiveRecord::Base))
    Object.const_set(:DcParent, Class.new(ActiveRecord::Base))
    Object.const_set(:DcRoot, Class.new(ActiveRecord::Base))
    DcChild.class_eval do
      self.table_name = CHILDREN
      include Lyra::Interceptors::CrudInterceptor
      belongs_to :dc_parent, class_name: "DcParent", optional: true, touch: true
    end
    DcParent.class_eval do
      self.table_name = PARENTS
      include Lyra::Interceptors::CrudInterceptor
      attr_accessor :child_id, :child_label, :child_label_before, :touch_child, :child_label_after_save,
                    :child_label_after_destroy

      # Every callback runs in the write scope: before_save, as a belongs_to
      # autosave does; after_create/after_update, as has_many autosave's do
      # (Solidus's Order line items); after_save and after_destroy, as
      # Solidus's Payment#update_order does.
      before_save { DcChild.find(child_id).update!(label: child_label_before) if child_label_before }
      after_create :write_child
      after_update :write_child
      before_destroy :write_child
      after_save { DcChild.find(child_id).update!(label: child_label_after_save) if child_label_after_save }
      after_destroy { DcChild.find(child_id).update!(label: child_label_after_destroy) if child_label_after_destroy }

      def write_child
        DcChild.find(child_id).update!(label: child_label) if child_label
        DcChild.find(child_id).touch if touch_child
      end
    end
    # A write whose after_create saves another record: the cause in scope.
    DcRoot.class_eval do
      self.table_name = ROOTS
      include Lyra::Interceptors::CrudInterceptor
      attr_accessor :parent_to_save

      after_create { parent_to_save&.save! }
    end
    [DcChild, DcParent, DcRoot].each do |model|
      model.monitor_with_lyra
      Lyra.config.monitor_model(model)
      model.reset_column_information
    end
  end

  LOCKED = "lyra_dc_locked"

  # A model with optimistic locking whose before_save writes the child.
  def define_locked_model
    connection.create_table(LOCKED, force: true) do |t|
      t.string :label
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    Object.send(:remove_const, :DcLocked) if Object.const_defined?(:DcLocked)
    Object.const_set(:DcLocked, Class.new(ActiveRecord::Base))
    DcLocked.class_eval do
      self.table_name = LOCKED
      include Lyra::Interceptors::CrudInterceptor
      attr_accessor :child_id

      before_save { DcChild.find(child_id).update!(label: "touched-by-#{label}") if child_id }
    end
    DcLocked.monitor_with_lyra
    Lyra.config.monitor_model(DcLocked)
    DcLocked.reset_column_information
  end

  def use(mode)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_noproj: :disabled, es_lazy: :lazy }.fetch(mode)
    end
  end

  def stream(model, id) = Lyra.config.event_store.read.stream(Lyra.stream_name(model, id)).to_a

  def markers = Lyra.config.event_store.read.stream(MARKERS).to_a

  def operation(event) = (event.data[:operation] || event.data["operation"]).to_s

  # An update a touch made (a bypass event, BypassEvents).
  def touch?(event)
    operation(event) == "updated" && (event.metadata[:bypass_source] || event.metadata[:source]).to_s == "touch"
  end

  def own_update?(event) = operation(event) == "updated" && !touch?(event)

  def connection = ActiveRecord::Base.connection

  def clean_events
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end

  def clean
    [ROOTS, PARENTS, CHILDREN].each { |table| connection.execute("DELETE FROM #{table}") if connection.table_exists?(table) }
    clean_events
    Lyra::Projections::LazyProjection.reset!
  end
end
