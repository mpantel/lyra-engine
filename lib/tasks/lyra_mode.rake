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
    result = Lyra::Repair.run(models: models, dry_run: ENV["DRY_RUN"].present?, operator: ENV["OPERATOR"])
    puts result.summary
    (ENV["DRY_RUN"].present? ? result.found : result.remaining).first(20).each { puts "  #{_1}" }
    exit 1 if result.remaining.any? && ENV["DRY_RUN"].blank?
  rescue Lyra::Repair::Refused => e
    abort e.message
  end
  desc "Erase one record's personal data from its row and its events (Art. 17) " \
       "(MODEL=Registration ID=5 REASON='Art. 17 request #12' [OPERATOR=jdoe] [FIELDS=email,phone] " \
       "[ANY_FIELDS=1: FIELDS may name columns the policy does not declare personal] [EVERYWHERE=1] " \
       "[MAX_COPIES=n: with EVERYWHERE, a value held by more other records is left as shared; default config.erasure_max_copies, 10] " \
       "[DRY_RUN=1: report what would be erased and the values left as shared, write nothing] " \
       "[ACCESS_LOG=1|0: delete or keep the record's access log; default config.erase_access_log] " \
       "[ACCESS_LOG_SUBJECTS=42,user-42: ids the application used as this person's subject, whose logs go too])"
  task erase: :environment do
    model = ENV.fetch("MODEL").constantize
    max_copies = Lyra.config.erasure_max_copies
    if ENV["MAX_COPIES"].present?
      max_copies = Integer(ENV["MAX_COPIES"], 10, exception: false)
      abort "MAX_COPIES must be a positive integer (got #{ENV['MAX_COPIES'].inspect})" unless max_copies&.positive?
    end
    access_log = case ENV["ACCESS_LOG"].to_s.strip.downcase
                 when "" then nil
                 when "1", "true", "yes", "erase" then true
                 when "0", "false", "no", "keep" then false
                 else abort "ACCESS_LOG must be 1 (erase) or 0 (keep) (got #{ENV['ACCESS_LOG'].inspect})"
                 end
    dry_run = ENV["DRY_RUN"].present?
    result = Lyra::Erasure.erase!(model, ENV.fetch("ID"), reason: ENV.fetch("REASON"),
                                  fields: ENV["FIELDS"]&.split(",")&.map(&:strip),
                                  everywhere: ENV["EVERYWHERE"].present?, max_copies: max_copies,
                                  any_fields: ENV["ANY_FIELDS"].present?, access_log: access_log,
                                  access_log_subjects: ENV["ACCESS_LOG_SUBJECTS"].to_s.split(",").map(&:strip).reject(&:empty?),
                                  erased_by: Lyra::ModeTransition.actor(ENV["OPERATOR"]), dry_run: dry_run,
                                  lifting: ENV["LIFTING"].to_s.split(",").map(&:strip).reject(&:empty?).presence)
    puts "Dry run: nothing was written. This is what the erasure would do." if dry_run
    # A key that holds an erased value is never printed.
    shown_id = result.key_withheld ? Lyra::Erasure::WITHHELD : result.id
    puts "Erased #{result.fields.join(', ')} of #{result.model} #{shown_id}: " \
         "#{result.events_rewritten} events rewritten, row #{result.row_erased ? 'erased' : 'absent'}."
    if result.access_log
      puts "Access log #{result.access_log}: #{result.access_log_entries} entries."
    end
    puts "Copies erased: #{result.copies.join(', ')}" if result.copies.any?
    lifted = Array(result.lifting)
    puts "Restrictions #{dry_run ? 'it would lift' : 'lifted'} (Art. 18(3) notice recorded): #{lifted.join(', ')}" if lifted.any?
    kept = Array(result.restricted_copies)
    if kept.any?
      puts "Copies kept under a restriction of processing (Art. 18), not modified; each stays until its holder's " \
           "restriction is lifted, then erase again with EVERYWHERE=1: " +
           kept.map { |entry| "#{entry[:record]} (#{entry[:columns].join(', ')})" }.join("; ")
    end
    left = Array(result.left_behind)
    if left.any?
      puts "Left behind (the value is still in these columns, as a JSON key, inside a longer string or in a key): " +
           left.map { |entry| "#{entry[:record]} (#{entry[:columns].join(', ')})" }.join("; ")
    end
    not_searched = Array(result.not_searched)
    if not_searched.any?
      puts "Not searched (encrypted, the log holds their ciphertext): #{not_searched.join(', ')}"
    end
    if result.shared_values.positive?
      puts "Values left as shared (held by more than #{max_copies} other records): #{result.shared_values}"
      # By field and count, never the value. Once the person's own values are
      # erased, a later run cannot find these copies: choose MAX_COPIES with a
      # dry run first.
      Array(result.shared).each do |entry|
        hint = if dry_run
                 "check them, and if they are this person's, erase with MAX_COPIES=#{entry[:holders]}"
               else
                 "left in place; this record's values are now erased, so a later run cannot find them: " \
                 "next time run with DRY_RUN=1 first and choose MAX_COPIES"
               end
        puts "  #{entry[:field]} (#{entry[:type]}): held by #{entry[:holders]} other records; #{hint}"
      end
    end
    rows_only = Array(result.rows_without_events)
    if rows_only.any?
      remedy = if Lyra.config.monitor_mode? || Lyra.config.disabled_mode?
                 "their rows differed from their events before the erasure: run bin/rails lyra:repair " \
                 "to record the rows' state in the log"
               else
                 "the events are authoritative in #{Lyra::ModeTransition.current}, and these rows differ from " \
                 "them: rebuild their tables from the events (bin/rails lyra:projections:rebuild MODEL=...)"
               end
      puts "Rows without events (erased in the row only): #{rows_only.join(', ')}; #{remedy}"
    end
  rescue KeyError => e
    abort "#{e.message}: MODEL, ID and REASON are required"
  rescue Lyra::Erasure::Unsupported, Lyra::AccessLog::ModelWideSubject => e
    abort e.message
  end
  desc "Delete one subject's access log (SUBJECT=Registration$5 or an id the application passes as the " \
       "subject, e.g. SUBJECT=42; REASON='Art. 17 request #12' [OPERATOR=jdoe]). Model-wide entries " \
       "(Registration$*) are refused: they name no subject"
  task erase_access_log: :environment do
    subject = ENV.fetch("SUBJECT")
    entries = Lyra::AccessLog.erase!(subject, reason: ENV.fetch("REASON"),
                                     erased_by: Lyra::ModeTransition.actor(ENV["OPERATOR"]))
    puts "Access log of #{subject} erased: #{entries} entries (recorded in #{Lyra::AccessLog::ERASURES})."
  rescue KeyError => e
    abort "#{e.message}: SUBJECT and REASON are required"
  rescue ArgumentError => e
    abort e.message
  end
  namespace :rights do
    desc "Rebuild lyra_rights and lyra_consents (the subjects' restrictions, objections and consent) from " \
         "their event streams, Lyra::Rights and Lyra::Consent"
    task rebuild: :environment do
      requests, consents = Lyra::Rights.rebuild!
      puts "Rebuilt #{requests} restrictions and objections, and #{consents} consent records."
    end
  end

  namespace :retention do
    desc "Apply the privacy policy's retention rules (config.retention_executor; DRY_RUN=1 lists what " \
         "would happen, executor on or off; MODELS=Registration,Order limits it)"
    task apply: :environment do
      models = ENV["MODELS"] ? ENV["MODELS"].split(",").map { _1.strip.constantize } : lyra_monitored_models.call
      result = Lyra::Retention.apply!(models: models, dry_run: ENV["DRY_RUN"].present?)
      puts result.summary
      result.actions.first(50).each { puts "  #{_1}" }
      if result.restricted.any?
        puts "Kept under a restriction of processing (Art. 18), acted on once it is lifted:"
        result.restricted.each { puts "  #{_1}" }
      end
    rescue Lyra::Retention::Disabled => e
      abort e.message
    end
  end
end
