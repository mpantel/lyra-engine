Rails.application.configure do
  config.enable_reloading = false

  # Eager load on CI to catch load errors; locally it only slows a run down.
  config.eager_load = ENV["CI"].present?

  config.consider_all_requests_local = true
  config.cache_store = :null_store
  config.active_support.deprecation = :stderr

  # Debug logging writes every SQL statement to log/test.log.
  config.log_level = :warn
end
