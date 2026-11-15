# frozen_string_literal: true

module Lyra
  # What only Lyra's own call sites hold. Lyra.projection_write and
  # PurposeBoundReads.internal switch off the checks that keep every write in
  # the log and every read under its purpose; they are for Lyra's projections,
  # replays and tasks, and application code that called them could change a row
  # with no event or read a declared field under :deny.
  #
  # The constant is private, so only code written inside `module Lyra` can name it.
  # That keeps application code from calling them by accident or by following the
  # documentation; it is not a barrier against code that is out to defeat it
  # (Lyra.const_get reaches it), which no Ruby code could provide.
  #
  # Application code that needs to write without events (seeding, fixtures, a
  # table wipe whose history is not wanted) uses Lyra.unrecorded_write, which asks
  # for a reason and records that it happened.
  INTERNAL = Object.new.freeze
  private_constant :INTERNAL

  # Lyra's internal switches called from outside Lyra.
  class InternalApiError < StandardError; end

  # Lyra.unrecorded_write while config.unrecorded_writes is :deny.
  class UnrecordedWriteDenied < StandardError; end
end
