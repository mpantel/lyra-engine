# frozen_string_literal: true

require "delegate"

module Lyra
  module Projections
    # A CachedRelation whose records are read when first needed.
    #
    # An association (order.shipments, stock_location.stock_items) hands back
    # its records before anything else is asked of them, and what is asked
    # next is usually a narrowing: stock_location.stock_item(variant) is
    # stock_items.where(variant_id: ...).first. Loading the association first
    # builds every item of the location to keep one. While the records have
    # not been read, a plain where on columns is merged into the conditions
    # that will load them, so the reference links can use all of the keys
    # (ReferenceLinks.lookup intersects them).
    #
    # Anything else (a record read, a query that is not a plain column
    # condition, a key already conditioned) reads the records and behaves as
    # CachedRelation does, with the same answers.
    class DeferredRelation < CachedRelation
      # The records, loaded on first use. Stands in for the Array a
      # CachedRelation keeps.
      class Records < Delegator
        def initialize(&loader)
          @loader = loader
          @loaded = false
          @records = nil
        end

        def loaded? = @loaded

        # Copies and conversions are plain Arrays (Kernel's dup and the
        # like are not delegated, and would hand the wrapper on).
        def dup = __getobj__.dup
        def clone(freeze: nil) = __getobj__.dup
        def to_a = __getobj__.dup
        def to_ary = __getobj__
        def is_a?(klass) = __getobj__.is_a?(klass)
        alias_method :kind_of?, :is_a?

        def __getobj__
          unless @loaded
            @records = @loader.call.to_a
            @loaded = true
          end
          @records
        end

        def __setobj__(records)
          @records = records
          @loaded = true
        end
      end

      # +conditions+ select the records of +model_class+ (a Hash for
      # EventStoreReader.where); +on_load+ sees them once, when they are read
      # (an association points them back at its owner).
      def initialize(model_class, records = nil, conditions: nil, on_load: nil)
        @conditions = conditions
        @on_load = on_load
        if conditions
          super(model_class, [])
          @model_class = model_class
          @records = Records.new { load_records }
          scalars = conditions.select { |key, value| plain_value?(model_class, key, value) && !value.is_a?(Array) && !value.is_a?(Range) }
          self.create_attributes = scalars.transform_keys(&:to_s)
        else
          super(model_class, records || [])
        end
      end

      def loaded?
        !(Records === @records) || @records.loaded?
      end

      def where(*args)
        return super unless mergeable?(args)

        merged = @conditions.merge(args.first)
        relation = self.class.new(model_class, conditions: merged, on_load: @on_load)
        relation.selected_columns = selected_columns
        relation.group_columns = group_columns
        relation.extending!(*extensions) if extensions.any?
        relation.create_attributes = create_attributes.merge(relation.create_attributes)
        relation
      end

      private

      def load_records
        found = EventStoreReader.where(model_class, @conditions).records
        @on_load&.call(found)
        found
      end

      # A where on columns of this model, with plain values, and none of them
      # already among the pending conditions (two conditions on one key are an
      # AND that a merge would turn into an override).
      def mergeable?(args)
        return false if loaded? || @conditions.nil? || args.size != 1

        added = args.first
        return false unless added.is_a?(Hash) && added.any?

        taken = @conditions.keys.map(&:to_s)
        added.all? do |key, value|
          plain_value?(model_class, key, value) && !taken.include?(key.to_s)
        end
      end

      def plain_value?(model_class, key, value)
        return false unless (key.is_a?(String) || key.is_a?(Symbol)) && model_class.column_names.include?(key.to_s)

        value.nil? || value.is_a?(Integer) || value.is_a?(String) || value.is_a?(Symbol) ||
          value == true || value == false || value.is_a?(Array) || value.is_a?(Range)
      end
    end
  end
end
