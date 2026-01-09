module Lyra
  class ApplicationController < ActionController::Base
    # Base controller for Lyra engine
    protect_from_forgery with: :exception, unless: -> { request.format.json? }

    helper_method :pam_dsl_available?, :user_tracking_configured?, :petri_flow_available?

    # Check if PAM DSL is available for privacy features
    def pam_dsl_available?
      PAM_DSL_AVAILABLE
    end

    # Check if PetriFlow is available for formal verification
    def petri_flow_available?
      PETRI_FLOW_AVAILABLE
    end

    # Check if user tracking is configured via Rails CurrentAttributes
    def user_tracking_configured?
      defined?(::Current) && ::Current.respond_to?(:user)
    end
  end
end
