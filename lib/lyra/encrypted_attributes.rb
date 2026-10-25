# frozen_string_literal: true

module Lyra
  # Active Record Encryption (encrypts :attr) and the event log.
  #
  # Events are built from a model's attributes and changes, which Active
  # Record has already decrypted, so an encrypted column reached the log in
  # clear while its row held ciphertext. Every event Lyra writes
  # passes through Lyra.append_events, which seals it here: the values of the
  # model's encrypted attributes, in attributes and in changes ([old, new]),
  # are replaced by their ciphertext, as Active Record writes it to the row.
  # The log then holds what the table holds.
  #
  # Whatever reads events back into rows or compares them with rows opens
  # them (ModelProjection, DualView). Instantiating a record from event
  # attributes needs nothing: Active Record decrypts as it does a row. A value
  # that is not ciphertext (an event written before this change) is left as
  # it is, by both.
  module EncryptedAttributes
    class << self
      # The encrypted attribute names of +model_class+ (strings), [] if none.
      def names(model_class)
        return [] unless model_class.respond_to?(:encrypted_attributes)

        Array(model_class.encrypted_attributes).map(&:to_s)
      end

      # Replace, in +event+'s data, the values of the model's encrypted
      # attributes by their ciphertext. Called by Lyra.append_events.
      def seal!(event)
        data = event.data
        return unless data.is_a?(Hash)

        model = model_for(data)
        encrypted = model ? names(model) : []
        return if encrypted.empty?

        attributes = data[:attributes] || data["attributes"]
        seal_values!(model, encrypted, attributes) if attributes.is_a?(Hash)
        changes = data[:changes] || data["changes"]
        seal_changes!(model, encrypted, changes) if changes.is_a?(Hash)
      end

      # A copy of +attributes+ with the model's encrypted attributes
      # decrypted, for writing them to a row or comparing them with one.
      def open(model_class, attributes)
        encrypted = names(model_class)
        return attributes if encrypted.empty? || !attributes.is_a?(Hash)

        attributes.to_h do |key, value|
          [key, encrypted.include?(key.to_s) ? decrypt(model_class, key, value) : value]
        end
      end

      private

      def model_for(data)
        name = data[:model_class] || data["model_class"]
        return nil unless name

        model = Lyra.config.monitored_model_named(name) || name.to_s.safe_constantize
        model.is_a?(Class) && model < ActiveRecord::Base ? model : nil
      end

      def seal_values!(model, encrypted, values)
        values.each_key do |key|
          values[key] = encrypt(model, key, values[key]) if encrypted.include?(key.to_s)
        end
      end

      def seal_changes!(model, encrypted, changes)
        changes.each_key do |key|
          next unless encrypted.include?(key.to_s)

          change = changes[key]
          changes[key] = change.is_a?(Array) ? change.map { encrypt(model, key, _1) } : encrypt(model, key, change)
        end
      end

      def encrypt(model, key, value)
        return value if value.nil? || ciphertext?(value)

        model.type_for_attribute(key.to_s).serialize(value)
      end

      def decrypt(model, key, value)
        return value unless ciphertext?(value)

        model.type_for_attribute(key.to_s).deserialize(value)
      rescue StandardError
        value
      end

      def ciphertext?(value)
        value.is_a?(String) && ActiveRecord::Encryption.encryptor.encrypted?(value)
      rescue StandardError
        false
      end
    end
  end
end
