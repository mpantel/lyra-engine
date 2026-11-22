# frozen_string_literal: true

namespace :lyra do
  namespace :projections do
    desc "Rebuild read-model tables from the event log " \
         "(MODEL=Namespace::Model[,Other] for specific models, or all monitored models; " \
         "TRUNCATE=false to reconstruct in place)"
    task rebuild: :environment do
      models =
        if ENV["MODEL"]
          ENV["MODEL"].split(",").map { |name| name.strip.constantize }
        else
          # Monitored models register as their classes load.
          Rails.application.eager_load! unless Rails.application.config.eager_load
          Lyra.config.monitored_models
        end

      if models.empty?
        puts "No models to rebuild."
        puts "Pass MODEL=YourModel, or configure models with Lyra.config.monitor_model(YourModel)."
        exit 1
      end

      truncate = ENV.fetch("TRUNCATE", "true") != "false"

      puts "Rebuilding #{models.size} model(s) from the event log (truncate=#{truncate})..."
      models.each do |model_class|
        stats = Lyra::Projections::Rebuild.rebuild(model_class, truncate: truncate)
        puts format(
          "  %-30s %5d records, %4d destroyed, %6d events across %5d streams",
          stats[:model], stats[:records], stats[:destroyed], stats[:events], stats[:streams]
        )
      end
      puts "Done."
    rescue Lyra::Projections::Rebuild::Refused => e
      abort e.message
    end
  end

  desc "Link every event of the monitored models (MODEL=Namespace::Model[,Other] for specific models) " \
       "into the value streams ES-NoProj checks unique indexes against, from the first event: after a " \
       "rolling deploy in which processes running an earlier Lyra, or reading the indexes before a migration " \
       "added one, wrote (Lyra::Projections::ReferenceLinks.relink_values!)"
  task link_values: :environment do
    models =
      if ENV["MODEL"]
        ENV["MODEL"].split(",").map { |name| name.strip.constantize }
      else
        Rails.application.eager_load! unless Rails.application.config.eager_load
        Lyra.config.monitored_models
      end
    models.map { _1.respond_to?(:base_class) ? _1.base_class : _1 }.uniq.each do |model|
      next if Lyra::Projections::UniqueIndexes.columns(model).empty?

      linked = Lyra::Projections::ReferenceLinks.relink_values!(model)
      puts "#{model.name}: #{linked} value links (#{Lyra::Projections::UniqueIndexes.columns(model).join(', ')})"
    end
  end

  desc "Give rows that predate Lyra their Imported events, ahead of first use " \
       "(MODEL=Namespace::Model[,Other] for specific models, or all monitored models; " \
       "UNREPRESENTABLE=skip imports the rest of a model holding rows whose values it cannot represent, " \
       "default config.genesis_unrepresentable, :refuse)"
  task genesis: :environment do
    models =
      if ENV["MODEL"]
        ENV["MODEL"].split(",").map { |name| name.strip.constantize }
      else
        # Monitored models register as their classes load.
        Rails.application.eager_load! unless Rails.application.config.eager_load
        Lyra.config.monitored_models
      end

    if models.empty?
      puts "No models to import."
      puts "Pass MODEL=YourModel, or configure models with Lyra.config.monitor_model(YourModel)."
      exit 1
    end

    # A model holding rows it cannot represent is refused (nothing of it
    # imported) and listed, the other models imported, and the task exits 1.
    # With UNREPRESENTABLE=skip those rows are listed and left out.
    unrepresentable = ENV["UNREPRESENTABLE"].presence || Lyra.config.genesis_unrepresentable
    refused = false
    models.each do |model_class|
      result = Lyra::Genesis.import(model_class, unrepresentable: unrepresentable)
      skipped = result.skipped.positive? ? ", #{result.skipped} skipped (values the model cannot represent)" : ""
      puts format("  %-30s %6d rows imported%s", model_class.name, result.imported, skipped)
      result.unrepresentable.each { puts "    #{_1}" }
    rescue Lyra::Genesis::Refused => e
      puts format("  %-30s refused: %d rows hold values the model cannot represent; nothing imported", model_class.name, e.rows)
      e.values.each { puts "    #{_1}" }
      puts "    (and #{e.found - e.values.size} more)" if e.found > e.values.size
      refused = true
    end
    if refused
      puts "Not every model was imported: fix the rows listed or their models, or skip those rows with UNREPRESENTABLE=skip."
      exit 1
    end
    puts "Done."
  end

  namespace :streams do
    desc "Link the events of single-table-inheritance records written under their subclass's stream " \
         "into the base class's stream (once, after upgrading to 0.9.0; DRY_RUN=1 to report only)"
    task migrate_sti: :environment do
      Rails.application.eager_load! unless Rails.application.config.eager_load
      dry_run = ENV["DRY_RUN"] == "1"
      result = Lyra::StiStreamMigration.run!(dry_run: dry_run)
      puts "#{dry_run ? 'Would link' : 'Linked'} #{result[:linked]} events from #{result[:streams]} subclass streams " \
           "(#{result[:already]} already in place)."
      next if result[:conflicts].empty?

      puts "Not linked, their base streams already hold newer events (#{result[:conflicts].size}):"
      result[:conflicts].first(20).each { |stream| puts "  #{stream}" }
      exit 1
    end
  end
end
