require "test_helper"

module PamDsl
  # What a PII scan of a foreign codebase (Solidus 4.7, replayed with real
  # Olist orders) found PAM missing or misreading, and the generator's rules
  # for names and for columns a model ignores.
  class PiiCoverageTest < Minitest::Test
    def setup
      PIIDetector.reset!
    end

    PERSONAL = {
      # Solidus 4.7
      address1: :address, address2: :address, zipcode: :address, city: :address, state_name: :address,
      alternative_phone: :phone, vat_id: :identifier, last_digits: :credit_card,
      last_ip_address: :ip_address, current_sign_in_ip: :ip_address, last_sign_in_ip: :ip_address,
      login: :identifier, unconfirmed_email: :email, encrypted_password: :credential,
      password_salt: :credential, spree_api_key: :credential, guest_token: :token,
      gateway_customer_profile_id: :payment_token, approver_name: :name, firstname: :name,
      # the Aegean testbed
      fathername: :name, debtor_name: :name, debtor_iban: :financial, debtor_bic: :financial,
      postal_code: :address, username: :identifier, birthdate: :date_of_birth
    }.freeze

    NOT_PERSONAL = %i[
      state shipment_state country_iso country_id bill_address_id stock_location_id
      cvv_response_message api_name bank_name product_name file_name company_name rest_income_budget
    ].freeze

    def test_personal_columns_are_found_with_their_type
      PERSONAL.each { |column, type| assert_equal type, PIIDetector.pii_type(column), column }
    end

    def test_columns_that_are_not_personal_are_left_alone
      NOT_PERSONAL.each { |column| assert_nil PIIDetector.pii_type(column), column }
    end

    # The generator has no dictionary of its own any more.
    def test_the_generator_detects_with_the_detector
      refute PolicyGenerator.const_defined?(:PII_PATTERNS, false)
      refute PolicyGenerator.const_defined?(:EXCLUDE_PATTERNS, false)
    end

    FakeModel = Struct.new(:name, :table_name, :primary_key, :columns, :ignored_columns) do
      def connection
        cols = columns
        Struct.new(:cols) { def columns(_table) = cols.map { |c| Struct.new(:name).new(c) } }.new(cols)
      end
    end

    def test_a_bare_name_counts_only_alongside_other_personal_data
      generator = PolicyGenerator.new(:test, output_path: File::NULL)
      product = FakeModel.new("Product", "products", "id", %w[id name description], [])
      address = FakeModel.new("Address", "addresses", "id", %w[id name address1 zipcode], [])

      assert_empty generator.send(:scan_model, product)
      assert_equal %w[address1 name zipcode], generator.send(:scan_model, address).keys.sort
    end

    # A column the model ignores still holds data nothing in the application
    # can see or erase (Solidus's legacy address names).
    def test_columns_the_model_ignores_are_scanned_and_marked
      generator = PolicyGenerator.new(:test, output_path: File::NULL)
      address = FakeModel.new("Address", "addresses", "id", %w[id name firstname lastname address1], %w[firstname lastname])

      found = generator.send(:scan_model, address)
      assert found["firstname"][:ignored]
      refute found["address1"][:ignored]
    end
  end
end
