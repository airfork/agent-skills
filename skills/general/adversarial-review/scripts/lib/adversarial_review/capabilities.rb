module AdversarialReview
  module Capabilities
    FIELDS = %w[
      fresh_context repository_access read_only model_selection effort_selection
      structured_output usage_metrics parallel_dispatch
    ].freeze
    SAFETY_BOUNDARIES = %w[fresh_context repository_access read_only].freeze
    STATUSES = %w[enforced behavioral unavailable].freeze
    STATUS_RANK = {"enforced" => 2, "behavioral" => 1, "unavailable" => 0}.freeze

    # What a host structurally cannot enforce, as a package-owned fact rather
    # than a caller's claim. A run that meets its host's ceiling discloses those
    # limits without losing an ordinary verdict; a run that falls below a ceiling
    # it could have met stays DEGRADED CAPABILITIES, so the verdict distinguishes
    # "this host cannot prove it" from "this run did not bother". Hosts absent
    # from this table get no allowances.
    HOST_BASELINES = {
      # Every Claude Code agent type retains a shell, so no dispatch can make a
      # reviewer mechanically read-only, and the harness reports no input/cached
      # token split. Reasoning effort and output schemas are pinnable per agent,
      # so neither is excused here.
      "claude-code" => {
        "read_only" => "behavioral",
        "usage_metrics" => "behavioral"
      },
      # Copilot exposes no machine-readable attestation of model or reasoning
      # effort, and no per-agent usage telemetry.
      "copilot" => {
        "read_only" => "behavioral",
        "model_selection" => "unavailable",
        "effort_selection" => "unavailable",
        "usage_metrics" => "unavailable"
      }
    }.freeze

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

    # The declared ceiling for a host name. Unknown or absent hosts get no
    # allowances, so a forged or missing host name can never soften the gate
    # beyond a ceiling this package already published.
    def baseline_for(host)
      HOST_BASELINES.fetch(host.to_s.downcase, {})
    end

    def verdict(record, ordinary_verdict = "PASS", required: FIELDS, baseline: {})
      gate(record, ordinary_verdict, required: required, baseline: baseline).fetch("verdict")
    end

    def gate(record, ordinary_verdict = "PASS", required: FIELDS, baseline: {})
      validate_normalized!(record)
      unknown_required = required - FIELDS
      unless unknown_required.empty?
        raise Error, "unknown required capabilities: #{unknown_required.join(", ")}"
      end
      validate_baseline!(baseline)
      degraded = required.select do |field|
        record.fetch(field).fetch("status") == "unavailable"
      end
      degraded.concat(SAFETY_BOUNDARIES.select do |field|
        required.include?(field) && record.fetch(field).fetch("status") == "behavioral"
      end)
      degraded.uniq!
      # A capability is only excused when the run met the ceiling; declaring a
      # status worse than the host's published limit still counts against it.
      host_limited = degraded.select do |field|
        permitted = baseline[field]
        permitted && STATUS_RANK.fetch(record.fetch(field).fetch("status")) >=
          STATUS_RANK.fetch(permitted)
      end
      below_baseline = degraded - host_limited
      capabilities_degraded = !below_baseline.empty?
      suppressed = capabilities_degraded && ordinary_verdict == "PASS"
      {
        "verdict" => suppressed ? "DEGRADED CAPABILITIES" : ordinary_verdict,
        "capability_status" => capabilities_degraded ?
          "DEGRADED CAPABILITIES" : "CAPABILITIES SATISFIED",
        "ordinary_verdict_suppressed" => suppressed,
        "findings_usable" => true,
        "degraded_capabilities" => below_baseline,
        "host_capability_limits" => host_limited
      }
    end

    def validate_baseline!(baseline)
      raise Error, "capability baseline must be an object" unless baseline.is_a?(Hash)
      unknown = baseline.keys - FIELDS
      raise Error, "unknown baseline capabilities: #{unknown.join(", ")}" unless unknown.empty?
      baseline.each_value do |status|
        raise Error, "invalid baseline status" unless STATUSES.include?(status)
      end
      true
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
