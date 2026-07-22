module PromptEngineer
  module Cutover
    QUALIFICATION_FIELDS = %w[status decision report_digest].freeze
    CAPABILITY_FIELDS = %w[
      status ruby_2_6 libc native_qualification sandbox
    ].freeze
    QUALIFICATION_DECISIONS = %w[QUALIFIED_EXPLICIT QUALIFIED_IMPLICIT].freeze
    EVIDENCE_STATUSES = %w[PASS PARTIAL UNAVAILABLE UNSUPPORTED BLOCKED].freeze
    LIVE_ACTIONS = %w[replace install symlink delete].freeze

    module_function

    def evaluate(qualification_result:, capability_record:)
      qualification_errors, qualification_blocks = validate_qualification(
        qualification_result
      )
      capability_errors, capability_blocks = validate_capability(capability_record)
      inconclusive = qualification_errors + capability_errors
      blocked = qualification_blocks + capability_blocks

      if !inconclusive.empty?
        result("INCONCLUSIVE", inconclusive)
      elsif !blocked.empty?
        result("BLOCKED", blocked)
      else
        result("READY", [])
      end
    end

    def validate_qualification(record)
      return [["qualification_result_invalid"], []] unless record.is_a?(Hash)

      errors = unknown_fields(record, QUALIFICATION_FIELDS, "qualification")
      errors.concat(missing_fields(record, QUALIFICATION_FIELDS, "qualification"))
      return [errors, []] unless errors.empty?

      errors = []
      blocks = []
      status = record.fetch("status")
      decision = record.fetch("decision")
      digest = record.fetch("report_digest")

      unless EVIDENCE_STATUSES.include?(status)
        errors << "qualification_status_invalid"
      end
      unless QUALIFICATION_DECISIONS.include?(decision)
        errors << "qualification_decision_invalid"
      end
      unless digest.is_a?(String) && !digest.empty?
        errors << "qualification_report_digest_invalid"
      end

      if errors.empty? && status != "PASS"
        if status == "INCONCLUSIVE"
          errors << "qualification_inconclusive"
        else
          blocks << "qualification_not_pass"
        end
      end

      [errors, blocks]
    end

    def validate_capability(record)
      return [["capability_record_invalid"], []] unless record.is_a?(Hash)

      errors = unknown_fields(record, CAPABILITY_FIELDS, "capability")
      errors.concat(missing_fields(record, CAPABILITY_FIELDS, "capability"))
      return [errors, []] unless errors.empty?

      errors = []
      blocks = []
      CAPABILITY_FIELDS.each do |field|
        value = record.fetch(field)
        unless EVIDENCE_STATUSES.include?(value)
          errors << "#{field}_evidence_invalid"
        end
      end
      return [errors, blocks] unless errors.empty?

      if record.fetch("status") != "PASS"
        blocks << "capability_#{record.fetch("status").downcase}"
      end
      %w[ruby_2_6 libc].each do |field|
        value = record.fetch(field)
        if value != "PASS"
          blocks << "#{field}_#{value.downcase}"
        end
      end
      if record.fetch("native_qualification") != "PASS"
        blocks << "native_qualification_not_pass"
      end
      if record.fetch("sandbox") != "PASS"
        blocks << "sandbox_#{record.fetch("sandbox").downcase}"
      end

      [errors, blocks]
    end

    def unknown_fields(record, allowed, prefix)
      record.keys.reject { |key| allowed.include?(key) }.map do |key|
        "#{prefix}_unknown_field_#{key}"
      end
    end

    def missing_fields(record, required, prefix)
      required.reject { |key| record.key?(key) }.map do |key|
        if prefix == "qualification" && key == "report_digest"
          "qualification_report_digest_missing"
        elsif prefix == "capability" && key == "ruby_2_6"
          "ruby_2_6_evidence_missing"
        elsif prefix == "capability" && key == "libc"
          "libc_evidence_missing"
        else
          "#{prefix}_#{key}_missing"
        end
      end
    end

    def result(status, reason_codes)
      {
        "status" => status,
        "reason_codes" => reason_codes,
        "mutations_allowed" => false,
        "live_actions" => LIVE_ACTIONS.each_with_object({}) do |action, actions|
          actions[action] = false
        end
      }
    end
  end
end
