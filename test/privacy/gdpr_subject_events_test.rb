# frozen_string_literal: true

require "test_helper"

# A data subject's events include every event of the records that refer to
# them, not only the create. Since 1.0.0 an update carries only its changes and
# a destroy carries nothing, so matching the foreign key in each event alone
# kept a related record's create and lost its updates and its destroy in the
# Art. 15/17/20 helpers.
class GDPRSubjectEventsTest < Minitest::Test
  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:articles)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?

    Object.send(:remove_const, :GdprArticle) if defined?(GdprArticle)
    Object.const_set(:GdprArticle, Class.new(ActiveRecord::Base) { self.table_name = "articles" })
    GdprArticle.include(Lyra::Interceptors::CrudInterceptor)
    GdprArticle.monitor_with_lyra
    Lyra.config.monitor_model(GdprArticle)
    clean
  end

  def teardown
    return unless defined?(GdprArticle)

    Lyra.config.enable_monitor!
    clean
  end

  %i[enable_monitor! enable_hijack!].each do |mode|
    define_method(:"test_a_related_record_s_updates_and_destroy_are_the_subject_s_in_#{mode.to_s.delete_prefix('enable_').delete_suffix('!')}") do
      Lyra.config.public_send(mode)
      mine = GdprArticle.create!(title: "t", author_id: 7)
      mine.update!(title: "u")
      mine.destroy!
      GdprArticle.create!(title: "x", author_id: 8).update!(title: "y")

      assert_equal %i[created updated destroyed], operations_for(7)
      assert_equal %i[created updated], operations_for(8), "another subject's record stays theirs"
    end
  end

  def test_a_record_moved_to_another_subject_belongs_to_each_while_it_pointed_at_them
    Lyra.config.enable_monitor!
    article = GdprArticle.create!(title: "t", author_id: 7)
    article.update!(author_id: 8)
    article.update!(title: "after the move")

    assert_equal %i[created updated], operations_for(7), "the move itself names both"
    assert_equal %i[updated updated], operations_for(8)
  end

  private

  def operations_for(author_id)
    compliance = Lyra::Privacy::GDPRCompliance.new(subject_id: author_id, subject_type: "Author")
    compliance.send(:read_subject_events, author_id, "Author").map { |e| Lyra::Event.operation_of(e) }
  end

  def clean
    conn = ActiveRecord::Base.connection
    conn.execute("DELETE FROM articles")
    conn.execute("DELETE FROM event_store_events_in_streams")
    conn.execute("DELETE FROM event_store_events")
  end
end
