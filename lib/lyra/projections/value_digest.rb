# frozen_string_literal: true

require "openssl"

module Lyra
  module Projections
    # A keyed digest of a value, for the names Lyra gives to things that are
    # about a value without holding it: ES-NoProj's value streams
    # ("Model!column$<digest>", UniqueIndexes) and the advisory locks of a
    # unique value (Uniqueness.value_lock_key), whose key text reaches the
    # database's statement log. An unkeyed hash of an email or an IBAN is
    # reversed by trying the likely values; this one is an HMAC-SHA256 keyed
    # by a secret of the installation: config.value_digest_key, or by
    # default a key derived from the application's secret_key_base
    # (Rails.application.key_generator, with a salt of Lyra's own: every
    # process of an application with the same secret_key_base derives the
    # same key). Without either: KeyMissing is raised at first use, naming both
    # settings, in every Rails environment but development and test (so a
    # staging or preview deployment fails closed too); in development, test
    # or without Rails a fixed key is used, with a warning once, and the digests are only as
    # private as an unkeyed hash. Applications that share an event store
    # (several apps, or apps with different secret_key_base) set
    # config.value_digest_key to one value in all of them, or their value
    # locks and streams miss each other.
    #
    # key_id names the key (a digest of it): ReferenceLinks stores it with
    # each column's link checkpoint, and a column linked under another key
    # has its value streams deleted and linked again under this one on its
    # next use (or with bin/rails lyra:link_values). The value locks follow
    # the key at once: every process of one installation must use the same.
    module ValueDigest
      # No key to digest values with, outside development and test (see above).
      class KeyMissing < StandardError; end

      SALT = "lyra/value-digest/v1"
      HEX = 32

      class << self
        # The digest of +text+ (32 hex characters, 128 bits).
        def hex(text) = OpenSSL::HMAC.hexdigest("SHA256", key, text.to_s)[0, HEX]

        # The key's own name: a digest of it, not the key.
        def key_id = OpenSSL::HMAC.hexdigest("SHA256", key, "#{SALT}/key-id")[0, 16]

        # The key in use, derived once per configured value.
        def key
          configured = Lyra.config.value_digest_key
          return @key if @key && @key_source.equal?(configured)

          @key_source = configured
          @key = configured.presence&.to_s || derived_key
        end

        # Forget the derived key (tests, a key rotation in a running process).
        def reset!
          @key = nil
          @key_source = nil
        end

        private

        def derived_key
          app = defined?(Rails) && Rails.respond_to?(:application) ? Rails.application : nil
          failure = nil
          if app.respond_to?(:key_generator)
            begin
              return app.key_generator.generate_key(SALT, 32)
            rescue StandardError => e
              failure = e
            end
          end
          if defined?(Rails) && Rails.respond_to?(:env) && !(Rails.env.development? || Rails.env.test?)
            raise KeyMissing, "Lyra cannot key the digests of unique values (value streams, value locks): set " \
                              "config.value_digest_key, or the application's secret_key_base" \
                              "#{failure ? " (#{failure.class}: #{failure.message})" : ''}"
          end
          warn_unkeyed(failure)
          SALT
        end

        def warn_unkeyed(failure)
          return if @warned

          @warned = true
          message = "Lyra: no key for the digests of unique values (config.value_digest_key, secret_key_base" \
                    "#{failure ? ": #{failure.class}" : ''}); a fixed key is used, as private as an unkeyed hash. " \
                    "Production refuses this."
          defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ? Rails.logger.warn(message) : Kernel.warn(message)
        end
      end
    end
  end
end
