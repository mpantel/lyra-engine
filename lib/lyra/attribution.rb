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
  end
end
