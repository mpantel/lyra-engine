# frozen_string_literal: true

require "test_helper"

# Active Record Encryption and the event log: an encrypted
# attribute reaches the log as ciphertext, as it reaches the row, in every
# mode; projections, rebuilds, DualView and ES-NoProj reads decrypt it like
# Active Record does; events written before (plaintext) still read.
class EncryptedAttributesTest < Minitest::Test
  TABLE = "lyra_secret_items"
  SECRET = "TOPSECRET-4711"
  NEWER = "NEWSECRET-0815"

  def setup
    skip "Requires Rails and PostgreSQL" unless defined?(ActiveRecord::Base) && connection.adapter_name.match?(/postgres/i)

    ActiveRecord::Encryption.configure(primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32)
    connection.create_table(TABLE, force: true) do |t|
      t.string :label
      t.text :secret
      t.timestamps
    end
    Object.send(:remove_const, :SecretItem) if defined?(SecretItem)
    Object.const_set(:SecretItem, Class.new(ActiveRecord::Base) do
      self.table_name = TABLE
      include Lyra::Interceptors::CrudInterceptor
      monitor_with_lyra
      encrypts :secret
    end)
    SecretItem.reset_column_information
    clean
    Rails.cache.clear
    Lyra.config.monitor_model(SecretItem)
  end

  def teardown
    return unless defined?(SecretItem)

    Lyra.reset_config!
    clean
    connection.drop_table(TABLE, if_exists: true)
  end

  def test_no_mode_puts_the_plaintext_in_the_log
    %i[monitor hijack es_sync es_async es_lazy es_noproj].each do |mode|
      use(mode)
      item = SecretItem.create!(label: "a", secret: SECRET)
      SecretItem.find(item.id).update!(secret: NEWER)

      log = events(item.id).map { _1.data.inspect }.join
      refute_includes log, SECRET, "#{mode}: the created value in clear"
      refute_includes log, NEWER, "#{mode}: the updated value in clear"
      assert_equal NEWER, SecretItem.find(item.id).secret, "#{mode}: the record reads the newer value"
      next if mode == :es_noproj

      refute_includes raw_secret(item.id), NEWER, "#{mode}: the row holds ciphertext"
      assert_equal({ no_differences: true }, Lyra::DualView.new(SecretItem, item.id).calculate_differences, "#{mode}: DualView")
    end
  end

  def test_the_log_holds_ciphertext_that_decrypts_to_the_value
    use(:monitor)
    item = SecretItem.create!(label: "a", secret: SECRET)

    stored = events(item.id).first.data[:attributes]["secret"] || events(item.id).first.data[:attributes][:secret]
    assert ActiveRecord::Encryption.encryptor.encrypted?(stored)
    assert_equal SECRET, SecretItem.type_for_attribute("secret").deserialize(stored)
  end

  def test_a_rebuild_writes_the_value_once_encrypted
    use(:es_sync)
    item = SecretItem.create!(label: "a", secret: SECRET)
    connection.execute("DELETE FROM #{TABLE}")

    Lyra::Projections::Rebuild.rebuild(SecretItem)

    assert_equal SECRET, SecretItem.find(item.id).secret, "decrypts to the value, not to a ciphertext (no double encryption)"
  end

  def test_a_bulk_update_is_logged_encrypted
    use(:monitor)
    item = SecretItem.create!(label: "a", secret: SECRET)

    SecretItem.where(id: item.id).update_all(secret: NEWER)

    refute_includes events(item.id).map { _1.data.inspect }.join, NEWER
  end

  # An event written before this change holds the value in clear: projected
  # and compared as it is, and the row still ends encrypted.
  def test_an_event_written_before_still_reads
    use(:es_sync)
    item = SecretItem.create!(label: "a", secret: SECRET)
    legacy = events(item.id).first
    legacy_data = legacy.data.deep_dup
    legacy_data[:attributes]["secret"] = SECRET if legacy_data[:attributes].key?("secret")
    legacy_data[:attributes][:secret] = SECRET if legacy_data[:attributes].key?(:secret)
    clean
    Lyra.config.event_store.publish(legacy.class.new(data: legacy_data), stream_name: Lyra.stream_name(SecretItem, item.id))
    connection.execute("DELETE FROM #{TABLE}")

    Lyra::Projections::Rebuild.rebuild(SecretItem)

    assert_equal SECRET, SecretItem.find(item.id).secret
    refute_includes raw_secret(item.id), SECRET, "the row is encrypted"
    assert_equal({ no_differences: true }, Lyra::DualView.new(SecretItem, item.id).calculate_differences)
  end

  def test_a_point_in_time_read_decrypts
    use(:monitor)
    item = SecretItem.create!(label: "a", secret: SECRET)
    later = Time.current + 1
    assert_equal SECRET, SecretItem.as_of(later).find(item.id).secret
  end

  private

  def use(mode)
    LyraConfigIsolation.install_fresh_config
    Lyra.config.monitor_model(SecretItem)
    case mode
    when :monitor then Lyra.config.enable_monitor!
    when :hijack then Lyra.config.enable_hijack!
    else
      Lyra.config.enable_event_sourcing!
      Lyra.config.projection_mode = { es_sync: :sync, es_async: :async, es_lazy: :lazy, es_noproj: :disabled }.fetch(mode)
      Lyra.config.async_projections_inline = true
    end
  end

  def events(id)
    Lyra.config.event_store.read.stream(Lyra.stream_name(SecretItem, id)).to_a
  rescue RubyEventStore::EventNotFoundInStream
    []
  end

  def raw_secret(id)
    connection.select_value("SELECT secret FROM #{TABLE} WHERE id = #{Integer(id)}").to_s
  end

  def connection = ActiveRecord::Base.connection

  def clean
    connection.execute("DELETE FROM event_store_events_in_streams")
    connection.execute("DELETE FROM event_store_events")
  end
end
