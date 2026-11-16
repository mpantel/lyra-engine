module Lyra
  class PrivacyController < ApplicationController
    before_action :require_pam_dsl, except: [:policy]

    # GET /lyra/privacy/subject/:subject_type/:subject_id
    def subject_data
      subject_type = params[:subject_type]
      subject_id = params[:subject_id]

      compliance = Privacy::GDPRCompliance.new(
        subject_id: subject_id,
        subject_type: subject_type
      )

      # A view of the data, not an answered Art. 15 request: not recorded as an
      # export (the application's explicit data_export call is).
      render json: {
        subject: { type: subject_type, id: subject_id },
        data_export: compliance.data_export(record: false),
        generated_at: Time.current
      }
    end

    # GET /lyra/privacy/gdpr_report/:subject_type/:subject_id
    def gdpr_report
      subject_type = params[:subject_type]
      subject_id = params[:subject_id]

      compliance = Privacy::GDPRCompliance.new(
        subject_id: subject_id,
        subject_type: subject_type
      )

      render json: {
        subject: { type: subject_type, id: subject_id },
        right_to_access: compliance.data_export(record: false), # a view, not recorded as an export
        right_to_be_forgotten: compliance.right_to_be_forgotten_report,
        rectification_history: compliance.rectification_history,
        processing_activities: compliance.processing_activities,
        retention_compliance: compliance.retention_compliance_check,
        consent_audit: compliance.consent_audit
      }
    end

    # GET /lyra/privacy/portable_export/:subject_type/:subject_id
    def portable_export
      subject_type = params[:subject_type]
      subject_id = params[:subject_id]
      format = params[:format]&.to_sym || :json

      compliance = Privacy::GDPRCompliance.new(
        subject_id: subject_id,
        subject_type: subject_type
      )

      data = compliance.portable_export(format: format)

      case format
      when :json
        render json: data
      when :csv
        send_data data, filename: "data_export_#{subject_id}.csv", type: 'text/csv'
      when :xml
        send_data data, filename: "data_export_#{subject_id}.xml", type: 'application/xml'
      else
        render json: { error: "Unsupported format" }, status: :bad_request
      end
    end

    # GET /lyra/privacy/pii_inventory/:subject_type/:subject_id
    def pii_inventory
      subject_type = params[:subject_type]
      subject_id = params[:subject_id]

      subject_model = Lyra.config.monitored_model_named(subject_type.to_s)
      refuse_restricted_record!(subject_model, subject_id) if subject_model
      flow = EventFlow.new(subject_id: subject_id, subject_type: subject_type, event_filter: method(:rights_visible))
      data = flow.privacy_impact_analysis

      render json: data
    end

    # GET /lyra/privacy/data_lineage/:field_name
    def data_lineage
      field_name = params[:field_name]
      model_class = params[:model_class]

      flow = EventFlow.new(event_filter: method(:rights_visible))
      lineage = flow.data_lineage(field_name, model_class)

      render json: lineage
    end

    # GET /lyra/privacy/policy
    def policy
      @pam_dsl_available = pam_dsl_available?
      @policies = @pam_dsl_available && PamDsl.respond_to?(:registry) ? PamDsl.registry.policies : {}
      @default_policy_name = Rails.application.config.respond_to?(:pam_dsl) ?
        Rails.application.config.pam_dsl.default_policy : nil
    end

    # GET /lyra/privacy/rights
    # The data subjects' requests still open (PamDsl.rights.open_requests):
    # restrictions not yet lifted (Art. 18) and objections not yet decided
    # (Art. 21), oldest first, each with its age against the month Art. 12(3)
    # gives the controller to act on a request. It reads Lyra's rights table,
    # not a monitored model's records, under the dashboard's purpose rules,
    # and is logged as a dashboard read. Names, grounds and states only:
    # never a value of the subject's data.
    def rights
      now = Time.current
      requests = PamDsl.rights.open_requests
      log_dashboard_read("privacy/rights", {}, returned: requests.size)
      @requests = requests.map { |request| open_request_row(request, now) }

      respond_to do |format|
        format.html
        format.json { render json: { open_requests: @requests, generated_at: now } }
      end
    end

    # GET /lyra/privacy/pii_detection
    def pii_detection
      # Detect PII across the most recent events (bounded: recent_events)
      events = recent_events
      log_dashboard_read("privacy/pii_detection", {}, returned: events.size)
      @pii_inventory = extract_pii_from_events(events)

      @total_events = events.count
      @events_with_pii = events.count { |e| Privacy::PIIDetector.detect(event_fields(e)).any? }
      @pii_categories = @pii_inventory.keys
      @sensitive_pii = @pii_inventory.select { |k, _|
        [:ssn, :credit_card, :health, :biometric].include?(k)
      }.keys
      @contact_pii = @pii_inventory.select { |k, _|
        [:email, :phone, :address].include?(k)
      }.keys

      respond_to do |format|
        format.html
        format.json do
          render json: {
            total_events: @total_events,
            events_with_pii: @events_with_pii,
            pii_categories: @pii_categories,
            pii_inventory: @pii_inventory,
            summary: {
              sensitive_pii: @sensitive_pii,
              contact_pii: @contact_pii
            }
          }
        end
      end
    end

    private

    # One open request, for the rights page. Only an objection still awaiting
    # the controller's decision has a deadline: one month from its receipt
    # (Art. 12(3); an extension under its second sentence is the
    # controller's to record and tell the subject of). A restriction in
    # force is the controller's action on the request already (Lyra records
    # it when it is applied), so it is listed with its age and no deadline:
    # it lasts until it is lifted, with the Art. 18(3) notice.
    def open_request_row(request, now)
      restriction = request.kind == :restriction
      deadline = restriction ? nil : (request.requested_at.to_datetime >> 1).to_time
      {
        id: request.id, kind: request.kind, subject: request.subject_key, article: request.article,
        ground: restriction ? request.ground : nil, fields: restriction ? request.fields : [],
        policy: restriction ? nil : request.policy, purpose: restriction ? nil : request.purpose,
        state: request.state, requested_at: request.requested_at,
        age_days: ((now - request.requested_at) / 86_400).floor, deadline: deadline,
        overdue: deadline ? now > deadline : false
      }
    end

    def require_pam_dsl
      unless defined?(PAM_DSL_AVAILABLE) && PAM_DSL_AVAILABLE
        respond_to do |format|
          format.html { render plain: "Privacy features require PAM DSL. Add 'pam_dsl' to your Gemfile.", status: :service_unavailable }
          format.json { render json: { error: "Privacy features unavailable", message: "PAM DSL is not installed" }, status: :service_unavailable }
        end
      end
    end

    def pam_dsl_available?
      defined?(PAM_DSL_AVAILABLE) && PAM_DSL_AVAILABLE
    end

    # The fields an event gives or changes, whatever mode wrote it
    # (Lyra::Event.fields_of): what personal data is detected in.
    def event_fields(event)
      Lyra::Event.fields_of(event)
    end

    def event_model_class(event)
      return event.model_class if event.respond_to?(:model_class)
      data = event.respond_to?(:data) ? event.data : nil
      return nil unless data
      data[:model_class] || data["model_class"]
    end

    def extract_pii_from_events(events)
      inventory = Hash.new { |h, k| h[k] = [] }
      events.each do |event|
        pii = Privacy::PIIDetector.detect(event_fields(event))
        next unless pii.is_a?(Hash)
        pii.each do |field, info|
          next unless info.is_a?(Hash) && info[:type]
          inventory[info[:type]] << {
            field: field,
            model_class: event_model_class(event),
            value: info[:value]
          }
        end
      end
      inventory
    end
  end
end
