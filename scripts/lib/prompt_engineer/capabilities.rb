module PromptEngineer
  module Capabilities
    class Error < StandardError; end
    class UnknownHostError < Error; end

    HOSTS = %w[codex claude].freeze
    EVIDENCE_ROOT = "/Users/tunji/.codex/prompt-engineer-replacement-evidence/task0".freeze

    RECORDS = {
      "codex" => {
        "host" => "codex",
        "status" => "unsupported",
        "normalizer" => "absent",
        "reason" => "real native export evidence is unavailable",
        "evidence" => {
          "root" => EVIDENCE_ROOT,
          "artifact" => "codex/export-capabilities.json",
          "pointer" => "#/",
          "sha256" => "2912ad89e4b33261e032f5f10380ea98b3f2e9f7378f2f68983897c4407efd98"
        }
      },
      "claude" => {
        "host" => "claude",
        "status" => "unsupported",
        "normalizer" => "absent",
        "reason" => "real native export evidence is unavailable",
        "evidence" => {
          "root" => EVIDENCE_ROOT,
          "artifact" => "claude/export-capabilities.json",
          "pointer" => "#/",
          "sha256" => "6ca71a57a6e5540e7dd3ef55081d46cbf8bf33f40091e7b694093f95765ed30b"
        }
      }
    }.freeze

    module_function

    def report
      HOSTS.each_with_object({}) do |host, result|
        result[host] = copy(RECORDS.fetch(host))
      end
    end

    def for(host)
      unless host.is_a?(String) && HOSTS.include?(host)
        raise UnknownHostError, "unknown native host: #{host.inspect}"
      end

      copy(RECORDS.fetch(host))
    end

    def copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key] = copy(child) }
      when Array
        value.map { |child| copy(child) }
      else
        value
      end
    end
    private_class_method :copy
  end
end
