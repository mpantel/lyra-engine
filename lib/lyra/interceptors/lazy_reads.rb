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
          super
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
      end

      def self.install!
        ActiveRecord::Base.singleton_class.prepend(Querying) unless ActiveRecord::Base.singleton_class.ancestors.include?(Querying)
        ActiveRecord::Relation.prepend(Relation) unless ActiveRecord::Relation.ancestors.include?(Relation)
      end
    end
  end
end
