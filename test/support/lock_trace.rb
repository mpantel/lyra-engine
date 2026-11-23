# frozen_string_literal: true

# Records the order in which test threads are granted Lyra's locks, for trace
# conformance against the concurrency nets (benchmarks/petri-concurrent-
# writers/TRACE_CONFORMANCE_PLAN.md). Tests only; nothing in lib/ calls it.
#
# A step is recorded when its lock is granted: an advisory lock when
# AdvisoryLock's call returns, a row lock when its statement finishes, a stream
# head when its INSERT or UPDATE finishes. A commit is recorded when COMMIT is
# sent, before the locks are released, so a lock another thread is granted
# after it is recorded after it too. Each lock is recorded once per
# transaction (advisory and row locks are reentrant).
module LockTrace
  Step = Struct.new(:seq, :actor, :action, :detail) do
    def to_s = "#{seq.to_s.rjust(3)} #{actor} #{action}#{" #{detail}" if detail}"
  end

  @mutex = Mutex.new
  @steps = nil
  @seq = 0

  class << self
    attr_reader :steps

    # Record the block's steps; +table+ is the test's model table (row locks
    # and row writes are recorded for it only). Returns the steps.
    def record(table:)
      @mutex.synchronize { @steps = []; @seq = 0; @table = table }
      @held = {}
      yield
      @steps.dup
    ensure
      @steps = nil
    end

    # The block's thread is +name+ (w0, j0, ...): its steps carry that name.
    def as(name)
      previous = Thread.current[:lock_trace_actor]
      Thread.current[:lock_trace_actor] = name
      yield
    ensure
      Thread.current[:lock_trace_actor] = previous
    end

    def table = @table

    def note(action, key = action, detail = nil)
      return unless @steps
      actor = Thread.current[:lock_trace_actor] or return

      @mutex.synchronize do
        held = (@held[actor] ||= {})
        next if key && action != :commit && held[key]

        held[key] = true if key
        @steps << Step.new(@seq += 1, actor, action, detail)
        @held[actor] = {} if action == :commit
      end
    end
  end

  module AdvisoryHooks
    def xact_lock(connection, key, purpose:)
      result = super
      LockTrace.note(*LockTrace::AdvisoryHooks.classify(key))
      result
    end

    def xact_lock_all(connection, keys, purpose:)
      result = super
      keys.each { LockTrace.note(*LockTrace::AdvisoryHooks.classify(_1)) }
      result
    end

    # The aggregate lock, a stream's projection lock, or another of Lyra's.
    def self.classify(key)
      key = key.to_s
      return [:a, "a:#{key}"] if key.start_with?("lyra_aggregate/")
      return [:s, "s:#{key}"] if key.include?("$")

      [:other, "o:#{key}"]
    end
  end

  # SQL: row locks, reads and writes of the test's table, a stream's version
  # query, stream heads, appends, and commits (at their start, before the locks go).
  class SqlSubscriber
    def start(_name, _id, payload)
      return unless LockTrace.steps && payload[:sql].to_s.strip.match?(/\ACOMMIT\b/i)

      LockTrace.note(:commit)
    end

    def finish(_name, _id, payload)
      return unless LockTrace.steps

      sql = payload[:sql].to_s
      table = LockTrace.table
      if sql.match?(/\bFOR (NO KEY )?UPDATE\b/i) && sql.include?("lyra_stream_heads")
        LockTrace.note(:h, "h")
      elsif sql.match?(/\bFOR (NO KEY )?UPDATE\b/i) && sql.include?(table.to_s)
        if sql.match?(/SKIP LOCKED/i) && payload[:row_count].to_i.zero?
          LockTrace.note(:x_busy, nil)
        elsif payload[:row_count] && payload[:row_count].to_i.zero?
          LockTrace.note(:x_none, nil) # no row to lock (a destroyed record): no grant
        else
          LockTrace.note(:x, "x")
        end
      elsif sql.match?(/\A\s*(UPDATE|DELETE FROM)\s+"?#{Regexp.escape(table.to_s)}"?/i)
        LockTrace.note(:x, "x")
      elsif sql.match?(/\A\s*SELECT\b/i) && sql.match?(/\bFROM\s+"?#{Regexp.escape(table.to_s)}"?/i)
        LockTrace.note(:read, "read")
      elsif sql.match?(/\A\s*SELECT event_id FROM event_store_events_in_streams WHERE stream = .* ORDER BY id DESC LIMIT 1/i)
        LockTrace.note(:read, "read") # ES-NoProj: the stream's last event, which decides what is read
      elsif sql.match?(/\A\s*(INSERT INTO|UPDATE)\s+"?lyra_stream_heads"?/i)
        LockTrace.note(:h, "h")
      elsif sql.match?(/\A\s*INSERT INTO\s+"?event_store_events"?\s/i)
        LockTrace.note(:append, nil)
      end
    end
  end

  def self.install!
    return if @installed

    Lyra::AdvisoryLock.singleton_class.prepend(AdvisoryHooks)
    ActiveSupport::Notifications.subscribe("sql.active_record", SqlSubscriber.new)
    @installed = true
  end
end
