require "digest"
require "time"

module PromptEngineer
  module Provenance
    class Error < StandardError; end

    DIGEST = /\A[0-9a-f]{64}\z/.freeze
    REQUIRED_FIELDS = %w[
      run_id case_id host arm nonce session fresh_session_evidence
      raw_export_digest sandbox_launch_attestation_digest expected_package_digest
      invocation_evidence frozen_input_digests discovery_evidence exit_status
      timestamps output_digests
    ].freeze

    module_function

    def validate_executor_record!(record, store:, task: nil, raw_export: nil)
      raise Error, "executor record must be an object" unless record.is_a?(Hash)
      reject_authority_paths!(record)
      bytes = PromptEngineer::Canonical.json(record)
      raise Error, "executor record is too large" if bytes.bytesize > RunStore::MAX_RECORD_BYTES

      task ||= task_for_record(store, record)
      missing = REQUIRED_FIELDS.reject { |field| record.key?(field) }
      raise Error, "provenance fields are missing: #{missing.join(", ")}" unless missing.empty?
      compare!(record, "run_id", store.run_id)
      compare!(record, "case_id", task.fetch("case_id"))
      compare!(record, "host", task.fetch("host"))
      compare!(record, "arm", task.fetch("arm"))
      compare!(record, "nonce", task.fetch("nonce"))
      compare!(record, "expected_package_digest", store.manifest.fetch("package_digest"))
      compare!(record, "expected_package_digest", task.fetch("staged_package_digest"))
      require_digest!(record.fetch("raw_export_digest"), "native export digest")
      require_digest!(record.fetch("sandbox_launch_attestation_digest"), "launch attestation digest")
      require_digest!(record.fetch("nonce"), "nonce")
      validate_session!(record.fetch("session"), record.fetch("fresh_session_evidence"), task)
      validate_evidence!(record.fetch("discovery_evidence"), "discovery evidence")
      validate_evidence!(record.fetch("invocation_evidence"), "invocation evidence")
      validate_frozen_inputs!(record.fetch("frozen_input_digests"), store.manifest)
      validate_exit_status!(record.fetch("exit_status"))
      validate_timestamps!(record.fetch("timestamps"))
      validate_output_digests!(record.fetch("output_digests"))
      validate_raw_export!(record.fetch("raw_export_digest"), raw_export)
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise Error, "malformed provenance: #{error.message}"
    end

    def ingest!(store:, record:, raw_export: nil)
      validate_executor_record!(record, store: store, raw_export: raw_export)
      store.persist_executor_record!(record, raw_export: raw_export)
    rescue RunStore::Error => error
      raise Error, error.message if error.message.include?("duplicate nonce")

      raise
    end

    def task_for_record(store, record)
      event = store.events.reverse.find do |candidate|
        candidate["event"] == "lease_created" && candidate["nonce"] == record.fetch("nonce")
      end
      raise Error, "unknown lease nonce" unless event

      event
    end
    private_class_method :task_for_record

    def compare!(record, field, expected)
      raise Error, "#{field} binding mismatch" unless record.fetch(field) == expected
    end
    private_class_method :compare!

    def digest_alias(record, primary, alternate)
      record.fetch(primary, record.fetch(alternate, nil))
    end
    private_class_method :digest_alias

    def require_digest!(value, label)
      raise Error, "#{label} is invalid" unless value.is_a?(String) && value.match?(DIGEST)
    end
    private_class_method :require_digest!

    def validate_session!(session, freshness, task)
      raise Error, "session is invalid" unless session.is_a?(Hash) && session["id"].is_a?(String) && !session["id"].empty?
      compare!(session, "id", task.fetch("session_id"))
      raise Error, "fresh session evidence is invalid" unless freshness.is_a?(Hash) && freshness["new_session"] == true
      raise Error, "fresh session evidence does not bind session" unless freshness["native_session_id"] == session["id"]
    end
    private_class_method :validate_session!

    def validate_evidence!(evidence, label)
      raise Error, "#{label} is missing" unless evidence.is_a?(Hash) && !evidence.empty?
      if evidence.key?("digest")
        require_digest!(evidence.fetch("digest"), "#{label} digest")
      end
    end
    private_class_method :validate_evidence!

    def validate_frozen_inputs!(inputs, manifest)
      raise Error, "frozen input digests are invalid" unless inputs.is_a?(Hash)
      expected = {
        "corpus" => manifest.fetch("corpus_digest"),
        "package" => manifest.fetch("package_digest"),
        "policy" => manifest.fetch("qualification_policy_digest"),
        "legacy_lock" => manifest.fetch("legacy_lock_digest")
      }
      raise Error, "frozen input digest keys are not closed" unless inputs.keys.sort == expected.keys.sort
      expected.each do |key, value|
        raise Error, "frozen input #{key} binding mismatch" unless inputs.fetch(key) == value
        require_digest!(inputs.fetch(key), "frozen input #{key}")
      end
    end
    private_class_method :validate_frozen_inputs!

    def validate_exit_status!(status)
      valid = status.is_a?(Hash) && status["code"].is_a?(Integer) && status["status"].is_a?(String) && !status["status"].empty?
      raise Error, "exit status is invalid" unless valid
    end
    private_class_method :validate_exit_status!

    def validate_timestamps!(timestamps)
      raise Error, "timestamps are invalid" unless timestamps.is_a?(Hash) && timestamps.keys.sort == %w[ended_at started_at]
      started = Time.iso8601(timestamps.fetch("started_at"))
      ended = Time.iso8601(timestamps.fetch("ended_at"))
      raise Error, "timestamp ordering is invalid" unless ended > started
    rescue ArgumentError, TypeError
      raise Error, "timestamps are invalid"
    end
    private_class_method :validate_timestamps!

    def validate_output_digests!(digests)
      raise Error, "declared output digests are invalid" unless digests.is_a?(Hash) && !digests.empty?
      digests.each { |name, digest| raise Error, "declared output digest is invalid" unless name.is_a?(String) && !name.empty? && digest.is_a?(String) && digest.match?(DIGEST) }
    end
    private_class_method :validate_output_digests!

    def validate_raw_export!(expected, raw_export)
      return true if raw_export.nil?
      raise Error, "raw export must be bytes" unless raw_export.is_a?(String)
      raise Error, "raw export is too large" if raw_export.bytesize > RunStore::MAX_EXPORT_BYTES
      raise Error, "native export digest mismatch" unless Digest::SHA256.hexdigest(raw_export) == expected
      true
    end
    private_class_method :validate_raw_export!

    def reject_authority_paths!(value, path = [])
      case value
      when Hash
        value.each do |key, child|
          key_name = key.to_s
          if key_name.end_with?("_path") || key_name == "path" || key_name == "source_path"
            raise Error, "provenance record cannot authorize reads by pathname at #{(path + [key_name]).join(".")}"
          end
          reject_authority_paths!(child, path + [key_name])
        end
      when Array
        value.each_with_index { |child, index| reject_authority_paths!(child, path + [index]) }
      end
    end
    private_class_method :reject_authority_paths!
  end
end
