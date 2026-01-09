require "test_helper"
require "csv"

module Lyra
  module Privacy
    class PIIEvaluationTest < Minitest::Test
      DATASET_PATH = File.expand_path("../fixtures/pii_evaluation_dataset.csv", __FILE__)

      def setup
        skip "PII evaluation tests require PAM DSL" unless PAM_DSL_AVAILABLE

        @dataset = load_dataset
        @results = evaluate_detector
      end

      def test_dataset_has_sufficient_samples
        assert @dataset.size >= 200, "Dataset should have at least 200 samples"

        true_positives = @dataset.count { |r| r[:category] == "true_positive" }
        true_negatives = @dataset.count { |r| r[:category] == "true_negative" }

        assert true_positives >= 80, "Should have at least 80 true positive samples"
        assert true_negatives >= 100, "Should have at least 100 true negative samples"
      end

      def test_all_pii_categories_represented
        expected_types = %i[email name phone address ssn date_of_birth ip_address
                           credit_card financial health biometric location identifier]

        actual_types = @dataset.select { |r| r[:category] == "true_positive" }
                               .map { |r| r[:expected_type].to_sym }
                               .uniq

        expected_types.each do |type|
          assert_includes actual_types, type, "Dataset should include #{type} samples"
        end
      end

      def test_precision_above_threshold
        precision = calculate_precision
        assert precision >= 0.95, "Precision should be >= 95%, got #{(precision * 100).round(1)}%"
      end

      def test_recall_above_threshold
        recall = calculate_recall
        assert recall >= 0.95, "Recall should be >= 95%, got #{(recall * 100).round(1)}%"
      end

      def test_f1_score_above_threshold
        f1 = calculate_f1
        assert f1 >= 0.95, "F1 score should be >= 95%, got #{(f1 * 100).round(1)}%"
      end

      def test_no_false_positives_on_common_fields
        common_non_pii = %w[id created_at updated_at status type amount price quantity]

        common_non_pii.each do |field|
          refute PIIDetector.contains_pii?(field),
                 "Field '#{field}' should not be detected as PII"
        end
      end

      def test_correctly_detects_all_pii_types
        # Maps expected PII type to sample field name
        # Note: mobile/cell are detected as 'phone' type by the detector
        pii_samples = {
          email: "user_email",
          name: "first_name",
          phone: "telephone",
          address: "street",
          ssn: "social_security",
          date_of_birth: "birthday",
          ip_address: "remote_ip",
          credit_card: "card_number",
          financial: "bank_account",
          health: "diagnosis",
          biometric: "fingerprint",
          location: "latitude",
          identifier: "passport"
        }

        pii_samples.each do |expected_type, field|
          detected = PIIDetector.detect({ field.to_sym => "test_value" })
          assert detected.key?(field.to_sym), "Should detect #{field} as PII"
          assert_equal expected_type, detected[field.to_sym][:type],
                       "#{field} should be detected as #{expected_type}"
        end
      end

      def test_prints_evaluation_report
        puts "\n" + "=" * 60
        puts "PII Detection Evaluation Report"
        puts "=" * 60
        puts "Dataset: #{DATASET_PATH}"
        puts "Total samples: #{@dataset.size}"
        puts "True positive samples: #{@results[:condition_positive]}"
        puts "True negative samples: #{@results[:condition_negative]}"
        puts "-" * 60
        puts "True Positives (TP):  #{@results[:tp]}"
        puts "True Negatives (TN):  #{@results[:tn]}"
        puts "False Positives (FP): #{@results[:fp]}"
        puts "False Negatives (FN): #{@results[:fn]}"
        puts "-" * 60
        puts "Precision: #{(calculate_precision * 100).round(2)}%"
        puts "Recall:    #{(calculate_recall * 100).round(2)}%"
        puts "F1 Score:  #{(calculate_f1 * 100).round(2)}%"
        puts "Accuracy:  #{(calculate_accuracy * 100).round(2)}%"
        puts "=" * 60

        # Print any errors for debugging
        if @results[:errors].any?
          puts "\nMisclassified fields:"
          @results[:errors].each do |error|
            puts "  - #{error[:field]}: expected=#{error[:expected]}, got=#{error[:actual]}"
          end
        end

        assert true # Test always passes, just prints report
      end

      private

      def load_dataset
        dataset = []

        CSV.foreach(DATASET_PATH, headers: true) do |row|
          # Skip comments
          next if row["field_name"]&.start_with?("#")
          next if row["field_name"].nil? || row["field_name"].empty?

          dataset << {
            field_name: row["field_name"],
            expected_type: row["expected_pii_type"],
            category: row["category"],
            description: row["description"]
          }
        end

        dataset
      end

      def evaluate_detector
        results = {
          tp: 0,  # True positives: correctly identified PII
          tn: 0,  # True negatives: correctly identified non-PII
          fp: 0,  # False positives: non-PII incorrectly flagged as PII
          fn: 0,  # False negatives: PII incorrectly missed
          condition_positive: 0,
          condition_negative: 0,
          errors: []
        }

        @dataset.each do |sample|
          field_name = sample[:field_name]
          expected_type = sample[:expected_type]
          is_pii_expected = sample[:category] == "true_positive"

          # Update condition counts
          if is_pii_expected
            results[:condition_positive] += 1
          else
            results[:condition_negative] += 1
          end

          # Test detection
          detected = PIIDetector.detect({ field_name.to_sym => "test_value" })
          is_pii_detected = detected.key?(field_name.to_sym)
          detected_type = detected.dig(field_name.to_sym, :type)&.to_s

          if is_pii_expected
            if is_pii_detected && detected_type == expected_type
              results[:tp] += 1
            else
              results[:fn] += 1
              results[:errors] << {
                field: field_name,
                expected: expected_type,
                actual: detected_type || "none"
              }
            end
          else
            if is_pii_detected
              results[:fp] += 1
              results[:errors] << {
                field: field_name,
                expected: "none",
                actual: detected_type
              }
            else
              results[:tn] += 1
            end
          end
        end

        results
      end

      def calculate_precision
        return 0.0 if @results[:tp] + @results[:fp] == 0
        @results[:tp].to_f / (@results[:tp] + @results[:fp])
      end

      def calculate_recall
        return 0.0 if @results[:tp] + @results[:fn] == 0
        @results[:tp].to_f / (@results[:tp] + @results[:fn])
      end

      def calculate_f1
        precision = calculate_precision
        recall = calculate_recall
        return 0.0 if precision + recall == 0
        2 * (precision * recall) / (precision + recall)
      end

      def calculate_accuracy
        total = @results[:tp] + @results[:tn] + @results[:fp] + @results[:fn]
        return 0.0 if total == 0
        (@results[:tp] + @results[:tn]).to_f / total
      end
    end
  end
end
