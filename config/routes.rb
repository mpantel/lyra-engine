Lyra::Engine.routes.draw do
  # Root redirect to dashboard
  root to: redirect('/lyra/dashboard')

  # Dashboard routes
  get 'dashboard', to: 'dashboard#index'
  get 'dashboard/model/:model_class', to: 'dashboard#model_overview', as: :model_overview
  get 'dashboard/compare/:model_class/:id', to: 'dashboard#compare', as: :compare
  get 'dashboard/discrepancies/:model_class', to: 'dashboard#discrepancies', as: :discrepancies
  get 'dashboard/audit_trail', to: 'dashboard#audit_trail', as: :audit_trail
  get 'dashboard/audit_trail/:model_class/:id', to: 'dashboard#audit_trail_for_record', as: :audit_trail_for_record

  # Privacy and GDPR routes
  get 'privacy/subject/:subject_type/:subject_id', to: 'privacy#subject_data', as: :subject_data
  get 'privacy/gdpr_report/:subject_type/:subject_id', to: 'privacy#gdpr_report', as: :gdpr_report
  get 'privacy/portable_export/:subject_type/:subject_id', to: 'privacy#portable_export', as: :portable_export
  get 'privacy/pii_inventory/:subject_type/:subject_id', to: 'privacy#pii_inventory', as: :pii_inventory
  get 'privacy/data_lineage/:field_name', to: 'privacy#data_lineage', as: :data_lineage
  get 'privacy/pii_detection', to: 'privacy#pii_detection', as: :pii_detection
  get 'privacy/policy', to: 'privacy#policy', as: :privacy_policy

  # Configuration and projections routes
  get 'config/projections', to: 'dashboard#projections', as: :projections
  get 'dashboard/schema', to: 'dashboard#schema', as: :schema
  get 'dashboard/schema/history', to: 'dashboard#schema_history', as: :schema_history
  get 'dashboard/schema/:version', to: 'dashboard#schema_version', as: :schema_version

  # Event flow and visualization routes
  get 'flow/timeline', to: 'flow#timeline', as: :timeline
  get 'flow/event_chain/:model_class/:model_id', to: 'flow#event_chain', as: :event_chain
  get 'flow/crud_mapping', to: 'flow#crud_mapping', as: :crud_mapping
  get 'flow/visualization/:model_class/:model_id', to: 'flow#visualization', as: :visualization
  get 'flow/correlation/:correlation_id', to: 'flow#correlation', as: :correlation
  get 'flow/user_actions/:user_id', to: 'flow#user_actions', as: :user_actions

  # Visualization routes (JSON API + HTML views)
  get 'visualizations/event_graph', to: 'dashboard#event_graph_view', as: :event_graph_view
  get 'visualizations/heatmap', to: 'dashboard#heatmap_view', as: :heatmap_view
  get 'visualizations/event_graph.json', to: 'dashboard#event_graph', as: :event_graph_data
  get 'visualizations/entity_graph/:model_class/:id.json', to: 'dashboard#entity_graph', as: :entity_graph_data
  get 'visualizations/event_list.json', to: 'dashboard#event_list', as: :event_list_data
  get 'visualizations/heatmap.json', to: 'dashboard#heatmap', as: :heatmap_data
  get 'visualizations/model_heatmap/:model_class.json', to: 'dashboard#model_heatmap', as: :model_heatmap_data

  # Formal verification routes (requires PetriFlow)
  get 'verification', to: 'dashboard#verification', as: :verification
  get 'verification.json', to: 'dashboard#verification_data', as: :verification_data
end
