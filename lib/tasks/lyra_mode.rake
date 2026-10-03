# frozen_string_literal: true

# Monitored models register as their classes load, which a rake task in
# development does not do by itself: without this, a check saw no models,
# found no discrepancy and certified the switch.
lyra_monitored_models = lambda do
  Rails.application.eager_load! unless Rails.application.config.eager_load
  models = Lyra.config.monitored_models
  abort "Lyra: no monitored models found; nothing to check." if models.empty?
  models
end

namespace :lyra do
  namespace :mode do
    desc "Check that a mode switch is safe and certify it (TO=hijack|event_sourcing|monitor|disabled " \
         "[PROJECTION=sync|async|disabled|lazy] [FROM=...] [REBUILD=1])"
    task check: :environment do
      to = Lyra::ModeTransition.label(ENV.fetch("TO"), ENV["PROJECTION"])
      from = ENV["FROM"] || Lyra::ModeTransition.last_applied || Lyra::ModeTransition.current

      unless Lyra::ModeTransition.gate_required?(from, to)
        puts "#{from} -> #{to} keeps the authoritative store; no check needed."
        next
      end

      report = Lyra::ModeTransition.check(to: to, from: from, models: lyra_monitored_models.call,
                                          rebuild: ENV["REBUILD"].present?)
      puts report.summary
      report.discrepancies.first(20).each { puts "  #{_1}" }
      puts(report.clean? ? "Clean: certified for #{Lyra.config.mode_transition_certificate_ttl}s." : "Not certified.")
      exit 1 unless report.clean?
    end

    desc "Show the mode the application runs in and the last one applied"
    task status: :environment do
      puts "configured:   #{Lyra::ModeTransition.current}"
      puts "last applied: #{Lyra::ModeTransition.last_applied || '(none recorded)'}"
      puts "gate:         #{Lyra::ModeTransition.gate_enabled? ? 'on' : 'off'}"
    end
  end

  desc "Bring the event log back in line with the tables after Monitor lost events " \
       "(DRY_RUN=1 lists them; MODELS=User,Order limits it)"
  task repair: :environment do
    models = ENV["MODELS"] ? ENV["MODELS"].split(",").map { _1.strip.constantize } : lyra_monitored_models.call
    result = Lyra::Repair.run(models: models, dry_run: ENV["DRY_RUN"].present?)
    puts result.summary
    (ENV["DRY_RUN"].present? ? result.found : result.remaining).first(20).each { puts "  #{_1}" }
    exit 1 if result.remaining.any? && ENV["DRY_RUN"].blank?
  rescue Lyra::Repair::Refused => e
    abort e.message
  end
  desc "Erase one record's personal data from its row and its events (Art. 17) " \
       "(MODEL=Registration ID=5 REASON='Art. 17 request #12' [FIELDS=email,phone] [EVERYWHERE=1])"
  task erase: :environment do
    model = ENV.fetch("MODEL").constantize
    result = Lyra::Erasure.erase!(model, ENV.fetch("ID"), reason: ENV.fetch("REASON"),
                                  fields: ENV["FIELDS"]&.split(",")&.map(&:strip),
                                  everywhere: ENV["EVERYWHERE"].present?)
    puts "Erased #{result.fields.join(', ')} of #{result.model} #{result.id}: " \
         "#{result.events_rewritten} events rewritten, row #{result.row_erased ? 'erased' : 'absent'}."
    puts "Copies erased: #{result.copies.join(', ')}" if result.copies.any?
  rescue KeyError => e
    abort "#{e.message}: MODEL, ID and REASON are required"
  rescue Lyra::Erasure::Unsupported => e
    abort e.message
  end
  namespace :retention do
    desc "Apply the privacy policy's retention rules (config.retention_executor; DRY_RUN=1 lists what " \
         "would happen, executor on or off; MODELS=Registration,Order limits it)"
    task apply: :environment do
      models = ENV["MODELS"] ? ENV["MODELS"].split(",").map { _1.strip.constantize } : lyra_monitored_models.call
      result = Lyra::Retention.apply!(models: models, dry_run: ENV["DRY_RUN"].present?)
      puts result.summary
      result.actions.first(50).each { puts "  #{_1}" }
    rescue Lyra::Retention::Disabled => e
      abort e.message
    end
  end
end
