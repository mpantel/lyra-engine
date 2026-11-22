# frozen_string_literal: true

module Lyra
  module Associations
    # The callback-bypassing writes Rails makes to keep an association, which
    # strict data access lets through (StrictDataAccess,
    # StrictDataAccessRelation, CachedRelation), as against the same writes
    # made by the application:
    #
    # - :nullify: a has_many's update_all clearing the children's foreign key
    #   (and, for a polymorphic as: association, their type), on
    #   dependent: :nullify when the owner is destroyed and when children are
    #   removed from the collection (delete, delete_all, clear, assigning a
    #   new set or new ids), whatever the key is called; a has_many
    #   :through's update_all clearing the source key of its through records
    #   (dependent: :nullify); a has_one's update_columns clearing its
    #   record's key (dependent: :nullify);
    # - :unlink: the delete_all of the rows that link an owner to its
    #   records: has_and_belongs_to_many join rows (delete, delete_all,
    #   clear, destroy, destroy_all, assigning, destroying the owner),
    #   recorded as AssociationUnlinked (HabtmLinks), the same rows through a
    #   model the application declared on the join table (HabtmLinks
    #   .join_model_of), and a has_many :through's through records when
    #   records are removed from it (delete, clear, assigning: the
    #   through records are deleted, not destroyed, unless the association
    #   says dependent: :destroy).
    #
    # A has_many's dependent: :delete_all is not maintenance: it deletes the
    # owner's children, past their callbacks, and strict mode refuses it.
    #
    # Rails' association code marks the one relation (or record) it is about
    # to write, just before the write, once the records it needs are loaded
    # (marking); the write on that very object takes the mark (claim), once,
    # and is let through, with its events. Any other write in between (the
    # application's after_find, after_initialize or destroy callbacks, Lyra's
    # own reads materialising records) is on another object, and the mark is
    # not its. The same write made by the application
    # (Model.where(...).update_all(fk: nil), Item::HABTM_Tags.delete_all) has
    # no mark: it is an ordinary bulk write, refused in strict mode. Before
    # 1.0.0 an update_all setting one *_id column to nil was taken for a
    # nullify by its shape alone, and application code could bypass strict
    # mode with it; and Rails' own writes of another shape (a polymorphic or
    # custom foreign key, a has_many :through's removal) were refused.
    module Maintenance
      KEY = :lyra_association_maintenance
      # Rails versions whose HasManyThroughAssociation#delete_records
      # HasManyThroughAssociationPatch reproduces, checked line by line
      # (8.0.5.1, 8.1.4.1).
      VERIFIED_THROUGH_DELETE = Gem::Requirement.new(">= 8.0", "< 8.2.a")

      class << self
        # Run Rails' association write in the block, marked as +kind+ for
        # +target+, the relation or record it writes.
        def marking(kind, target)
          previous = Thread.current[KEY]
          Thread.current[KEY] = [kind, target]
          yield
        ensure
          Thread.current[KEY] = previous
        end

        # Whether the write about to be made on +receiver+ is Rails'
        # association write marked +kind+. The mark is taken: Rails makes
        # one write of the object it marks. A mark on a model class (the
        # coarser fallback, HasManyThroughAssociationFallback) is taken by
        # the first write of that model's records.
        def claim(kind, receiver)
          mark = Thread.current[KEY]
          return false unless mark && mark[0] == kind && marked?(mark[1], receiver)

          Thread.current[KEY] = nil
          true
        end

        # The has_many :through patch for Active Record +version+: the copy
        # of delete_records where it was verified, else the coarser
        # fallback, which marks around Rails' own method.
        def through_patch(version = ActiveRecord.version)
          if VERIFIED_THROUGH_DELETE.satisfied_by?(Gem::Version.new(version.to_s))
            HasManyThroughAssociationPatch
          else
            HasManyThroughAssociationFallback
          end
        end

        # Said once, when the fallback is installed.
        def warn_coarse_through!(version = ActiveRecord.version)
          return if @warned_coarse_through

          @warned_coarse_through = true
          message = "Lyra: Active Record #{version} is not one whose has_many :through delete_records Lyra " \
                    "has checked (#{VERIFIED_THROUGH_DELETE}); strict data access tells its nullify and " \
                    "through-record deletes from the application's by model there, not by the relation written, " \
                    "so a write of the same model made during them (a callback) is let through too"
          defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : Kernel.warn(message)
        end

        private

        def marked?(target, receiver)
          return true if target.equal?(receiver)
          return false unless target.is_a?(Class)

          model = if receiver.respond_to?(:model_class) then receiver.model_class
                  elsif receiver.respond_to?(:klass) then receiver.klass
                  else receiver.class
                  end
          model.is_a?(Class) && model <= target
        end

        public

        # The kind of a has_many's delete_count(+method+) on +klass+'s
        # records: a nullify, or the unlink of join rows; nil for a
        # dependent: :delete_all of the children.
        def has_many_kind(method, klass)
          return :nullify unless method == :delete_all

          HabtmLinks.join_model_of(klass) ? :unlink : nil
        end
      end

      # has_many: Rails' delete_count is the write of dependent: :nullify and
      # :delete_all, and of removing records from the collection (delete,
      # clear, replace): update_all of the owner's key, or delete_all, on the
      # scope it is given.
      module HasManyAssociationPatch
        private

        def delete_count(method, scope)
          kind = Maintenance.has_many_kind(method, scope.klass)
          return super unless kind

          Maintenance.marking(kind, scope) { super }
        end
      end

      # has_many :through: removing records deletes, nullifies or destroys
      # their through records, by the through association's scope. Active
      # Record's HasManyThroughAssociation#delete_records (Rails 8.0, 8.1),
      # with the relation it writes marked just before the write: the scope is
      # built, and the records a :destroy loads have run their callbacks, by
      # then. A :destroy of through records with a primary key goes through
      # their callbacks (destroy_all) and is no bypass.
      module HasManyThroughAssociationPatch
        private

        def delete_records(records, method)
          ensure_not_nested

          scope = through_association.scope
          scope.where! construct_join_attributes(*records)
          scope = scope.where(through_scope_attributes)

          case method
          when :destroy
            if scope.model.primary_key
              count = scope.destroy_all.count(&:destroyed?)
            else
              scope.each(&:_run_destroy_callbacks)
              count = Maintenance.marking(:unlink, scope) { scope.delete_all }
            end
          when :nullify
            count = Maintenance.marking(:nullify, scope) { scope.update_all(source_reflection.foreign_key => nil) }
          else
            count = Maintenance.marking(:unlink, scope) { scope.delete_all }
          end

          delete_through_records(records)

          if source_reflection.options[:counter_cache] && method != :destroy
            counter = source_reflection.counter_cache_column
            klass.decrement_counter counter, records.map(&:id)
          end

          if through_reflection.collection? && update_through_counter?(method)
            update_counter(-count, through_reflection)
          else
            update_counter(-count)
          end

          count
        end
      end

      # has_many :through on an Active Record not checked
      # (VERIFIED_THROUGH_DELETE): Rails' own delete_records, with the
      # through model marked for the whole of it. Coarser: a write of the
      # through model made meanwhile (a callback of a :destroy) is taken for
      # Rails'.
      module HasManyThroughAssociationFallback
        private

        def delete_records(records, method)
          return super if method == :destroy && through_reflection.klass.primary_key

          kind = method == :nullify ? :nullify : :unlink
          Maintenance.marking(kind, through_reflection.klass) { super }
        end
      end

      # has_one dependent: :nullify clears its record's key with
      # update_columns. The record is loaded first (its after_find and
      # after_initialize run before the mark), then marked.
      module HasOneAssociationPatch
        def delete(method = options[:dependent])
          return super unless method == :nullify

          record = load_target
          return super unless record

          Maintenance.marking(:nullify, record) { super }
        end
      end

      def self.install!
        return if @installed

        ActiveRecord::Associations::HasManyAssociation.prepend(HasManyAssociationPatch)
        through = through_patch
        warn_coarse_through! unless through == HasManyThroughAssociationPatch
        ActiveRecord::Associations::HasManyThroughAssociation.prepend(through)
        ActiveRecord::Associations::HasOneAssociation.prepend(HasOneAssociationPatch)
        HabtmLinks.install!
        @installed = true
      end
    end
  end
end
