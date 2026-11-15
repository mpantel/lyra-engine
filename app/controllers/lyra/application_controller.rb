module Lyra
  class ApplicationController < ActionController::Base
    # Base controller for Lyra engine
    protect_from_forgery with: :exception, unless: -> { request.format.json? }

    # Every engine action is authorized first: the routes expose a data
    # subject's personal data (privacy/subject, portable_export, gdpr_report,
    # pii_inventory), so the dashboard fails closed. See
    # Lyra::Configuration#dashboard_authorization.
    before_action :authorize_lyra_dashboard!

    # A model_class parameter that names no monitored model answers 404.
    class UnknownModel < StandardError; end
    rescue_from(UnknownModel) { head :not_found }

    # The dashboard reads as the application does, under a purpose: the one the
    # request names (?purpose=), else config.dashboard_purpose; with neither it
    # reads without one, as config.reads_without_purpose decides. A read the
    # policy refuses answers 403 and says how to name a purpose.
    around_action :with_dashboard_purpose
    READ_REFUSALS = [Lyra::PurposeBoundReads::PurposeRequiredError] +
                    %w[PurposeFieldMismatchError UndeclaredPurposeError ConsentRequiredError UndeterminedBasisError
                       SensitivityViolationError InvalidFieldError]
                      .filter_map { |name| PamDsl.const_get(name) if defined?(PamDsl) && PamDsl.const_defined?(name) }
    rescue_from(*READ_REFUSALS) { |error| refuse_read(error) }

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

    def with_dashboard_purpose(&block)
      purpose = params[:purpose].presence || Lyra.config.dashboard_purpose
      return yield unless purpose

      Lyra::PurposeBoundReads.with_purpose(purpose, &block)
    end

    def refuse_read(error)
      message = "The dashboard read was refused: #{error.message}. Name a purpose the policy allows for it " \
                "(?purpose=...), or set config.dashboard_purpose."
      if request.format.json?
        render json: { error: message }, status: :forbidden
      else
        render plain: message, status: :forbidden
      end
    end

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

    # The monitored model a request names, or 404. The routes that take a model
    # read its records and return their attributes, so only models Lyra monitors
    # may be named: resolving any constant (as 0.9.2 and earlier did) let a
    # dashboard user read any table, unmonitored ones included.
    def monitored_model!(name)
      Lyra.config.monitored_model_named(name) || raise(UnknownModel, name.to_s)
    end

    # The most recent events, newest first, at most this request's ?limit=
    # (default and ceiling: config.dashboard_max_events), access-log entries
    # left out (Lyra::EventWindow): a dashboard request does not read the whole
    # log. @window says what was read, for the response.
    def recent_events
      max = Lyra.config.dashboard_max_events
      limit = bounded_param(:limit, default: max, max: max)
      events, @window = Lyra::EventWindow.recent(limit)
      events
    end

    # Record a dashboard read in the access log (when config.record_access_events
    # is on): which route, for what, how much came back, never a value.
    def log_dashboard_read(route, scope = {}, returned: nil)
      # The access log loads with PAM DSL; without it there is nothing to record to.
      return unless defined?(Lyra::AccessLog)

      Lyra::AccessLog.dashboard_read(route: route, scope: scope, returned: returned, truncated: @window&.dig(:truncated))
    end

    # An integer parameter, clamped to 1..max; the default when absent. Bounds
    # the work a single dashboard request can ask for.
    def bounded_param(key, default:, max:)
      value = params[key].presence&.to_i || default
      value.clamp(1, max)
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
