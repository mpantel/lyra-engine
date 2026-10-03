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
    end
  end

  desc "Give rows that predate Lyra their Imported events, ahead of first use " \
       "(MODEL=Namespace::Model[,Other] for specific models, or all monitored models)"
  task genesis: :environment do
    models =
      if ENV["MODEL"]
        ENV["MODEL"].split(",").map { |name| name.strip.constantize }
      else
        Lyra.config.monitored_models
      end

    if models.empty?
      puts "No models to import."
      puts "Pass MODEL=YourModel, or configure models with Lyra.config.monitor_model(YourModel)."
      exit 1
    end

    models.each do |model_class|
      puts format("  %-30s %6d rows imported", model_class.name, Lyra::Genesis.import_all(model_class))
    end
    puts "Done."
  end
end
