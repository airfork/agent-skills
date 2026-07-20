require "digest"
require "time"

module PromptEngineer
  module Provenance
    class Error < StandardError; end

    DIGEST = /\A[0-9a-f]{64}\z/.freeze
    REQUIRED_FIELDS = %w[
      schema_version run_id host case_id arm repeat_index nonce
      public_task_packet_digest arm_environment_manifest_digest expected_package_digest
      masked_label_map_digest sandbox_launch_attestation_digest activation_evidence
      invocation_evidence session fresh_session_evidence timestamps cli model effort
      configuration_digest environment_digest tool_inventory messages tool_events
      final_status exit_status raw_export_digest usage
    ].freeze
    DIGEST_FIELDS = %w[
      public_task_packet_digest arm_environment_manifest_digest expected_package_digest
      masked_label_map_digest sandbox_launch_attestation_digest configuration_digest
      environment_digest raw_export_digest
    ].freeze

    module_function

    def validate_executor_record!(record, store:, task: nil, raw_export: nil, require_raw_export: true)
      raise Error, "executor record must be an object" unless record.is_a?(Hash)
      reject_authority_paths!(record)
      bytes = PromptEngineer::Canonical.json(record)
      raise Error, "executor record is too large" if bytes.bytesize > RunStore::MAX_RECORD_BYTES

      task ||= task_for_record(store, record)
      missing = REQUIRED_FIELDS.reject { |field| record.key?(field) }
      raise Error, "provenance fields are missing: #{missing.join(", ")}" unless missing.empty?
      raise Error, "executor result fields are not closed" unless record.keys.sort == REQUIRED_FIELDS.sort
      validate_schema_compatible_fields!(record)
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
      facts = executor_facts(record, task)
      PromptEngineer::Contracts.validate_executor_result!(record, facts, token_cap: token_cap(store, task))
      validate_raw_export!(record.fetch("raw_export_digest"), raw_export) if require_raw_export
      true
    rescue PromptEngineer::Contracts::Error, KeyError, TypeError, NoMethodError => error
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

    def validate_schema_compatible_fields!(record)
      raise Error, "executor result schema version is invalid" unless record.fetch("schema_version") == 1
      raise Error, "executor result repeat index is invalid" unless record.fetch("repeat_index").is_a?(Integer) && record.fetch("repeat_index") >= 0
      raise Error, "executor result host is invalid" unless Corpus::HOSTS.include?(record.fetch("host"))
      raise Error, "executor result arm is invalid" unless RunStore::ARMS.include?(record.fetch("arm"))
      DIGEST_FIELDS.each { |field| require_digest!(record.fetch(field), field) }
      raise Error, "executor result case ID is invalid" unless record.fetch("case_id").match?(/\APE-[0-9]{3}\z/)
      raise Error, "executor result final status is invalid" unless %w[completed failed aborted inconclusive].include?(record.fetch("final_status"))
      raise Error, "executor result exit status is invalid" unless record.fetch("exit_status").is_a?(Integer) && record.fetch("exit_status") >= 0
      validate_session!(record.fetch("session"), record.fetch("fresh_session_evidence"), nil)
      validate_closed_hash!(record.fetch("cli"), %w[name version executable_digest], "cli")
      require_digest!(record.fetch("cli").fetch("executable_digest"), "CLI executable digest")
      %w[activation_evidence invocation_evidence].each do |field|
        validate_closed_hash!(record.fetch(field), %w[status event_ordinal staged_path machine_id binding binding_digest machine_binding_digest evidence_digest], field)
        require_digest!(record.fetch(field).fetch("binding_digest"), "#{field} binding digest")
        require_digest!(record.fetch(field).fetch("machine_binding_digest"), "#{field} machine binding digest")
        require_digest!(record.fetch(field).fetch("evidence_digest"), "#{field} evidence digest")
      end
      validate_closed_hash!(record.fetch("usage"), %w[input_tokens output_tokens total_tokens], "usage")
      usage = record.fetch("usage")
      raise Error, "executor usage is invalid" unless usage.values.all? { |value| value.is_a?(Integer) && value >= 0 } && usage.fetch("total_tokens") == usage.fetch("input_tokens") + usage.fetch("output_tokens")
      raise Error, "executor messages are invalid" unless record.fetch("messages").is_a?(Array) && !record.fetch("messages").empty?
      raise Error, "executor tool events are invalid" unless record.fetch("tool_events").is_a?(Array)
      raise Error, "executor tool inventory is invalid" unless record.fetch("tool_inventory").is_a?(Array)
      true
    rescue KeyError, NoMethodError => error
      raise Error, "executor result schema is invalid: #{error.message}"
    end
    private_class_method :validate_schema_compatible_fields!

    def validate_closed_hash!(value, fields, label)
      raise Error, "#{label} is invalid" unless value.is_a?(Hash) && value.keys.sort == fields.sort
    end
    private_class_method :validate_closed_hash!

    def executor_facts(record, task)
      binding = record.fetch("activation_evidence").fetch("binding")
      {
        "run_id" => task.fetch("run_id", record.fetch("run_id")),
        "case_id" => task.fetch("case_id"),
        "host" => task.fetch("host"),
        "session_id" => task.fetch("session_id"),
        "arm" => task.fetch("arm"),
        "nonce" => task.fetch("nonce"),
        "staged_package_digest" => task.fetch("staged_package_digest"),
        "machine_id" => binding.fetch("machine_id"),
        "staged_path" => binding.fetch("staged_path"),
        "public_task_packet_digest" => task.fetch("public_task_packet_digest"),
        "raw_export_digest" => record.fetch("raw_export_digest"),
        "launch_attestation_digest" => record.fetch("sandbox_launch_attestation_digest")
      }
    end
    private_class_method :executor_facts

    def token_cap(store, task)
      policy = store.manifest.fetch("policy_snapshot")
      policy.fetch("token_caps").fetch(task.fetch("host"))
    rescue KeyError, TypeError
      nil
    end
    private_class_method :token_cap

    def validate_session!(session, freshness, task)
      raise Error, "session is invalid" unless session.is_a?(Hash) && session.keys.sort == %w[fresh id] && session["id"].is_a?(String) && !session["id"].empty? && session["fresh"] == true
      compare!(session, "id", task.fetch("session_id")) if task
      raise Error, "fresh session evidence is invalid" unless freshness.is_a?(Hash) && freshness.keys.sort == %w[first_event_ordinal new_session_marker parent_session_absent] && freshness["parent_session_absent"] == true
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
          if (key_name.end_with?("_path") && key_name != "staged_path") || key_name == "path" || key_name == "source_path"
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
