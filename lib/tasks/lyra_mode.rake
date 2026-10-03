# frozen_string_literal: true

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

      report = Lyra::ModeTransition.check(to: to, from: from, rebuild: ENV["REBUILD"].present?)
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
end
