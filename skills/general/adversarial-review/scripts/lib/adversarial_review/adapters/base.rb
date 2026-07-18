module AdversarialReview
  module Adapters
    class Base
      LOCALE_VARIABLES = %w[LANG LC_ALL LC_CTYPE].freeze
      Decision = Struct.new(
        :status, :execution_allowed, :ordinary_result, :reason,
        keyword_init: true
      )
      ExecutionResult = Struct.new(
        :status, :payload, :usage, :capabilities, :attempts,
        :runner_results, :error_code, :ordinary_result,
        keyword_init: true
      )

      DIRECT_SUPPORT = {
        "codex" => %w[default high],
        "claude" => %w[default high ultra],
        "cursor" => %w[default high],
        "gemini" => %w[default high]
      }.freeze
      TIERS = %w[default high ultra].freeze

      class << self
        def direct_contracts
          DIRECT_SUPPORT.keys.sort.flat_map do |adapter|
            TIERS.map do |tier|
              {
                "adapter" => adapter,
                "tier" => tier,
                "direct_supported" => DIRECT_SUPPORT.fetch(adapter).include?(tier)
              }
            end
          end.freeze
        end

        def runtime_decision(adapter:, tier:, requested_model:, requested_effort:,
                             observed_model:, observed_effort:)
          contract = direct_contracts.find do |entry|
            entry.fetch("adapter") == adapter && entry.fetch("tier") == tier
          end
          unless contract && contract.fetch("direct_supported")
            return generic_decision("direct adapter does not support the requested tier")
          end
          unless nonempty_string?(requested_model) && nonempty_string?(requested_effort)
            return generic_decision("direct execution requires exact requested model and effort")
          end
          unless observed_model == requested_model && observed_effort == requested_effort
            return generic_decision("runtime model or effort was missing or weaker than requested")
          end

          Decision.new(
            status: "direct", execution_allowed: true, ordinary_result: true,
            reason: "runtime model and effort match the requested contract"
          )
        end

        private

        def generic_decision(reason)
          Decision.new(
            status: "generic", execution_allowed: false,
            ordinary_result: false, reason: reason
          )
        end

        def nonempty_string?(value)
          value.is_a?(String) && !value.strip.empty?
        end
      end

      def capabilities(requested_model:, requested_effort:, observations: {})
        unless observations.is_a?(Hash)
          raise Capabilities::Error, "capability observations must be an object"
        end
        declarations = observations.each_with_object({}) do |(field, value), result|
          unless value.is_a?(Array) && value.length == 3
            raise Capabilities::Error, "capability observation must contain status, evidence, and source"
          end
          result[field] = {
            "status" => value.fetch(0),
            "evidence" => value.fetch(1),
            "source" => value.fetch(2)
          }
        end
        Capabilities.normalize(
          declarations,
          requested_model: requested_model,
          requested_effort: requested_effort
        )
      end

      def credential_variables
        []
      end

      def child_environment(source_env: ENV, isolated_home: nil, isolated_config_root: nil)
        unless credential_variables.is_a?(Array) &&
               credential_variables.all? { |name| valid_environment_name?(name) }
          raise ArgumentError, "environment source and credential allowlist are invalid"
        end
        source = environment_hash(source_env)
        allowed = (LOCALE_VARIABLES + credential_variables).uniq
        environment = allowed.each_with_object({}) do |name, result|
          value = source[name]
          result[name] = value if value.is_a?(String)
        end
        if isolated_home
          environment["HOME"] = validated_isolated_root(isolated_home, "HOME")
        end
        if isolated_config_root
          environment["XDG_CONFIG_HOME"] = validated_isolated_root(
            isolated_config_root, "config root"
          )
        end
        environment
      end

      def execute_with_one_repair(requested_model:, requested_effort:,
                                  required_checks: [])
        attempts = 0
        results = []
        usage = Hash.new(0)
        loop do
          attempts += 1
          runner_result, envelope = invoke(attempts == 2)
          results << runner_result
          unless successful_process?(runner_result)
            code = runner_result && runner_result.timed_out ? "process_timeout" : "process_failed"
            return failed_execution(code, attempts, results, usage)
          end
          if runner_result.stdout_truncated || runner_result.stderr_truncated
            return failed_execution("process_output_truncated", attempts, results, usage)
          end
          unless envelope.is_a?(Hash)
            return failed_execution("runtime_attestation_missing", attempts, results, usage)
          end
          merge_usage!(usage, envelope["usage"])
          unless envelope["terminal"].is_a?(Hash) &&
                 envelope.dig("terminal", "terminal") == true
            return failed_execution("runtime_attestation_missing", attempts, results, usage)
          end

          terminal = envelope.fetch("terminal")
          decision = self.class.runtime_decision(
            adapter: adapter_name,
            tier: tier,
            requested_model: requested_model,
            requested_effort: requested_effort,
            observed_model: terminal["model"],
            observed_effort: terminal["effort"]
          )
          unless decision.execution_allowed
            return failed_execution("runtime_selection_mismatch", attempts, results, usage)
          end

          begin
            normalized_capabilities = Capabilities.normalize(
              envelope["capabilities"] || {},
              requested_model: requested_model,
              requested_effort: requested_effort
            )
            capability_gate = Capabilities.gate(normalized_capabilities, "PASS")
          rescue Capabilities::Error
            return failed_execution("capability_attestation_invalid", attempts, results, usage)
          end
          unless capability_gate.fetch("capability_status") == "CAPABILITIES SATISFIED"
            return failed_execution(
              "capabilities_degraded", attempts, results, usage, normalized_capabilities
            )
          end

          payload = envelope["payload"]
          checks_present = required_checks.is_a?(Array) &&
                           required_checks.all? do |check|
                             payload.is_a?(Hash) && payload["checks"].is_a?(Array) &&
                               payload.fetch("checks").include?(check)
                           end
          if valid_payload?(payload) && checks_present
            return ExecutionResult.new(
              status: "complete", payload: payload, usage: usage.to_h,
              capabilities: normalized_capabilities, attempts: attempts,
              runner_results: results, error_code: nil, ordinary_result: true
            )
          end
          return failed_execution("invalid_result", attempts, results, usage) if attempts == 2
        end
      rescue Runner::Error
        failed_execution("runner_error", attempts, results, usage)
      rescue StandardError
        failed_execution("adapter_error", attempts, results, usage)
      end

      def invoke(_repair)
        raise NotImplementedError, "direct adapters must implement invoke"
      end

      def valid_payload?(_payload)
        raise NotImplementedError, "direct adapters must validate their role schema"
      end

      def adapter_name
        name = self.class.name.to_s.split("::").last.to_s.downcase
        DIRECT_SUPPORT.key?(name) ? name : "unknown"
      end

      def tier
        "default"
      end

      private

      def environment_hash(source)
        pairs = if source.respond_to?(:each_pair)
                  source
                elsif source.respond_to?(:to_h)
                  source.to_h
                end
        unless pairs && pairs.respond_to?(:each_pair)
          raise ArgumentError, "environment source must provide each_pair or to_h"
        end
        result = {}
        pairs.each_pair do |key, value|
          unless valid_environment_name?(key) && value.is_a?(String) && !value.include?("\0")
            raise ArgumentError, "environment keys and values must be strings"
          end
          result[key] = value
        end
        result
      end

      def valid_environment_name?(name)
        name.is_a?(String) && !name.empty? && !name.include?("=") && !name.include?("\0")
      end

      def validated_isolated_root(path, label)
        unless path.is_a?(String) && path.start_with?(File::SEPARATOR)
          raise ArgumentError, "isolated #{label} must be an absolute path"
        end
        expected = File.lstat(path)
        unless expected.directory? && !expected.symlink? && expected.uid == Process.euid &&
               (expected.mode & 0o777) == 0o700
          raise ArgumentError, "isolated #{label} must be a private owned directory"
        end
        canonical = File.realpath(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(canonical, flags) do |directory|
          opened = directory.stat
          unless opened.directory? && opened.dev == expected.dev && opened.ino == expected.ino &&
                 opened.uid == Process.euid && (opened.mode & 0o777) == 0o700
            raise ArgumentError, "isolated #{label} identity or permissions changed"
          end
        end
        canonical
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM
        raise ArgumentError, "isolated #{label} is unavailable"
      end

      def successful_process?(result)
        result.is_a?(Runner::Result) && !result.timed_out && result.exit_status == 0
      end

      def merge_usage!(aggregate, current)
        return unless current.is_a?(Hash)
        current.each do |key, value|
          aggregate[key] += value if key.is_a?(String) && value.is_a?(Integer) && value >= 0
        end
      end

      def failed_execution(code, attempts, results, usage, capabilities = nil)
        ExecutionResult.new(
          status: "generic", payload: nil, usage: usage.to_h,
          capabilities: capabilities, attempts: attempts, runner_results: results,
          error_code: code, ordinary_result: false
        )
      end
    end
  end
end
