# frozen_string_literal: true

require "etc"
require "socket"

module Lyra
  # Who made a change that no record's callbacks attribute: a mode switch, an
  # erasure, a repair. The actor is a label the operator or the application
  # supplies (OPERATOR=..., Current.user, LYRA_OPERATOR): nothing checks it, so it
  # can name anyone. Next to it Lyra records what the operating system says: the
  # user the process runs as, the host and the process id. They do not make the
  # label true, but a reader can compare the two, and OS and SSH audit logs
  # (which Lyra cannot replace) can be matched against the host and the time.
  module Attribution
    module_function

    # { actor:, os_user:, host:, pid: }
    def of(operator = nil)
      { actor: Lyra::ModeTransition.actor(operator), os_user: os_user, host: host, pid: Process.pid }
    end

    # The user the process runs as (by uid, not by the USER variable, which any
    # caller can set).
    def os_user
      Etc.getpwuid(Process.uid)&.name || Process.uid.to_s
    rescue StandardError
      Process.uid.to_s
    end

    def host
      Socket.gethostname
    end

    # The class of the user who acted (Current.user), as events record it
    # beside user_id from 1.0.0 (user_type): the table's owner class for an
    # Active Record user (the STI base class), the class name otherwise, nil
    # for an anonymous class. An id alone cannot tell a staff User 7 from the
    # data subject Person 7; the Art. 15 copy compares both.
    def actor_type(user)
      return nil if user.nil?

      klass = user.class
      klass.respond_to?(:base_class) ? Lyra.stream_owner_name(klass) : klass.name
    rescue StandardError
      nil
    end
  end
end
