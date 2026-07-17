module AdversarialReview
  module Capabilities
    FIELDS = %w[
      fresh_context repository_access read_only model_selection effort_selection
      structured_output usage_metrics parallel_dispatch
    ].freeze
    SAFETY_BOUNDARIES = %w[fresh_context repository_access read_only].freeze
    STATUSES = %w[enforced behavioral unavailable].freeze

    class Error < StandardError; end

    module_function

    def template(requested_model: nil, requested_effort: nil)
      FIELDS.each_with_object({}) do |field, declarations|
        requested = case field
                    when "model_selection" then requested_model
                    when "effort_selection" then requested_effort
                    else true
                    end
        declarations[field] = {
          "requested" => requested,
          "status" => "unavailable",
          "evidence" => "not reported",
          "source" => "parent capability declaration"
        }
      end
    end

    def normalize(record, requested_model: nil, requested_effort: nil)
      unless record.is_a?(Hash)
        raise Error, "capability declaration must be an object"
      end
      unknown_fields = record.keys - FIELDS
      unless unknown_fields.empty?
        raise Error, "unknown capability fields: #{unknown_fields.join(", ")}"
      end
      requested = template(
        requested_model: requested_model,
        requested_effort: requested_effort
      )
      FIELDS.each_with_object({}) do |field, normalized|
        declaration = record[field]
        if declaration.nil?
          normalized[field] = requested.fetch(field).dup
          next
        end
        unless declaration.is_a?(Hash)
          raise Error, "capability #{field} must be an object"
        end
        allowed_keys = %w[status evidence source observation_source requested]
        unknown_keys = declaration.keys - allowed_keys
        unless unknown_keys.empty?
          raise Error, "unknown keys for capability #{field}: #{unknown_keys.join(", ")}"
        end
        if declaration.key?("status") && !STATUSES.include?(declaration.fetch("status"))
          raise Error, "invalid status for capability #{field}"
        end
        %w[evidence source observation_source].each do |key|
          next unless declaration.key?(key)
          value = declaration.fetch(key)
          unless value.is_a?(String) && !value.strip.empty?
            raise Error, "#{key} for capability #{field} must be nonempty"
          end
        end
        if declaration.key?("source") && declaration.key?("observation_source")
          raise Error, "capability #{field} must use one source field"
        end
        if declaration.key?("requested") &&
           declaration.fetch("requested") != requested.fetch(field).fetch("requested")
          raise Error, "requested value for capability #{field} does not match the task"
        end
        source_key = declaration.key?("source") ? "source" : "observation_source"
        if %w[status evidence].all? { |key| declaration.key?(key) } && declaration.key?(source_key)
          normalized[field] = requested.fetch(field).merge(
            "status" => declaration.fetch("status"),
            "evidence" => declaration.fetch("evidence"),
            "source" => declaration.fetch(source_key)
          )
        else
          normalized[field] = requested.fetch(field).dup
        end
      end
    end

    def verdict(record, ordinary_verdict = "PASS", required: FIELDS)
      gate(record, ordinary_verdict, required: required).fetch("verdict")
    end

    def gate(record, ordinary_verdict = "PASS", required: FIELDS)
      validate_normalized!(record)
      unknown_required = required - FIELDS
      unless unknown_required.empty?
        raise Error, "unknown required capabilities: #{unknown_required.join(", ")}"
      end
      degraded = required.select do |field|
        record.fetch(field).fetch("status") == "unavailable"
      end
      degraded.concat(SAFETY_BOUNDARIES.select do |field|
        required.include?(field) && record.fetch(field).fetch("status") == "behavioral"
      end)
      degraded.uniq!
      suppressed = !degraded.empty?
      {
        "verdict" => suppressed ? "DEGRADED CAPABILITIES" : ordinary_verdict,
        "ordinary_verdict_suppressed" => suppressed,
        "findings_usable" => true,
        "degraded_capabilities" => degraded
      }
    end

    def validate_normalized!(record)
      unless record.is_a?(Hash) && record.keys.sort == FIELDS.sort
        raise Error, "capability record must be normalized before gating"
      end
      expected_keys = %w[evidence requested source status]
      record.each do |field, declaration|
        unless declaration.is_a?(Hash) && declaration.keys.sort == expected_keys &&
               STATUSES.include?(declaration["status"]) &&
               declaration["evidence"].is_a?(String) && !declaration["evidence"].strip.empty? &&
               declaration["source"].is_a?(String) && !declaration["source"].strip.empty?
          raise Error, "capability #{field} is not normalized"
        end
      end
      true
    end
    private_class_method :validate_normalized!
  end
end
