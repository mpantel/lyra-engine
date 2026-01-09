module Lyra
  class FlowController < ApplicationController
    # GET /lyra/flow/timeline
    def timeline
      subject_id = params[:subject_id]
      subject_type = params[:subject_type]

      flow = EventFlow.new(
        subject_id: subject_id,
        subject_type: subject_type
      )

      @flow_data = flow.flow_data
      @timeline = @flow_data[:timeline] || []
      @flows = @flow_data[:flows] || []
      @statistics = @flow_data[:statistics] || {}
      @privacy_impact = @flow_data[:privacy_impact] || {}

      # Get available filter options
      @available_models = @timeline.map { |e| e[:model_class] }.compact.uniq.sort
      @available_operations = @timeline.map { |e| e[:operation] }.compact.uniq.sort

      # Apply filters
      @filter_model = params[:model]
      @filter_operation = params[:operation]

      if @filter_model.present?
        @timeline = @timeline.select { |e| e[:model_class] == @filter_model }
      end
      if @filter_operation.present?
        @timeline = @timeline.select { |e| e[:operation].to_s == @filter_operation }
      end

      respond_to do |format|
        format.html
        format.json { render json: @flow_data }
      end
    end

    # GET /lyra/flow/event_chain/:model_class/:model_id
    def event_chain
      model_class = params[:model_class].constantize
      model_id = params[:model_id]

      flow = EventFlow.new
      chain = flow.reconstruct_state_chain(model_class.name, model_id)

      render json: chain
    end

    # GET /lyra/flow/crud_mapping
    def crud_mapping
      model_class = params[:model_class]
      operation = params[:operation]&.to_sym
      model_id = params[:model_id]

      if model_class && operation
        # Specific mapping lookup
        flow = EventFlow.new
        mapping = flow.crud_to_event_mapping(model_class, operation, model_id)
        respond_to do |format|
          format.html { render json: mapping }
          format.json { render json: mapping }
        end
      else
        # Show summary of all CRUD operations
        events = Lyra.config.event_store.read.to_a
        @models_summary = events.group_by { |e| event_model_class(e) }.transform_values do |model_events|
          {
            total: model_events.count,
            operations: model_events.group_by { |e| event_operation(e) }.transform_values(&:count)
          }
        end
        @total_events = events.count
        @operations_summary = events.group_by { |e| event_operation(e) }.transform_values(&:count)

        respond_to do |format|
          format.html
          format.json do
            render json: {
              total_events: @total_events,
              operations: @operations_summary,
              models: @models_summary
            }
          end
        end
      end
    end

    # GET /lyra/flow/visualization/:model_class/:model_id
    def visualization
      model_class = params[:model_class].constantize
      model_id = params[:model_id]
      format = params[:format] || 'json'

      stream_name = "#{model_class.name}$#{model_id}"
      events = Lyra.config.event_store.read.stream(stream_name).to_a

      timeline = Visualization::Timeline.new(events)

      case format
      when 'html'
        render html: timeline.to_html.html_safe
      when 'mermaid'
        render plain: timeline.to_mermaid
      when 'ascii'
        render plain: timeline.to_ascii
      when 'd3'
        render json: JSON.parse(timeline.to_d3_json)
      else
        render json: timeline.to_data
      end
    end

    # GET /lyra/flow/correlation/:correlation_id
    def correlation
      correlation_id = params[:correlation_id]

      events = Lyra.config.event_store.read.to_a.select do |event|
        event.metadata[:correlation_id] == correlation_id
      end

      flow = EventFlow.new
      timeline = flow.build_timeline(events)

      render json: {
        correlation_id: correlation_id,
        events_count: events.count,
        started_at: events.min_by(&:timestamp)&.timestamp,
        completed_at: events.max_by(&:timestamp)&.timestamp,
        events: timeline,
        privacy_impact: pam_dsl_available? ? events.count { |e| Privacy::PIIDetector.detect(event_attributes(e)).any? } : nil
      }
    end

    # GET /lyra/flow/user_actions/:user_id
    def user_actions
      user_id = params[:user_id]

      events = Lyra.config.event_store.read.to_a.select do |event|
        event.metadata[:user_id] == user_id.to_i
      end

      actions = events.group_by { |e| e.metadata[:action_id] }

      render json: {
        user_id: user_id,
        total_actions: actions.count,
        total_events: events.count,
        actions: actions.map do |action_id, action_events|
          {
            action_id: action_id,
            user_action: action_events.first.metadata[:user_action],
            timestamp: event_timestamp(action_events.min_by { |e| event_timestamp(e) }),
            events_count: action_events.count,
            models_affected: action_events.map { |e| event_model_class(e) }.uniq,
            pii_affected: pam_dsl_available? ? action_events.any? { |e| Privacy::PIIDetector.detect(event_attributes(e)).any? } : nil
          }
        end
      }
    end

    private

    def pam_dsl_available?
      defined?(PAM_DSL_AVAILABLE) && PAM_DSL_AVAILABLE
    end

    # Helper methods to extract data from events (works with both Lyra::Event and RubyEventStore::Event)
    def event_operation(event)
      return event.operation if event.respond_to?(:operation)
      data = event.respond_to?(:data) ? event.data : nil
      return nil unless data
      op = data[:operation] || data["operation"]
      op.is_a?(String) ? op.to_sym : op
    end

    def event_model_class(event)
      return event.model_class if event.respond_to?(:model_class)
      data = event.respond_to?(:data) ? event.data : nil
      return nil unless data
      data[:model_class] || data["model_class"]
    end

    def event_model_id(event)
      return event.model_id if event.respond_to?(:model_id)
      data = event.respond_to?(:data) ? event.data : nil
      return nil unless data
      data[:model_id] || data["model_id"]
    end

    def event_timestamp(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      data = event.respond_to?(:data) ? event.data : nil
      return nil unless data
      data[:timestamp] || data["timestamp"] || event.metadata[:timestamp]
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

    def load_events(subject_id, subject_type)
      events = Lyra.config.event_store.read.to_a

      if subject_id && subject_type
        events = events.select do |event|
          event.metadata[:user_id] == subject_id.to_i ||
          (event_model_class(event) == subject_type && event_model_id(event) == subject_id.to_i)
        end
      end

      events
    end
  end
end
