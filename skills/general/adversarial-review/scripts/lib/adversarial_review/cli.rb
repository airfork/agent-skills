require "digest"
require "json"
require "optparse"
require "securerandom"
require "time"

module AdversarialReview
  module CLI
    VERSION = "portable-1".freeze
    DIRECT_EXECUTORS = %w[codex claude cursor gemini].freeze
    EXECUTABLES = {
      "codex" => "codex", "claude" => "claude", "cursor" => "agent", "gemini" => "gemini"
    }.freeze
    ADAPTERS = {
      "codex" => Adapters::Codex,
      "claude" => Adapters::Claude,
      "cursor" => Adapters::Cursor,
      "gemini" => Adapters::Gemini
    }.freeze

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
    rescue Adapters::Generic::Error => error
      allowed = %w[
        invalid_task invalid_task_digests invalid_task_id invalid_task_identity
        invalid_task_schema target_digest_mismatch unsafe_task_path task_collision
      ]
      code = allowed.include?(error.code) ? error.code : "invalid_task"
      emit_error(stderr, Error.new(code, "generic task operation was rejected", 3))
    rescue Prompts::Error
      emit_error(stderr, Error.new("invalid_task", "review task could not be constructed", 3))
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
      aliases = {report_only: false, chat_only: false, ultra: false}
      supplied = {tier: [], mode: [], output: []}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review start [options]\n(one of --spec PATH or --plan PATH is required)"
        opts.on("--repository PATH") { |value| options[:repository] = value }
        opts.on("--spec PATH") { |value| options[:spec] = value }
        opts.on("--plan PATH") { |value| options[:plan] = value }
        opts.on("--tier TIER", Manifest::TIERS, "default|high|ultra") { |value| supplied[:tier] << value }
        opts.on("--mode MODE", Manifest::MODES, "critique|revise") { |value| supplied[:mode] << value }
        opts.on("--output OUTPUT", Manifest::OUTPUTS, "chat|file|both") { |value| supplied[:output] << value }
        opts.on("--executor EXECUTOR", Manifest::EXECUTORS,
                "auto|codex|claude|cursor|gemini|generic") { |value| options[:executor] = value }
        opts.on("--model MODEL") { |value| options[:model] = value }
        opts.on("--effort EFFORT") { |value| options[:effort] = value }
        opts.on("--jobs N", Integer) { |value| options[:jobs] = value }
        opts.on("--context PATH") { |value| options[:context] << value }
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("--report-only") { aliases[:report_only] = true }
        opts.on("--chat-only") { aliases[:chat_only] = true }
        opts.on("--ultra") { aliases[:ultra] = true }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      normalize_start_options!(options, supplied, aliases)
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
      if DIRECT_EXECUTORS.include?(selected) && options.fetch(:jobs) > 1
        raise Error.new(
          "invocation_error", "direct execution currently requires --jobs 1; generic mode emits parallel batches",
          2, {"executor" => selected, "jobs" => options.fetch(:jobs)}
        )
      end
      manifest = Manifest.build(
        repository: options[:repository], spec: options[:spec], plan: options[:plan],
        tier: options[:tier], mode: options[:mode], output: options[:output],
        executor: options[:executor], model: options[:model], effort: options[:effort],
        context_paths: options[:context]
      )
      manifest["selected_executor"] = selected
      manifest["jobs"] = options.fetch(:jobs)
      manifest["execution_metadata_required"] = true
      run_dir = options[:run_dir] || State.default_run_dir(
        repository: manifest.fetch("repository").fetch("root"),
        run_id: manifest.fetch("run_id")
      )
      if %w[file both].include?(manifest.fetch("output"))
        manifest["report_path"] = report_path_for(
          manifest, options[:report], run_dir: run_dir
        )
      end
      state = State.create(run_dir, manifest)
      state.transition_to("attacking")
      selected = dispatch_attack_tasks(
        state, selected, env, fallback_generic: options.fetch(:executor) == "auto"
      )
      state.pin_executor!(selected)
      response(state)
    end

    def continue_run(argv, env:, program_path:)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adversarial-review continue --run-dir PATH [options]"
        opts.on("--run-dir PATH") { |value| options[:run_dir] = value }
        opts.on("--actions PATH") { |value| options[:actions] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("-h", "--help") { raise Error.new("help", opts.to_s, 0) }
      end
      parse!(parser, argv)
      require_option!(options, :run_dir)
      state = State.load(options.fetch(:run_dir))
      manifest = state.manifest_snapshot
      selected = state.to_h.fetch("execution").fetch("selected_executor")
      snapshot = state.to_h
      fallback_generic = manifest.fetch("requested_executor") == "auto" &&
        snapshot.dig("execution", "tasks").empty?
      if options[:actions]
        action_tasks = pending_task_ids(snapshot).select do |task_id|
          snapshot.fetch("emitted_tasks").fetch(task_id).fetch("kind") == "author-actions"
        end
        unless action_tasks.length == 1 && snapshot.fetch("stage") == "awaiting-author"
          raise Error.new(
            "invalid_state", "--actions requires exactly one pending author-actions task", 3,
            {"stage" => snapshot.fetch("stage"), "pending_author_tasks" => action_tasks}
          )
        end
        ingest_summary = state.accept_result(
          action_tasks.first, read_json_file(options.fetch(:actions)),
          authority: "parent", capabilities: nil, usage: {}, attempts: 0,
          runtime_provenance: {"authority" => "parent", "source" => "continue --actions"}
        )
        return response(state).merge("task_id" => action_tasks.first, "ingest" => ingest_summary)
      end
      recover_selection_intent!(state)
      manifest = state.manifest_snapshot
      snapshot = state.to_h
      selected = snapshot.dig("execution", "selected_executor")
      fallback_generic = generic_fallback_available?(manifest, snapshot)
      if stage_roster_pending?(state, selected, env, fallback_generic: fallback_generic)
        return response(state)
      end
      current_pending = current_stage_pending_task_ids(snapshot, manifest)
      unless current_pending.empty?
        reviewer_pending = current_pending.reject do |task_id|
          snapshot.dig("emitted_tasks", task_id, "authority") == "parent"
        end
        if DIRECT_EXECUTORS.include?(selected) && !reviewer_pending.empty?
          reviewer_pending.each do |task_id|
            task = nil
            state.read_task_bundle(task_id) { |_manifest, _data, value| task = value }
            selected = dispatch_task(
              state, task, selected, env, fallback_generic: fallback_generic
            )
          end
          resume_stage_dispatch(state, selected, env)
        end
        return response(state)
      end

      case snapshot.fetch("stage")
      when "prepared"
        state.transition_to("attacking")
        selected = dispatch_attack_tasks(
          state, selected, env, fallback_generic: fallback_generic
        )
        state.pin_executor!(selected)
      when "attacking"
        state.transition_to("deduplicating")
        selected = dispatch_role_task(state, "dedupe", selected, env,
                                      fallback_generic: fallback_generic)
      when "deduplicating"
        next_cull = snapshot.fetch("revise_round") == 2 && snapshot.fetch("fresh_sweep_required") ?
          "culling-new-findings" : "culling"
        state.transition_to(next_cull)
        selected = dispatch_judge_tasks(state, selected, env, fallback_generic: fallback_generic)
      when "culling", "culling-new-findings"
        if manifest.fetch("mode") == "critique"
          state.transition_to("complete")
        elsif snapshot.fetch("stage") == "culling-new-findings" &&
              snapshot.fetch("findings").none? { |finding| finding.fetch("state") == "pending" }
          state.transition_to("complete")
        else
          state.transition_to("awaiting-author")
          task = Prompts.parent_action_task(manifest, state.to_h)
          state.create_task_bundle(task.fetch("task_id")) { task }
        end
      when "awaiting-author"
        parent_action_recorded = snapshot.dig("execution", "tasks").any? do |task_id, record|
          record.fetch("authority") == "parent" &&
            snapshot.dig("emitted_tasks", task_id, "kind") == "author-actions"
        end
        unless parent_action_recorded
          return response(state).merge("next_action" => "submit-author-actions")
        end
        state.refresh_targets_after_actions! unless snapshot.fetch("findings").empty?
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
          if latest.fetch("revise_round") >= 2
            state.transition_to("did-not-converge")
          else
            state.transition_to("fresh-sweep")
            selected = dispatch_attack_tasks(
              state, selected, env,
              fallback_generic: manifest.fetch("requested_executor") == "auto"
            )
          end
        else
          state.transition_to("complete")
        end
      when "fresh-sweep"
        state.transition_to("deduplicating")
        selected = dispatch_role_task(state, "dedupe", selected, env,
                                      fallback_generic: fallback_generic)
      when "arbitrating"
        state.transition_to(state.can_complete? ? "complete" : "did-not-converge")
      when "complete", "did-not-converge"
        # Idempotent terminal render/status.
      else
        raise Error.new("invalid_state", "run cannot be continued from this stage", 3,
                        {"stage" => snapshot.fetch("stage")})
      end
      report_path = if options[:report]
                      report_path_for(manifest, options[:report], run_dir: state_run_dir(state))
                    else
                      manifest["report_path"]
                    end
      terminal_response(state, report_path: report_path, program_path: program_path)
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
      task = nil
      task_bytes = nil
      state.read_task_bundle(options.fetch(:task)) do |_manifest, _data, value, bytes|
        task = value
        task_bytes = bytes
      end
      if task["authority"] == "parent"
        raise Error.new("invalid_authority", "parent author actions must use continue --actions", 3)
      end
      attestation = Adapters::Generic.new.ingest_capability_declaration(
        read_json_file(options.fetch(:capabilities)), task, options.fetch(:run_dir)
      )
      declaration = attestation.fetch("capabilities")
      result_payload = read_json_file(options.fetch(:result))
      schema_name = task.fetch("schema").sub(%r{\Aassets/schemas/}, "").sub(/\.json\z/, "")
      schema_errors = Schema.validate(schema_name, result_payload)
      if schema_errors.empty? && !required_check_coverage?(task, result_payload)
        state.record_result_repair!(task.fetch("task_id"), reason: "missing_required_checks")
        raise Error.new(
          "missing_required_checks", "result did not complete the authoritative required checks", 3,
          {"task_id" => task.fetch("task_id"), "required_checks" => task.fetch("required_checks")}
        )
      end
      repair_count = state.to_h.fetch("result_repairs").fetch(task.fetch("task_id"), {})
                          .fetch("count", 0)
      summary = state.accept_result(
        task.fetch("task_id"), result_payload,
        authority: "reviewer", capabilities: declaration,
        usage: {"prompt_bytes" => task_bytes.bytesize}, attempts: 1 + repair_count,
        runtime_provenance: {
          "adapter" => "generic", "capability_gate" => attestation.reject { |key, _| key == "capabilities" }
        }
      )
      response(state).merge(
        "task_id" => options.fetch(:task), "ingest" => summary,
        "capabilities" => declaration,
        "capability_gate" => attestation.reject { |key, _| key == "capabilities" }
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

    def normalize_start_options!(options, supplied, aliases)
      supplied.each do |name, values|
        if values.uniq.length > 1
          raise OptionParser::InvalidArgument, "conflicting --#{name} values"
        end
      end
      if aliases.fetch(:report_only) &&
         (supplied.fetch(:mode).any? { |value| value != "critique" } ||
          supplied.fetch(:output).any? { |value| value != "both" } || aliases.fetch(:chat_only))
        raise OptionParser::InvalidArgument,
              "--report-only conflicts with revise mode, non-both output, or --chat-only"
      end
      if aliases.fetch(:chat_only) && supplied.fetch(:output).any? { |value| value != "chat" }
        raise OptionParser::InvalidArgument, "--chat-only conflicts with non-chat output"
      end
      if aliases.fetch(:ultra) && supplied.fetch(:tier).any? { |value| value != "ultra" }
        raise OptionParser::InvalidArgument, "--ultra conflicts with another tier"
      end
      options[:tier] = aliases.fetch(:ultra) ? "ultra" : supplied.fetch(:tier).last || options[:tier]
      options[:mode] = aliases.fetch(:report_only) ? "critique" : supplied.fetch(:mode).last || options[:mode]
      options[:output] = if aliases.fetch(:report_only)
                           "both"
                         elsif aliases.fetch(:chat_only)
                           "chat"
                         else
                           supplied.fetch(:output).last || options[:output]
                         end
    end

    def required_check_coverage?(task, payload)
      required = task.fetch("required_checks")
      return true if required.empty?

      completed = payload["checks_completed"]
      completed.is_a?(Array) && completed.uniq.length == completed.length &&
        completed.sort == required.sort
    end

    def report_path_for(manifest, requested, run_dir:)
      root = manifest.fetch("repository").fetch("root")
      path = if requested
               File.expand_path(requested, root)
             else
               first = manifest.fetch("targets").first.fetch("path")
               stem = File.basename(first, File.extname(first))
               File.join(root, File.dirname(first), "#{stem}-review.md")
             end
      parent = File.dirname(path)
      basename = File.basename(path)
      missing = []
      cursor = parent
      until File.exist?(cursor) || File.symlink?(cursor)
        missing.unshift(File.basename(cursor))
        next_cursor = File.dirname(cursor)
        raise Error.new("invalid_report", "report parent cannot be resolved", 2) if next_cursor == cursor
        cursor = next_cursor
      end
      raise Error.new("invalid_report", "report parent contains a symlink", 2) if File.symlink?(cursor)
      canonical_parent = File.join(File.realpath(cursor), *missing)
      canonical_path = File.join(canonical_parent, basename)
      unless File.absolute_path(path) == path && !%w[. ..].include?(basename)
        raise Error.new("invalid_report", "report path must resolve through a real parent directory", 2)
      end
      expanded_run = File.expand_path(run_dir)
      if path == expanded_run || path.start_with?(expanded_run + File::SEPARATOR) ||
         canonical_path == expanded_run || canonical_path.start_with?(expanded_run + File::SEPARATOR)
        raise Error.new("invalid_report", "report path must be outside the review run directory", 2)
      end
      protected = manifest.fetch("targets").map { |target| target.fetch("path") } +
        manifest.fetch("context_paths", [])
      protected_paths = protected.map { |relative| File.expand_path(relative, root) }
      protected_paths.concat(%w[SKILL.md attack-angles.md judge-rubric.md].map do |name|
        File.join(AdversarialReview.root, name)
      end)
      if protected_paths.include?(canonical_path)
        raise Error.new("invalid_report", "report path collides with protected review input", 2)
      end
      if File.exist?(canonical_path) || File.symlink?(canonical_path)
        destination = File.lstat(canonical_path)
        unless destination.file? && !destination.symlink?
          raise Error.new("invalid_report", "existing report destination is not a regular file", 2)
        end
        protected_paths.select { |protected_path| File.file?(protected_path) }.each do |protected_path|
          protected_stat = File.stat(protected_path)
          if destination.dev == protected_stat.dev && destination.ino == protected_stat.ino
            raise Error.new("invalid_report", "report destination aliases protected review input", 2)
          end
        end
      end
      path
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
      raise Error.new(
        "invalid_report", "report destination cannot be resolved safely", 2,
        {"cause" => error.class.name}
      )
    end

    def select_executor(options, env)
      requested = options.fetch(:executor)
      return requested unless requested == "auto"
      host = env["ADVERSARIAL_REVIEW_HOST"].to_s.downcase
      return "generic" unless DIRECT_EXECUTORS.include?(host)
      return "generic" if unresolved?(options[:model], options[:effort])
      host
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
      task = Prompts.role_task(manifest, snapshot, kind)
      dispatch_task(state, task, selected, env, fallback_generic: fallback_generic)
    end

    def dispatch_judge_tasks(state, selected, env, fallback_generic: false)
      manifest = state.manifest_snapshot
      return dispatch_role_task(state, "judge", selected, env,
                                fallback_generic: fallback_generic) unless manifest.fetch("tier") == "ultra"

      voters = %w[voter-1 voter-2 voter-3]
      vote_group = "VG-cull-r#{state.to_h.fetch("revise_round")}"
      voters.each do |voter|
        task = Prompts.role_task(
          manifest, state.to_h, "judge", voter_id: voter,
          voter_ids: voters, vote_group_id: vote_group
        )
        selected = dispatch_task(state, task, selected, env, fallback_generic: fallback_generic)
      end
      selected
    end

    def dispatch_task(state, task, selected, env, fallback_generic: false)
      snapshot = state.to_h
      already_emitted = snapshot.fetch("emitted_tasks").key?(task.fetch("task_id"))
      return selected if snapshot.fetch("ingested_results").key?(task.fetch("task_id"))

      if selected == "generic"
        state.pin_executor!("generic") unless snapshot.dig("execution", "executor_pinned")
        Adapters::Generic.new.run(task, state_run_dir(state))
        return selected
      end

      intent = snapshot.dig("execution", "selection_intent")
      if intent.nil?
        manifest = state.manifest_snapshot
        state.begin_selection_intent!(
          task_id: task.fetch("task_id"),
          requested_executor: manifest.fetch("requested_executor"),
          candidate_executor: selected, vendor: selected,
          model: manifest.fetch("requested_model"), effort: manifest.fetch("requested_effort"),
          stage: snapshot.fetch("stage")
        )
        snapshot = state.to_h
        intent = snapshot.dig("execution", "selection_intent")
      end
      pinned = snapshot.dig("execution", "executor_pinned")
      fallback_before_call = fallback_generic && intent["status"] == "active" &&
        intent["requested_executor"] == "auto" && intent["external_attempts"].zero?
      state.create_task_bundle(task.fetch("task_id")) { task } unless already_emitted
      claim_file, claim_token = acquire_dispatch_claim(state, task.fetch("task_id"))
      begin
      if intent["status"] == "active" && intent["task_id"] == task.fetch("task_id")
        state.mark_selection_call_started!(task.fetch("task_id"))
      end
      result = execute_direct(state, task, selected, env)
      prompt_bytes = JSON.generate(task).bytesize
      phase = dispatch_phase(result)
      selecting = intent["status"] == "active" && intent["task_id"] == task.fetch("task_id")
      unless result.status == "complete" && result.payload
        eligible = Adapters::Base.eligibility_error?(result.error_code)
        if fallback_before_call && eligible && phase != "execution" && selecting && !pinned
          state.finalize_selection_intent!(
            task_id: task.fetch("task_id"), executor: selected, status: "fallback",
            error_code: result.error_code, phase: phase, content_sent: false,
            prompt_bytes: prompt_bytes, selected_executor: "generic"
          )
          Adapters::Generic.new.run(task, state_run_dir(state))
          return "generic"
        end
        if selecting
          state.finalize_selection_intent!(
            task_id: task.fetch("task_id"), executor: selected, status: "failed",
            error_code: result.error_code, phase: phase, content_sent: phase == "execution",
            prompt_bytes: prompt_bytes, selected_executor: selected
          )
        else
          state.record_dispatch_attempt!(
            task_id: task.fetch("task_id"), executor: selected, status: "failed",
            error_code: result.error_code, phase: phase, content_sent: phase == "execution",
            prompt_bytes: prompt_bytes
          )
        end
        status = eligible ? 4 : 5
        code = status == 4 ? "capability_blocked" : "adapter_execution_failed"
        raise Error.new(code, "#{selected} adapter could not produce an eligible result", status,
                        {"executor" => selected, "reason" => result.error_code})
      end
      # Count the reviewed task JSON once; adapter preflight and repair attempts do not
      # resubmit a different authoritative bundle and therefore do not multiply this value.
      usage = (result.usage || {}).merge("prompt_bytes" => prompt_bytes)
      state.accept_result(
        task.fetch("task_id"), result.payload,
        authority: "reviewer", capabilities: result.capabilities,
        usage: usage, attempts: result.attempts || 1,
        runtime_provenance: result.runtime_provenance || {}
      )
      if selecting
        state.finalize_selection_intent!(
          task_id: task.fetch("task_id"), executor: selected, status: "complete",
          error_code: nil, phase: "execution", content_sent: true,
          prompt_bytes: prompt_bytes, selected_executor: selected
        )
      else
        state.record_dispatch_attempt!(
          task_id: task.fetch("task_id"), executor: selected, status: "complete",
          error_code: nil, phase: "execution", content_sent: true, prompt_bytes: prompt_bytes
        )
      end
      selected
      ensure
        release_dispatch_claim(state, task.fetch("task_id"), claim_file, claim_token)
      end
    end

    def dispatch_phase(result)
      phase = result.runtime_provenance.to_h.dig("failure", "phase")
      %w[probe preflight execution].include?(phase) ? phase :
        (result.status == "complete" ? "execution" : "probe")
    end

    def acquire_dispatch_claim(state, task_id)
      path = File.join(state_run_dir(state), ".dispatch-#{task_id}.lock")
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = File.open(path, flags, 0o600)
      unless file.stat.file? && file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise Error.new(
          "dispatch_in_progress", "task already has an active direct dispatch", 3,
          {"task_id" => task_id}
        )
      end
      token = SecureRandom.hex(16)
      state.claim_dispatch!(task_id, token)
      [file, token]
    rescue Errno::ELOOP, Errno::EACCES, Errno::EPERM, Errno::ENOTDIR => error
      file.close if file && !file.closed?
      raise Error.new(
        "unsafe_dispatch_claim", "dispatch claim path is unsafe", 3,
        {"task_id" => task_id, "cause" => error.class.name}
      )
    end

    def release_dispatch_claim(state, task_id, file, token)
      state.release_dispatch_claim!(task_id, token) if token
    ensure
      if file && !file.closed?
        file.flock(File::LOCK_UN)
        file.close
      end
    end

    def resume_stage_dispatch(state, selected, env)
      fallback = false
      case state.to_h.fetch("stage")
      when "attacking", "fresh-sweep"
        dispatch_attack_tasks(state, selected, env, fallback_generic: fallback)
      when "deduplicating"
        dispatch_role_task(state, "dedupe", selected, env, fallback_generic: fallback)
      when "culling", "culling-new-findings"
        dispatch_judge_tasks(state, selected, env, fallback_generic: fallback)
      when "resolving"
        dispatch_role_task(state, "resolution", selected, env, fallback_generic: fallback)
      when "arbitrating"
        dispatch_role_task(state, "arbiter", selected, env, fallback_generic: fallback)
      end
    end

    def generic_fallback_available?(manifest, snapshot)
      return false unless manifest.fetch("requested_executor") == "auto" &&
                          snapshot.dig("execution", "tasks").empty?

      intent = snapshot.dig("execution", "selection_intent")
      intent.nil? || (intent["status"] == "active" &&
        intent["requested_executor"] == "auto" && intent["external_attempts"].zero?)
    end

    def recover_selection_intent!(state)
      snapshot = state.to_h
      intent = snapshot.dig("execution", "selection_intent")
      return unless intent.is_a?(Hash) && intent["status"] == "active"

      task_id = intent.fetch("task_id")
      unless snapshot.fetch("emitted_tasks").key?(task_id)
        task = selection_intent_task(state, intent)
        state.create_task_bundle(task_id) { task }
        snapshot = state.to_h
      end
      return unless snapshot.fetch("ingested_results").key?(task_id) &&
                    snapshot.dig("execution", "tasks", task_id)

      task = nil
      state.read_task_bundle(task_id) { |_manifest, _data, value| task = value }
      state.finalize_selection_intent!(
        task_id: task_id, executor: intent.fetch("candidate_executor"), status: "complete",
        error_code: nil, phase: "execution", content_sent: true,
        prompt_bytes: JSON.generate(task).bytesize,
        selected_executor: intent.fetch("candidate_executor")
      )
    end

    def selection_intent_task(state, intent)
      snapshot = state.to_h
      manifest = state.manifest_snapshot
      tasks = manifest.fetch("enabled_tasks").map do |angle|
        Prompts.attack_task(
          manifest, angle, 1, round: snapshot.fetch("revise_round"),
          current_digests: snapshot.fetch("current_target_digests")
        )
      end
      task = tasks.find { |candidate| candidate.fetch("task_id") == intent.fetch("task_id") }
      return task if task && %w[attacking fresh-sweep].include?(intent.fetch("stage"))

      raise Error.new(
        "selection_task_unrecoverable", "selection intent does not identify an expected attack task", 3,
        {"task_id" => intent.fetch("task_id"), "stage" => intent.fetch("stage")}
      )
    end

    def attack_roster_pending?(state, selected, env, fallback_generic: false)
      snapshot = state.to_h
      manifest = state.manifest_snapshot
      round = snapshot.fetch("revise_round")
      expected = manifest.fetch("enabled_tasks").map do |angle|
        Prompts.attack_task(
          manifest, angle, 1, round: round,
          current_digests: snapshot.fetch("current_target_digests")
        ).fetch("task_id")
      end
      observed = snapshot.fetch("emitted_tasks").values.select do |task|
        task.fetch("kind") == "attack" && task.fetch("round") == round
      end.map { |task| task.fetch("task_id") }
      unexpected = observed - expected
      unless unexpected.empty?
        raise Error.new("invalid_attack_roster", "attack stage contains unexpected tasks", 3,
                        {"task_ids" => unexpected.sort})
      end
      unless (expected - observed).empty?
        dispatch_attack_tasks(
          state, selected, env, fallback_generic: fallback_generic
        )
        return true
      end
      false
    end

    def stage_roster_pending?(state, selected, env, fallback_generic: false)
      snapshot = state.to_h
      stage = snapshot.fetch("stage")
      return attack_roster_pending?(
        state, selected, env, fallback_generic: fallback_generic
      ) if %w[attacking fresh-sweep].include?(stage)

      if stage == "awaiting-author"
        task_id = "author-actions-parent-r#{snapshot.fetch("revise_round")}-a1"
        if snapshot.fetch("emitted_tasks").key?(task_id)
          return false
        end
      end

      manifest = state.manifest_snapshot
      tasks = case stage
              when "deduplicating"
                [Prompts.role_task(manifest, snapshot, "dedupe")]
              when "culling", "culling-new-findings"
                if manifest.fetch("tier") == "ultra"
                  voters = %w[voter-1 voter-2 voter-3]
                  vote_group = "VG-cull-r#{snapshot.fetch("revise_round")}"
                  voters.map do |voter|
                    Prompts.role_task(
                      manifest, snapshot, "judge", voter_id: voter,
                      voter_ids: voters, vote_group_id: vote_group
                    )
                  end
                else
                  [Prompts.role_task(manifest, snapshot, "judge")]
                end
              when "awaiting-author"
                [Prompts.parent_action_task(manifest, snapshot)]
              when "resolving"
                [Prompts.role_task(manifest, snapshot, "resolution")]
              when "arbitrating"
                [Prompts.role_task(manifest, snapshot, "arbiter")]
              else
                return false
              end
      expected_ids = tasks.map { |task| task.fetch("task_id") }
      expected_kind = tasks.first.fetch("kind")
      observed_ids = snapshot.fetch("emitted_tasks").values.select do |record|
        record.fetch("kind") == expected_kind &&
          record.fetch("round") == snapshot.fetch("revise_round") && record.fetch("attempt") == 1
      end.map { |record| record.fetch("task_id") }
      unexpected = observed_ids - expected_ids
      unless unexpected.empty?
        raise Error.new(
          "invalid_stage_roster", "stage contains an unexpected authoritative task", 3,
          {"stage" => stage, "task_ids" => unexpected.sort}
        )
      end
      missing = tasks.reject do |task|
        snapshot.fetch("emitted_tasks").key?(task.fetch("task_id"))
      end
      unless missing.empty?
        missing.each do |task|
          if task["authority"] == "parent"
            state.create_task_bundle(task.fetch("task_id")) { task }
          else
            selected = dispatch_task(state, task, selected, env, fallback_generic: false)
          end
        end
        return true
      end
      false
    end

    def current_stage_pending_task_ids(snapshot, _manifest)
      stage = snapshot.fetch("stage")
      kind = case stage
             when "attacking", "fresh-sweep" then "attack"
             when "deduplicating" then "dedupe"
             when "culling", "culling-new-findings" then "judge"
             when "awaiting-author" then "author-actions"
             when "resolving" then "resolution"
             when "arbitrating" then "arbiter"
             end
      return [] unless kind

      round = snapshot.fetch("revise_round")
      pending_task_ids(snapshot).select do |task_id|
        record = snapshot.fetch("emitted_tasks").fetch(task_id)
        record.fetch("kind") == kind && record.fetch("round") == round
      end
    end

    def execute_direct(state, task, selected, env)
      snapshot = state.to_h
      intent = snapshot.dig("execution", "selection_intent")
      authorized_selection = intent.is_a?(Hash) && intent["status"] == "active" &&
        intent["task_id"] == task.fetch("task_id") && intent["external_attempts"].positive?
      authorized_pinned = intent.is_a?(Hash) && intent["status"] == "terminal" &&
        snapshot.dig("execution", "executor_pinned")
      unless snapshot.fetch("emitted_tasks").key?(task.fetch("task_id")) &&
             (authorized_selection || authorized_pinned)
        raise Error.new(
          "selection_call_not_authorized",
          "direct execution requires a durable executor intent and authenticated task", 3,
          {"task_id" => task.fetch("task_id"), "executor" => selected}
        )
      end
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
      adapter.execute(
        required_checks: task.fetch("required_checks"),
        dispatch_capability: {
          "status" => "unavailable",
          "evidence" => "portable CLI dispatch is serial and does not provide parallel role execution",
          "source" => "portable CLI dispatch loop"
        }
      )
    end

    def state_run_dir(state)
      state.instance_variable_get(:@run_dir)
    end

    def response(state)
      snapshot = state.to_h
      manifest = state.manifest_snapshot
      pending = pending_task_ids(snapshot).map do |task_id|
        File.join(state_run_dir(state), "tasks", "#{task_id}.json")
      end
      pending_task_handoffs = pending.map do |task_path|
        task_id = File.basename(task_path, ".json")
        state.read_task_bundle(task_id) do |_manifest, _data, task, task_bytes|
          Adapters::Generic.handoff_metadata(task_path, task, task_bytes)
        end
      end
      parent_pending = pending.any? do |path|
        task_id = File.basename(path, ".json")
        snapshot.dig("emitted_tasks", task_id, "kind") == "author-actions"
      end
      next_action = if parent_pending
                      "submit-author-actions"
                    elsif pending.empty?
                      snapshot.fetch("next_action")
                    else
                      "awaiting-results"
                    end
      {
        "schema_version" => 1,
        "run_id" => snapshot.fetch("run_id"),
        "run_dir" => state_run_dir(state),
        "stage" => snapshot.fetch("stage"),
        "next_action" => next_action,
        "pending_tasks" => pending.sort,
        "pending_task_handoffs" => pending_task_handoffs.sort_by { |entry| entry.fetch("task_path") },
        "pending_batch_size" => pending.length,
        "requested_executor" => manifest.fetch("requested_executor"),
        "selected_executor" => snapshot.dig("execution", "selected_executor"),
        "jobs" => snapshot.dig("execution", "jobs"),
        "report_path" => snapshot.dig("execution", "report_path")
      }
    end

    def pending_task_ids(snapshot)
      snapshot.fetch("emitted_tasks").keys.reject do |task_id|
        snapshot.fetch("ingested_results").key?(task_id)
      end.sort
    end

    def terminal_response(state, report_path:, program_path:)
      snapshot = state.to_h
      result = response(state)
      return result unless %w[complete did-not-converge].include?(snapshot.fetch("stage"))

      manifest = state.manifest_snapshot
      existing_summary = snapshot.fetch("summary")
      summary = existing_summary || Reporting.summary(
        report_source(state, manifest, snapshot, program_path)
      )
      unless existing_summary
        state.persist_summary!(summary)
        summary = state.to_h.fetch("summary")
      end
      output = manifest.fetch("output")
      if %w[file both].include?(output)
        unless report_path
          raise Error.new("invocation_error", "--report is required for file output", 2)
        end
        result["report_path"] = append_terminal_report(report_path, summary)
      end
      result["summary"] = Reporting.chat_payload(summary) if %w[chat both].include?(output)
      result["verdict"] = summary.fetch("verdict")
      result
    end

    def append_terminal_report(report_path, summary)
      Reporting.append(report_path, summary)
    rescue Reporting::Error => error
      expanded = File.expand_path(report_path)
      duplicate = error.code == "duplicate_run" &&
        error.details["run_id"] == summary.fetch("run_id") &&
        error.details["path"] == expanded
      raise error unless duplicate

      expanded
    end

    def report_source(state, manifest, snapshot, program_path)
      execution = snapshot.fetch("execution")
      selected = execution.fetch("selected_executor")
      records = execution.fetch("tasks")
      ingested = snapshot.fetch("ingested_results")
      missing = ingested.keys.reject { |task_id| records.key?(task_id) }
      unless missing.empty?
        raise Error.new(
          "incomplete_execution_metadata", "ingested tasks are missing authoritative execution evidence",
          3, {"task_ids" => missing.sort}
        )
      end
      reviewer_records = records.select { |_task_id, record| record.fetch("authority") == "reviewer" }
      capabilities = if reviewer_records.empty? && !execution.fetch("metadata_required")
                       Capabilities.normalize(
                         {}, requested_model: manifest.fetch("requested_model"),
                         requested_effort: manifest.fetch("requested_effort")
                       )
                     else
                       aggregate_capabilities(reviewer_records, manifest)
                     end
      gate = Capabilities.gate(capabilities, "PASS")
      emitted = snapshot.fetch("emitted_tasks")
      angles = manifest.fetch("enabled_tasks").map do |angle|
        tasks = emitted.values.select { |record| record["angle"] == angle }
        complete = !tasks.empty? && tasks.all? { |record| ingested.key?(record.fetch("task_id")) }
        attempts = tasks.sum do |record|
          [records.dig(record.fetch("task_id"), "attempts").to_i - 1, 0].max
        end
        {
          "name" => angle,
          "status" => complete ? "completed" : "failed",
          "failure_reason" => complete ? nil : "task did not complete",
          "retries" => attempts,
          "retry_reasons" => Array.new(attempts, "adapter format repair")
        }
      end
      usage = aggregate_usage(reviewer_records)
      runtime = aggregate_runtime(reviewer_records)
      started_at = run_started_at(manifest.fetch("run_id"))
      current_targets, current_inventory = Prompts.current_targets_and_inventory(
        manifest, snapshot.fetch("current_target_digests")
      )
      {
        "schema_version" => 1,
        "run_id" => manifest.fetch("run_id"),
        "targets" => current_targets,
        "repository" => manifest.fetch("repository"),
        "started_at" => started_at,
        "ended_at" => Time.now.utc.iso8601,
        "tier" => manifest.fetch("tier"),
        "mode" => manifest.fetch("mode"),
        "output" => manifest.fetch("output"),
        "requested_executor" => manifest.fetch("requested_executor"),
        "selected_executor" => selected,
        "cli" => runtime.fetch("cli", {"realpath" => File.realpath(program_path), "version" => VERSION}),
        "requested_model" => manifest.fetch("requested_model"),
        "observed_model" => runtime["observed_model"],
        "requested_effort" => manifest.fetch("requested_effort"),
        "observed_effort" => runtime["observed_effort"],
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
        "metrics" => comparison_metrics(manifest.fetch("starting_metrics"), current_inventory)
      }
    end

    def comparison_metrics(starting, inventory)
      current = {
        "target_count" => inventory.length,
        "word_count" => inventory.sum { |item| item.fetch("word_count") },
        "line_count" => inventory.sum { |item| item.fetch("line_count") },
        "unresolved_placeholder_count" => inventory.sum { |item| item.fetch("placeholder_count") }
      }
      starting.keys.sort.each_with_object({}) do |name, metrics|
        metrics["starting_#{name}"] = starting.fetch(name)
        metrics["current_#{name}"] = current.fetch(name)
        metrics["delta_#{name}"] = current.fetch(name) - starting.fetch(name)
      end
    end

    def aggregate_capabilities(records, manifest)
      raise Error.new("incomplete_execution_metadata", "review has no reviewer capability records", 3) if records.empty?
      rank = {"enforced" => 0, "behavioral" => 1, "unavailable" => 2}
      Capabilities::FIELDS.each_with_object({}) do |field, aggregate|
        declarations = records.map { |_task_id, record| record.fetch("capabilities").fetch(field) }
        worst = declarations.max_by { |declaration| rank.fetch(declaration.fetch("status")) }
        aggregate[field] = {
          "requested" => field == "model_selection" ? manifest.fetch("requested_model") :
            (field == "effort_selection" ? manifest.fetch("requested_effort") : true),
          "status" => worst.fetch("status"),
          "evidence" => "worst persisted task evidence: #{worst.fetch("evidence")}",
          "source" => "persisted per-task capability records"
        }
      end
    end

    def aggregate_usage(records)
      aliases = {
        "prompt_bytes" => %w[prompt_bytes],
        "input_tokens" => %w[input_tokens],
        "cached_input_tokens" => %w[cached_input_tokens cache_read_input_tokens cache_creation_input_tokens],
        "output_tokens" => %w[output_tokens],
        "reasoning_tokens" => %w[reasoning_tokens],
        "total_tokens" => %w[total_tokens]
      }
      aliases.each_with_object({}) do |(target, sources), usage|
        values = records.flat_map do |_task_id, record|
          sources.each_with_object([]) do |source, found|
            found << record.fetch("usage").fetch(source) if record.fetch("usage").key?(source)
          end
        end
        usage[target] = values.empty? ? nil : values.sum
      end
    end

    def aggregate_runtime(records)
      observations = records.values.flat_map do |record|
        provenance = record.fetch("runtime_provenance")
        Array(provenance["executions"])
      end
      models = observations.each_with_object([]) { |item, values| values << item["observed_model"] if item["observed_model"] }.uniq
      efforts = observations.each_with_object([]) { |item, values| values << item["observed_effort"] if item["observed_effort"] }.uniq
      cli_record = observations.find { |item| item["executable"] && item["cli_version"] }
      result = {
        "observed_model" => models.length == 1 ? models.first : nil,
        "observed_effort" => efforts.length == 1 ? efforts.first : nil
      }
      if cli_record
        result["cli"] = {
          "realpath" => cli_record.fetch("executable"),
          "version" => cli_record.fetch("cli_version")
        }
      end
      result
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
