require "digest"
require "json"
require "optparse"
require "time"

module AdversarialReview
  module CLI
    VERSION = "portable-1".freeze
    DIRECT_EXECUTORS = %w[codex claude cursor gemini].freeze
    ROLE_NAMES = {
      "dedupe" => "deduplicator",
      "judge" => "judge",
      "author-actions" => "author",
      "resolution" => "resolver",
      "arbiter" => "arbiter"
    }.freeze
    EXECUTABLES = {
      "codex" => "codex", "claude" => "claude", "cursor" => "agent", "gemini" => "gemini"
    }.freeze
    ADAPTERS = {
      "codex" => Adapters::Codex,
      "claude" => Adapters::Claude,
      "cursor" => Adapters::Cursor,
      "gemini" => Adapters::Gemini
    }.freeze
    CAPABILITY_FAILURES = %w[
      unsupported_tier capability_probe_failed version_probe_failed version_contract_failed
      unsupported_version_contract runner_error
      preflight_failed preflight_attestation_invalid capability_attestation_invalid
      runtime_model_mismatch runtime_effort_mismatch dispatch_capability_invalid
    ].freeze

    class Error < StandardError
      attr_reader :code, :details, :exit_status

      def initialize(code, message, exit_status, details = {})
        @code = code
        @details = details
        @exit_status = exit_status
        super(message)
      end

      def to_h
        {"code" => code, "message" => message, "details" => details,
         "exit_status" => exit_status}
      end
    end

    module_function

    def run(argv, stdout: $stdout, stderr: $stderr, env: ENV, program_path: $PROGRAM_NAME)
      command = argv.shift
      if command.nil? || %w[-h --help help].include?(command)
        stdout.write(help(program_path))
        return 0
      end

      payload = case command
                when "start" then start(argv, env: env, program_path: program_path)
                when "continue" then continue_run(argv, env: env, program_path: program_path)
                when "ingest" then ingest(argv)
                when "status" then status(argv)
                else
                  raise Error.new("invocation_error", "unknown subcommand: #{command}", 2)
                end
      stdout.write(JSON.generate(payload) + "\n")
      0
    rescue OptionParser::ParseError => error
      emit_error(stderr, Error.new("invocation_error", error.message, 2))
    rescue Error => error
      if error.exit_status.zero? && error.code == "help"
        stdout.write(error.message)
        0
      else
        emit_error(stderr, error)
      end
    rescue Manifest::Error, State::Error, Reporting::Error => error
      exit_status = error.respond_to?(:exit_status) ? error.exit_status : 3
      exit_status = 3 if error.respond_to?(:code) && error.code == "run_exists"
      emit_error(stderr, Error.new(error.code, error.message, exit_status, safe_details(error)))
    rescue Capabilities::Error => error
      emit_error(stderr, Error.new("invalid_capabilities", error.message, 3))
    rescue JSON::ParserError => error
      emit_error(stderr, Error.new("invalid_json", "input JSON is invalid", 3,
                                   {"cause" => error.message}))
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM, Errno::ELOOP => error
      emit_error(stderr, Error.new("unavailable_path", "required path is unavailable", 2,
                                   {"cause" => error.class.name}))
    rescue StandardError => error
      emit_error(stderr, Error.new("internal_error", "adversarial review command failed", 5,
                                   {"cause" => error.class.name}))
    end

    def help(program_path)
      name = File.basename(program_path)
      <<~TEXT
        Usage: #{name} SUBCOMMAND [options]

        Subcommands:
          start      create a review run and dispatch or emit attack tasks
          continue   advance one validated state-machine stage
          ingest     validate and ingest one task result
          status     print deterministic JSON run status

        Run `#{name} SUBCOMMAND --help` for exact options.
      TEXT
    end

    def start(argv, env:, program_path:)
      options = {
        repository: Dir.pwd, tier: "default", mode: "revise", output: "both",
        executor: "auto", model: "inherit", effort: "inherit", context: [], jobs: 1
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review start --spec PATH [options]"
        opts.on("--repository PATH") { |value| options[:repository] = value }
        opts.on("--spec PATH") { |value| options[:spec] = value }
        opts.on("--plan PATH") { |value| options[:plan] = value }
        opts.on("--tier TIER", Manifest::TIERS, "default|high|ultra") { |value| options[:tier] = value }
        opts.on("--mode MODE", Manifest::MODES, "critique|revise") { |value| options[:mode] = value }
        opts.on("--output OUTPUT", Manifest::OUTPUTS, "chat|file|both") { |value| options[:output] = value }
        opts.on("--executor EXECUTOR", Manifest::EXECUTORS,
                "auto|codex|claude|cursor|gemini|generic") { |value| options[:executor] = value }
        opts.on("--model MODEL") { |value| options[:model] = value }
        opts.on("--effort EFFORT") { |value| options[:effort] = value }
        opts.on("--jobs N", Integer) { |value| options[:jobs] = value }
        opts.on("--context PATH") { |value| options[:context] << value }
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("--report-only") do
          options[:mode] = "critique"
          options[:output] = "both"
        end
        opts.on("--chat-only") { options[:output] = "chat" }
        opts.on("--ultra") { options[:tier] = "ultra" }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      unless options.fetch(:jobs).positive?
        raise OptionParser::InvalidArgument, "--jobs must be a positive integer"
      end
      selected = select_executor(options, env)
      if DIRECT_EXECUTORS.include?(selected) && unresolved?(options[:model], options[:effort])
        raise Error.new(
          "capability_blocked",
          "direct execution requires exact model and effort values",
          4, {"executor" => selected}
        )
      end
      manifest = Manifest.build(
        repository: options[:repository], spec: options[:spec], plan: options[:plan],
        tier: options[:tier], mode: options[:mode], output: options[:output],
        executor: options[:executor], model: options[:model], effort: options[:effort],
        context_paths: options[:context]
      )
      if options[:report]
        manifest["report_path"] = File.expand_path(
          options.fetch(:report), manifest.fetch("repository").fetch("root")
        )
      end
      run_dir = options[:run_dir] || State.default_run_dir(
        repository: manifest.fetch("repository").fetch("root"),
        run_id: manifest.fetch("run_id")
      )
      state = State.create(run_dir, manifest)
      state.transition_to("attacking")
      selected = dispatch_attack_tasks(
        state, selected, env, fallback_generic: options.fetch(:executor) == "auto"
      )
      response(state, selected_executor: selected)
    end

    def continue_run(argv, env:, program_path:)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review continue --run-dir PATH [options]"
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--actions PATH") { |value| options[:actions] = value }
        opts.on("--capabilities PATH") { |value| options[:capabilities] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      require_option!(options, :run_dir)
      state = State.load(options.fetch(:run_dir))
      manifest = state.manifest_snapshot
      selected = effective_executor(manifest, env)
      fallback_generic = manifest.fetch("requested_executor") == "auto"
      snapshot = state.to_h
      if options[:actions]
        capability_record = options[:capabilities] ? read_json_file(options[:capabilities]) : {}
        normalize_capabilities(capability_record, manifest)
        action_tasks = pending_task_ids(snapshot).select do |task_id|
          snapshot.fetch("emitted_tasks").fetch(task_id).fetch("kind") == "author-actions"
        end
        unless action_tasks.length == 1 && snapshot.fetch("stage") == "awaiting-author"
          raise Error.new(
            "invalid_state", "--actions requires exactly one pending author-actions task", 3,
            {"stage" => snapshot.fetch("stage"), "pending_author_tasks" => action_tasks}
          )
        end
        state.ingest(action_tasks.first, read_json_file(options.fetch(:actions)))
        snapshot = state.to_h
      end
      return response(state, selected_executor: selected) unless pending_task_ids(snapshot).empty?

      case snapshot.fetch("stage")
      when "attacking"
        state.transition_to("deduplicating")
        selected = dispatch_role_task(state, "dedupe", selected, env,
                                      fallback_generic: fallback_generic)
      when "deduplicating"
        state.transition_to("culling")
        selected = dispatch_role_task(state, "judge", selected, env,
                                      fallback_generic: fallback_generic)
      when "culling", "culling-new-findings"
        if manifest.fetch("mode") == "critique"
          state.transition_to("complete")
        else
          state.transition_to("awaiting-author")
          selected = dispatch_role_task(state, "author-actions", selected, env,
                                        fallback_generic: fallback_generic)
        end
      when "awaiting-author"
        state.transition_to("resolving")
        selected = dispatch_role_task(state, "resolution", selected, env,
                                      fallback_generic: fallback_generic)
      when "resolving"
        latest = state.to_h
        if latest.fetch("pending_arbiter_subjects").any?
          state.transition_to("arbitrating")
          selected = dispatch_role_task(state, "arbiter", selected, env,
                                        fallback_generic: fallback_generic)
        elsif latest.fetch("fresh_sweep_required") && !latest.fetch("fresh_sweep_completed")
          state.transition_to("fresh-sweep")
          selected = dispatch_attack_tasks(
            state, selected, env,
            fallback_generic: manifest.fetch("requested_executor") == "auto"
          )
        else
          state.transition_to("complete")
        end
      when "fresh-sweep"
        state.transition_to("culling-new-findings")
        selected = dispatch_role_task(state, "judge", selected, env,
                                      fallback_generic: fallback_generic)
      when "arbitrating"
        state.transition_to(state.can_complete? ? "complete" : "did-not-converge")
      when "complete", "did-not-converge"
        # Idempotent terminal render/status.
      else
        raise Error.new("invalid_state", "run cannot be continued from this stage", 3,
                        {"stage" => snapshot.fetch("stage")})
      end
      terminal_response(
        state, selected: selected, capabilities_path: options[:capabilities],
        report_path: options[:report] || manifest["report_path"], program_path: program_path
      )
    end

    def ingest(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review ingest --run-dir PATH --task ID --result PATH --capabilities PATH"
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--task ID") { |value| options[:task] = value }
        opts.on("--result PATH") { |value| options[:result] = value }
        opts.on("--capabilities PATH") { |value| options[:capabilities] = value }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      %i[run_dir task result capabilities].each { |name| require_option!(options, name) }
      state = State.load(options.fetch(:run_dir))
      manifest = state.manifest_snapshot
      declaration = normalize_capabilities(read_json_file(options.fetch(:capabilities)), manifest)
      summary = state.ingest(options.fetch(:task), read_json_file(options.fetch(:result)))
      gate = Capabilities.gate(declaration, "PASS")
      response(state).merge(
        "task_id" => options.fetch(:task), "ingest" => summary,
        "capabilities" => declaration, "capability_gate" => gate
      )
    end

    def status(argv)
      options = {json: false}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review status --run-dir PATH [--json]"
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--json") { options[:json] = true }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      require_option!(options, :run_dir)
      response(State.load(options.fetch(:run_dir)))
    end

    def parse!(parser, argv)
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(" ")}" unless argv.empty?
    rescue Error => error
      raise error unless error.code == "help"
      raise error
    end

    def require_option!(options, name)
      value = options[name]
      return if value.is_a?(String) && !value.empty?
      raise OptionParser::MissingArgument, "--#{name.to_s.tr("_", "-")}"
    end

    def unresolved?(model, effort)
      [model, effort].any? { |value| value.nil? || value.strip.empty? || value == "inherit" }
    end

    def select_executor(options, env)
      requested = options.fetch(:executor)
      return requested unless requested == "auto"
      host = env["ADVERSARIAL_REVIEW_HOST"].to_s.downcase
      return "generic" unless DIRECT_EXECUTORS.include?(host)
      return "generic" if unresolved?(options[:model], options[:effort])
      host
    end

    def effective_executor(manifest, env)
      requested = manifest.fetch("requested_executor")
      return requested unless requested == "auto"
      select_executor(
        {executor: "auto", model: manifest["requested_model"], effort: manifest["requested_effort"]},
        env
      )
    end

    def dispatch_attack_tasks(state, selected, env, fallback_generic: false)
      manifest = state.manifest_snapshot
      round = state.to_h.fetch("revise_round")
      manifest.fetch("enabled_tasks").each do |angle|
        task = Prompts.attack_task(manifest, angle, 1, round: round,
                                   current_digests: state.to_h.fetch("current_target_digests"))
        selected = dispatch_task(
          state, task, selected, env, fallback_generic: fallback_generic
        )
      end
      selected
    end

    def dispatch_role_task(state, kind, selected, env, fallback_generic: false)
      snapshot = state.to_h
      manifest = state.manifest_snapshot
      round = snapshot.fetch("revise_round")
      attempt = 1
      task_id = "#{kind}-batch-r#{round}-a#{attempt}"
      task = {
        "schema_version" => 1,
        "run_id" => manifest.fetch("run_id"),
        "task_id" => task_id,
        "role" => ROLE_NAMES.fetch(kind),
        "kind" => kind,
        "schema" => "assets/schemas/#{kind}.json",
        "artifact_digests" => snapshot.fetch("current_target_digests"),
        "round" => round,
        "attempt" => attempt,
        "prompt" => role_prompt(kind, snapshot)
      }
      if kind == "arbiter"
        subjects = snapshot.fetch("pending_arbiter_subjects")
        task["dispute_kind"] = "author-resolution"
        task["subject_ids"] = subjects
        task["subject_mappings"] = subjects.each_with_object({}) do |finding_id, mappings|
          finding = snapshot.fetch("findings").find { |item| item.fetch("id") == finding_id }
          mappings[finding_id] = finding ? finding.fetch("candidate_ids") : []
        end
      end
      dispatch_task(state, task, selected, env, fallback_generic: fallback_generic)
    end

    def role_prompt(kind, snapshot)
      evidence = case kind
                 when "dedupe" then snapshot.fetch("candidates")
                 when "judge" then snapshot.fetch("candidates")
                 when "author-actions" then snapshot.fetch("findings")
                 when "resolution" then snapshot.fetch("author_actions")
                 when "arbiter" then snapshot.fetch("pending_arbiter_subjects")
                 else []
                 end
      JSON.generate(
        "instruction" => "Perform only the named read-only adversarial review role and return schema JSON.",
        "role" => kind, "evidence" => evidence
      )
    end

    def dispatch_task(state, task, selected, env, fallback_generic: false)
      if selected == "generic"
        if task.fetch("role") == "attacker"
          Adapters::Generic.new.run(task, state_run_dir(state))
        else
          state.create_task_bundle(task.fetch("task_id")) { task }
        end
        return selected
      end

      state.create_task_bundle(task.fetch("task_id")) { task }
      result = execute_direct(state, task, selected, env)
      unless result.status == "complete" && result.payload
        if fallback_generic && CAPABILITY_FAILURES.include?(result.error_code)
          if task.fetch("role") == "attacker"
            Adapters::Generic.new.run(task, state_run_dir(state))
          else
            state.create_task_bundle(task.fetch("task_id")) { task }
          end
          return "generic"
        end
        status = CAPABILITY_FAILURES.include?(result.error_code) ? 4 : 5
        code = status == 4 ? "capability_blocked" : "adapter_execution_failed"
        raise Error.new(code, "#{selected} adapter could not produce an eligible result", status,
                        {"executor" => selected, "reason" => result.error_code})
      end
      state.ingest(task.fetch("task_id"), result.payload)
      selected
    end

    def execute_direct(state, task, selected, env)
      manifest = state.manifest_snapshot
      schema_name = task.fetch("schema").sub(%r{\Aassets/schemas/}, "").sub(/\.json\z/, "")
      schema = read_json_file(File.join(AdversarialReview.root, task.fetch("schema")))
      executable = env.fetch("ADVERSARIAL_REVIEW_#{selected.upcase}_CLI", EXECUTABLES.fetch(selected))
      adapter = ADAPTERS.fetch(selected).new(
        executable: executable,
        repository: manifest.fetch("repository").fetch("root"),
        model: manifest.fetch("requested_model"),
        effort: manifest.fetch("requested_effort"),
        role_schema: schema,
        schema_name: schema_name,
        prompt: JSON.generate(task),
        tier: manifest.fetch("tier"),
        run_directory: state_run_dir(state),
        source_env: env
      )
      adapter.execute(required_checks: [])
    end

    def state_run_dir(state)
      state.instance_variable_get(:@run_dir)
    end

    def response(state, selected_executor: nil)
      snapshot = state.to_h
      pending = pending_task_ids(snapshot).map do |task_id|
        File.join(state_run_dir(state), "tasks", "#{task_id}.json")
      end
      next_action = pending.empty? ? snapshot.fetch("next_action") : "awaiting-results"
      {
        "schema_version" => 1,
        "run_id" => snapshot.fetch("run_id"),
        "run_dir" => state_run_dir(state),
        "stage" => snapshot.fetch("stage"),
        "next_action" => next_action,
        "pending_tasks" => pending.sort
      }.tap do |result|
        result["selected_executor"] = selected_executor if selected_executor
      end
    end

    def pending_task_ids(snapshot)
      snapshot.fetch("emitted_tasks").keys.reject do |task_id|
        snapshot.fetch("ingested_results").key?(task_id)
      end.sort
    end

    def terminal_response(state, selected:, capabilities_path:, report_path:, program_path:)
      snapshot = state.to_h
      result = response(state, selected_executor: selected)
      return result unless %w[complete did-not-converge].include?(snapshot.fetch("stage"))

      manifest = state.manifest_snapshot
      raw_capabilities = capabilities_path ? read_json_file(capabilities_path) : {}
      capabilities = normalize_capabilities(raw_capabilities, manifest)
      summary = Reporting.summary(
        report_source(state, manifest, snapshot, selected, capabilities, program_path)
      )
      output = manifest.fetch("output")
      if %w[file both].include?(output)
        unless report_path
          raise Error.new("invocation_error", "--report is required for file output", 2)
        end
        result["report_path"] = Reporting.append(report_path, summary)
      end
      result["summary"] = Reporting.chat_payload(summary) if %w[chat both].include?(output)
      result["verdict"] = summary.fetch("verdict")
      result
    end

    def report_source(state, manifest, snapshot, selected, capabilities, program_path)
      gate = Capabilities.gate(capabilities, "PASS")
      emitted = snapshot.fetch("emitted_tasks")
      ingested = snapshot.fetch("ingested_results")
      angles = manifest.fetch("enabled_tasks").map do |angle|
        tasks = emitted.values.select { |record| record["angle"] == angle }
        complete = !tasks.empty? && tasks.all? { |record| ingested.key?(record.fetch("task_id")) }
        {
          "name" => angle,
          "status" => complete ? "completed" : "failed",
          "failure_reason" => complete ? nil : "task did not complete",
          "retries" => 0,
          "retry_reasons" => []
        }
      end
      usage = Reporting::USAGE_KEYS.each_with_object({}) { |key, values| values[key] = nil }
      usage["prompt_bytes"] = emitted_task_bytes(state, snapshot)
      started_at = run_started_at(manifest.fetch("run_id"))
      {
        "schema_version" => 1,
        "run_id" => manifest.fetch("run_id"),
        "targets" => manifest.fetch("targets"),
        "repository" => manifest.fetch("repository"),
        "started_at" => started_at,
        "ended_at" => Time.now.utc.iso8601,
        "tier" => manifest.fetch("tier"),
        "mode" => manifest.fetch("mode"),
        "output" => manifest.fetch("output"),
        "requested_executor" => manifest.fetch("requested_executor"),
        "selected_executor" => selected,
        "cli" => {"realpath" => File.realpath(program_path), "version" => VERSION},
        "requested_model" => manifest.fetch("requested_model"),
        "observed_model" => selected == "generic" ? nil : manifest.fetch("requested_model"),
        "requested_effort" => manifest.fetch("requested_effort"),
        "observed_effort" => selected == "generic" ? nil : manifest.fetch("requested_effort"),
        "enabled_tasks" => manifest.fetch("enabled_tasks"),
        "angles" => angles,
        "capabilities" => capabilities,
        "degraded_capabilities" => gate.fetch("degraded_capabilities"),
        "usage" => usage,
        "findings" => snapshot.fetch("findings"),
        "semantic_groups" => snapshot.fetch("semantic_groups"),
        "author_actions" => snapshot.fetch("author_actions"),
        "resolution_checks" => snapshot.fetch("resolution_checks"),
        "evidence_gaps" => snapshot.fetch("evidence_gaps"),
        "overflow" => snapshot.fetch("overflow"),
        "overflow_evidence_gaps" => snapshot.fetch("overflow_evidence_gaps"),
        "metrics" => manifest.fetch("starting_metrics")
      }
    end

    def run_started_at(run_id)
      timestamp = run_id[/\Aar-(\d{8}T\d{12}Z)-/, 1]
      return Time.now.utc.iso8601 unless timestamp
      Time.strptime(timestamp, "%Y%m%dT%H%M%S%6NZ").utc.iso8601
    rescue ArgumentError
      Time.now.utc.iso8601
    end

    def emitted_task_bytes(state, snapshot)
      snapshot.fetch("emitted_tasks").keys.sum do |task_id|
        task = nil
        state.read_task_bundle(task_id) { |_manifest, _data, value| task = value }
        JSON.generate(task).bytesize
      end
    end

    def normalize_capabilities(record, manifest)
      Capabilities.normalize(
        record,
        requested_model: manifest.fetch("requested_model"),
        requested_effort: manifest.fetch("requested_effort")
      )
    end

    def read_json_file(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = File.open(path, flags)
      begin
        raise Error.new("unsafe_input", "JSON input must be a regular file", 3) unless file.stat.file?
        if file.stat.size > Atomic::MAX_JSON_BYTES
          raise Error.new("input_too_large", "JSON input exceeds the size limit", 3)
        end
        JSON.parse(file.read(Atomic::MAX_JSON_BYTES + 1))
      ensure
        file.close unless file.closed?
      end
    end

    def safe_details(error)
      details = error.respond_to?(:details) && error.details.is_a?(Hash) ? error.details : {}
      details.reject { |key, _value| key.to_s.match?(/token|secret|credential|stderr/i) }
    end

    def emit_error(stderr, error)
      stderr.write(JSON.generate(error.to_h) + "\n")
      error.exit_status
    end
  end
end
