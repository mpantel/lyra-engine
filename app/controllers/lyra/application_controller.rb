module Lyra
  class ApplicationController < ActionController::Base
    # Base controller for Lyra engine
    protect_from_forgery with: :exception, unless: -> { request.format.json? }

    # Every engine action is authorized first: the routes expose a data
    # subject's personal data (privacy/subject, portable_export, gdpr_report,
    # pii_inventory), so the dashboard fails closed. See
    # Lyra::Configuration#dashboard_authorization.
    before_action :authorize_lyra_dashboard!

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

    private

    # config.dashboard_authorization is evaluated with instance_exec on this
    # controller, so its body may call the controller's methods directly,
    # private ones included (request, session, cookies, params, and any
    # helper on ActionController::Base, such as Devise's current_user). A
    # proc taking an argument is also given the controller:
    #
    #   config.dashboard_authorization = ->(controller) { controller.current_user&.admin? }
    #   config.dashboard_authorization = -> { session[:admin] == true }
    #
    # This controller inherits ActionController::Base, not the host's
    # ApplicationController, so methods defined only there are not reachable.
    #
    # Truthy allows the request; falsy answers 403. Unset (nil), the dashboard
    # is open only in the development and test environments.
    def authorize_lyra_dashboard!
      check = Lyra.config.dashboard_authorization

      allowed =
        if check.nil?
          lyra_dashboard_open_by_default?
        elsif check.arity.zero?
          instance_exec(&check)
        else
          instance_exec(self, &check)
        end

      head :forbidden unless allowed
    end

    def lyra_dashboard_open_by_default?
      return true if Rails.env.development? || Rails.env.test?

      Rails.logger&.warn(
        "[Lyra] Dashboard request refused (403): set config.dashboard_authorization " \
        "in the Lyra initializer to allow access outside development and test, " \
        "e.g. ->(controller) { controller.current_user&.admin? }"
      )
      false
    end
  end
end
