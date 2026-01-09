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

      render json: {
        subject: { type: subject_type, id: subject_id },
        data_export: compliance.data_export,
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
        right_to_access: compliance.data_export,
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

      flow = EventFlow.new(subject_id: subject_id, subject_type: subject_type)
      data = flow.privacy_impact_analysis

      render json: data
    end

    # GET /lyra/privacy/data_lineage/:field_name
    def data_lineage
      field_name = params[:field_name]
      model_class = params[:model_class]

      flow = EventFlow.new
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

    # GET /lyra/privacy/pii_detection
    def pii_detection
      # Detect PII across all events
      events = Lyra.config.event_store.read.to_a
      @pii_inventory = extract_pii_from_events(events)

      @total_events = events.count
      @events_with_pii = events.count { |e| Privacy::PIIDetector.detect(event_attributes(e)).any? }
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

    def event_attributes(event)
      # First try Lyra::Event accessor method
      if event.respond_to?(:attributes)
        attrs = event.attributes
        return attrs if attrs.is_a?(Hash)
      end
      # Fall back to data hash for RubyEventStore events
      data = event.respond_to?(:data) ? event.data : nil
      return {} unless data
      data[:attributes] || data["attributes"] || {}
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
        pii = Privacy::PIIDetector.detect(event_attributes(event))
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
