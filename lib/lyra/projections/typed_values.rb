# frozen_string_literal: true

module Lyra
  module Projections
    # Conditions and orders on records rebuilt from events (ES-NoProj),
    # decided as Active Record and the database decide them on a table.
    #
    # Active Record binds a condition's value through the column's type
    # before the database compares it: where(amount: 250.0), (amount: "250.00")
    # and (amount: 250) all find a decimal 250.00; where(kind: :card) finds
    # "card"; where(active: "t") finds true; where(qty: "abc") binds NULL and
    # finds nothing. The comparison is SQL's, with NULL unknown: where.not(tag:
    # "x") leaves out the rows whose tag is NULL. Comparing the Ruby values as
    # given missed all of these (a Float against the event's "250.0", a Symbol
    # against a String).
    #
    # A condition's value is bound here as Active Record binds it (the type
    # serializes it) and read back as a record holds it (the type
    # deserializes it); the record's value is the attribute's; the two are
    # compared as SQL would: true, false or nil (unknown).
    #
    # Conditions are compiled once per query, and what each model's types
    # need is worked out once per model (Schema): ES-NoProj answers every
    # query by testing every record, so the per-record work is kept to a read
    # and a comparison.
    module TypedValues
      # A value the database is given as NULL: one the type serializes to nil
      # ("abc" or "" on an integer column, "" on a boolean one).
      NULL = Object.new.freeze
      # The type a serialized attribute's stored text is compared as.
      TEXT = ActiveModel::Type::String.new
      # A value out of the column's range (Active Record's unboundable): no
      # row equals it.
      OUT_OF_RANGE = Object.new.freeze
      # A value the column's type binds but cannot read back (an integer
      # that is no enum's label: where(status: 5) binds = 5): no row read as
      # the type reads it equals it, and NULL is unknown against it.
      UNREADABLE = Object.new.freeze
      # Column types Active Record converts to and from Time.zone.
      TIME_TYPES = %i[datetime timestamptz time].freeze
      # Types whose values are worth remembering once read from an event's
      # text (a time is parsed, a decimal built).
      PARSED_TYPES = %i[datetime timestamptz time date decimal].freeze
      # Values read from events, per attribute, before the memo starts again.
      MEMO_LIMIT = 100_000

      # What a model's attribute types need, worked out once per model (and
      # again after reset_column_information, which replaces the types).
      class Schema
        attr_reader :model_class, :types, :names, :aliases, :conversions, :enums, :encrypted, :nondeterministic, :sti,
                    :serialized, :blank_padded

        def initialize(model_class)
          @model_class = model_class
          @types = model_class.attribute_types
          @names = model_class.attribute_names.to_set
          @aliases = model_class.attribute_aliases
          @encrypted = encrypted_names(model_class)
          @enums = @names.select { enum?(@types[_1]) }.to_set
          # Event attributes hold the attributes' values as the model gives
          # them (Model#attributes: an enum's label, a serialized column's
          # Hash); a record is instantiated from the values the table holds.
          @conversions = @names.filter_map do |name|
            type = @types[name]
            [name, type] if (enum?(type) || serialized?(type)) && !@encrypted.include?(name)
          end.to_h
          @nondeterministic = @names.select { nondeterministic?(@types[_1]) }.to_set
          # A serialized attribute is compared as the table compares it: as
          # the text it is stored as ({"a"=>1,"b"=>2} and {"b"=>2,"a"=>1}
          # are two values there).
          @serialized = @names.select { serialized?(@types[_1]) && !@encrypted.include?(_1) }.to_set
          # A character(n) column (PostgreSQL's bpchar) compares without its
          # trailing spaces: 'ab' and 'ab ' are one value there.
          @blank_padded = @names.select { blank_padded?(model_class, _1) }.to_set
          @inheritance_column = model_class.inheritance_column.to_s if model_class.respond_to?(:inheritance_column)
          @sti = @inheritance_column && @names.include?(@inheritance_column)
          @subclasses = {}
          @memo = Hash.new { |hash, name| hash[name] = {} }
          # Read from an event's text with work worth remembering: a time
          # parsed, a decimal built, a ciphertext decrypted.
          @memoized = @names.select { PARSED_TYPES.include?(@types[_1].type) || @encrypted.include?(_1) }.to_set
          # The attributes whose value, when the entry holds it as this Ruby
          # class, is already what the type reads (an integer, a string, a
          # boolean): not passed through the type.
          @as_is = @names.filter_map do |name|
            next if @encrypted.include?(name)

            klass = as_is_class(@types[name])
            [name, klass] if klass
          end.to_h
        end

        def current? = @types.equal?(@model_class.attribute_types)

        def attribute_name(key)
          name = key.to_s
          @aliases.fetch(name, name)
        end

        # The class a record of these event attributes is: an STI subclass
        # when its inheritance column names one (its enums and serialized
        # attributes are its own).
        def class_for(attributes)
          return @model_class unless @sti

          type_name = attributes[@inheritance_column] || attributes[@inheritance_column.to_sym]
          return @model_class if type_name.nil? || type_name == "" || type_name == @model_class.sti_name

          @subclasses.fetch(type_name) do
            @subclasses[type_name] =
              begin
                @model_class.sti_class_for(type_name)
              rescue ActiveRecord::SubclassNotFound, NameError
                @model_class
              end
          end
        end

        # The value of +name+ in the record that +attributes+ (a cache
        # entry's, as the table holds them) build, without building it.
        def event_value(attributes, name)
          value = attributes.fetch(name) { attributes[name.to_sym] }
          return nil if value.nil?
          return value if (klass = @as_is[name]) && klass === value

          type = @types[name]
          return type.deserialize(value) unless value.is_a?(String) && @memoized.include?(name)

          memo = @memo[name]
          memo.fetch(value) do
            memo.clear if memo.size >= MEMO_LIMIT
            read = type.deserialize(value)
            # Only compared: a datetime as a plain UTC time, which compares faster.
            read = read.utc if read.is_a?(ActiveSupport::TimeWithZone) && type.type != :time
            memo[value.frozen? ? value : value.dup.freeze] = read
          end
        end

        private

        BOOLEAN = ->(value) { true.equal?(value) || false.equal?(value) }
        private_constant :BOOLEAN

        def as_is_class(type)
          case type
          when ActiveModel::Type::Integer then Integer
          when ActiveModel::Type::ImmutableString then String
          when ActiveModel::Type::Boolean then BOOLEAN
          end
        end

        def enum?(type) = type.is_a?(ActiveRecord::Enum::EnumType)

        def blank_padded?(model_class, name)
          column = model_class.columns_hash[name] if model_class.respond_to?(:columns_hash)
          column&.sql_type.to_s.match?(/\A(character|char|bpchar)(\(\d+\))?\z/i)
        rescue StandardError
          false
        end
        def serialized?(type) = type.is_a?(ActiveRecord::Type::Serialized)

        def nondeterministic?(type)
          defined?(ActiveRecord::Encryption::EncryptedAttributeType) &&
            type.is_a?(ActiveRecord::Encryption::EncryptedAttributeType) && !type.deterministic?
        end

        def encrypted_names(model_class)
          return Set.new unless model_class.respond_to?(:encrypted_attributes)

          Array(model_class.encrypted_attributes).to_set(&:to_s)
        end
      end

      SCHEMAS = ObjectSpace::WeakKeyMap.new
      SCHEMAS_LOCK = Mutex.new

      # A condition on one attribute, compiled: +test+ takes the attribute's
      # value and answers true, false or nil.
      Condition = Struct.new(:name, :test) do
        def evaluate(reader, source) = test.call(reader.read(source, name))
      end

      # A tuple condition, where([:a, :b] => [[1, 2], ...]), as Active Record
      # builds for a record's query constraints (an association's
      # delete(record)): the record matches one of the tuples.
      TupleCondition = Struct.new(:tuples) do
        def evaluate(reader, source)
          TypedValues.any_of(tuples.map { |tests| tests ? TypedValues.all_of(tests.map { _1.evaluate(reader, source) }) : false })
        end
      end

      # Reads a built record's attribute (CachedRelation).
      module RecordReader
        def self.read(record, name) = record.read_attribute(name)
      end

      # Reads an attribute from event attributes (CachedProjection), as the
      # record they build would hold it.
      class EventReader
        def initialize(model_class)
          @schema = TypedValues.schema(model_class)
        end

        def read(attributes, name)
          return @schema.event_value(attributes, name) unless @schema.sti

          klass = @schema.class_for(attributes)
          schema = klass.equal?(@schema.model_class) ? @schema : TypedValues.schema(klass)
          schema.event_value(attributes, name)
        end
      end

      module_function

      def schema(model_class)
        found = SCHEMAS[model_class]
        return found if found&.current?

        SCHEMAS_LOCK.synchronize { SCHEMAS[model_class] = Schema.new(model_class) }
      end

      def attribute_name(model_class, key) = schema(model_class).attribute_name(key)

      # The condition +key+ => +value+ on +model_class+, compiled once for
      # every record it is tested on (Condition, TupleCondition). A condition
      # on a name that is not an attribute is refused, as the table refuses
      # it (an unknown column).
      def condition(model_class, key, value)
        if key.is_a?(Array)
          tuples = Array(value).map do |tuple|
            tuple = Array(tuple)
            key.zip(tuple).map { |column, v| condition(model_class, column, v) } if tuple.size == key.size
          end
          return TupleCondition.new(tuples)
        end

        facts = schema(model_class)
        name = facts.attribute_name(key)
        raise UnsupportedQuery.new(model_class, "a condition on #{key}, which is not an attribute") unless facts.names.include?(name)

        value = normalize(value)
        type = facts.types[name]
        padded = facts.blank_padded.include?(name)
        value = unpadded(value) if padded
        test =
          if facts.nondeterministic.include?(name)
            ciphertext_test(model_class, name, value)
          elsif facts.serialized.include?(name)
            serialized_test(model_class, name, type, value)
          else
            time_of_day_test(type, value_test(type, value))
          end
        test = unpadded_test(test) if padded
        Condition.new(name, test)
      end

      # A serialized attribute's value as the table holds it: the text its
      # coder writes (nil for NULL, which a default value is stored as).
      # Equality and IN compare those texts; a range or a pattern on them
      # is refused.
      def serialized_test(model_class, name, type, value)
        if value.is_a?(Range) || value.is_a?(Regexp) || (value.is_a?(Array) && value.any? { _1.is_a?(Range) || _1.is_a?(Regexp) })
          raise UnsupportedQuery.new(model_class, "a range or pattern on #{name}, which is serialized")
        end

        texts = value.is_a?(Array) ? value.map { serialized_text(type, _1) } : serialized_text(type, value)
        test = value_test(TEXT, texts)
        ->(stored) { test.call(stored.nil? ? nil : serialized_text(type, stored)) }
      end

      def serialized_text(type, value)
        return nil if value.nil?

        text = type.serialize(value)
        text&.to_s
      end

      # character(n): trailing spaces are not part of the value.
      def unpadded(value)
        case value
        when String then value.sub(/ +\z/, "")
        when Array then value.map { unpadded(_1) }
        when Range then Range.new(unpadded(value.begin), unpadded(value.end), value.exclude_end?)
        else value
        end
      end

      def unpadded_test(test)
        ->(stored) { test.call(stored.is_a?(String) ? unpadded(stored) : stored) }
      end

      # A time column holds a time of day, in UTC: the record's value (a
      # time on 2000-01-01 in Time.zone, which wraps at midnight) is compared
      # as its time of day in UTC, as the bound value is (query_value).
      def time_of_day_test(type, test)
        return test unless type.type == :time

        ->(stored) { test.call(stored && time_of_day(stored)) }
      end

      # Microseconds since midnight UTC.
      def time_of_day(time)
        time = time.utc
        (((time.hour * 60) + time.min) * 60 + time.sec) * 1_000_000 + time.usec
      end

      # Whether every one of +conditions+ holds for +source+, as SQL's AND:
      # true, false (at the first that fails) or nil.
      def all_hold(conditions, reader, source)
        unknown = false
        conditions.each do |condition|
          result = condition.evaluate(reader, source)
          return false if false.equal?(result)

          unknown = true if result.nil?
        end
        unknown ? nil : true
      end

      # A record, or a relation of records, stands for its primary key, as in
      # Active Record: where(variant_id: [variant]) matched nothing, and
      # Solidus's stock check found no stock under ES-NoProj.
      def normalize(value)
        value = value.to_a if value.is_a?(ActiveRecord::Relation) || value.is_a?(CachedRelation) || value.is_a?(Set)
        value = value.id if value.is_a?(ActiveRecord::Base)
        value = value.map { |v| v.is_a?(ActiveRecord::Base) ? v.id : v } if value.is_a?(Array)
        value
      end

      # A test of an attribute's value against +value+, a condition's value
      # on an attribute of +type+.
      def value_test(type, value)
        case value
        when Array then list_test(type, value)
        when Range then range_test(type, value)
        when nil then ->(stored) { stored.nil? }
        when Regexp then ->(stored) { stored.nil? ? nil : stored.to_s.match?(value) }
        else
          bound = query_value(type, value)
          return ->(_) { false } if bound.equal?(OUT_OF_RANGE)
          # Active Record binds such a value as IS NULL when the type wraps
          # another (an enum's unknown label, a serialized default), else as
          # = NULL, which no row satisfies (Relation::QueryAttribute#nil?).
          return ->(stored) { stored.nil? } if bound.equal?(NULL) && wraps_a_type?(type)
          return ->(_) { nil } if bound.equal?(NULL)
          return ->(stored) { stored.nil? ? nil : false } if bound.equal?(UNREADABLE)
          # An integer or a string equals what it is ==: no <=> needed.
          return ->(stored) { stored.nil? ? nil : stored == bound } if bound.is_a?(Integer) || bound.is_a?(String)

          ->(stored) { stored.nil? ? nil : (cmp = compare(stored, bound)) ? cmp.zero? : false }
        end
      end

      # A non-deterministically encrypted attribute: the table holds a
      # ciphertext no bound value can equal, so an equality finds no row
      # (and IS NULL its NULLs), as on the table; an order or a pattern on
      # ciphertexts has no answer here, and is refused.
      def ciphertext_test(model_class, name, value)
        case value
        when nil then ->(stored) { stored.nil? }
        when Array
          tests = value.map { ciphertext_test(model_class, name, _1) }
          ->(stored) { any_of(tests.map { _1.call(stored) }) }
        when Range, Regexp
          raise UnsupportedQuery.new(model_class, "a range or pattern on #{name}, which is encrypted non-deterministically")
        else ->(stored) { stored.nil? ? nil : false }
        end
      end

      # A list of values, as Active Record builds its condition
      # (PredicateBuilder::ArrayHandler): one value is an equality; two or
      # more are an IN of those the type binds (HomogeneousIn: a value it
      # binds as NULL or cannot bind is left out, and with none left the IN
      # is IN (NULL), unknown); a nil adds OR IS NULL, a range OR BETWEEN.
      # So where.not(rank: [9, "abc"]) is NOT IN (9): it used to be unknown
      # for every row. A list of integers or strings (ids, codes) is looked
      # up in a set.
      def list_test(type, values)
        return ->(_) { false } if values.empty?
        if values.any? { _1.is_a?(Array) || _1.is_a?(Regexp) }
          tests = values.map { value_test(type, _1) }
          return ->(stored) { any_of(tests.map { _1.call(stored) }) }
        end

        scalars = values.reject { _1.nil? || _1.is_a?(Range) }
        tests = []
        tests << (scalars.size == 1 ? value_test(type, scalars.first) : homogeneous_test(type, scalars)) if scalars.any?
        tests << ->(stored) { stored.nil? } if values.any?(&:nil?)
        values.each { tests << range_test(type, _1) if _1.is_a?(Range) }
        return tests.first if tests.size == 1

        ->(stored) { any_of(tests.map { _1.call(stored) }) }
      end

      # IN over two or more values (Arel::Nodes::HomogeneousIn#casted_values:
      # the values the type cannot bind, or binds as NULL, are left out; with
      # none left, IN (NULL)). A value bound but not readable back (5 on an
      # enum without that label) stays a member, which no row equals.
      def homogeneous_test(type, values)
        bound = values.map { query_value(type, _1) }.reject { _1.equal?(NULL) || _1.equal?(OUT_OF_RANGE) }
        return ->(_) { nil } if bound.empty?

        bounds = bound.reject { _1.equal?(UNREADABLE) }
        return ->(stored) { stored.nil? ? nil : false } if bounds.empty?

        if bounds.all? { _1.is_a?(Integer) || _1.is_a?(String) }
          set = bounds.to_set
          return ->(stored) { stored.nil? ? nil : set.include?(stored) }
        end

        ->(stored) { stored.nil? ? nil : bounds.any? { |bound| (cmp = compare(stored, bound)) && cmp.zero? } }
      end

      def wraps_a_type?(type) = type.respond_to?(:subtype) || type.respond_to?(:normalizer)

      # +value+ as Active Record binds it for a condition on +type+ (the
      # type serializes it), read back as a record holds it (the type
      # deserializes it); NULL when it binds NULL, OUT_OF_RANGE when it
      # cannot be bound. So an enum compares in its column's domain
      # (where(status: "0") is the label of 0), a decimal at its scale, a
      # deterministically encrypted attribute as its ciphertext's plaintext
      # (downcased, if it is), and a time-zone-aware time as the database
      # reads the bound value: a string or a date in its own clock (Active
      # Record's default_timezone), not in Time.zone.
      def query_value(type, value)
        return nil if value.nil?
        return OUT_OF_RANGE unless type.serializable?(value)

        bound = type.serialize(value)
        return NULL if bound.nil?
        return time_of_day(bound) if type.type == :time && bound.respond_to?(:utc)

        result = type.deserialize(bound)
        return UNREADABLE if result.nil?

        return result unless TIME_TYPES.include?(type.type)

        # A plain UTC time: the same instant, and cheaper to compare a
        # record's time with than a time in a zone.
        result = clock_time(result)
        result.respond_to?(:utc) ? result.utc : result
      rescue ActiveModel::RangeError
        OUT_OF_RANGE
      end

      # A date given for a time-zone-aware column is its midnight in the
      # database's clock, as the database reads '2026-02-01'.
      def clock_time(value)
        return value unless value.is_a?(Date) && !value.is_a?(DateTime)

        if ActiveRecord.default_timezone == :utc
          Time.utc(value.year, value.month, value.day)
        else
          Time.local(value.year, value.month, value.day)
        end
      end

      # BETWEEN, with an endless or infinite end unbounded.
      def range_test(type, range)
        low = range_end(type, range.begin)
        high = range_end(type, range.end)
        # Out of the column's range: a begin above it or an end below it
        # selects nothing; one below or above it leaves that side open.
        return ->(_) { false } if low.equal?(OUT_OF_RANGE) && (range.begin <=> 0) == 1
        return ->(_) { false } if high.equal?(OUT_OF_RANGE) && (range.end <=> 0) == -1

        low = nil if low.equal?(OUT_OF_RANGE)
        high = nil if high.equal?(OUT_OF_RANGE)
        return ->(_) { nil } if low.equal?(NULL) || high.equal?(NULL) || low.equal?(UNREADABLE) || high.equal?(UNREADABLE)

        exclusive = range.exclude_end?
        lambda do |stored|
          next nil if stored.nil?

          above = low.nil? || ((cmp = compare(stored, low)) && cmp >= 0)
          below = high.nil? || ((cmp = compare(stored, high)) && (exclusive ? cmp.negative? : cmp <= 0))
          (above && below) ? true : false
        end
      end

      def range_end(type, value)
        return nil if value.nil? || (value.respond_to?(:infinite?) && value.infinite?)

        query_value(type, value)
      end

      # The value bound in an SQL fragment ("col OP ?") on +name+. Active
      # Record quotes it, not casting it through the attribute's type, and
      # the database casts the literal to the column's type: a number is
      # compared as it is (qty >= 2.5, amount = 250.004: no rounding to the
      # column's scale), a string that is not one of the column's values
      # is an error (fail closed: refused), and a time-zone-aware column
      # reads a string or a date in the database's clock. nil for NULL.
      def fragment_value(model_class, name, value)
        facts = schema(model_class)
        type = facts.types[name]
        if facts.nondeterministic.include?(name)
          raise UnsupportedQuery.new(model_class, "an SQL fragment on #{name}, which is encrypted non-deterministically")
        end
        return nil if value.nil?

        case type.type
        when *TIME_TYPES, :date
          bound = query_value(type, value)
          bound.equal?(NULL) || bound.equal?(OUT_OF_RANGE) || bound.equal?(UNREADABLE) ? nil : bound
        when :integer, :decimal, :float
          return type.cast(value) if facts.enums.include?(name)

          numeric_literal(model_class, name, type.type, value)
        else
          type.cast(value)
        end
      end

      def numeric_literal(model_class, name, kind, value)
        case value
        when Integer then value
        # Quoted ('2.5', '3.0'): the database reads a numeric column's
        # literal, and rejects it for an integer column.
        when Float, BigDecimal, Rational then kind == :integer ? raise(ArgumentError) : value
        when String
          stripped = value.strip
          case kind
          when :integer then Integer(stripped, 10)
          when :float then Float(stripped)
          else BigDecimal(stripped)
          end
        else raise ArgumentError
        end
      rescue ArgumentError, TypeError
        raise UnsupportedQuery.new(model_class, "an SQL fragment comparing #{name} (#{kind}) with #{value.inspect[0, 40]}, " \
                                                "which the database rejects")
      end

      # <=> on two values of one attribute; booleans compare as false < true,
      # as in SQL. nil when they cannot be compared.
      def compare(a, b)
        a = 1 if true.equal?(a)
        a = 0 if false.equal?(a)
        b = 1 if true.equal?(b)
        b = 0 if false.equal?(b)
        a <=> b
      end

      # SQL's OR and AND over true, false and nil (unknown).
      def any_of(results)
        return true if results.include?(true)

        results.include?(nil) ? nil : false
      end

      def all_of(results)
        return false if results.include?(false)

        results.include?(nil) ? nil : true
      end

      # How a record's value of +column+ is read for an order, worked out
      # once: the attribute's value, except an enum's, which is ordered by
      # the integer (or string) the column holds, not by its label.
      def sort_reader(model_class, column)
        facts = schema(model_class)
        name = facts.attribute_name(column)
        # The table rejects an order on a column it lacks (id, where the
        # primary key is code); it used to be ordered by the method's value.
        raise UnsupportedQuery.new(model_class, "an order on #{column}, which is not an attribute") unless facts.names.include?(name)

        if facts.encrypted.include?(name)
          # The table orders the ciphertexts, an order the plaintexts here
          # do not have: refused rather than answered in another order.
          raise UnsupportedQuery.new(model_class, "an order on #{name}, which is encrypted")
        end

        if facts.enums.include?(name)
          type = facts.types[name]
          ->(record) { type.serialize(record.read_attribute(name)) }
        else
          comparable_reader(model_class, name)
        end
      end

      # How a record's value of the attribute +name+ is read to be compared
      # with a bound value: a time column's as its time of day in UTC.
      def comparable_reader(model_class, name)
        if schema(model_class).types[name].type == :time
          ->(record) { (value = record.read_attribute(name)) && time_of_day(value) }
        else
          ->(record) { record.read_attribute(name) }
        end
      end

      # +attributes+ (event attributes) as the table holds them, for
      # instantiate: an enum's label turned into the column's value, a
      # serialized attribute's Hash into its text, as a projection writing
      # the row does (insert serializes). An enum's label read as the
      # column's integer was 0, the first label, for every record.
      # Encrypted attributes are left alone: the event holds their
      # ciphertext, as the row does. An STI record is converted with its
      # own class's types.
      def database_attributes(model_class, attributes)
        conversions = conversions_for(model_class, attributes)
        return attributes if conversions.empty? || conversions.none? { |name, _| !attributes[name].nil? }

        convert_event_values!(model_class, attributes.dup, nil)
      end

      # Converts, in place, the values of +names+ (nil: all) in +attributes+
      # from the events' form to the table's (database_attributes).
      def convert_event_values!(model_class, attributes, names)
        conversions = conversions_for(model_class, attributes)
        return attributes if conversions.empty?

        conversions.each do |name, type|
          next if names && !names.include?(name)

          value = attributes[name]
          attributes[name] = type.serialize(value) unless value.nil?
        end
        attributes
      end

      def conversions_for(model_class, attributes)
        facts = schema(model_class)
        klass = facts.class_for(attributes)
        klass.equal?(model_class) ? facts.conversions : schema(klass).conversions
      end
    end
  end
end
