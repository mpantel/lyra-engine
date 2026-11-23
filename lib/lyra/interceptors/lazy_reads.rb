# frozen_string_literal: true

module Lyra
  module Interceptors
    # Read hooks for ES-Lazy (projection_mode :lazy): before ActiveRecord reads
    # from the database, Projections::LazyProjection brings the tables up to
    # date from the event log. Outside lazy mode each hook is one config check.
    #
    # Record loads, associations included, all run through
    # Querying#_query_by_sql. Aggregates (count, sum, ...), pluck and exists?
    # go to the connection directly, so Relation gets hooks of its own. A read
    # on any model triggers catch-up, not only on monitored ones: a query on an
    # unmonitored model can join or merge a monitored table. Raw SQL through
    # the connection (connection.select_all) is not covered.
    module LazyReads
      module Querying
        def _query_by_sql(*args, **kwargs, &block)
          Lyra::Projections::LazyProjection.before_read(self)
          result = super
          # A locking read (lock, lock!, with_lock): the catch-up above ran
          # before the lock was granted, and the lock's previous holder may have
          # committed events the row does not have yet. Under the row lock and
          # the records' stream heads, which no writer of the records can pass,
          # the records behind their streams are replayed, and the read runs
          # again (from 1.0.1; 1.0.0 returned the row as the catch-up before the
          # lock left it, and an update made under the lock could be lost).
          if !kwargs[:async] && Lyra::Projections::LazyProjection.locked_read?(args[1]) &&
             Lyra::Projections::LazyProjection.bring_locked_up_to_date(self, args[0], result).positive?
            result = super
          end
          result
        end
      end

      module Relation
        def calculate(*args, **kwargs, &block)
          Lyra::Projections::LazyProjection.before_read(klass)
          super
        end

        def pluck(*args, **kwargs, &block)
          Lyra::Projections::LazyProjection.before_read(klass)
          super
        end

        def exists?(*args, **kwargs, &block)
          Lyra::Projections::LazyProjection.before_read(klass)
          super
        end

        # Model.lock.find(ids): the records' aggregate locks before the row
        # locks the query takes, the order ES-Lazy's writers take them in (the
        # aggregate lock, then the row, then the stream head; the lock-order
        # net, Lyra::Verification::LazyLockOrderNet).
        def find(*args, &block)
          if lock_value && Lyra::Projections::LazyProjection.orders_locking_reads?
            ids = args.flatten
            Lyra::Projections::LazyProjection.take_aggregate_locks(klass, ids) if ids.all? { _1.is_a?(Integer) || _1.is_a?(String) }
          end
          super
        end

        private

        # Any other locking load (Model.lock.where(...), lock with a join): the
        # keys it selects are read first without the lock, their aggregate
        # locks taken (LazyProjection.lock_selection), and then the locking
        # query runs. Eager loads and selections without the primary key run
        # as before (the CHANGELOG's known issues).
        def exec_main_query(async: false)
          return super if async || !lock_value || Thread.current[:lyra_locking_selection] || eager_loading?
          return super unless klass.respond_to?(:lyra_monitored) && klass.lyra_monitored
          return super unless Lyra::Projections::LazyProjection.orders_locking_reads?
          return super unless (pk = klass.primary_key).is_a?(String) && klass.with_connection(&:transaction_open?)

          Lyra::Projections::LazyProjection.lock_selection(klass, pk, -> { unscope(:lock).pluck(pk) }) { super(async: false) }
        end
      end

      # A record's lock! (and with_lock, which calls it): its aggregate lock
      # before the row lock, as for Relation#find above; in ES-NoProj before
      # the reload reads its stream (CachedRelation#find for lock.find).
      module Locking
        def lock!(*args, **kwargs)
          if persisted? && Lyra::Projections::LazyProjection.orders_locking_reads?
            Lyra::Projections::LazyProjection.take_aggregate_locks(self.class, [id])
          end
          super
        end
      end

      def self.install!
        ActiveRecord::Base.singleton_class.prepend(Querying) unless ActiveRecord::Base.singleton_class.ancestors.include?(Querying)
        ActiveRecord::Relation.prepend(Relation) unless ActiveRecord::Relation.ancestors.include?(Relation)
        ActiveRecord::Locking::Pessimistic.prepend(Locking) unless ActiveRecord::Locking::Pessimistic.ancestors.include?(Locking)
      end
    end
  end
end
