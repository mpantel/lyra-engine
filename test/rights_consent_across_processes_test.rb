# frozen_string_literal: true

require "test_helper"

# Consent, restrictions and objections across real operating-system
# processes. Lyra::Rights keeps them in the database (Lyra::Rights::Store,
# Lyra::Rights::ConsentStore), shared by every process of an application; each
# process answers its checks from what it last read, until the next checking
# scope (config.rights_refresh :scope, the default), the refresh interval
# (config.rights_refresh_interval), or Lyra::Rights.refresh!.
# rights_store_test.rb stands in for "another process" with a second store
# object in the same process; here each process is a fork with its own memory,
# its own caches and its own database connection.
#
# The processes are workers forked by the test, which drives them over pipes:
# a worker runs one command at a time and answers; a command can pause
# (send a value and wait to be resumed), which is how two workers are lined up
# at the same point. Nothing waits on a sleep, except where the refresh
# interval itself is under test, and that interval is 0.2 s.
class RightsConsentAcrossProcessesTest < Minitest::Test
  POLICY = :consent_xp_policy
  TIMEOUT = 60

  # A forked process, driven over two pipes with Marshal frames.
  class Worker
    # What a command gets: a way to pause.
    class Context
      def initialize(input, output)
        @input = input
        @output = output
      end

      # Tell the driver +value+, and wait for it to resume this command.
      def pause(value = nil)
        Worker.write(@output, [:paused, value])
        message = Worker.read(@input)
        raise "expected :resume, got #{message.inspect}" unless message == [:resume]
      end
    end

    def self.write(io, value)
      data = Marshal.dump(value)
      io.write([data.bytesize].pack("N"), data)
      io.flush
    end

    def self.read(io, timeout: nil)
      raise "no answer from the worker within #{timeout} s" if timeout && !IO.select([io], nil, nil, timeout)

      header = io.read(4)
      return nil if header.nil?

      Marshal.load(io.read(header.unpack1("N"))) # rubocop:disable Security/MarshalLoad
    end

    # The driver's ends of the running workers' pipes.
    OPEN = {}.compare_by_identity

    attr_reader :pid, :name

    def initialize(name, commands)
      @name = name
      down_read, @down = IO.pipe.each(&:binmode)
      @up, up_write = IO.pipe.each(&:binmode)
      @pid = fork do
        # Not the pipes of the other workers this process inherited: a worker
        # sees the end of its input only when every writer has closed it.
        (OPEN.values.flatten + [@down, @up]).each { |io| io.close unless io.closed? }
        # A process of its own: its own connection (the parent's pools are
        # not used here), and nothing remembered from the parent.
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all) rescue nil
        Lyra::Rights.refresh!
        context = Context.new(down_read, up_write)
        while (message = Worker.read(down_read)) && message != [:exit]
          command, args = message
          result = begin
            [:done, commands.fetch(command).call(context, *args)]
          rescue StandardError => e
            [:error, "#{e.class}: #{e.message}", e.backtrace.first(8)]
          end
          Worker.write(up_write, result)
        end
        exit!(0)
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "worker #{name}: #{e.class}: #{e.message}"
        exit!(1)
      end
      down_read.close
      up_write.close
      OPEN[self] = [@down, @up]
    end

    # Run +command+ to its end; its value.
    def call(command, *args)
      start(command, *args)
      finish
    end

    # Send +command+ without waiting for it.
    def start(command, *args)
      Worker.write(@down, [command, args])
      self
    end

    # The value the running command paused with.
    def paused
      kind, value = receive
      raise "worker #{name}: expected a pause, got #{kind.inspect} #{value.inspect}" unless kind == :paused

      value
    end

    def resume
      Worker.write(@down, [:resume])
      self
    end

    # The value of the running command.
    def finish
      kind, value, backtrace = receive
      raise "worker #{name}: #{value}\n  #{Array(backtrace).join("\n  ")}" if kind == :error
      raise "worker #{name}: expected the command's end, got #{kind.inspect}" unless kind == :done

      value
    end

    def stop
      OPEN.delete(self)
      unless @down.closed?
        begin
          Worker.write(@down, [:exit])
        rescue IOError, SystemCallError
          nil # it has gone already
        end
        @down.close
      end
      return @status unless @pid

      unless wait(10)
        Process.kill(:KILL, @pid)
        Process.wait(@pid)
      end
      @status = $?
      @up.close unless @up.closed?
      @pid = nil
      @status
    end

    private

    def receive
      message = Worker.read(@up, timeout: TIMEOUT)
      raise "worker #{name} exited" if message.nil?

      message
    end

    def wait(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return true if Process.wait(@pid, Process::WNOHANG)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        IO.select(nil, nil, nil, 0.01)
      end
    end
  end

  # In the workers only: counts ConsentStore's appends and the conflicts they
  # meet (another process appended to the subject's stream first), and can
  # pause the first append of an operation, after the operation has read the
  # subject's stream and before it writes. Lyra's code is not changed: this
  # wraps its private append in the forked process.
  module AppendProbe
    private

    def append(*args)
      probe = $consent_xp_probe
      return super unless probe

      probe[:appends] += 1
      probe[:hold]&.call if probe[:appends] == 1
      super
    rescue PamDsl::RightsConcurrencyError
      probe[:conflicts] += 1 if probe
      raise
    end
  end

  def setup
    skip "Requires Rails and database" unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connection.table_exists?(:users)
    skip "Requires pam_dsl" unless Lyra.pam_dsl_available?
    skip "Requires fork" unless Process.respond_to?(:fork)
    skip "Requires PostgreSQL" unless ActiveRecord::Base.connection.adapter_name.match?(/postg/i)

    PamDsl.reset!
    PamDsl.logger = Logger.new(nil)
    PamDsl.define_policy(POLICY) do
      field :name, type: :name
      field :email, type: :email
      field :title, type: :custom
      field :body, type: :custom
      purpose :publishing do
        basis :contract
        requires :title, :body, :name, :email
      end
      purpose :defence do
        basis :legitimate_interests
        lia_documented!
        allowed_when_restricted :legal_claims
        requires :title, :body, :name, :email
      end
      purpose :survey do
        basis :legitimate_interests
        lia_documented!
        allowed_when_restricted :consent
        requires :title, :body
      end
      purpose :newsletter do
        basis :consent
        requires :title, :body, :name, :email
      end
      consent do
        for_purpose(:newsletter) { required! }
        for_purpose(:survey) { required! false }
      end
    end

    %i[ConsentXpAuthor ConsentXpArticle].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Object.const_set(:ConsentXpAuthor, Class.new(ActiveRecord::Base) { self.table_name = "users" })
    Object.const_set(:ConsentXpArticle, Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      belongs_to :author, class_name: "ConsentXpAuthor", optional: true
    end)
    [ConsentXpAuthor, ConsentXpArticle].each do |model|
      model.include(Lyra::Interceptors::CrudInterceptor)
      model.monitor_with_lyra(privacy_policy: POLICY)
      Lyra.config.monitor_model(model, privacy_policy: POLICY)
    end
    clean
    Lyra.config.enable_monitor!
    @ann = ConsentXpAuthor.create!(name: "Ann", email: "ann@example.com")
    @bob = ConsentXpAuthor.create!(name: "Bob", email: "bob@example.com")
    @anns = ConsentXpArticle.create!(title: "Ann's", body: "text", author_id: @ann.id)
    @bobs = ConsentXpArticle.create!(title: "Bob's", body: "text", author_id: @bob.id)
    @ann_key = "ConsentXpAuthor$#{@ann.id}"
    @bob_key = "ConsentXpAuthor$#{@bob.id}"
    @workers = []
  end

  def teardown
    return unless defined?(ConsentXpAuthor) && @workers

    exited = @workers.to_h { [_1.name, _1.stop] }
    assert exited.values.all?(&:success?), "every worker ends cleanly: #{exited.inspect}" unless skipped?
    PamDsl.rights_store = Lyra::Rights.store
    PamDsl.consent_store = Lyra::Rights.consent_store
    clean
    PamDsl.reset!
    PamDsl.logger = nil
  end

  # ── 0. The workers are processes of their own ──

  def test_the_workers_are_separate_processes_with_their_own_connections
    a, b = workers(:a, :b)
    here = [Process.pid, ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")]
    ids = [here, a.call(:identity), b.call(:identity)]
    assert_equal 3, ids.map(&:first).uniq.size, "three operating-system processes"
    assert_equal 3, ids.map(&:last).uniq.size, "three database sessions"
  end

  # ── 1. A grant in one process is seen by another ──

  def test_a_grant_in_one_process_is_seen_by_another
    configure(:scope, 60)
    a, b = workers(:a, :b)
    assert_equal :consent_required, b.call(:read, :newsletter, @anns.id), "no consent yet"
    assert_equal :consent_required, b.call(:validate, @ann_key, true)

    a.call(:grant, @ann_key, :newsletter)

    assert_equal :consent_required, b.call(:validate, @ann_key, false),
                 "outside a checking scope, B answers from what it read, for up to the interval"
    assert_equal :allowed, b.call(:read, :newsletter, @anns.id), "B's next purpose block (a scope) reads afresh"
    assert_equal :allowed, b.call(:validate, @ann_key, true), "validate_access! in a scope (a request, a job)"
    assert_equal :allowed, b.call(:validate, @ann_key, false), "and, read afresh, outside one"
    assert_equal :consent_required, b.call(:read, :newsletter, @bobs.id), "Ann's consent is Ann's only"

    c = worker(:c)
    assert_equal :allowed, c.call(:read, :newsletter, @anns.id), "a process started after the grant"
  end

  # ── 2. A withdrawal in one process takes effect in another, per refresh mode ──

  # :scope (the default): from B's next checking scope (or the interval, or
  # Lyra::Rights.refresh!, whichever comes first). A scope that began before
  # the withdrawal may finish on what it read.
  def test_a_withdrawal_applies_in_another_process_from_its_next_scope
    configure(:scope, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)

    b.start(:read_twice_in_one_scope, :newsletter, @anns.id)
    assert_equal :allowed, b.paused, "B's request reads Ann's article"
    a.call(:withdraw, @ann_key, :newsletter)
    assert_equal :withdrawn, a.call(:state, @ann_key, :newsletter), "A sees its withdrawal at once"
    assert_equal :allowed, b.resume.finish, "the scope that began before the withdrawal ends on what it read"

    assert_equal :consent_required, b.call(:read, :newsletter, @anns.id), "B's next scope refuses"
    assert_equal :consent_required, b.call(:validate, @ann_key, true)
    assert_equal :consent_required, b.call(:validate, @ann_key, false)
  end

  def test_under_scope_a_check_outside_any_scope_sees_the_withdrawal_after_refresh
    configure(:scope, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)
    assert_equal :allowed, b.call(:validate, @ann_key, false)

    a.call(:withdraw, @ann_key, :newsletter)
    assert_equal :allowed, b.call(:validate, @ann_key, false), "outside a scope: what B read, within the interval"
    b.call(:refresh)
    assert_equal :consent_required, b.call(:validate, @ann_key, false), "after Lyra::Rights.refresh!"
  end

  # :interval: only after the interval (or Lyra::Rights.refresh!); a new scope
  # does not read afresh, so B may go on allowing for up to the interval.
  def test_under_interval_a_withdrawal_applies_after_refresh_and_not_per_scope
    configure(:interval, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)
    assert_equal :allowed, b.call(:read, :newsletter, @anns.id)

    a.call(:withdraw, @ann_key, :newsletter)
    assert_equal :allowed, b.call(:read, :newsletter, @anns.id), "a new scope still answers from what B read"
    assert_equal :allowed, b.call(:validate, @ann_key, true)
    b.call(:refresh)
    assert_equal :consent_required, b.call(:read, :newsletter, @anns.id), "after Lyra::Rights.refresh!"
  end

  # Either mode, with a 0.2 s interval: once the interval has passed since B
  # read the consent, B's next check (in a scope or not) refuses.
  def test_once_the_interval_has_passed_the_withdrawal_applies_in_either_mode
    %i[interval scope].each do |mode|
      configure(mode, 0.2)
      a, b = workers(:"a_#{mode}", :"b_#{mode}")
      a.call(:grant, @ann_key, :newsletter)
      # B read the consent at some time in [read_from, read_by] (monotonic
      # clock, the one Lyra::Rights uses, system-wide on Linux).
      allowed, read_from, read_by = b.call(:validate_timed, @ann_key)
      assert_equal :allowed, allowed, mode

      a.call(:withdraw, @ann_key, :newsletter)
      before, _, checked_by = b.call(:validate_timed, @ann_key)
      if checked_by - read_from < 0.2
        assert_equal :allowed, before, "#{mode}: within the interval B answers from what it read"
      end

      b.call(:wait_until, read_by + 0.2)
      assert_equal :consent_required, b.call(:validate, @ann_key, false), "#{mode}: after the interval, outside a scope"
      assert_equal :consent_required, b.call(:read, :newsletter, @anns.id), "#{mode}: after the interval, in a scope"
      [a, b].each(&:stop)
      clean_rights
    end
  end

  # ── 3. Restrictions and objections recorded in one process are in force in another ──

  def test_a_restriction_and_an_objection_in_one_process_are_in_force_in_another
    configure(:scope, 60)
    a, b = workers(:a, :b)
    assert_equal :allowed, b.call(:read, :publishing, @anns.id)
    assert_equal :allowed, b.call(:read, :survey, @bobs.id)

    restriction = a.call(:restrict, @ann_key)
    assert_equal :restricted, b.call(:read, :publishing, @anns.id), "Art. 18 restriction, in B's next scope"
    assert_equal :allowed, b.call(:read, :defence, @anns.id), "Art. 18(2) legal claims"
    assert_equal :allowed, b.call(:read, :publishing, @bobs.id), "Bob is not restricted"

    # Art. 18(2) consent: given in A after the restriction, it lets B process.
    assert_equal :restricted, b.call(:read, :survey, @anns.id)
    a.call(:grant, @ann_key, :survey)
    assert_equal :allowed, b.call(:read, :survey, @anns.id), "the consent exception reads the durable consent"

    objection = a.call(:object, @bob_key, :survey)
    assert_equal :restricted, b.call(:read, :survey, @bobs.id), "a pending objection restricts (Art. 18(1)(d))"
    a.call(:decide, objection, :upheld)
    assert_equal :objected, b.call(:read, :survey, @bobs.id), "an upheld objection (Art. 21) stops the purpose"
    assert_equal :allowed, b.call(:read, :publishing, @bobs.id), "other purposes go on"

    a.call(:lift, restriction)
    assert_equal :allowed, b.call(:read, :publishing, @anns.id), "the lift applies in B's next scope too"
  end

  def test_under_interval_a_restriction_applies_in_another_process_after_refresh
    configure(:interval, 60)
    a, b = workers(:a, :b)
    assert_equal :allowed, b.call(:read, :publishing, @anns.id)
    a.call(:restrict, @ann_key)
    assert_equal :allowed, b.call(:read, :publishing, @anns.id), "within the interval: what B read"
    b.call(:refresh)
    assert_equal :restricted, b.call(:read, :publishing, @anns.id)
  end

  # ── 4. Concurrent transitions of one subject's consent from two processes ──
  #
  # Every transition reads the subject's stream (Lyra::Consent$<key>), folds
  # the record, and appends with the stream's expected version; the projection
  # row is written in the same transaction. Two processes that read the same
  # version cannot both append: the second fails on the stream's unique
  # position, nothing of it is stored, and it is retried on the new state
  # (ConsentStore::RETRIES). So the transitions are serialised in the order
  # they commit, each checked against the state the one before it left: the
  # last to commit wins, by stream position (not by the times they carry).
  # Each case below holds both workers after their reads and before their
  # appends, so they always conflict.

  def test_a_grant_and_a_withdrawal_at_once_end_in_the_state_of_the_last_to_commit
    configure(:scope, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)
    new_grant = Time.current.change(usec: 0) + 60

    results = overlap(a => [:withdraw, @ann_key, :newsletter], b => [:grant, @ann_key, :newsletter, new_grant])

    assert_equal [:recorded, :recorded], results.values.map { _1[:outcome] }, "both transitions are legal in either order"
    assert_equal 1, results.values.sum { _1[:conflicts] }, "one of them met the other's append and was retried"
    events = assert_consistent(@ann_key, :newsletter, [a, b])
    assert_equal 3, events.size
    last = results.find { |_, r| r[:conflicts] == 1 }.first
    if last == a
      assert_equal %w[ConsentGranted ConsentGranted ConsentWithdrawn], events.map { _1[:type] }
      assert_equal :withdrawn, state_of(@ann_key, :newsletter)
    else
      assert_equal %w[ConsentGranted ConsentWithdrawn ConsentGranted], events.map { _1[:type] }
      assert_equal :granted, state_of(@ann_key, :newsletter)
      assert_in_delta new_grant, row(@ann_key, :newsletter)["granted_at"], 0.001
    end
  end

  def test_two_withdrawals_at_once_record_one
    configure(:scope, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)

    results = overlap(a => [:withdraw, @ann_key, :newsletter], b => [:withdraw, @ann_key, :newsletter])

    assert_equal [:recorded, :refused], results.values.map { _1[:outcome] }.sort
    refused = results.values.find { _1[:outcome] == :refused }
    assert_equal 1, refused[:conflicts]
    assert_match(/state 'withdrawn'/, refused[:message], "the retry found it withdrawn")
    events = assert_consistent(@ann_key, :newsletter, [a, b])
    assert_equal %w[ConsentGranted ConsentWithdrawn], events.map { _1[:type] }
  end

  def test_two_requests_at_once_record_one
    configure(:scope, 60)
    a, b = workers(:a, :b)

    results = overlap(a => [:request, @ann_key, :newsletter], b => [:request, @ann_key, :newsletter])

    assert_equal [:recorded, :refused], results.values.map { _1[:outcome] }.sort
    assert_match(/already in state 'pending'/, results.values.find { _1[:outcome] == :refused }[:message])
    events = assert_consistent(@ann_key, :newsletter, [a, b])
    assert_equal %w[ConsentRequested], events.map { _1[:type] }
  end

  def test_two_grants_at_once_keep_the_last_to_commit
    configure(:scope, 60)
    a, b = workers(:a, :b)
    a.call(:grant, @ann_key, :newsletter)
    t1 = Time.current.change(usec: 0) + 60
    t2 = t1 + 60

    results = overlap(a => [:grant, @ann_key, :newsletter, t1], b => [:grant, @ann_key, :newsletter, t2])

    assert_equal [:recorded, :recorded], results.values.map { _1[:outcome] }
    events = assert_consistent(@ann_key, :newsletter, [a, b])
    assert_equal %w[ConsentGranted ConsentGranted ConsentGranted], events.map { _1[:type] }
    last = results.find { |_, r| r[:conflicts] == 1 }.first
    assert_in_delta (last == a ? t1 : t2), row(@ann_key, :newsletter)["granted_at"], 0.001,
                    "the grant that committed last stands, whatever its time"
  end

  # Unforced: the two workers are released at once and race; each round ends
  # consistent whichever order they commit in.
  def test_racing_grants_and_withdrawals_always_end_consistent
    configure(:scope, 60)
    a, b = workers(:a, :b)
    rounds = 20
    conflicts = 0
    finals = Hash.new(0)
    rounds.times do |round|
      a.call(:grant, @ann_key, :newsletter) unless state_of(@ann_key, :newsletter) == :granted
      before = events_of(@ann_key, :newsletter).size
      a.start(:after_go, :withdraw, @ann_key, :newsletter)
      b.start(:after_go, :grant, @ann_key, :newsletter, Time.current.change(usec: 0) + round + 1)
      [a, b].each(&:paused)
      [a, b].each(&:resume)
      results = [a.finish, b.finish]

      assert_equal [:recorded, :recorded], results.map { _1[:outcome] }, "round #{round}"
      conflicts += results.sum { _1[:conflicts] }
      events = assert_consistent(@ann_key, :newsletter, [a, b])
      assert_equal before + 2, events.size, "round #{round}: both recorded, nothing lost"
      finals[events.last[:type]] += 1
    end
    # How often they met, and who committed last, is up to the scheduler.
    puts "\n  racing rounds: #{rounds}, conflicts retried: #{conflicts}, last: #{finals}" if ENV["CONSENT_XP_VERBOSE"]
  end

  # More processes than a transition retries (ConsentStore::RETRIES = 3):
  # each transition either records or is refused with nothing stored (an
  # illegal transition, PamDsl::Error, or RightsConcurrencyError once its
  # retries are spent), and the subject's consent stays consistent.
  def test_many_processes_at_once_record_or_are_refused_and_lose_nothing
    configure(:scope, 60)
    racers = workers(*(1..6).map { :"p#{_1}" })
    racers.first.call(:grant, @ann_key, :newsletter)
    outcomes = Hash.new(0)
    10.times do |round|
      before = events_of(@ann_key, :newsletter).size
      racers.each_with_index do |w, i|
        args = i.even? ? [:withdraw, @ann_key, :newsletter] : [:grant, @ann_key, :newsletter, Time.current.change(usec: 0) + (round * 10) + i]
        w.start(:after_go, *args)
      end
      racers.each(&:paused)
      racers.each(&:resume)
      results = racers.map(&:finish)

      results.each_with_index { |r, i| outcomes[[i.even? ? :withdraw : :grant, r[:outcome]]] += 1 }
      assert_empty results.map { _1[:outcome] } - %i[recorded refused conflict], "round #{round}"
      events = assert_consistent(@ann_key, :newsletter, racers.first(2))
      assert_equal before + results.count { _1[:outcome] == :recorded }, events.size,
                   "round #{round}: one event per recorded transition, none for a refused one"
    end
    puts "\n  six processes, 10 rounds: #{outcomes}" if ENV["CONSENT_XP_VERBOSE"]
  end

  # Only committed consent counts in another process: a grant in A's open
  # transaction is not seen by B; committed, it is; rolled back, never.
  def test_a_grant_in_an_open_transaction_counts_in_another_process_only_once_committed
    configure(:scope, 60)
    a, b = workers(:a, :b)
    [[false, :consent_required], [true, :allowed]].each do |commit, after|
      a.start(:grant_in_transaction, @ann_key, :newsletter, commit)
      assert_equal :granted, a.paused, "A's transaction sees its own grant"
      assert_equal :consent_required, b.call(:read, :newsletter, @anns.id), "B does not see an uncommitted grant"
      a.resume.finish
      assert_equal after, b.call(:read, :newsletter, @anns.id), commit ? "committed" : "rolled back"
    end
  end

  private

  def configure(mode, interval)
    Lyra.config.rights_refresh = mode
    Lyra.config.rights_refresh_interval = interval
  end

  def policy = PamDsl.policy(POLICY)

  def workers(*names) = names.map { worker(_1) }

  def worker(name)
    Worker.new(name, commands).tap { @workers << _1 }
  end

  # What a worker can be asked to do. Checks answer :allowed, or the refusal.
  def commands
    policy_name = POLICY
    consent = -> { PamDsl.policy(policy_name).consent_policy }
    attempt = lambda do |&block|
      block.call
      :allowed
    rescue PamDsl::ConsentRequiredError then :consent_required
    rescue PamDsl::ObjectedProcessingError then :objected
    rescue PamDsl::RestrictedProcessingError then :restricted
    end
    find = ->(id) { ConsentXpArticle.find(id).title }
    validate = ->(key) { attempt.call { PamDsl.policy(policy_name).validate_access!([:email], :newsletter, subject: key) } }
    transition = lambda do |kind, key, purpose, granted_at = nil|
      store = Lyra::Rights.consent_store
      case kind
      when :grant
        granted_at ? consent.call.grant_consent(purpose: purpose, subject: key, granted_at: granted_at) : consent.call.grant_consent(purpose: purpose, subject: key)
      when :withdraw then consent.call.withdraw_consent(purpose: purpose, subject: key)
      when :request then store.request(purpose: purpose, subject: key)
      end
    end
    probed = lambda do |hold, kind, *args|
      ActiveRecord::Base.connection # connect first, outside the measured part
      Lyra::Rights::ConsentStore.prepend(AppendProbe) unless Lyra::Rights::ConsentStore <= AppendProbe
      $consent_xp_probe = { appends: 0, conflicts: 0, hold: hold }
      begin
        transition.call(kind, *args)
        { outcome: :recorded, conflicts: $consent_xp_probe[:conflicts], appends: $consent_xp_probe[:appends] }
      rescue PamDsl::RightsConcurrencyError => e
        { outcome: :conflict, conflicts: $consent_xp_probe[:conflicts], message: e.message }
      rescue PamDsl::Error => e
        { outcome: :refused, conflicts: $consent_xp_probe[:conflicts], message: e.message }
      ensure
        $consent_xp_probe = nil
      end
    end
    {
      identity: ->(_) { [Process.pid, ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")] },
      read: ->(_, purpose, id) { attempt.call { Lyra.with_purpose(purpose) { find.call(id) } } },
      read_twice_in_one_scope: lambda do |ctx, purpose, id|
        Lyra.with_purpose(purpose) do
          ctx.pause(attempt.call { find.call(id) })
          attempt.call { find.call(id) }
        end
      end,
      validate: ->(_, key, scoped) { scoped ? Lyra::Rights.scope { validate.call(key) } : validate.call(key) },
      validate_timed: lambda do |_, key|
        started = Lyra::Rights.now
        [validate.call(key), started, Lyra::Rights.now]
      end,
      # The interval under test: the only sleep.
      wait_until: ->(_, at) { (left = at - Lyra::Rights.now).positive? && sleep(left) },
      refresh: ->(_) { Lyra::Rights.refresh! && nil },
      state: ->(_, key, purpose) { Lyra::Rights.consent_store.record_for(purpose, key)&.state },
      fresh_state: lambda do |_, key, purpose|
        Lyra::Rights.refresh!
        Lyra::Rights.consent_store.record_for(purpose, key)&.state
      end,
      grant: ->(_, key, purpose) { transition.call(:grant, key, purpose) && nil },
      withdraw: ->(_, key, purpose) { transition.call(:withdraw, key, purpose) && nil },
      grant_in_transaction: lambda do |ctx, key, purpose, commit|
        ActiveRecord::Base.transaction do
          transition.call(:grant, key, purpose)
          ctx.pause(Lyra::Rights.consent_store.record_for(purpose, key)&.state)
          raise ActiveRecord::Rollback unless commit
        end
        nil
      end,
      restrict: ->(_, key) { PamDsl.rights.restrict!(subject: key, ground: :accuracy_contested).id },
      object: ->(_, key, purpose) { PamDsl.rights.object!(subject: key, policy: policy_name, purpose: purpose).id },
      decide: ->(_, id, outcome) { PamDsl.rights.decide!(id, outcome: outcome, by: "dpo") && nil },
      lift: lambda do |_, id|
        PamDsl.rights.notify_lift!(id)
        PamDsl.rights.lift!(id, reason: :verified_accurate) && nil
      end,
      # Hold the transition after its read, before its append.
      held: ->(ctx, kind, *args) { probed.call(-> { ctx.pause(:read) }, kind, *args) },
      # Wait for the go, then run the transition.
      after_go: lambda do |ctx, kind, *args|
        ActiveRecord::Base.connection
        ctx.pause(:ready)
        probed.call(nil, kind, *args)
      end
    }
  end

  # Run two held transitions: both read the subject's stream, then both are
  # released to append. The workers' results, by worker.
  def overlap(plan)
    plan.each { |w, (kind, *args)| w.start(:held, kind, *args) }
    plan.each_key { |w| assert_equal :read, w.paused }
    plan.each_key(&:resume)
    plan.keys.to_h { |w| [w, w.finish] }
  end

  # The consistency the store promises, checked from this (third) process:
  # the subject's stream is a legal sequence of PAM's transitions, the row in
  # lyra_consents is its fold, written at its version, and every process,
  # once it reads afresh, sees that state. Returns the purpose's events.
  def assert_consistent(key, purpose, processes)
    all = Lyra::Rights::ConsentStore.new.events_for(key)
    events = all.select { _1[:purpose] == purpose }
    state = events.reduce(nil) do |current, event|
      case event[:type]
      when "ConsentRequested"
        refute_includes %i[pending granted], current, "a request while #{current}"
        :pending
      when "ConsentGranted" then :granted
      when "ConsentWithdrawn"
        assert_equal :granted, current, "a withdrawal of #{current.inspect}"
        :withdrawn
      end
    end
    assert_equal all.size, events.size, "one purpose in this subject's stream here"
    stored = row(key, purpose)
    assert_equal state.to_s, stored["state"], "the row is the stream's fold"
    assert_equal all.size, stored["stream_version"].to_i, "written with the stream's last append"
    assert_equal state, state_of(key, purpose)
    processes.each { |p| assert_equal state, p.call(:fresh_state, key, purpose), "worker #{p.name}" }
    events
  end

  def events_of(key, purpose)
    Lyra::Rights::ConsentStore.new.events_for(key).select { _1[:purpose] == purpose }
  end

  def state_of(key, purpose)
    Lyra::Rights::ConsentStore.new.record_for(purpose, key)&.state
  end

  def row(key, purpose)
    c = ActiveRecord::Base.connection
    c.select_all("SELECT * FROM lyra_consents WHERE subject_key = #{c.quote(key)} AND purpose = #{c.quote(purpose.to_s)}")
     .to_a.first.tap do |r|
      r["granted_at"] = ActiveRecord::Type::DateTime.new.cast(r["granted_at"]) if r && r["granted_at"].is_a?(String)
    end
  end

  def clean_rights
    LyraRightsIsolation.purge!
  end

  def clean
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM articles")
    connection.execute("DELETE FROM users")
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
    LyraRightsIsolation.purge!
  end
end
