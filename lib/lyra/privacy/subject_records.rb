# frozen_string_literal: true

module Lyra
  module Privacy
    # The data subject's records for the Art. 15 copy (from 1.0.0), as
    # PamDsl::GDPRCompliance's records_reader gives them: which records are
    # the subject's, their values now, and their stored history.
    #
    # Selection: a record is the subject's by what it is, not by which of its
    # events repeat the foreign key.
    # - Rows: the subject's own row (the model named by the subject type),
    #   and, in each monitored model that links to the subject
    #   (Lyra::Privacy::SubjectLinks: a belongs_to to the subject's class,
    #   polymorphic included, or the <type>_id column), the rows that name
    #   them, by indexed queries. A row that pre-dates monitoring, never
    #   imported, is found this way.
    # - Events: every record the subject's events touch (the GDPR helpers'
    #   one batched pass over the log), so a destroyed record, a record of an
    #   events-only model (ES-NoProj) and one that has since moved to someone
    #   else are found by their create, import or move.
    #
    # Periods. A related record is the subject's while one of its links
    # names them. Each event of its stream is inside a period, outside it,
    # or a transition: the event that moves the record in (its new values are
    # the subject's, not the old ones) or away (its old values are the
    # subject's, not the new ones). The history gives events inside the
    # periods whole, a transition only the subject's side of it (the link's
    # new value on a move away reads "moved to another person"), and nothing
    # outside; +periods+ lists the periods when they are not the whole stream.
    #
    # Values: the row's, read as Lyra (encrypted columns come back in
    # plaintext as Active Record decrypts them), +state+ :current; or, with
    # no row or in ES-NoProj and ES-Async, the state replayed from the
    # stream: :replayed, or :destroyed with the last state before the
    # destroy; or, for a record whose links no longer name the subject,
    # :reassigned with the state just before it moved away. A value last set
    # outside the subject's periods (by or for another person) is not given:
    # its field is listed in +set_outside_periods+. Encrypted values in the
    # log are opened.
    #
    # History: each change as { at:, operation:, field:, from:, to:, actor: },
    # a create or an import giving each attribute (from nil), a destroy one
    # entry with no field, any other event in a period (ErasureApplied, a
    # domain event) one entry naming it, with no values.
    class SubjectRecords
      MOVED_AWAY = "moved to another person"

      # Each event of a related record's stream with its kind (:inside, :in,
      # :away or :outside the subject's periods), and the link columns'
      # values after the last event. +initial+ holds the columns' values
      # before the stream, where known (a row the stream never changed); a
      # change of a column gives its value before the change.
      def self.classify(events, links:, model:, subject_id:, initial: {})
        columns = links.columns(model)
        values = initial.dup
        touched = []
        classified = events.map do |event|
          data = event.data.is_a?(Hash) ? event.data : {}
          operation = Lyra::Event.operation_of(event)
          changes = operation == :updated ? (data[:changes] || data["changes"] || {}) : {}
          columns.each do |column|
            next if touched.include?(column) || !change_for(changes, column)

            values[column] = Array(change_for(changes, column)).first
          end
          # Before its create or import the record named no one.
          before = %i[created imported].include?(operation) ? false : links.names?(model, values, subject_id)
          case operation
          when :created, :imported
            attributes = Lyra::Event.created_attributes(data)
            columns.each { |column| values[column] = value_for(attributes, column) }
            touched |= columns
          when :updated
            columns.each do |column|
              change = change_for(changes, column)
              next unless change

              values[column] = change.is_a?(Array) ? change.last : change
              touched |= [column]
            end
          end
          after = links.names?(model, values, subject_id)
          [event, before ? (after ? :inside : :away) : (after ? :in : :outside)]
        end
        [classified, values]
      end

      def self.change_for(changes, column)
        changes.key?(column) ? changes[column] : changes[column.to_sym]
      end

      def self.value_for(hash, column)
        hash.key?(column) ? hash[column] : hash[column.to_sym]
      end

      def initialize(subject_id, subject_type, events, history: true)
        @subject_id = subject_id
        @subject_type = subject_type.to_s
        @events = events
        @history = history
        @links = SubjectLinks.new(@subject_type)
      end

      def call
        candidates.filter_map { |candidate| collect(*candidate) }
      end

      private

      # [model class or name, id, row or nil], each record once.
      def candidates
        found = {}
        add = lambda do |model, id, row = nil|
          entry = (found[stream_for(model, id)] ||= [model, id, nil])
          entry[2] ||= row
        end

        Lyra::PurposeBoundReads.internal(INTERNAL) do
          Lyra::Projections::LazyProjection.catch_up! if lazy?
          unless events_only?
            own_row&.then { |row| add.call(own_model, row.id, row) }
            @links.linked_models.each do |model|
              @links.rows(model, @subject_id).each { |row| add.call(model, row.id, row) }
            end
          end
          @events.each do |event|
            id = event_model_id(event)
            next if id.nil?

            model = model_named(event_model_class(event))
            add.call(model, id) if model
          end
          # A record the events found, in a model with a table: its row, if any.
          found.each do |key, (model, id, row)|
            next if row || events_only? || !table?(model)

            found[key][2] = model.unscoped.find_by(model.primary_key => id)
          end
        end
        found.values
      end

      def collect(model, id, row)
        events = read_stream(stream_for(model, id))
        own = own_record?(model, id)
        if own
          classified = events.map { |event| [event, :inside] }
          names_now = true
        else
          initial = row ? @links.columns(model).to_h { |column| [column, row_value(row, column)] } : {}
          classified, final = self.class.classify(events, links: @links, model: model, subject_id: @subject_id,
                                                          initial: initial)
          names_now = @links.names?(model, final, @subject_id)
        end
        kept = classified.reject { |_event, kind| kind == :outside }
        return nil if kept.empty? && !(row && names_now)

        replay = replay(model, classified)
        state, as_of, attributes, mine = state_of(model, row, replay, kept, own || names_now)
        {
          model: model_name(model), id: id, state: state, as_of: as_of, attributes: attributes,
          set_outside_periods: outside_fields(model, attributes, mine),
          history_from: kept.first && timestamp(kept.first.first),
          periods: own ? nil : periods(classified),
          history: @history ? kept.flat_map { |event, kind| history_entries(model, event, kind) } : nil
        }
      end

      # The record's state: the row (:current) unless the log is the truth
      # here, else the replayed state; :reassigned when the record no longer
      # names the subject. With it, which fields the subject's periods set.
      def state_of(model, row, replay, kept, names_now)
        if !names_now && kept.any?
          return [:reassigned, replay[:away_at], open(model, replay[:away_state]), replay[:away_mine]]
        end
        if row && !(replay_preferred? && replay[:any])
          return [:current, Time.current, open(model, row.attributes), replay[:mine]]
        end
        return [:current, Time.current, {}, {}] unless replay[:any]

        [replay[:destroyed] ? :destroyed : :replayed, replay[:last_at], open(model, replay[:state]), replay[:mine]]
      end

      # The stream replayed, each field remembering whether the subject's
      # periods set it; and the state just before the last move away.
      def replay(_model, classified)
        state = {}
        mine = {}
        result = { any: false, destroyed: false }
        classified.each do |event, kind|
          operation = Lyra::Event.operation_of(event)
          next unless operation

          data = event.data.is_a?(Hash) ? event.data : {}
          if kind == :away
            result.merge!(away_state: state.dup, away_mine: mine.dup, away_at: timestamp(event))
          end
          ours = %i[inside in].include?(kind)
          case operation
          when :created, :imported
            state = Lyra::Event.created_attributes(data).to_h.transform_keys(&:to_s)
            mine = state.keys.to_h { |field| [field, ours] }
          when :updated
            (data[:changes] || data["changes"] || {}).each do |field, change|
              state[field.to_s] = change.is_a?(Array) ? change.last : change
              mine[field.to_s] = ours
            end
          end
          result.merge!(any: true, destroyed: operation == :destroyed, last_at: timestamp(event))
        end
        result.merge(state: state, mine: mine)
      end

      # The fields whose value the subject's periods did not set; the
      # record's key and links are never among them.
      def outside_fields(model, attributes, mine)
        keep = [primary_key(model), *@links.columns(model)].compact
        attributes.keys.select { |field| mine[field] == false && !keep.include?(field) }
      end

      def periods(classified)
        kinds = classified.map(&:last)
        throughout = !kinds.include?(:away) && !kinds.include?(:outside) &&
                     kinds.each_with_index.none? { |kind, i| kind == :in && i.positive? }
        return nil if throughout

        classified.each_with_object([]) do |(event, kind), periods|
          at = timestamp(event)
          case kind
          when :in then periods << { from: at, to: nil }
          when :inside, :away
            periods << { from: nil, to: nil } if periods.empty? || periods.last[:to]
            periods.last[:to] = at if kind == :away
          end
        end
      end

      def history_entries(model, event, kind)
        data = event.data.is_a?(Hash) ? event.data : {}
        at = timestamp(event)
        actor = actor_of(event)
        operation = Lyra::Event.operation_of(event)
        links = @links.columns(model)
        case operation
        when :created, :imported
          open(model, Lyra::Event.created_attributes(data).to_h).map do |field, value|
            { at: at, operation: operation, field: field.to_s, from: nil, to: value, actor: actor }
          end
        when :updated
          (data[:changes] || data["changes"] || {}).map do |field, change|
            from, to = change.is_a?(Array) ? change : [nil, change]
            entry = { at: at, operation: operation, field: field.to_s, actor: actor }
            case kind
            when :in then entry[:to] = open_value(model, field, to)
            when :away
              entry[:from] = open_value(model, field, from)
              entry[:to] = MOVED_AWAY if links.include?(field.to_s)
            else
              entry[:from] = open_value(model, field, from)
              entry[:to] = open_value(model, field, to)
            end
            entry
          end
        when :destroyed
          [{ at: at, operation: operation, field: nil, from: nil, to: nil, actor: actor }]
        else
          [{ at: at, operation: nil, event: event.event_type.to_s.demodulize, field: nil, from: nil, to: nil, actor: actor }]
        end
      end

      # Who wrote the event: the ids its metadata records (Lyra::Event#user_id
      # reads both places Lyra has kept them).
      def actor_of(event)
        metadata = event.metadata.to_h
        nested = event.data.is_a?(Hash) ? (event.data[:metadata] || event.data["metadata"] || {}) : {}
        %i[user_id ip_address user_type].to_h do |key|
          [key, nested[key] || nested[key.to_s] || metadata[key] || metadata[key.to_s]]
        end.compact
      end

      def open(model, attributes)
        attributes = attributes.to_h.transform_keys(&:to_s)
        model.is_a?(Class) ? Lyra::EncryptedAttributes.open(model, attributes) : attributes
      end

      def open_value(model, field, value)
        open(model, { field.to_s => value })[field.to_s]
      end

      def timestamp(event)
        data = event.data.is_a?(Hash) ? event.data : {}
        data[:timestamp] || data["timestamp"] || event.metadata[:timestamp]
      end

      def read_stream(stream)
        Lyra.config.event_store.read.stream(stream).to_a
      rescue RubyEventStore::EventNotFoundInStream
        []
      end

      def row_value(row, column)
        row.has_attribute?(column) ? row[column] : nil
      end

      def primary_key(model)
        model.is_a?(Class) ? model.primary_key.to_s : "id"
      rescue StandardError
        "id"
      end

      # The subject's own model, if the subject type names one with a table.
      def own_model
        model = @links.subject_model
        model && table?(model) ? model : nil
      end

      def own_row
        own_model&.unscoped&.find_by(own_model.primary_key => @subject_id)
      end

      def own_record?(model, id)
        model_name(model) == model_name(@links.subject_model || @subject_type) && id.to_s == @subject_id.to_s
      end

      def model_named(name)
        return nil if name.nil? || name.to_s.empty?

        model = Lyra.config.monitored_model_named(name) || name.to_s.safe_constantize
        model.is_a?(Class) && model < ActiveRecord::Base ? model : name.to_s
      end

      def model_name(model)
        model.is_a?(Class) ? Lyra.stream_owner_name(model) : model.to_s
      end

      def stream_for(model, id)
        model.is_a?(Class) ? Lyra.stream_name(model, id) : "#{model}$#{id}"
      end

      def event_model_class(event)
        event.data.is_a?(Hash) ? (event.data[:model_class] || event.data["model_class"]) : nil
      end

      def event_model_id(event)
        event.data.is_a?(Hash) ? (event.data[:model_id] || event.data["model_id"]) : nil
      end

      def table?(model)
        model.is_a?(Class) && model.table_exists?
      rescue StandardError
        false
      end

      def events_only?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :disabled
      end

      def lazy?
        Lyra.config.event_sourcing_mode? && Lyra.config.projection_mode == :lazy
      end

      # ES-NoProj has no rows, and ES-Async's may not have caught up yet: the
      # log is read for their values.
      def replay_preferred?
        Lyra.config.event_sourcing_mode? && %i[disabled async].include?(Lyra.config.projection_mode)
      end
    end
  end
end
