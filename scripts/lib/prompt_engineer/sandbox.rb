require "digest"

module PromptEngineer
  module Sandbox
    class Error < StandardError; end
    class UnsupportedError < Error; end
    class ValidationError < Error
      attr_reader :code

      def initialize(code, message = code)
        @code = code
        super(message)
      end
    end

    REQUIRED = %w[
      kind run_id case_id nonce lease_id reservation_id argv_template
      executable_realpath run_root_identity packet_digest environment_allowlist
      runtime_read_allowlist write_roots endpoint_policy timeout_seconds
      expected_package_digest
    ].freeze
    KINDS = %w[executor judge].freeze
    OLD_PACKET_FIELDS = %w[
      schema_version kind run_id case_id host arm_id repeat_index nonce lease_id
      reservation_id argv executable_path run_root run_root_identity ledger_path
      lease_event_digest staged_roots environment_allowlist runtime_read_allowlist
      write_roots provider_endpoint_policy timeout_seconds expected_package_digest
      expected_input_digest
    ].freeze
    FORBIDDEN_ENV = /(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|AUTH|PROXY|SOCK)/i.freeze

    module_function

    def validate_launch_packet!(packet)
      raise ValidationError.new("invalid_packet", "launch packet must be an object") unless packet.is_a?(Hash)
      return validate_old_packet!(packet) if packet.key?("schema_version")

      missing = REQUIRED.reject { |key| packet.key?(key) }
      raise ValidationError.new("missing_field", "launch packet missing #{missing.join(', ')}") unless missing.empty?
      raise ValidationError.new("unknown_field", "unknown launch packet fields") unless (packet.keys - REQUIRED).empty?
      raise ValidationError.new("invalid_kind", "invalid launch kind") unless KINDS.include?(packet.fetch("kind"))
      %w[run_id case_id nonce lease_id reservation_id executable_realpath packet_digest expected_package_digest].each do |key|
        value = packet.fetch(key)
        raise ValidationError.new("invalid_field", "#{key} must be a nonempty string") unless value.is_a?(String) && !value.empty?
      end
      raise ValidationError.new("invalid_argv", "argv_template must be a nonempty array") unless packet.fetch("argv_template").is_a?(Array) && !packet.fetch("argv_template").empty?
      raise ValidationError.new("invalid_allowlist", "allowlists must be arrays") unless %w[environment_allowlist runtime_read_allowlist write_roots].all? { |key| packet.fetch(key).is_a?(Array) }
      timeout = packet.fetch("timeout_seconds")
      raise ValidationError.new("invalid_timeout", "timeout must be a positive integer") unless timeout.is_a?(Integer) && timeout.positive? && timeout <= 86_400
      raise ValidationError.new("packet_digest_mismatch", "packet digest mismatch") unless packet.fetch("packet_digest") == packet_digest(packet)
      packet
    end

    def validate_old_packet!(packet)
      unknown = packet.keys - OLD_PACKET_FIELDS
      raise ValidationError.new("unknown_field", "unknown launch packet fields") unless unknown.empty?
      raise ValidationError.new("invalid_schema", "schema version must be 1") unless packet["schema_version"] == 1
      %w[run_root executable_path].each { |key| validate_absolute_path!(packet.fetch(key)) }
      validate_relative_path!(packet.fetch("ledger_path"))
      %w[environment_allowlist runtime_read_allowlist].each do |key|
        values = packet.fetch(key)
        raise ValidationError.new("invalid_allowlist", "#{key} must be sorted and unique") unless values.is_a?(Array) && values == values.sort.uniq
      end
      if packet.fetch("environment_allowlist").any? { |name| name.match?(FORBIDDEN_ENV) }
        raise ValidationError.new("forbidden_environment", "credential or proxy environment variable is forbidden")
      end
      raise ValidationError.new("invalid_timeout", "timeout must be positive") unless packet.fetch("timeout_seconds").is_a?(Integer) && packet.fetch("timeout_seconds") > 0
      root = packet.fetch("run_root")
      write_roots = packet.fetch("write_roots")
      raise ValidationError.new("invalid_allowlist", "write_roots must be an array") unless write_roots.is_a?(Array)
      write_roots.each do |write_root|
        validate_absolute_path!(write_root)
        unless write_root.start_with?(root + "/")
          raise ValidationError.new("invalid_write_root", "write root must be a strict run-root descendant")
        end
      end
      raise ValidationError.new("invalid_allowlist", "write_roots must be sorted and unique") unless write_roots == write_roots.sort.uniq
      packet
    rescue KeyError
      raise ValidationError.new("missing_field", "required launch packet field is missing")
    end

    def validate_launch_request!(packet, run_dir:, result_dir:)
      validate_launch_packet!(packet)
      validate_absolute_path!(run_dir)
      validate_absolute_path!(result_dir)
      roots = packet.fetch("write_roots")
      raise ValidationError.new("result_root_not_allowed", "result directory is outside write roots") unless roots.any? { |root| result_dir.start_with?(root + "/") }
      packet
    end

    def validate_attestation!(attestation, packet:)
      raise ValidationError.new("invalid_attestation", "attestation must be an object") unless attestation.is_a?(Hash)
      raise ValidationError.new("nonce_mismatch", "attestation nonce does not match packet") unless attestation["nonce"] == packet["nonce"]
      raise ValidationError.new("packet_digest_mismatch", "attestation packet digest does not match packet") unless attestation["packet_digest"] == digest(packet)
      attestation
    end

    def digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def packet_digest(packet)
      body = packet.reject { |key, _| key == "packet_digest" }
      PromptEngineer::Canonical.digest(body)
    end

    def launch!(_packet)
      raise UnsupportedError, "sandbox launch is unsupported: host authentication and tool isolation evidence is unavailable"
    end

    def probe(host:, platform:, **_options)
      {
        "host" => host,
        "platform" => platform,
        "launch_supported" => false,
        "qualification_capable" => false,
        "reasons" => %w[host_auth_unproven provider_reachability_unproven tool_isolation_unproven]
      }
    end

    def capability
      {"status" => "unsupported", "reason" => "host authentication and tool isolation evidence is unavailable", "live_launch" => false}
    end

    def validate_absolute_path!(path)
      valid = path.is_a?(String) && path.start_with?("/") && !path.split("/").include?("..") && !path.split("/").include?(".")
      raise ValidationError.new("invalid_path", "path must be absolute and normalized") unless valid
    end
    private_class_method :validate_absolute_path!

    def validate_relative_path!(path)
      valid = path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.split("/").include?("..") && !path.split("/").include?(".")
      raise ValidationError.new("invalid_path", "path must be relative and normalized") unless valid
    end
    private_class_method :validate_relative_path!
  end
end
