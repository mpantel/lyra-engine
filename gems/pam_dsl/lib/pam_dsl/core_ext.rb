# frozen_string_literal: true

# Minimal standard-library polyfills for the small subset of ActiveSupport that
# pam_dsl uses. Loaded only when ActiveSupport is not available (see pam_dsl.rb),
# so the gem runs with no external dependencies when used standalone.
#
# Durations use a FIXED-LENGTH approximation: 1 minute = 60 s, 1 hour = 3600 s,
# 1 day = 86 400 s, 1 week = 7 days, 1 month = 30 days, 1 year = 365 days. This is
# the same approximation the gem's report tooling assumes. If exact calendar
# arithmetic is required (e.g. leap years, real month lengths), install
# activesupport and pam_dsl will use it in preference to this polyfill.

# Numeric duration helpers — return a number of seconds.
class Numeric
  def seconds = self
  def minutes = self * 60
  def hours   = self * 3_600
  def days    = self * 86_400
  def weeks   = self * 7 * 86_400
  def months  = self * 30 * 86_400
  def years   = self * 365 * 86_400
  alias_method :second, :seconds
  alias_method :minute, :minutes
  alias_method :hour, :hours
  alias_method :day, :days
  alias_method :week, :weeks
  alias_method :month, :months
  alias_method :year, :years

  def ago(time = Time.now)      = time - self
  def from_now(time = Time.now) = time + self
end unless 1.respond_to?(:years)

class Time
  def self.current = now
end unless Time.respond_to?(:current)

class String
  # CamelCase / namespaced -> snake_case (matches ActiveSupport::Inflector#underscore
  # for the simple identifiers pam_dsl applies it to).
  def underscore
    gsub("::", "/")
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .tr("-", "_")
      .downcase
  end

  # snake_case / CamelCase -> "Title Case" (e.g. "fraud_detection" -> "Fraud Detection").
  def titleize
    underscore.tr("_", " ").gsub(/\b[a-z]/, &:upcase)
  end
end unless "".respond_to?(:underscore)

# Object#blank?/present? — same truth table as ActiveSupport for the values
# pam_dsl checks (nil, false, "", [], and "present" objects).
class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present? = !blank?
end unless Object.new.respond_to?(:present?)

class NilClass
  def blank? = true
end unless nil.respond_to?(:blank?)
