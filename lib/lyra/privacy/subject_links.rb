# frozen_string_literal: true

module Lyra
  module Privacy
    # How a monitored model's records refer to a data subject, for the
    # Art. 15 copy and the GDPR helpers: each belongs_to whose class is the
    # subject's model (belongs_to :owner, class_name: "Person"), each
    # polymorphic belongs_to (with its type column naming the subject's
    # class), and the <type>_id column by convention (person_id for Person).
    # A column an association owns links only to that association's class
    # (a polymorphic one's, only with its type column naming the subject's
    # class): before 1.0.0's fix the convention also read it, so owner_id of
    # belongs_to :owner, class_name: "Person" named a model called Owner too,
    # and a polymorphic owner_id named Owner whatever owner_type said. The
    # convention reads only a column no association owns, and only for a
    # subject type that is a monitored model or names no model at all (not
    # for a model Lyra does not monitor). The subject's own model is not
    # linked to itself: a person record pointing at another person (a
    # manager) is that other person's record.
    #
    # A record names the subject while one of its links holds the subject's
    # id (and, for a polymorphic link, the subject's class name).
    class SubjectLinks
      Link = Struct.new(:fk, :type_column, :type_value, keyword_init: true)

      attr_reader :subject_type

      def initialize(subject_type)
        @subject_type = subject_type.to_s
        @convention = "#{@subject_type.demodulize.underscore}_id"
        @cache = {}
      end

      # The subject's model, if the subject type names an Active Record class.
      def subject_model
        return @subject_model if defined?(@subject_model)

        model = Lyra.config.monitored_model_named(@subject_type) || @subject_type.safe_constantize
        @subject_model = model.is_a?(Class) && model < ActiveRecord::Base ? model : nil
      end

      # The links of +model+ (a class or a model name) to the subject.
      def for(model)
        key = model.is_a?(Class) ? model.name : model.to_s
        @cache[key] ||= model.is_a?(Class) ? class_links(model) : name_links(key)
      end

      # The columns the links read.
      def columns(model)
        self.for(model).flat_map { |link| [link.fk, link.type_column] }.compact.uniq
      end

      # Whether +values+ (column => value) name the subject through a link.
      def names?(model, values, subject_id)
        self.for(model).any? do |link|
          value = values[link.fk]
          next false if value.nil? || value.to_s != subject_id.to_s
          next true unless link.type_column

          values[link.type_column].to_s == link.type_value
        end
      end

      # The monitored models (one per table) with at least one link and a table.
      def linked_models
        Lyra.config.monitored_models.map { |m| m.respond_to?(:base_class) ? m.base_class : m }.uniq.select do |model|
          self.for(model).any? && model.table_exists?
        rescue StandardError
          false
        end
      end

      # The rows of +model+ that name the subject now, one query per link.
      def rows(model, subject_id)
        self.for(model).flat_map do |link|
          scope = model.unscoped.where(link.fk => subject_id)
          scope = scope.where(link.type_column => link.type_value) if link.type_column
          scope.to_a
        end.uniq(&:id)
      end

      private

      def own_model?(model)
        subject_model && Lyra.stream_owner_name(model) == Lyra.stream_owner_name(subject_model)
      end

      def class_links(model)
        return [] if own_model?(model)

        reflections = model.reflect_on_all_associations(:belongs_to)
        links = reflections.filter_map { |reflection| link_for(reflection) }
        owned = reflections.map { |reflection| reflection.foreign_key.to_s }
        columns = safe_columns(model)
        if convention? && columns.include?(@convention) && !owned.include?(@convention)
          links << Link.new(fk: @convention)
        end
        links.select { |link| columns.empty? || columns.include?(link.fk) }.uniq
      end

      def name_links(name)
        return [] if name == @subject_type || !convention?

        [Link.new(fk: @convention)]
      end

      # The <type>_id convention holds for a subject type that is a monitored
      # model, or that names no Active Record class at all (a subject the
      # application identifies by type and id only); not for a model Lyra
      # does not monitor.
      def convention?
        return true if subject_model.nil?

        Lyra.config.monitored_models.any? do |model|
          Lyra.stream_owner_name(model) == Lyra.stream_owner_name(subject_model)
        end
      end

      def link_for(reflection)
        if reflection.polymorphic?
          return nil unless subject_model

          Link.new(fk: reflection.foreign_key.to_s, type_column: reflection.foreign_type.to_s,
                   type_value: subject_model.polymorphic_name)
        else
          target = reflection.class_name.to_s.safe_constantize
          return nil unless target.is_a?(Class) && subject_model
          return nil unless Lyra.stream_owner_name(target) == Lyra.stream_owner_name(subject_model)

          Link.new(fk: reflection.foreign_key.to_s)
        end
      rescue StandardError
        nil
      end

      def safe_columns(model)
        model.table_exists? ? model.column_names : []
      rescue StandardError
        []
      end
    end
  end
end
