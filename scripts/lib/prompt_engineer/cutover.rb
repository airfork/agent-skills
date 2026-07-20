module PromptEngineer
  module Cutover
    class Error < StandardError; end

    QUALIFICATION_DECISIONS = %w[
      QUALIFIED_EXPLICIT QUALIFIED_IMPLICIT NOT_QUALIFIED INCONCLUSIVE
    ].freeze
    REQUIRED_HOSTS = %w[codex claude].freeze
    CAPABILITY_FIELDS = %w[host status normalizer reason evidence].freeze
    EVIDENCE_FIELDS = %w[artifact pointer root sha256].freeze
    DIGEST = /\A[0-9a-f]{64}\z/.freeze

    module_function

    def evaluate(qualification:, capabilities:, runtime:, sandbox:, evidence_manifest: nil)
      reasons = []
      reasons << "qualification is not a scorer decision" unless QUALIFICATION_DECISIONS.include?(qualification)
      reasons << "qualification decision is not qualified" unless %w[QUALIFIED_EXPLICIT QUALIFIED_IMPLICIT].include?(qualification)
      trusted_capabilities = defined?(PromptEngineer::Capabilities::RECORDS) && capabilities.equal?(PromptEngineer::Capabilities::RECORDS)
      reasons << "capability evidence authenticity is unproven" unless trusted_capabilities
      reasons.concat(capability_errors(capabilities, evidence_manifest))
      reasons << "Ruby 2.6 compatibility evidence is unavailable" unless runtime == "ruby-2.6"
      reasons << "sandbox support is unavailable" unless sandbox == "supported"
      {
        "decision" => reasons.empty? ? "READY" : "BLOCKED",
        "mutations_permitted" => reasons.empty?,
        "reasons" => reasons
      }
    end

    def apply!(_decision)
      raise Error, "cutover mutations are disabled until all qualification gates pass"
    end

    def capability_errors(capabilities, evidence_manifest)
      return ["capability evidence is not an object"] unless capabilities.is_a?(Hash)
      return ["capability hosts are not exactly codex and claude"] unless capabilities.keys.sort == REQUIRED_HOSTS.sort

      REQUIRED_HOSTS.each_with_object([]) do |host, reasons|
        record = capabilities.fetch(host)
        unless record.is_a?(Hash) && record.keys.sort == CAPABILITY_FIELDS.sort
          reasons << "#{host} capability record is not exact and nonempty"
          next
        end
        reasons << "#{host} capability host does not match key" unless record["host"] == host
        reasons << "#{host} capability is not supported" unless record.fetch("status") == "supported"
        reasons << "#{host} normalizer evidence is missing" unless nonempty_string?(record.fetch("normalizer"))
        reasons << "#{host} capability reason is missing" unless nonempty_string?(record.fetch("reason"))
        evidence = record.fetch("evidence")
        unless evidence.is_a?(Hash) && evidence.keys.sort == EVIDENCE_FIELDS.sort &&
               evidence.values.all? { |value| nonempty_string?(value) } &&
               evidence.fetch("sha256").match?(DIGEST)
          reasons << "#{host} capability evidence is not exact and nonempty"
        end
        if evidence_manifest
          manifest_file = Array(evidence_manifest["files"]).find { |file| file.is_a?(Hash) && file["path"] == evidence["artifact"] }
          unless manifest_file && manifest_file["sha256"] == evidence["sha256"]
            reasons << "#{host} capability evidence is not bound to immutable manifest"
          end
        end
      end
    end
    private_class_method :capability_errors

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end
    private_class_method :nonempty_string?
  end
end
