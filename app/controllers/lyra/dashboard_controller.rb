module Lyra
  class DashboardController < ApplicationController
    helper_method :user_display_name
    before_action :ensure_models_loaded

    # GET /lyra/dashboard
    def index
      @monitored_models = Lyra.config.monitored_models
      @mode = Lyra.config.mode
    end

    # GET /lyra/dashboard/model/:model_class
    def model_overview
      @model_class = params[:model_class].constantize
      @records_count = @model_class.count
      @events_count = count_events_for_model(@model_class)
    end

    # GET /lyra/dashboard/compare/:model_class/:id
    def compare
      model_class = params[:model_class].constantize
      model_id = params[:id]

      @comparison = DualView.new(model_class, model_id).compare
      @audit_trail = DualView.new(model_class, model_id).audit_trail
      @analysis = StateAnalyzer.analyze(model_class, model_id)

      render json: {
        comparison: @comparison,
        audit_trail: @audit_trail,
        analysis: @analysis
      }
    end

    # GET /lyra/dashboard/discrepancies/:model_class
    def discrepancies
      @model_class = params[:model_class].constantize
      @discrepancies = DualView.find_discrepancies(@model_class)

      respond_to do |format|
        format.html
        format.json { render json: { discrepancies: @discrepancies } }
      end
    end

    # GET /lyra/config/projections
    def projections
      @mode = Lyra.config.mode
      @projection_mode = Lyra.config.projection_mode
      @strict_projections = Lyra.config.strict_projections
      @monitored_models = Lyra.config.monitored_models
      @async_inline = Lyra.config.async_projections_inline

      # Projection types available in Lyra
      @projection_types = [
        {
          name: "StateProjection",
          description: "Rebuilds current state by replaying events. Used for dual-view comparison between DB and event-sourced state.",
          use_case: "Consistency checking, debugging, state recovery"
        },
        {
          name: "AuditProjection",
          description: "Generates chronological audit trail from events. Shows who changed what and when.",
          use_case: "Compliance reporting, change history, forensics"
        },
        {
          name: "ModelProjection",
          description: "Synchronizes ActiveRecord model tables from events using raw SQL (bypasses callbacks).",
          use_case: "Event sourcing mode - keeps read models in sync"
        },
        {
          name: "AsyncProjectionJob",
          description: "Background job for eventual consistency. Retries with exponential backoff on failures.",
          use_case: "High-throughput systems, async projection mode",
          queue: "lyra_projections",
          retry_attempts: 5
        }
      ]

      # Get model configurations
      @model_configs = {}
      @monitored_models.each do |model_class|
        config = Lyra.config.model_config(model_class)
        @model_configs[model_class.name] = {
          event_prefix: config.event_prefix,
          aggregate_class: config.aggregate_class,
          command_handler: config.command_handler,
          privacy_policy: config.privacy_policy
        }
      end

      # Get event counts per model with operation breakdown
      @model_stats = {}
      @monitored_models.each do |model_class|
        events = collect_events_for_model(model_class)
        record_count = model_class.count rescue 0

        # Group by operation
        by_operation = events.group_by { |e| e.data[:operation] || e.data["operation"] }

        @model_stats[model_class.name] = {
          events: events.count,
          records: record_count,
          avg_events_per_record: record_count > 0 ? (events.count.to_f / record_count).round(2) : 0,
          created: by_operation[:created]&.count || by_operation["created"]&.count || 0,
          updated: by_operation[:updated]&.count || by_operation["updated"]&.count || 0,
          destroyed: by_operation[:destroyed]&.count || by_operation["destroyed"]&.count || 0,
          last_event_at: events.max_by { |e| e.metadata[:timestamp] || e.timestamp rescue Time.at(0) }&.then { |e| e.metadata[:timestamp] || e.timestamp rescue nil }
        }
      end
    end

    # GET /lyra/dashboard/audit_trail
    def audit_trail
      @monitored_models = Lyra.config.monitored_models
      @selected_model = params[:model_class]
      @selected_id = params[:record_id]
      @search_query = params[:search]

      # If a model is selected, load available records for the picker
      if @selected_model.present?
        @model_class = @selected_model.constantize
        @available_records = fetch_available_records(@model_class, @search_query)
      end

      if @selected_model.present? && @selected_id.present?
        @record = @model_class.find_by(id: @selected_id)
        @audit_entries = AuditProjection.audit_trail(@model_class, @selected_id)
      end
    end

    # GET /lyra/dashboard/audit_trail/:model_class/:id
    def audit_trail_for_record
      @model_class = params[:model_class].constantize
      @model_id = params[:id]
      @record = @model_class.find_by(id: @model_id)
      @audit_entries = AuditProjection.audit_trail(@model_class, @model_id)
      @monitored_models = Lyra.config.monitored_models

      respond_to do |format|
        format.html { render :audit_trail }
        format.json { render json: { audit_trail: @audit_entries, record_id: @model_id, model: @model_class.name } }
      end
    end

    # GET /lyra/dashboard/visualizations/timeline
    def timeline
      events = fetch_recent_events(limit: params[:limit]&.to_i || 100)
      timeline = Visualization::Timeline.new(events)

      render json: timeline.to_data
    end

    # GET /lyra/dashboard/visualizations/event_graph
    # Returns filtered events based on query params
    def event_graph
      events = fetch_filtered_events(
        model_class: params[:model_class],
        operation: params[:operation],
        limit: params[:limit]&.to_i || 50
      )
      graph = Visualization::EventGraph.new(events)

      render json: graph.to_data
    end

    # GET /lyra/dashboard/visualizations/entity_graph/:model_class/:id
    # Returns focused graph for a specific entity's lifecycle
    def entity_graph
      model_class = params[:model_class]
      model_id = params[:id]
      depth = params[:depth]&.to_i || 1  # How many related entities to include

      events = fetch_entity_events(model_class, model_id, depth: depth)
      graph = Visualization::EventGraph.new(events)

      render json: graph.to_data.merge(
        focused_entity: { model_class: model_class, model_id: model_id }
      )
    end

    # GET /lyra/dashboard/visualizations/event_list
    # Returns list of entities with event counts for the picker UI
    def event_list
      model_filter = params[:model_class]
      limit = params[:limit]&.to_i || 20

      entities = []
      models = model_filter.present? ? [model_filter.constantize] : Lyra.config.monitored_models

      models.each do |model_class|
        model_class.order(updated_at: :desc).limit(limit).each do |record|
          stream_name = "#{model_class.name}$#{record.id}"
          begin
            event_count = Lyra.config.event_store.read.stream(stream_name).count
            next if event_count == 0

            # Get display name for the record
            display_name = record_display_name(record)

            entities << {
              model_class: model_class.name,
              model_id: record.id,
              display_name: display_name,
              event_count: event_count,
              updated_at: record.updated_at
            }
          rescue
            # Skip if stream doesn't exist
          end
        end
      end

      # Sort by event_count descending, then updated_at descending
      entities.sort_by! { |e| [-e[:event_count], -e[:updated_at].to_i] }
      entities = entities.first(limit)

      render json: {
        entities: entities,
        model_classes: Lyra.config.monitored_models.map(&:name)
      }
    end

    # GET /lyra/dashboard/visualizations/heatmap
    def heatmap
      events = fetch_events_for_period(days: params[:days]&.to_i || 7)
      heatmap = Visualization::ActivityHeatmap.new(events)

      render json: heatmap.to_data
    end

    # GET /lyra/visualizations/event_graph (HTML view)
    def event_graph_view
      @limit = params[:limit]&.to_i || 50
      events = fetch_recent_events(limit: @limit)
      graph = Visualization::EventGraph.new(events)
      @graph_data = graph.to_data
      @mermaid = graph.to_mermaid
    end

    # GET /lyra/visualizations/heatmap (HTML view)
    def heatmap_view
      @days = params[:days]&.to_i || 7
      events = fetch_events_for_period(days: @days)
      heatmap = Visualization::ActivityHeatmap.new(events)
      @heatmap_data = heatmap.to_data
      @hourly = heatmap.hourly_breakdown
      @daily = heatmap.daily_breakdown
      @operation_heatmap = heatmap.operation_heatmap
    end

    # GET /lyra/verification (HTML view)
    def verification
      @petri_flow_available = Lyra.petri_flow_available?

      if @petri_flow_available
        verifier = Lyra::Verification::CrudVerifier.new
        @report = verifier.verify_all
        @summary = @report[:summary]
        @lifecycle = @report[:details][:lifecycle]
        @modes = @report[:details][:modes]
        @generated_workflows = @report[:details][:generated_workflows] || {}
      else
        @report = nil
        @summary = nil
        @generated_workflows = {}
      end
    end

    # GET /lyra/verification.json
    def verification_data
      if Lyra.petri_flow_available?
        verifier = Lyra::Verification::CrudVerifier.new
        render json: verifier.verify_all
      else
        render json: { error: "PetriFlow not available", available: false }, status: :service_unavailable
      end
    end

    # GET /lyra/dashboard/schema
    def schema
      @schema = Schema::Store.load_current || Schema::Generator.generate
      @report = Schema::Reporter.new.generate

      # Parse schema for view
      @version = @schema[:version]
      @fingerprint = @schema[:fingerprint]
      @created_at = @schema[:created_at]
      @lyra_version = @schema[:lyra_version]
      @configuration = @schema[:configuration] || {}
      @models = @schema[:models] || {}
      @summary = @schema[:summary] || {}

      # Load version history
      @history = Schema::Store.history.reverse  # Most recent first

      # Check for uncommitted changes
      if @version
        current_schema = Schema::Generator.generate
        @pending_changes = Schema::Diff.compare(@schema, current_schema)
        @has_pending_changes = @pending_changes.any?
      else
        @pending_changes = []
        @has_pending_changes = false
      end

      respond_to do |format|
        format.html
        format.json { render json: @schema }
      end
    end

    # GET /lyra/dashboard/schema/:version
    def schema_version
      version = params[:version].to_i
      @schema = Schema::Store.load_version(version)

      unless @schema
        redirect_to schema_path, alert: "Schema version #{version} not found"
        return
      end

      # Schema metadata
      @version = @schema[:version]
      @fingerprint = @schema[:fingerprint]
      @created_at = @schema[:created_at]
      @lyra_version = @schema[:lyra_version]
      @rails_version = @schema[:rails_version]
      @configuration = @schema[:configuration] || {}
      @models = @schema[:models] || {}
      @summary = @schema[:summary] || {}

      # Load version history for navigation
      @history = Schema::Store.history
      @current_index = @history.find_index { |h| h[:version] == version }
      @prev_version = @current_index && @current_index > 0 ? @history[@current_index - 1][:version] : nil
      @next_version = @current_index && @current_index < @history.size - 1 ? @history[@current_index + 1][:version] : nil

      # Compare with previous version if available
      if @prev_version
        prev_schema = Schema::Store.load_version(@prev_version)
        @diff_from_previous = Schema::Diff.compare(prev_schema, @schema) if prev_schema
      end

      respond_to do |format|
        format.html
        format.json { render json: @schema }
      end
    end

    # GET /lyra/dashboard/schema/history
    def schema_history
      @history = Schema::Store.history.reverse  # Most recent first
      @current_version = Schema::Store.load_current&.dig(:version)

      respond_to do |format|
        format.html
        format.json { render json: { history: @history, current_version: @current_version } }
      end
    end

    # GET /lyra/dashboard/visualizations/model_heatmap/:model_class
    def model_heatmap
      model_class = params[:model_class].constantize
      events = fetch_events_for_model(model_class, days: params[:days]&.to_i || 7)
      heatmap = Visualization::ActivityHeatmap.new(events)

      render json: {
        heatmap: heatmap.to_data,
        model_specific: heatmap.model_heatmap,
        operation_breakdown: heatmap.operation_heatmap
      }
    end

    private

    # Ensure models are loaded so Lyra.config.monitored_models is populated
    # In development mode, Rails uses lazy loading so models with monitor_with_lyra
    # may not be loaded yet when the dashboard is accessed
    def ensure_models_loaded
      return if Rails.application.config.eager_load

      # Only eager load the models directory to avoid loading the entire app
      models_path = Rails.root.join("app", "models")
      if models_path.exist?
        Dir[models_path.join("**", "*.rb")].each do |file|
          require_dependency file
        rescue StandardError
          # Skip files that can't be loaded
        end
      end
    end

    def count_events_for_model(model_class)
      collect_events_for_model(model_class).count
    end

    def collect_events_for_model(model_class)
      # Collect all events for a model class
      events = []
      model_class.pluck(:id).each do |id|
        stream_name = "#{model_class.name}$#{id}"
        begin
          events.concat(Lyra.config.event_store.read.stream(stream_name).to_a)
        rescue
          # Skip if stream doesn't exist
        end
      end
      events
    end

    def fetch_available_records(model_class, search_query = nil)
      # Determine display fields for this model
      display_fields = [:name, :title, :email, :firstname, :lastname, :description, :label].select do |field|
        model_class.column_names.include?(field.to_s)
      end

      scope = model_class.order(updated_at: :desc)

      # Apply search if provided
      if search_query.present? && display_fields.any?
        conditions = display_fields.map { |f| "#{f} LIKE ?" }.join(' OR ')
        search_term = "%#{search_query}%"
        scope = scope.where(conditions, *([search_term] * display_fields.size))
      end

      # Limit results
      records = scope.limit(50)

      # Build display info for each record
      records.map do |record|
        display_name = display_fields.map { |f| record.send(f) }.compact.first
        display_name ||= "Record ##{record.id}"

        # Add more context if available
        if model_class.column_names.include?('firstname') && model_class.column_names.include?('lastname')
          full_name = [record.firstname, record.lastname].compact.join(' ')
          display_name = full_name if full_name.present?
        end

        {
          id: record.id,
          display_name: display_name,
          updated_at: record.updated_at,
          extra_info: build_extra_info(record, display_fields)
        }
      end
    end

    def build_extra_info(record, display_fields)
      info = []
      info << record.email if record.respond_to?(:email) && record.email.present? && !display_fields.include?(:email)
      info << record.phone if record.respond_to?(:phone) && record.phone.present?
      info << "Amount: #{record.amount}" if record.respond_to?(:amount) && record.amount.present?
      info << record.status.to_s.titleize if record.respond_to?(:status) && record.status.present?
      info.first(2).join(' | ')
    end

    def fetch_recent_events(limit: 100)
      events = []
      Lyra.config.monitored_models.each do |model_class|
        model_class.order(updated_at: :desc).limit(limit / Lyra.config.monitored_models.size).each do |record|
          stream_name = "#{model_class.name}$#{record.id}"
          begin
            stream_events = Lyra.config.event_store.read.stream(stream_name).to_a
            events.concat(stream_events)
          rescue
            # Skip if stream doesn't exist
          end
        end
      end
      events.sort_by { |e| event_timestamp(e) }.last(limit)
    end

    def fetch_filtered_events(model_class: nil, operation: nil, limit: 50)
      events = []
      models = model_class.present? ? [model_class.constantize] : Lyra.config.monitored_models

      models.each do |klass|
        klass.order(updated_at: :desc).limit(limit).each do |record|
          stream_name = "#{klass.name}$#{record.id}"
          begin
            stream_events = Lyra.config.event_store.read.stream(stream_name).to_a
            events.concat(stream_events)
          rescue
            # Skip if stream doesn't exist
          end
        end
      end

      # Filter by operation if specified
      if operation.present?
        events = events.select do |e|
          op = e.data[:operation] || e.data["operation"]
          op.to_s == operation.to_s
        end
      end

      events.sort_by { |e| event_timestamp(e) }.last(limit)
    end

    def fetch_entity_events(model_class, model_id, depth: 1)
      events = []
      stream_name = "#{model_class}$#{model_id}"

      begin
        # Get all events for the primary entity
        primary_events = Lyra.config.event_store.read.stream(stream_name).to_a
        events.concat(primary_events)

        # If depth > 0, also include related entities (via correlation_id)
        if depth > 0 && primary_events.any?
          correlation_ids = primary_events.map { |e| e.metadata[:correlation_id] }.compact.uniq

          # Find events sharing correlation IDs
          correlation_ids.each do |corr_id|
            Lyra.config.monitored_models.each do |klass|
              klass.order(updated_at: :desc).limit(20).each do |record|
                other_stream = "#{klass.name}$#{record.id}"
                next if other_stream == stream_name

                begin
                  other_events = Lyra.config.event_store.read.stream(other_stream).to_a
                  related = other_events.select { |e| e.metadata[:correlation_id] == corr_id }
                  events.concat(related)
                rescue
                  # Skip
                end
              end
            end
          end
        end
      rescue
        # Stream doesn't exist
      end

      events.uniq { |e| e.event_id }.sort_by { |e| event_timestamp(e) }
    end

    def record_display_name(record)
      # Try common display name fields
      [:name, :title, :email, :display_name].each do |field|
        return record.send(field) if record.respond_to?(field) && record.send(field).present?
      end

      # Try firstname + lastname
      if record.respond_to?(:firstname) && record.respond_to?(:lastname)
        full_name = [record.firstname, record.lastname].compact.join(' ')
        return full_name if full_name.present?
      end

      # Fallback
      "#{record.class.name}##{record.id}"
    end

    def fetch_events_for_period(days: 7)
      cutoff = days.days.ago
      events = []

      Lyra.config.monitored_models.each do |model_class|
        model_class.where("updated_at >= ?", cutoff).find_each do |record|
          stream_name = "#{model_class.name}$#{record.id}"
          begin
            stream_events = Lyra.config.event_store.read.stream(stream_name).to_a
            events.concat(stream_events.select { |e| event_timestamp(e) >= cutoff })
          rescue
            # Skip if stream doesn't exist
          end
        end
      end

      events.sort_by { |e| event_timestamp(e) }
    end

    def fetch_events_for_model(model_class, days: 7)
      cutoff = days.days.ago
      events = []

      model_class.where("updated_at >= ?", cutoff).find_each do |record|
        stream_name = "#{model_class.name}$#{record.id}"
        begin
          stream_events = Lyra.config.event_store.read.stream(stream_name).to_a
          events.concat(stream_events.select { |e| event_timestamp(e) >= cutoff })
        rescue
          # Skip if stream doesn't exist
        end
      end

      events.sort_by { |e| event_timestamp(e) }
    end

    def event_timestamp(event)
      return event.timestamp if event.respond_to?(:timestamp) && event.timestamp
      event.data[:timestamp] || event.data["timestamp"] || event.metadata[:timestamp]
    end

    # Look up user display name from user_id
    # Tries to find a User model with name/display_name method
    # Falls back to "User #ID" if lookup fails
    def user_display_name(user_id)
      return nil unless user_id

      begin
        # Try to find User model in the host app
        if defined?(::User) && ::User.respond_to?(:find_by)
          user = ::User.find_by(id: user_id)
          if user
            # Prefer display_name, then name, then username
            return user.display_name if user.respond_to?(:display_name)
            return user.name if user.respond_to?(:name)
            return user.username if user.respond_to?(:username)
            return user.email if user.respond_to?(:email)
          end
        end
      rescue => e
        # Log but don't fail if user lookup has issues
        Rails.logger.debug { "Lyra: Could not look up user ##{user_id}: #{e.message}" }
      end

      # Fallback to showing the ID
      "User ##{user_id}"
    end
  end
end
