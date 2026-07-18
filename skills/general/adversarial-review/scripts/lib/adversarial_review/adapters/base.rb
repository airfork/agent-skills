require "json"

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
        :runner_results, :error_code, :ordinary_result, :runtime_provenance,
        keyword_init: true
      )

      DIRECT_SUPPORT = {
        "codex" => %w[default high],
        "claude" => %w[default high ultra],
        "cursor" => %w[default high],
        "gemini" => %w[default high]
      }.freeze
      TIERS = %w[default high ultra].freeze
      PREFLIGHT_SCHEMA = {
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["ok"],
        "properties" => {"ok" => {"const" => true}}
      }.freeze
      PREFLIGHT_PAYLOAD = {"ok" => true}.freeze

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

      def configure_direct(executable:, repository:, model:, effort:, role_schema:,
                           schema_name:, prompt:, tier: "default", timeout_seconds: 120,
                           source_env: ENV, run_directory: nil, config_root: nil)
        unless executable.is_a?(String) && !executable.empty? &&
               model.is_a?(String) && !model.empty? &&
               effort.is_a?(String) && !effort.empty? &&
               role_schema.is_a?(Hash) && !role_schema.empty? &&
               schema_name.is_a?(String) && !schema_name.empty? &&
               prompt.is_a?(String) && !prompt.empty? &&
               TIERS.include?(tier) && timeout_seconds.is_a?(Numeric) &&
               timeout_seconds.positive?
          raise ArgumentError, "direct adapter configuration is invalid"
        end
        canonical_repository = File.realpath(repository)
        unless File.directory?(canonical_repository)
          raise ArgumentError, "direct adapter repository must be a directory"
        end

        @executable_candidate = executable
        @repository = canonical_repository
        @requested_model = model
        @requested_effort = effort
        @role_schema = JSON.parse(JSON.generate(role_schema))
        @schema_name = schema_name
        @prompt = prompt
        @tier = tier
        @timeout_seconds = timeout_seconds
        @source_env = source_env
        @run_directory = run_directory
        @configured_config_root = config_root
        @runtime_provenance_records = nil
        @capability_probe = nil
        self
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
             Errno::ELOOP
        raise ArgumentError, "direct adapter repository is unavailable"
      end

      def execute(required_checks: [])
        ensure_direct_configuration!
        @runtime_provenance_records = nil
        @direct_session_ids = nil
        @last_active_phase = nil
        @last_active_attempt = nil
        support = self.class.runtime_decision(
          adapter: adapter_name, tier: tier,
          requested_model: @requested_model, requested_effort: @requested_effort,
          observed_model: @requested_model, observed_effort: @requested_effort
        )
        return direct_failure("unsupported_tier") unless support.execution_allowed

        @pinned_executable = Runner.resolve_executable(
          @executable_candidate, repository: @repository,
          run_directory: @run_directory, config_root: @configured_config_root
        )
        Runner.with_isolated_directory(prefix: "adversarial-review-direct") do |root|
          prepare_isolated_runtime(root)
          @preflight_mode = true
          @active_phase = "probe"
          @active_attempt = nil
          probe_results = []
          help_result = run_probe(help_argv)
          probe_results << help_result
          unless successful_process?(help_result) && help_capabilities_present?(help_result.stdout)
            return direct_failure("capability_probe_failed", probe_results)
          end
          version_result = run_probe([@pinned_executable.path, "--version"])
          probe_results << version_result
          unless successful_process?(version_result) && nonempty_text?(version_result.stdout)
            return direct_failure("version_probe_failed", probe_results)
          end
          @cli_version = version_result.stdout.strip
          @capability_probe = {
            "help_argv" => help_argv.dup,
            "version_argv" => [@pinned_executable.path, "--version"],
            "cli_version" => @cli_version,
            "executable" => @pinned_executable.path
          }

          @active_phase = "preflight"
          @active_attempt = 0
          preflight_result, preflight_envelope = invoke_prompt(preflight_prompt)
          probe_results << preflight_result if preflight_result
          record_runtime_observation(preflight_envelope)
          preflight_error = attestation_error(preflight_result, preflight_envelope)
          return direct_failure(preflight_error, probe_results) if preflight_error
          preflight_usage = valid_usage(preflight_envelope["usage"])

          @preflight_mode = false
          @active_phase = "execution"
          result = execute_with_one_repair(
            requested_model: @requested_model,
            requested_effort: @requested_effort,
            required_checks: required_checks
          )
          result.runner_results.unshift(*probe_results)
          merge_usage!(result.usage, preflight_usage)
          result
        ensure
          @schema_path = nil
          @preflight_schema_path = nil
          @preflight_repository = nil
          @isolated_home = nil
          @isolated_config_root = nil
          @direct_root = nil
          @preflight_mode = false
          @active_phase = nil
          @active_attempt = nil
        end
      rescue Runner::Error
        direct_failure("runner_error")
      rescue Capabilities::Error
        direct_failure("capability_attestation_invalid")
      rescue StandardError
        direct_failure("adapter_error")
      end

      def runtime_provenance
        provenance_snapshot
      end

      def capability_probe
        @capability_probe && JSON.parse(JSON.generate(@capability_probe))
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
          @active_attempt = attempts if @runtime_provenance_records
          runner_result, envelope = invoke(attempts == 2)
          results << runner_result
          record_runtime_observation(envelope) if @runtime_provenance_records
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
          terminal_error = direct_terminal_error(terminal)
          if terminal_error
            return failed_execution(terminal_error, attempts, results, usage)
          end
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
                             payload_checks(payload).include?(check)
                           end
          if valid_payload?(payload) && checks_present
            return ExecutionResult.new(
              status: "complete", payload: payload, usage: usage.to_h,
              capabilities: normalized_capabilities, attempts: attempts,
              runner_results: results, error_code: nil, ordinary_result: true,
              runtime_provenance: provenance_snapshot
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
        @tier || "default"
      end

      def help_argv
        raise NotImplementedError, "direct adapters must define a capability help probe"
      end

      def required_help_tokens
        raise NotImplementedError, "direct adapters must define required capability flags"
      end

      def invoke_prompt(_prompt)
        raise NotImplementedError, "direct adapters must invoke one isolated role process"
      end

      private

      def ensure_direct_configuration!
        required = [@executable_candidate, @repository, @requested_model,
                    @requested_effort, @role_schema, @schema_name, @prompt]
        raise ArgumentError, "direct adapter is not configured" if required.any?(&:nil?)
      end

      def prepare_isolated_runtime(root)
        @direct_root = File.realpath(root)
        @preflight_repository = File.join(@direct_root, "empty-repository")
        @isolated_home = File.join(@direct_root, "home")
        @isolated_config_root = File.join(@direct_root, "config")
        Dir.mkdir(@preflight_repository, 0o700)
        Dir.mkdir(@isolated_home, 0o700)
        Dir.mkdir(@isolated_config_root, 0o700)
        @schema_path = File.join(@direct_root, "role-schema.json")
        Runner.write_private_file(@schema_path, JSON.generate(@role_schema))
        @preflight_schema_path = File.join(@direct_root, "preflight-schema.json")
        Runner.write_private_file(@preflight_schema_path, JSON.generate(PREFLIGHT_SCHEMA))
        @runtime_provenance_records = {
          "preflight" => nil,
          "executions" => [],
          "failure" => nil
        }
        @direct_session_ids = {}
      end

      def run_probe(argv)
        repository = active_repository
        Runner.run(
          argv: argv, stdin_data: "", timeout_seconds: @timeout_seconds,
          env: child_environment(
            source_env: @source_env, isolated_home: @isolated_home,
            isolated_config_root: @isolated_config_root
          ),
          chdir: repository, repository: repository, run_directory: @run_directory,
          config_root: @isolated_config_root, executable: @pinned_executable
        )
      end

      def run_direct(argv:, stdin_data:)
        repository = active_repository
        Runner.run(
          argv: argv, stdin_data: stdin_data, timeout_seconds: @timeout_seconds,
          env: child_environment(
            source_env: @source_env, isolated_home: @isolated_home,
            isolated_config_root: @isolated_config_root
          ),
          chdir: repository, repository: repository,
          run_directory: @run_directory, config_root: @isolated_config_root,
          executable: @pinned_executable
        )
      end

      def help_capabilities_present?(stdout)
        nonempty_text?(stdout) && required_help_tokens.all? do |token|
          stdout.match?(/(?:\A|[\s,])#{Regexp.escape(token)}(?=\z|[\s,=])/)
        end
      end

      def attestation_error(runner_result, envelope)
        return "process_failed" unless successful_process?(runner_result)
        return "process_output_truncated" if runner_result.stdout_truncated || runner_result.stderr_truncated
        return "runtime_attestation_missing" unless envelope.is_a?(Hash)
        terminal = envelope["terminal"]
        return "runtime_attestation_missing" unless terminal.is_a?(Hash) && terminal["terminal"] == true
        terminal_error = direct_terminal_error(terminal)
        return terminal_error if terminal_error
        decision = self.class.runtime_decision(
          adapter: adapter_name, tier: tier,
          requested_model: @requested_model, requested_effort: @requested_effort,
          observed_model: terminal["model"], observed_effort: terminal["effort"]
        )
        return "runtime_selection_mismatch" unless decision.execution_allowed
        normalized = Capabilities.normalize(
          envelope["capabilities"] || {},
          requested_model: @requested_model,
          requested_effort: @requested_effort
        )
        gate = Capabilities.gate(normalized, "PASS")
        return "capabilities_degraded" unless gate.fetch("capability_status") == "CAPABILITIES SATISFIED"
        return "structured_output_unattested" unless direct_payload_valid?(envelope["payload"])
        nil
      rescue Capabilities::Error
        "capability_attestation_invalid"
      end

      def direct_failure(code, runner_results = [])
        record_failure(code)
        ExecutionResult.new(
          status: "generic", payload: nil, usage: {}, capabilities: nil,
          attempts: 0, runner_results: runner_results,
          error_code: code, ordinary_result: false,
          runtime_provenance: provenance_snapshot
        )
      end

      def payload_checks(payload)
        return [] unless payload.is_a?(Hash)
        checks = payload["checks_completed"] || payload["checks"]
        checks.is_a?(Array) ? checks : []
      end

      def active_repository
        @preflight_mode ? @preflight_repository : @repository
      end

      def direct_terminal_error(terminal)
        return nil unless @direct_session_ids
        session_id = terminal["session_id"]
        return "runtime_attestation_missing" unless nonempty_text?(session_id)
        return "session_reused" if @direct_session_ids.key?(session_id)
        if tier == "ultra" && terminal["independent_vote"] != true
          return "independent_vote_unattested"
        end

        @direct_session_ids[session_id] = {
          "phase" => @active_phase,
          "attempt" => @active_attempt
        }
        nil
      end

      def record_runtime_observation(envelope)
        return unless @runtime_provenance_records
        @last_active_phase = @active_phase
        @last_active_attempt = @active_attempt
        vendor = envelope.is_a?(Hash) && envelope["provenance"].is_a?(Hash) ?
          envelope.fetch("provenance") : {}
        record = JSON.parse(JSON.generate(vendor)).merge(
          "phase" => @active_phase,
          "attempt" => @active_attempt,
          "status" => vendor.empty? ? "missing" : "observed"
        )
        if @active_phase == "preflight"
          @runtime_provenance_records["preflight"] = record
        else
          @runtime_provenance_records.fetch("executions") << record
        end
      end

      def record_failure(code)
        return unless @runtime_provenance_records
        @runtime_provenance_records["failure"] = {
          "phase" => @active_phase || @last_active_phase || "probe",
          "attempt" => @active_attempt || @last_active_attempt,
          "error_code" => code
        }
      end

      def provenance_snapshot
        return nil unless @runtime_provenance_records
        JSON.parse(JSON.generate(@runtime_provenance_records))
      end

      def valid_usage(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) do |(key, amount), usage|
          usage[key] = amount if key.is_a?(String) && amount.is_a?(Integer) && amount >= 0
        end
      end

      def valid_usage?(usage)
        usage.is_a?(Hash) && !usage.empty? && usage.all? do |key, amount|
          key.is_a?(String) && amount.is_a?(Integer) && amount >= 0
        end
      end

      def parse_json_line_objects(text, label)
        unless text.is_a?(String) && !text.empty?
          raise JSON::ParserError, "empty #{label} event stream"
        end
        text.lines.reject { |line| line.strip.empty? }.map do |line|
          event = JSON.parse(line)
          unless event.is_a?(Hash)
            raise JSON::ParserError, "#{label} event is not an object"
          end
          event
        end
      end

      def direct_capabilities(source:, fresh_context:, repository_access:, read_only:,
                              model_selection:, effort_selection:, structured_output:,
                              usage_metrics:)
        conditions = {
          "fresh_context" => fresh_context,
          "repository_access" => repository_access,
          "read_only" => read_only,
          "model_selection" => model_selection,
          "effort_selection" => effort_selection,
          "structured_output" => structured_output,
          "usage_metrics" => usage_metrics
        }
        observations = conditions.each_with_object({}) do |(field, condition), record|
          unless condition.is_a?(Array) && condition.length == 2 &&
                 [true, false].include?(condition.fetch(0)) &&
                 nonempty_text?(condition.fetch(1))
            raise Capabilities::Error, "direct capability evidence is malformed"
          end
          record[field] = [
            condition.fetch(0) ? "enforced" : "unavailable",
            condition.fetch(1), source
          ]
        end
        observations["parallel_dispatch"] = [
          "behavioral", "parent schedules isolated role processes", "adapter contract"
        ]
        capabilities(
          requested_model: @requested_model,
          requested_effort: @requested_effort,
          observations: observations
        )
      end

      def preflight_prompt
        "Return {\"ok\":true} only. Do not inspect repository content. This request only verifies the isolated runtime controls."
      end

      def active_schema
        @preflight_mode ? PREFLIGHT_SCHEMA : @role_schema
      end

      def active_schema_path
        @preflight_mode ? @preflight_schema_path : @schema_path
      end

      def direct_payload_valid?(payload)
        @preflight_mode ? payload == PREFLIGHT_PAYLOAD : valid_payload?(payload)
      end

      def nonempty_text?(value)
        value.is_a?(String) && !value.strip.empty?
      end

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
        record_failure(code)
        ExecutionResult.new(
          status: "generic", payload: nil, usage: usage.to_h,
          capabilities: capabilities, attempts: attempts, runner_results: results,
          error_code: code, ordinary_result: false,
          runtime_provenance: provenance_snapshot
        )
      end
    end
  end
end
