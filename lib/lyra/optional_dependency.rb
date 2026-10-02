# frozen_string_literal: true

module Lyra
  # Loads Lyra's optional companion gems (PAM DSL, PetriFlow).
  #
  # Only a gem that is not installed counts as unavailable. A gem that is
  # installed but fails to load (one of its own dependencies missing, an error
  # in its code) raises: rescuing every LoadError used to report such a gem as
  # "not installed" while leaving it half-defined, which surfaced much later as
  # an unrelated NameError (PetriFlow without rexml: PetriFlow::Workflow
  # undefined when eager loading app/workflows).
  module OptionalDependency
    module_function

    def load(feature)
      require feature
      true
    rescue LoadError => e
      raise unless e.path == feature

      false
    end
  end
end
