# frozen_string_literal: true

module PamDsl
  # The Art. 15 copy that GDPRCompliance#data_export returns beside its
  # event summaries: the subject's records whole (+records+), the access log
  # (+accesses+), the context the policy declares (+processing_context+), the
  # controller's +notice+, and the +gaps+ the policy leaves.
  #
  # Which records are the subject's, their values and their history come from
  # the store (GDPRCompliance's records_reader; without one, they are rebuilt
  # from the subject's events). What this class adds is the policy's part:
  # a field declared withheld_from_access: is named with its basis instead of
  # its value, a field about another person goes to +review+, who acted is a
  # role label, and the purposes, bases, recipients, transfers, retention and
  # sources are the declared ones, each undeclared item a gap rather than an
  # empty value.
  class SubjectAccess
    SUBJECT_SOURCE = "the data subject"

    # Who acted, as the subject is told it. An actor is { user_id:,
    # ip_address:, user_type: }.
    # - "system": the event names no one.
    # - "you": the actor's id and class (user_type) are the subject's.
    # - "staff or you": the id is the subject's but the event records no
    #   class, so it may be another class's record with the same id.
    # - "staff": anyone else.
    # An actor of another class that is the subject's own login (a User
    # account of a Person subject) reads "staff"; an application with such a
    # mapping passes actor_label:.
    DEFAULT_ACTOR_LABEL = lambda do |actor, subject|
      actor ||= {}
      id = actor[:user_id]
      next "system" if id.nil? || id.to_s.empty?
      next "staff" unless id.to_s == subject[:id].to_s

      type = actor[:user_type]
      next "staff or you" if type.nil? || type.to_s.empty?

      type.to_s == subject[:type].to_s ? "you" : "staff"
    end

    # The basis given, under +withheld+, for a value set while a moved record
    # was another person's: it is not the subject's data.
    OTHER_PERIOD = "set while the record was another person's"

    # Columns no policy declaration covers: no purpose, basis or retention is
    # stated for them. The record's own id is left out.
    UNDECLARED = "not declared in the policy (no purpose, basis or retention stated)"

    def initialize(subject:, policy_for:, actor_label: nil, disclose_actors: false)
      @subject = subject
      @policy_for = policy_for
      @actor_label = actor_label || DEFAULT_ACTOR_LABEL
      @disclose_actors = disclose_actors
    end

    # A store's record ({ model:, id:, state:, as_of:, attributes:,
    # history_from:, periods:, history: [entry] or nil }, each history entry
    # { at:, operation:, field:, from:, to:, actor:, event: }) as the copy
    # gives it.
    def record(raw)
      policy = @policy_for.call(raw[:model])
      attributes = stringify(raw[:attributes])
      history = raw[:history]&.map { |entry| stringify_field(entry) }
      withheld_fields = fields_where(policy, attributes, history, &:withheld_from_access?)
      other_period = Array(raw[:set_outside_periods]).map(&:to_s) - withheld_fields
      review_fields = fields_where(policy, attributes, history, &:about_another_person?) - withheld_fields - other_period
      set_aside = withheld_fields + review_fields

      {
        model: raw[:model].to_s,
        id: raw[:id],
        state: raw[:state],
        as_of: raw[:as_of],
        attributes: attributes.except(*set_aside, *other_period),
        withheld: withheld_fields.map { |f| { field: f, basis: policy.fields[f.to_sym].withheld_from_access } } +
                  other_period.map { |f| { field: f, basis: OTHER_PERIOD } },
        review: review_fields.map { |f| review_entry(policy, f, attributes, history) },
        history_from: raw[:history_from],
        periods: raw[:periods],
        history: history&.reject { |entry| set_aside.include?(entry[:field]) }&.map { |entry| history_entry(entry) }
      }
    end

    # An access log entry as the copy gives it.
    def access(entry)
      presented = entry.except(:actor, :policy).merge(by: label(entry[:actor]))
      presented[:actor] = disclosed(entry[:actor]) if @disclose_actors
      presented.compact
    end

    # The purposes that admit the records' declared fields, with their bases,
    # recipients, transfers, retention and sources, one entry per policy and
    # purpose.
    def processing_context(records)
      contexts = {}
      records.each do |record|
        policy = @policy_for.call(record[:model])
        next unless policy

        model = record[:model].to_s
        fields = declared_fields(policy, record)
        policy.purposes.each_value do |purpose|
          admitted = fields.select { |f| policy.allowed?(f, purpose.name) }
          next if admitted.empty?

          context = (contexts[[policy.name, purpose.name]] ||= context_for(policy, purpose))
          context[:fields][model] = (context[:fields].fetch(model, []) | admitted).sort
          admitted.each do |f|
            category = policy.fields[f.to_sym].type.to_s
            context[:data_categories] << category unless context[:data_categories].include?(category)
            source = policy.fields[f.to_sym].collected_from
            context[:sources]["#{model}.#{f}"] = source_text(source) if source
          end
          context[:retention][model] = retention(policy, model, context[:fields][model])
        end
      end
      contexts.values
    end

    # What the copy cannot state because the policy does not declare it, as
    # [purpose name or nil, the item].
    def gaps(records, contexts, notice)
      gaps = []
      gaps << [nil, "no records: nothing is held about the subject"] if records.empty?
      records.each do |record|
        policy = @policy_for.call(record[:model])
        model = record[:model].to_s
        unless policy
          gaps << [nil, "no privacy policy for #{model}: purposes, bases and retention not declared"]
          next
        end

        declared_fields(policy, record).each do |f|
          field = policy.fields[f.to_sym]
          gaps << [nil, "Art. 15(1)(g) source not declared: #{model}.#{f}"] unless field.collected_from
          gaps << [nil, "Art. 15(1)(a) no purpose declared for #{model}.#{f}"] if policy.purposes.values.none? { |p| policy.allowed?(f, p.name) }
        end
        gaps << [nil, "Art. 15(1)(d) retention not declared: #{model}"] if policy.declared_retention_for(model).nil?
        undeclared = (stringify(record[:attributes]).keys - ["id"]).reject { |f| policy.fields.key?(f.to_sym) }.sort
        gaps << [nil, "#{UNDECLARED}: #{undeclared.map { |f| "#{model}.#{f}" }.join(', ')}"] if undeclared.any?
      end
      contexts.each do |context|
        purpose = context[:purpose]
        gaps << [purpose, "Art. 6(1) legal basis (undetermined)"] if context[:legal_basis] == Purpose::UNDETERMINED
        gaps << [purpose, "Art. 15(1)(c) recipients"] if context[:recipients].nil?
        gaps << [purpose, "Art. 15(2) transfers to third countries"] if context[:transfers].nil?
      end
      Policy::ACCESS_NOTICE_ITEMS.each { |item, gap| gaps << [nil, gap] if notice[item].nil? }
      gaps.uniq
    end

    # The notice of the policies that govern the subject's records: each
    # item's text, or an array of the texts when the policies differ.
    def notice(policies)
      Policy::ACCESS_NOTICE_ITEMS.keys.to_h do |item|
        texts = policies.filter_map { |policy| policy.access_notice[item] }.uniq
        [item, texts.size > 1 ? texts : texts.first]
      end
    end

    def self.legal_basis_label(basis)
      GDPRCompliance::LEGAL_BASIS_LABELS[basis&.to_sym]
    end

    def self.format_duration(duration)
      return nil if duration.nil?
      return duration.inspect if defined?(ActiveSupport::Duration) && duration.is_a?(ActiveSupport::Duration)

      duration
    end

    private

    def context_for(policy, purpose)
      {
        policy: policy.name,
        purpose: purpose.name,
        description: purpose.description.to_s.empty? ? nil : purpose.description,
        legal_basis: purpose.legal_basis,
        legal_basis_label: self.class.legal_basis_label(purpose.legal_basis),
        art9_bases: purpose.art9_bases.dup,
        fields: {},
        data_categories: [],
        recipients: purpose.recipients.empty? ? nil : purpose.recipients.dup,
        transfers: purpose.transfers&.map(&:dup),
        retention: {},
        sources: {}
      }
    end

    # The model's period and the periods of +fields+ that differ from it.
    # What the policy declares, not PAM's 7-year fallback: nil when nothing is
    # declared (a gap).
    def retention(policy, model, fields)
      period = policy.declared_retention_for(model)
      overrides = fields.filter_map do |f|
        own = policy.declared_retention_for(model, field_name: f)
        [f, self.class.format_duration(own)] if own != period
      end
      { period: self.class.format_duration(period), fields: overrides.to_h }
    end

    def source_text(source)
      source == :data_subject ? SUBJECT_SOURCE : source.to_s
    end

    # The record's fields the policy declares: its attributes and those its
    # history names, withheld and review fields included.
    def declared_fields(policy, record)
      names = stringify(record[:attributes]).keys
      names |= Array(record[:history]).filter_map { |entry| entry[:field]&.to_s }
      names.select { |name| policy.fields.key?(name.to_sym) }.sort
    end

    def fields_where(policy, attributes, history)
      return [] unless policy

      names = attributes.keys | Array(history).filter_map { |entry| entry[:field] }
      names.select { |name| (field = policy.fields[name.to_sym]) && yield(field) }.sort
    end

    def review_entry(policy, field, attributes, history)
      {
        field: field,
        about: policy.fields[field.to_sym].about,
        value: attributes[field],
        history: history&.select { |entry| entry[:field] == field }&.map { |entry| history_entry(entry) }
      }
    end

    def history_entry(entry)
      presented = entry.except(:actor).merge(by: label(entry[:actor]))
      presented[:actor] = disclosed(entry[:actor]) if @disclose_actors
      presented.delete(:event) if presented[:event].nil?
      presented
    end

    def label(actor)
      @actor_label.call(actor || {}, @subject)
    end

    def disclosed(actor)
      (actor || {}).slice(:user_id, :ip_address).compact
    end

    def stringify(hash)
      (hash || {}).to_h.transform_keys(&:to_s)
    end

    def stringify_field(entry)
      entry[:field].nil? ? entry : entry.merge(field: entry[:field].to_s)
    end
  end
end
