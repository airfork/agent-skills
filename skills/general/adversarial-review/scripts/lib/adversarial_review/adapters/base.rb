require "json"
require "thread"

module AdversarialReview
  module Adapters
    class Base
      LOCALE_VARIABLES = %w[LANG LC_ALL LC_CTYPE].freeze
      PROXY_VARIABLES = %w[
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
        http_proxy https_proxy all_proxy no_proxy
      ].freeze
      PRIVATE_CA_PATHS = {
        "SSL_CERT_FILE" => :file,
        "SSL_CERT_DIR" => :directory
      }.freeze
      Decision = Struct.new(
        :status, :execution_allowed, :ordinary_result, :reason,
        keyword_init: true
      )
      ExecutionResult = Struct.new(
        :status, :payload, :usage, :capabilities, :attempts,
        :runner_results, :error_code, :ordinary_result, :runtime_provenance,
        keyword_init: true
      )
      # json >= 2.16 no longer routes duplicate keys through +[]=+ when
      # +object_class+ is given, so parse sites must also pass
      # +allow_duplicate_key: false+; this class covers older json versions,
      # which ignore that option.
      class DuplicateRejectingHash < Hash
        def []=(key, value)
          raise JSON::ParserError, "duplicate JSON key #{key.inspect}" if key?(key)
          super
        end
      end

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
      USAGE_FIELDS = %w[
        input_tokens cached_input_tokens cache_read_input_tokens
        cache_creation_input_tokens output_tokens reasoning_tokens total_tokens
      ].freeze
      MAX_EXECUTABLE_CANDIDATES = 2
      ELIGIBILITY_ERROR_CODES = %w[
        capability_probe_failed version_probe_failed unsupported_tier
        unsupported_version_contract unsupported_effort_contract capabilities_degraded
        runtime_selection_mismatch structured_output_unattested
        capability_attestation_invalid independent_vote_unattested
        runner_error preflight_failed preflight_attestation_invalid
        runtime_model_mismatch runtime_effort_mismatch dispatch_capability_invalid
        runtime_attestation_missing session_reused
      ].freeze

      class << self
        def eligibility_error?(code)
          ELIGIBILITY_ERROR_CODES.include?(code)
        end

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
                           source_env: ENV, run_directory: nil, config_root: nil,
                           prior_session_ids: [])
        unless executable.is_a?(String) && !executable.empty? &&
               model.is_a?(String) && !model.empty? &&
               effort.is_a?(String) && !effort.empty? &&
               role_schema.is_a?(Hash) && !role_schema.empty? &&
               schema_name.is_a?(String) && !schema_name.empty? &&
               prompt.is_a?(String) && !prompt.empty? &&
               TIERS.include?(tier) && timeout_seconds.is_a?(Numeric) &&
               timeout_seconds.positive? && prior_session_ids.is_a?(Array) &&
               prior_session_ids.uniq.length == prior_session_ids.length &&
               prior_session_ids.all? { |id| id.is_a?(String) && !id.empty? }
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
        @prior_session_ids = prior_session_ids.dup.freeze
        @runtime_provenance_records = nil
        @capability_probe = nil
        @execution_mutex ||= Mutex.new
        self
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
             Errno::ELOOP
        raise ArgumentError, "direct adapter repository is unavailable"
      end

      def execute(required_checks: [], dispatch_capability: nil)
        (@execution_mutex ||= Mutex.new).synchronize do
          execute_serial(
            required_checks: required_checks,
            dispatch_capability: dispatch_capability
          )
        end
      end

      def execute_serial(required_checks:, dispatch_capability:)
        reset_execution_state!
        ensure_direct_configuration!
        @dispatch_capability = normalize_dispatch_capability(dispatch_capability)
        support = self.class.runtime_decision(
          adapter: adapter_name, tier: tier,
          requested_model: @requested_model, requested_effort: @requested_effort,
          observed_model: @requested_model, observed_effort: @requested_effort
        )
        return direct_failure("unsupported_tier") unless support.execution_allowed

        Runner.with_isolated_directory(prefix: "adversarial-review-direct") do |root|
          prepare_isolated_runtime(root)
          @preflight_mode = true
          probe_results = []
          aggregate_preflight_usage = Hash.new(0)
          selected = nil
          last_error = "capability_probe_failed"
          direct_executable_candidates.each_with_index do |candidate, index|
            attempt = attempt_precontent_candidate(candidate, index + 1)
            probe_results.concat(attempt.fetch("runner_results"))
            merge_usage!(aggregate_preflight_usage, attempt.fetch("usage"))
            last_error = attempt.fetch("error_code") if attempt["error_code"]
            if attempt.fetch("selected")
              selected = attempt
              break
            end
            break if attempt.fetch("fatal")
          end
          @preflight_usage = aggregate_preflight_usage.to_h
          unless selected
            return direct_failure(last_error, probe_results, @preflight_usage)
          end

          @preflight_mode = false
          @active_phase = "execution"
          result = execute_with_one_repair(
            requested_model: @requested_model,
            requested_effort: @requested_effort,
            required_checks: required_checks
          )
          result.runner_results.unshift(*probe_results)
          merge_usage!(result.usage, @preflight_usage)
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
      private :execute_serial

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
        allowed = (LOCALE_VARIABLES + credential_variables + PROXY_VARIABLES).uniq
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
        PRIVATE_CA_PATHS.each do |name, kind|
          value = source[name]
          environment[name] = validated_external_path(value, name, kind) if value
        end
        environment
      end

      def execute_with_one_repair(requested_model:, requested_effort:,
                                  required_checks: [])
        @execution_requested_model = requested_model
        @execution_requested_effort = requested_effort
        attempts = 0
        results = []
        usage = Hash.new(0)
        loop do
          attempts += 1
          @active_attempt = attempts if @runtime_provenance_records
          @last_normalized_capabilities = unavailable_capabilities(
            "execution attempt #{attempts} capability attestation missing"
          )
          runner_result, envelope = invoke(attempts == 2)
          results << runner_result
          record_runtime_observation(envelope) if @runtime_provenance_records
          capture_envelope_capabilities(envelope)
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
            normalized_capabilities = @last_normalized_capabilities ||
              unavailable_capabilities("execution capability envelope missing")
            capability_gate = Capabilities.gate(
              normalized_capabilities, "PASS", required: hard_required_capabilities
            )
            @last_normalized_capabilities = normalized_capabilities
          rescue Capabilities::Error
            return failed_execution("capability_attestation_invalid", attempts, results, usage)
          end
          unless capability_gate.fetch("capability_status") == "CAPABILITIES SATISFIED"
            return failed_execution(
              "capabilities_degraded", attempts, results, usage, normalized_capabilities
            )
          end

          payload = envelope["payload"]
          completed_checks = payload_checks(payload)
          checks_present = required_checks.is_a?(Array) &&
                           required_checks.uniq.length == required_checks.length &&
                           (required_checks.empty? ||
                            (completed_checks.is_a?(Array) &&
                             completed_checks.uniq.length == completed_checks.length &&
                             completed_checks.sort == required_checks.sort))
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

      def executable_candidates
        [@executable_candidate]
      end

      def version_contract_error
        nil
      end

      def direct_executable_candidates
        candidates = executable_candidates
        unless candidates.is_a?(Array) && candidates.length.between?(1, MAX_EXECUTABLE_CANDIDATES) &&
               candidates.uniq.length == candidates.length &&
               candidates.all? { |candidate| nonempty_text?(candidate) }
          raise ArgumentError, "direct adapter executable candidates are invalid"
        end
        candidates.dup
      end

      def attempt_precontent_candidate(candidate, index)
        reset_candidate_state!
        results = []
        usage = {}
        record = {
          "index" => index,
          "candidate" => candidate,
          "status" => "rejected",
          "error_code" => nil
        }
        selected = false
        fatal = false
        error_code = nil
        begin
          @active_phase = "probe"
          @active_attempt = nil
          @pinned_executable = Runner.resolve_executable(
            candidate, repository: @repository, run_directory: @run_directory,
            config_root: @configured_config_root
          )
          record["executable"] = @pinned_executable.path
          candidate_help_argv = help_argv
          record["help_argv"] = candidate_help_argv.dup
          help_result = run_probe(candidate_help_argv)
          results << help_result
          unless successful_process?(help_result) && help_capabilities_present?(help_result.stdout)
            error_code = "capability_probe_failed"
            return candidate_attempt_result(selected, fatal, error_code, results, usage)
          end

          version_argv = [@pinned_executable.path, "--version"]
          record["version_argv"] = version_argv.dup
          version_result = run_probe(version_argv)
          results << version_result
          unless successful_process?(version_result) && nonempty_text?(version_result.stdout)
            error_code = "version_probe_failed"
            return candidate_attempt_result(selected, fatal, error_code, results, usage)
          end
          @cli_version = version_result.stdout.strip
          record["cli_version"] = @cli_version
          if (contract_error = version_contract_error)
            error_code = contract_error
            return candidate_attempt_result(selected, fatal, error_code, results, usage)
          end
          @capability_probe = {
            "help_argv" => candidate_help_argv.dup,
            "version_argv" => version_argv.dup,
            "cli_version" => @cli_version,
            "executable" => @pinned_executable.path
          }

          @active_phase = "preflight"
          @active_attempt = 0
          @last_normalized_capabilities = unavailable_capabilities("preflight attestation missing")
          preflight_result, preflight_envelope = invoke_prompt(preflight_prompt)
          results << preflight_result if preflight_result
          record_runtime_observation(preflight_envelope)
          capture_envelope_capabilities(preflight_envelope)
          usage = trusted_envelope_usage(preflight_result, preflight_envelope)
          record["preflight"] = @runtime_provenance_records["preflight"] &&
            JSON.parse(JSON.generate(@runtime_provenance_records["preflight"]))
          error_code = attestation_error(preflight_result, preflight_envelope)
          return candidate_attempt_result(selected, fatal, error_code, results, usage) if error_code

          selected = true
          record["status"] = "selected"
          candidate_attempt_result(selected, fatal, nil, results, usage)
        rescue Runner::Error
          error_code = "runner_error"
          candidate_attempt_result(selected, fatal, error_code, results, usage)
        ensure
          record["error_code"] = error_code
          @runtime_provenance_records.fetch("candidate_attempts") << record
          @runtime_provenance_records["preflight"] = nil unless selected
        end
      end

      def reset_candidate_state!
        @last_normalized_capabilities = nil
        @capability_probe = nil
        @cli_version = nil
        @pinned_executable = nil
        @active_phase = "probe"
        @active_attempt = nil
        @last_active_phase = nil
        @last_active_attempt = nil
        @direct_session_ids = prior_session_id_map
        @runtime_provenance_records["preflight"] = nil
      end

      def candidate_attempt_result(selected, fatal, error_code, results, usage)
        {
          "selected" => selected,
          "fatal" => fatal,
          "error_code" => error_code,
          "runner_results" => results,
          "usage" => usage
        }
      end

      def reset_execution_state!
        @runtime_provenance_records = nil
        @direct_session_ids = nil
        @last_normalized_capabilities = nil
        @last_active_phase = nil
        @last_active_attempt = nil
        @active_phase = nil
        @active_attempt = nil
        @pinned_executable = nil
        @preflight_mode = false
        @schema_path = nil
        @preflight_schema_path = nil
        @preflight_repository = nil
        @isolated_home = nil
        @isolated_config_root = nil
        @direct_root = nil
        @cli_version = nil
        @capability_probe = nil
        @invocation_sequence = 0
        @execution_requested_model = nil
        @execution_requested_effort = nil
        @dispatch_capability = nil
        @preflight_usage = {}
      end

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
        initialize_preflight_repository!
        @schema_path = File.join(@direct_root, "role-schema.json")
        Runner.write_private_file(@schema_path, JSON.generate(@role_schema))
        @preflight_schema_path = File.join(@direct_root, "preflight-schema.json")
        Runner.write_private_file(@preflight_schema_path, JSON.generate(PREFLIGHT_SCHEMA))
        @runtime_provenance_records = {
          "preflight" => nil,
          "executions" => [],
          "failure" => nil,
          "candidate_attempts" => []
        }
        @direct_session_ids = prior_session_id_map
      end

      def prior_session_id_map
        (@prior_session_ids || []).each_with_object({}) do |session_id, result|
          result[session_id] = {"phase" => "prior-task", "attempt" => nil}
        end
      end
      private :prior_session_id_map

      def initialize_preflight_repository!
        git = Runner.resolve_executable(
          "git", repository: @repository, run_directory: @run_directory,
          config_root: @isolated_config_root, excluded_roots: [@direct_root]
        )
        environment = {
          "HOME" => @isolated_home,
          "XDG_CONFIG_HOME" => @isolated_config_root,
          "GIT_CONFIG_NOSYSTEM" => "1",
          "GIT_CONFIG_GLOBAL" => File::NULL
        }
        initialized = Runner.run(
          argv: [git.path, "init", "--quiet", @preflight_repository],
          stdin_data: "", timeout_seconds: @timeout_seconds,
          env: environment, chdir: @direct_root, executable: git,
          excluded_roots: [@direct_root]
        )
        verified = Runner.run(
          argv: [git.path, "rev-parse", "--is-inside-work-tree"],
          stdin_data: "", timeout_seconds: @timeout_seconds,
          env: environment, chdir: @preflight_repository,
          repository: @preflight_repository, executable: git,
          excluded_roots: [@direct_root]
        )
        unless successful_process?(initialized) && successful_process?(verified) &&
               verified.stdout.strip == "true"
          raise Runner::Error.new(
            "preflight_git_init_failed",
            "private preflight repository could not be initialized"
          )
        end
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
        normalized = @last_normalized_capabilities ||
          unavailable_capabilities("preflight capability envelope missing")
        gate = Capabilities.gate(normalized, "PASS", required: hard_required_capabilities)
        return "capabilities_degraded" unless gate.fetch("capability_status") == "CAPABILITIES SATISFIED"
        return "structured_output_unattested" unless direct_payload_valid?(envelope["payload"])
        nil
      rescue Capabilities::Error
        "capability_attestation_invalid"
      end

      def direct_failure(code, runner_results = [], usage = nil)
        record_failure(code)
        normalized = result_capabilities(nil, code)
        ExecutionResult.new(
          status: "generic", payload: nil, usage: (usage || @preflight_usage || {}).dup,
          capabilities: normalized,
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
        recognized = value.each_with_object({}) do |(key, amount), result|
          next unless USAGE_FIELDS.include?(key)
          return {} unless amount.is_a?(Integer) && amount >= 0
          result[key] = amount
        end
        recognized
      end

      def valid_usage?(usage)
        usage.is_a?(Hash) && !valid_usage(usage).empty?
      end

      def hard_required_capabilities
        required = Capabilities::FIELDS.dup
        if %w[codex claude].include?(adapter_name) && tier != "ultra"
          required.delete("parallel_dispatch")
        end
        required
      end

      def parse_json_line_objects(text, label, max_objects: nil)
        unless text.is_a?(String) && !text.empty?
          raise JSON::ParserError, "empty #{label} event stream"
        end
        unless max_objects.nil? || (max_objects.is_a?(Integer) && max_objects.positive?)
          raise ArgumentError, "event object limit must be a positive integer"
        end
        events = []
        text.each_line do |line|
          next if line.strip.empty?
          if max_objects && events.length >= max_objects
            raise JSON::ParserError, "#{label} event limit exceeded"
          end
          event = JSON.parse(line, object_class: DuplicateRejectingHash,
                                   allow_duplicate_key: false)
          unless event.is_a?(Hash)
            raise JSON::ParserError, "#{label} event is not an object"
          end
          events << event
        end
        events
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
        observations["parallel_dispatch"] = @dispatch_capability
        capabilities(
          requested_model: @requested_model,
          requested_effort: @requested_effort,
          observations: observations
        )
      end

      def capture_envelope_capabilities(envelope)
        return unless envelope.is_a?(Hash)
        record = envelope["capabilities"]
        return unless record.is_a?(Hash)
        normalized = Capabilities.normalize(
          record,
          requested_model: requested_model_for_capabilities,
          requested_effort: requested_effort_for_capabilities
        )
        source = "#{adapter_name} #{@active_phase || "execution"} capability envelope"
        normalized.each do |field, declaration|
          next unless declaration.fetch("status") == "unavailable" &&
                      declaration.fetch("evidence") == "not reported"
          normalized[field] = declaration.merge(
            "evidence" => "#{field} was not reported",
            "source" => source
          )
        end
        @last_normalized_capabilities = normalized
      rescue Capabilities::Error
        @last_normalized_capabilities = unavailable_capabilities(
          "capability envelope was invalid"
        )
      end

      def normalize_dispatch_capability(observation)
        if observation.nil?
          return [
            "unavailable", "caller did not report observed parallel dispatch",
            "caller capability observation"
          ]
        end
        unless observation.is_a?(Hash)
          raise Capabilities::Error, "parallel dispatch capability must be an observation object"
        end
        record = if observation.keys.sort == Capabilities::FIELDS.sort
                   Capabilities.normalize(
                     observation,
                     requested_model: @requested_model,
                     requested_effort: @requested_effort
                   )
                 else
                   Capabilities.normalize(
                     {"parallel_dispatch" => observation},
                     requested_model: @requested_model,
                     requested_effort: @requested_effort
                   )
                 end
        declaration = record.fetch("parallel_dispatch")
        [declaration.fetch("status"), declaration.fetch("evidence"), declaration.fetch("source")]
      end

      def trusted_envelope_usage(runner_result, envelope)
        return {} unless successful_process?(runner_result) &&
                         !runner_result.stdout_truncated && !runner_result.stderr_truncated &&
                         envelope.is_a?(Hash)
        valid_usage(envelope["usage"])
      end

      def result_capabilities(candidate, code)
        if candidate
          Capabilities.gate(candidate, "PASS")
          return JSON.parse(JSON.generate(candidate))
        end
        return JSON.parse(JSON.generate(@last_normalized_capabilities)) if @last_normalized_capabilities

        unavailable_capabilities(code.tr("_", " "))
      rescue Capabilities::Error
        unavailable_capabilities("#{code.tr("_", " ")} and capability record invalid")
      end

      def unavailable_capabilities(reason)
        source = "#{adapter_name} #{@active_phase || "adapter"} capability gate"
        template = Capabilities.template(
          requested_model: requested_model_for_capabilities,
          requested_effort: requested_effort_for_capabilities
        )
        template.each do |field, declaration|
          declaration["evidence"] = "#{field} unavailable: #{reason}"
          declaration["source"] = source
        end
        Capabilities.normalize(
          template,
          requested_model: requested_model_for_capabilities,
          requested_effort: requested_effort_for_capabilities
        )
      end

      def requested_model_for_capabilities
        @requested_model || @execution_requested_model
      end

      def requested_effort_for_capabilities
        @requested_effort || @execution_requested_effort
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
        unless Atomic.canonical_absolute_path?(path)
          raise ArgumentError, "isolated #{label} must be an absolute path"
        end
        expected = File.lstat(path)
        # 0700 is inexpressible on hosts without POSIX permission bits, where
        # Atomic.guarantees already reports posix_permissions false.
        private_mode = !Atomic::POSIX_PERMISSIONS || (expected.mode & 0o777) == 0o700
        unless expected.directory? && !expected.symlink? && expected.uid == Process.euid &&
               private_mode
          raise ArgumentError, "isolated #{label} must be a private owned directory"
        end
        canonical = File.realpath(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(canonical, flags) do |directory|
          opened = directory.stat
          unless opened.directory? && Atomic.same_identity?(expected, opened) &&
                 opened.uid == Process.euid &&
                 (!Atomic::POSIX_PERMISSIONS || (opened.mode & 0o777) == 0o700)
            raise ArgumentError, "isolated #{label} identity or permissions changed"
          end
        end
        canonical
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM
        raise ArgumentError, "isolated #{label} is unavailable"
      end

      def validated_external_path(path, label, kind)
        unless Atomic.canonical_absolute_path?(path)
          raise ArgumentError, "#{label} must be an absolute path"
        end
        canonical = File.realpath(path)
        stat = File.stat(canonical)
        valid_kind = kind == :file ? stat.file? : stat.directory?
        raise ArgumentError, "#{label} has the wrong path type" unless valid_kind
        controlled_roots = [
          @repository, @run_directory, @configured_config_root, @direct_root,
          @isolated_home, @isolated_config_root
        ].compact
        if controlled_roots.any? { |root| path_within_root?(canonical, root) }
          raise ArgumentError, "#{label} must be outside review-controlled directories"
        end
        canonical
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM
        raise ArgumentError, "#{label} is unavailable"
      end

      def path_within_root?(path, root)
        return false unless File.exist?(root)
        root_stat = File.stat(File.realpath(root))
        cursor = File.realpath(path)
        loop do
          current = File.stat(cursor)
          return true if current.dev == root_stat.dev && current.ino == root_stat.ino
          parent = File.dirname(cursor)
          return false if parent == cursor
          cursor = parent
        end
      end

      def successful_process?(result)
        result.is_a?(Runner::Result) && !result.timed_out && result.exit_status == 0
      end

      def merge_usage!(aggregate, current)
        valid_usage(current).each do |key, value|
          aggregate[key] += value
        end
      end

      def failed_execution(code, attempts, results, usage, capabilities = nil)
        record_failure(code)
        normalized = result_capabilities(capabilities, code)
        ExecutionResult.new(
          status: "generic", payload: nil, usage: usage.to_h,
          capabilities: normalized, attempts: attempts, runner_results: results,
          error_code: code, ordinary_result: false,
          runtime_provenance: provenance_snapshot
        )
      end
    end
  end
end
