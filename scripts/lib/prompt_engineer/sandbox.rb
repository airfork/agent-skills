require "digest"

module PromptEngineer
  module Sandbox
    class Error < StandardError; end
    class UnsupportedError < Error; end

    REQUIRED = %w[
      kind run_id case_id nonce lease_id reservation_id argv_template
      executable_realpath run_root_identity packet_digest environment_allowlist
      runtime_read_allowlist write_roots endpoint_policy timeout_seconds
      expected_package_digest
    ].freeze
    KINDS = %w[executor judge].freeze

    module_function

    def validate_launch_packet!(packet)
      raise Error, "launch packet must be an object" unless packet.is_a?(Hash)
      missing = REQUIRED.reject { |key| packet.key?(key) }
      raise Error, "launch packet missing #{missing.join(', ')}" unless missing.empty?
      raise Error, "unknown launch packet fields" unless (packet.keys - REQUIRED).empty?
      raise Error, "invalid launch kind" unless KINDS.include?(packet.fetch("kind"))
      %w[run_id case_id nonce lease_id reservation_id executable_realpath packet_digest expected_package_digest].each do |key|
        value = packet.fetch(key)
        raise Error, "#{key} must be a nonempty string" unless value.is_a?(String) && !value.empty?
      end
      raise Error, "argv_template must be a nonempty array" unless packet.fetch("argv_template").is_a?(Array) && !packet.fetch("argv_template").empty?
      raise Error, "allowlists must be arrays" unless %w[environment_allowlist runtime_read_allowlist write_roots].all? { |key| packet.fetch(key).is_a?(Array) }
      timeout = packet.fetch("timeout_seconds")
      raise Error, "timeout must be a positive finite integer" unless timeout.is_a?(Integer) && timeout.positive? && timeout <= 86_400
      raise Error, "packet digest mismatch" unless packet.fetch("packet_digest") == packet_digest(packet)
      packet
    end

    def packet_digest(packet)
      body = packet.reject { |key, _| key == "packet_digest" }
      Canonical.digest(body)
    end

    def launch!(_packet)
      raise UnsupportedError, "sandbox launch is unsupported: host authentication and tool isolation evidence is unavailable"
    end

    def capability
      {
        "status" => "unsupported",
        "reason" => "host authentication and tool isolation evidence is unavailable",
        "live_launch" => false
      }
    end
  end
end
