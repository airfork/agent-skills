require "open3"
require "digest"

module AdversarialReview
  class State
    class Error < StandardError
      attr_reader :code, :details, :exit_status

      def initialize(code, message, details = {}, exit_status = 2)
        @code = code
        @details = details
        @exit_status = exit_status
        super(message)
      end

      def to_h
        {
          "code" => code,
          "message" => message,
          "details" => details,
          "exit_status" => exit_status
        }
      end
    end

    class InvalidResult < Error
      def initialize(code, message, details = {})
        super(code, message, details, 3)
      end
    end

    RUN_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/.freeze
    MAX_STATE_ITEMS = 4096
    TRANSITIONS = {
      "prepared" => %w[attacking].freeze,
      "attacking" => %w[deduplicating].freeze,
      "deduplicating" => %w[culling culling-new-findings].freeze,
      "culling" => %w[awaiting-author complete].freeze,
      "awaiting-author" => %w[resolving].freeze,
      "resolving" => %w[fresh-sweep arbitrating complete did-not-converge].freeze,
      "fresh-sweep" => %w[deduplicating culling-new-findings].freeze,
      "culling-new-findings" => %w[awaiting-author arbitrating complete did-not-converge].freeze,
      "arbitrating" => %w[awaiting-author complete did-not-converge].freeze
    }.freeze
    NEXT_ACTIONS = {
      "prepared" => "attack",
      "attacking" => "collect-attacks",
      "deduplicating" => "deduplicate",
      "culling" => "cull",
      "awaiting-author" => "collect-author-actions",
      "resolving" => "resolve",
      "fresh-sweep" => "attack",
      "culling-new-findings" => "cull",
      "arbitrating" => "arbitrate",
      "complete" => nil,
      "did-not-converge" => nil
    }.freeze
    SEVERITY_RANK = {
      "CRITICAL" => 0,
      "HIGH" => 1,
      "MEDIUM" => 2,
      "LOW" => 3
    }.freeze
    RESULT_SCHEMAS = %w[attack divergence dedupe judge author-actions resolution arbiter].freeze
    RESULT_TASK_KEYS = %w[
      schema_version run_id task_id role kind schema schema_name artifact_digests
      round attempt angle vote_group_id voter_id expected_voters voter_ids
      dispute_kind subject_ids subject_mappings mapped_candidate_ids allow_new_findings
      targets inventory context_pointers applicable_guidance role_contract
      capability_declaration_template mutation_restrictions tool_restrictions prompt
      authority review_evidence repository_root schema_path schema_sha256 required_checks
    ].freeze
    INGEST_STAGES = {
      "attack" => %w[attacking fresh-sweep].freeze,
      "divergence" => %w[attacking fresh-sweep].freeze,
      "dedupe" => %w[deduplicating].freeze,
      "judge" => %w[culling culling-new-findings].freeze,
      "author-actions" => %w[awaiting-author].freeze,
      "resolution" => %w[resolving].freeze,
      "arbiter" => %w[arbitrating].freeze
    }.freeze
    TERMINAL_PAIRINGS = {
      "fixed" => "resolved",
      "rejected" => "rejected"
    }.freeze
    MUTATION_STAGES = {
      "ingest_candidate" => %w[attacking fresh-sweep].freeze,
      "promote" => %w[culling culling-new-findings].freeze,
      "record_author_action" => %w[awaiting-author].freeze,
      "record_resolution" => %w[resolving].freeze,
      "record_nonblocking_evidence_gap" => TRANSITIONS.keys.freeze,
      "set_pending_arbiter_subjects" => %w[resolving culling-new-findings].freeze,
      "require_fresh_sweep" => %w[resolving culling-new-findings].freeze,
      "mark_fresh_sweep_completed" => %w[fresh-sweep].freeze,
      "record_degraded_capability" => TRANSITIONS.keys.freeze,
      "update_current_digests" => TRANSITIONS.keys.freeze,
      "apply_arbiter" => %w[arbitrating].freeze
    }.freeze

    def self.default_run_dir(repository:, run_id:)
      validate_run_id!(run_id)
      repository = File.realpath(File.expand_path(repository))
      arguments = ["git", "-C", repository, "rev-parse", "--git-path", "adversarial-review/runs"]
      output, status = Open3.capture2e(*arguments)
      unless status.success? && !output.strip.empty?
        raise Error.new(
          "git_path_unresolved", "could not resolve the adversarial-review run directory",
          {
            "command" => arguments,
            "output" => output.to_s.strip,
            "git_exit_status" => status.respond_to?(:exitstatus) ? status.exitstatus : nil
          }
        )
      end
      parent = canonical_missing_path(File.expand_path(output.strip, repository))
      run_dir = File.expand_path(run_id, parent)
      unless run_dir.start_with?(parent + File::SEPARATOR)
        raise Error.new("run_path_escape", "run directory escapes the Git run root", {"path" => run_dir})
      end
      run_dir
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => error
      raise Error.new(
        "git_error", "could not invoke Git to resolve the run directory",
        {"command" => arguments, "cause" => error.class.name, "errno" => error.respond_to?(:errno) ? error.errno : nil}
      )
    end

    class << self
      alias resolve_run_dir default_run_dir
    end

    def self.create(run_dir, manifest)
      created_run_dir = nil
      run_identity = nil
      tasks_identity = nil
      results_identity = nil
      run_id = manifest.fetch("run_id")
      validate_run_id!(run_id)
      digests = target_digests(manifest)
      data = {
        "schema_version" => 1,
        "run_id" => run_id,
        "mode" => manifest.fetch("mode"),
        "stage" => "prepared",
        "revise_round" => 1,
        "task_attempts" => {},
        "result_repairs" => {},
        "emitted_tasks" => {},
        "ingested_results" => {},
        "exact_duplicate_map" => {},
        "exact_duplicate_sources" => {},
        "semantic_groups" => {},
        "judge_votes" => {},
        "evidence_gaps" => [],
        "overflow" => {"total" => 0, "by_category_severity" => {}, "items" => []},
        "overflow_evidence_gaps" => {},
        "candidates" => [],
        "findings" => [],
        "author_actions" => {},
        "resolution_checks" => {},
        "pending_arbiter_subjects" => [],
        "target_digest_history" => [digests],
        "current_target_digests" => digests,
        "fresh_sweep_required" => false,
        "fresh_sweep_completed" => false,
        "degraded_capabilities" => [],
        "execution" => {
          "selected_executor" => manifest["selected_executor"] ||
            (manifest.fetch("requested_executor", "generic") == "auto" ? "generic" :
              manifest.fetch("requested_executor", "generic")),
          "executor_pinned" => manifest.fetch("requested_executor", "generic") != "auto",
          "jobs" => manifest.fetch("jobs", 1),
          "metadata_required" => manifest.fetch("execution_metadata_required", false),
          "report_path" => manifest["report_path"],
          "dispatch_attempts" => [],
          "dispatch_claims" => {},
          "selection_intent" => nil,
          "tasks" => {}
        },
        "summary" => nil,
        "events" => [],
        "next_action" => "attack"
      }
      validate_snapshot!(manifest, data)
      expanded_run_dir = Atomic.normalize_root_alias(File.expand_path(run_dir))
      if File.symlink?(expanded_run_dir)
        raise Error.new("unsafe_run_dir", "review run path must not be a symlink", {"run_dir" => expanded_run_dir})
      end
      parent = Atomic.secure_directory(File.dirname(expanded_run_dir))
      canonical_run_dir = File.join(parent, File.basename(run_dir))
      begin
        Dir.mkdir(canonical_run_dir, 0o700)
        created_run_dir = capture_created_run(canonical_run_dir)
      rescue Errno::EEXIST
        raise Error.new("run_exists", "review run already exists", {"run_dir" => canonical_run_dir})
      end
      File.chmod(0o700, canonical_run_dir)
      %w[tasks results events].each do |entry|
        path = File.join(canonical_run_dir, entry)
        Dir.mkdir(path, 0o700)
        File.chmod(0o700, path)
      end
      lock_path = File.join(canonical_run_dir, ".state.lock")
      create_lock(lock_path)
      Atomic.open_lock(lock_path, exclusive: true) do |_lock, run_directory|
        validate_snapshot!(manifest, data)
        Atomic.write_json_relative(run_directory, "manifest.json", manifest)
        Atomic.write_json_relative(run_directory, "state.json", data)
        run_identity = run_directory.stat
        Atomic.with_relative_directory(run_directory, "tasks") do |tasks_directory|
          tasks_identity = tasks_directory.stat
        end
        Atomic.with_relative_directory(run_directory, "results") do |results_directory|
          results_identity = results_directory.stat
        end
      end
      new(
        canonical_run_dir, data, manifest,
        run_identity: run_identity, tasks_identity: tasks_identity,
        results_identity: results_identity
      )
    rescue KeyError => error
      cleanup_created_run(created_run_dir)
      raise Error.new("invalid_manifest", "manifest is missing required state fields", {"field" => error.key}, 3)
    rescue StandardError
      cleanup_created_run(created_run_dir)
      raise
    ensure
      if created_run_dir && created_run_dir[:directory] && !created_run_dir[:directory].closed?
        created_run_dir[:directory].close
      end
    end

    def self.load(run_dir)
      canonical_run_dir = secure_run_directory(run_dir)
      lock_path = File.join(canonical_run_dir, ".state.lock")
      manifest = nil
      data = nil
      run_identity = nil
      tasks_identity = nil
      results_identity = nil
      Atomic.open_lock(lock_path, exclusive: false) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        validate_snapshot!(manifest, data)
        run_identity = run_directory.stat
        Atomic.with_relative_directory(run_directory, "tasks") do |tasks_directory|
          tasks_identity = tasks_directory.stat
        end
        Atomic.with_relative_directory(run_directory, "results") do |results_directory|
          results_identity = results_directory.stat
        end
        verify_ingested_files!(
          run_directory, data,
          tasks_identity: tasks_identity, results_identity: results_identity
        )
      end
      new(
        canonical_run_dir, data, manifest,
        run_identity: run_identity, tasks_identity: tasks_identity,
        results_identity: results_identity
      )
    end

    def self.verify_ingested_files!(run_directory, data, tasks_identity:, results_identity:)
      return true if data.fetch("ingested_results").empty?

      tasks = nil
      results = nil
      Atomic.with_relative_directory(
        run_directory, "tasks", code: "invalid_state", expected_identity: tasks_identity
      ) do |tasks_directory|
        tasks = tasks_directory
        Atomic.with_relative_directory(
          run_directory, "results", code: "invalid_state", expected_identity: results_identity
        ) do |results_directory|
          results = results_directory
          data.fetch("ingested_results").each do |task_id, record|
            task_bytes = read_integrity_bytes!(tasks, "#{task_id}.json")
            auth, auth_bytes = read_integrity_json_bytes!(tasks, "#{task_id}.auth.json")
            expected_auth = {
              "schema_version" => 1,
              "task_id" => task_id,
              "sha256" => Digest::SHA256.hexdigest(task_bytes)
            }
            unless auth.is_a?(Hash) && auth.keys.sort == expected_auth.keys.sort && auth == expected_auth &&
                   auth_bytes == JSON.generate(expected_auth) + "\n" &&
                   expected_auth.fetch("sha256") == record.fetch("task_sha256")
              raise Error.new(
                "invalid_state", "ingested task authentication does not match committed state",
                {"task_id" => task_id}, 3
              )
            end

            result_bytes = read_integrity_bytes!(results, "#{task_id}.json")
            unless Digest::SHA256.hexdigest(result_bytes) == record.fetch("sha256")
              raise Error.new(
                "invalid_state", "ingested result bytes do not match committed state",
                {"task_id" => task_id}, 3
              )
            end
          end
        end
      end
      true
    end

    def self.read_integrity_json_bytes!(directory, name)
      bytes = read_integrity_bytes!(directory, name)
      [JSON.parse(bytes), bytes]
    rescue JSON::ParserError => error
      raise Error.new(
        "invalid_state", "committed JSON is invalid",
        {"path" => name, "cause" => error.message}, 3
      )
    end

    def self.read_integrity_bytes!(directory, name)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = Atomic.open_relative(directory, name, flags)
      begin
        unless file.stat.file?
          raise Error.new("invalid_state", "committed path must be a regular file", {"path" => name}, 3)
        end
        if file.stat.size > Atomic::MAX_JSON_BYTES
          raise Error.new("invalid_state", "committed file exceeds the size limit", {"path" => name}, 3)
        end
        bytes = file.read(Atomic::MAX_JSON_BYTES + 1)
        if bytes.bytesize > Atomic::MAX_JSON_BYTES
          raise Error.new("invalid_state", "committed file exceeds the size limit", {"path" => name}, 3)
        end
        bytes
      ensure
        file.close if file && !file.closed?
      end
    rescue Error
      raise
    rescue SystemCallError => error
      raise Error.new(
        "invalid_state", "committed file is unavailable",
        {"path" => name, "cause" => error.class.name}, 3
      )
    end

    def initialize(run_dir, data, manifest, run_identity:, tasks_identity:, results_identity:)
      @run_dir = run_dir
      @data = data
      @manifest = manifest
      @run_identity = run_identity
      @tasks_identity = tasks_identity
      @results_identity = results_identity
    end

    def to_h
      refresh!
      deep_copy(@data)
    end

    def manifest_snapshot
      snapshot = nil
      Atomic.open_lock(
        File.join(@run_dir, ".state.lock"),
        exclusive: false,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        @manifest = manifest
        @data = data
        snapshot = deep_freeze(deep_copy(manifest))
      end
      snapshot
    end

    def create_task_bundle(task_id)
      unless task_id.is_a?(String) && RUN_ID.match?(task_id) && task_id != "." && task_id != ".."
        raise Error.new("invalid_task_id", "task ID contains unsafe characters", {"task_id" => task_id})
      end
      task_path = File.join(@run_dir, "tasks", "#{task_id}.json")
      Atomic.open_lock(
        File.join(@run_dir, ".state.lock"),
        exclusive: true,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        intent = data.dig("execution", "selection_intent")
        selection_task = intent.is_a?(Hash) && intent["status"] == "active" &&
          intent["task_id"] == task_id
        unless data.dig("execution", "executor_pinned") || selection_task
          raise Error.new(
            "executor_not_pinned", "task bundles require a pinned executor or matching selection intent",
            {"task_id" => task_id}, 3
          )
        end
        Atomic.with_relative_directory(
          run_directory, "tasks", code: "unsafe_task_path", expected_identity: @tasks_identity
        ) { |_tasks_directory| nil }
        value = yield(
          deep_freeze(deep_copy(manifest)),
          deep_freeze(deep_copy(data))
        )
        task_bytes = JSON.generate(value) + "\n"
        task_record = authoritative_task_record!(task_id, value, task_bytes, manifest, data)
        existing_record = data.fetch("emitted_tasks")[task_id]
        if existing_record && existing_record != task_record
          invalid_result!(
            "invalid_task", "task identity conflicts with its authoritative emitted record",
            {"task_id" => task_id}
          )
        end
        publication = nil
        Atomic.with_relative_directory(
          run_directory, "tasks",
          code: "unsafe_task_path",
          expected_identity: @tasks_identity
        ) do |tasks_directory|
          publication = publish_authenticated_task!(tasks_directory, task_id, value)
        end
        state_published = false
        begin
          data.fetch("emitted_tasks")[task_id] = task_record
          data.fetch("task_attempts")[task_id] = task_record.fetch("attempt")
          self.class.validate_snapshot!(manifest, data)
          Atomic.write_json_relative(
            run_directory, "state.json", data,
            on_publish: -> { state_published = true }
          )
        rescue StandardError => error
          if state_published
            @manifest = manifest
            @data = data
            raise Error.new(
              "durability_uncertain",
              "task and authoritative state are visible but directory durability could not be confirmed",
              {"task_id" => task_id, "cause" => error.class.name, "message" => error.message}, 3
            )
          end
          rollback_task_publication!(run_directory, task_id, publication)
          raise
        end
        @manifest = manifest
        @data = data
      end
      task_path
    end

    def read_task_bundle(task_id)
      unless task_id.is_a?(String) && RUN_ID.match?(task_id) && task_id != "." && task_id != ".."
        raise Error.new("invalid_task_id", "task ID contains unsafe characters", {"task_id" => task_id})
      end
      task_path = File.join(@run_dir, "tasks", "#{task_id}.json")
      result = nil
      Atomic.open_lock(
        File.join(@run_dir, ".state.lock"),
        exclusive: false,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        Atomic.with_relative_directory(
          run_directory, "tasks",
          code: "unsafe_task_path",
          expected_identity: @tasks_identity
        ) do |tasks_directory|
          emitted, _emitted_bytes = read_authenticated_task!(tasks_directory, task_id)
          verify_authoritative_task!(task_id, emitted, _emitted_bytes, manifest, data)
          result = yield(
            deep_freeze(deep_copy(manifest)),
            deep_freeze(deep_copy(data)),
            deep_freeze(emitted),
            _emitted_bytes.dup.freeze
          )
        end
      end
      result
    end

    def ingest(task_id, payload)
      ingest_with_execution(task_id, payload, nil)
    end

    def accept_result(task_id, payload, authority:, capabilities:, usage:, attempts:,
                      runtime_provenance:)
      execution_record = build_execution_record!(
        task_id, authority: authority, capabilities: capabilities, usage: usage,
        attempts: attempts, runtime_provenance: runtime_provenance
      )
      ingest_with_execution(task_id, payload, execution_record)
    end

    def ingest_with_execution(task_id, payload, execution_record)
      validate_task_id!(task_id)
      summary = nil
      Atomic.open_lock(
        File.join(@run_dir, ".state.lock"),
        exclusive: true,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        task = nil
        task_bytes = nil
        Atomic.with_relative_directory(
          run_directory, "tasks",
          code: "unsafe_task_path",
          expected_identity: @tasks_identity
        ) do |tasks_directory|
          task, task_bytes = read_authenticated_task!(tasks_directory, task_id)
        end
        verify_authoritative_task!(task_id, task, task_bytes, manifest, data)
        schema_name = result_schema_name!(task)
        errors = Schema.validate(schema_name, payload)
        unless errors.empty?
          raise InvalidResult.new(
            "invalid_result", "result payload does not match its schema",
            {"schema" => schema_name, "errors" => errors}
          )
        end
        validate_result_task!(task_id, task, schema_name, manifest, data, payload)
        ensure_ingest_stage!(data, schema_name)
        if execution_record
          existing_execution = data.dig("execution", "tasks", task_id)
          if existing_execution
            existing_base = existing_execution.reject do |key, _value|
              %w[result_sha256 task_sha256].include?(key)
            end
            if existing_base != execution_record
              raise Error.new(
                "execution_record_conflict", "accepted task execution evidence is immutable",
                {"task_id" => task_id}, 3
              )
            end
          end
        end
        if data.fetch("ingested_results").key?(task_id)
          invalid_result!(
            "duplicate_result", "task result has already been ingested",
            {"task_id" => task_id}
          )
        end
        live_digests = live_target_digests!(manifest)
        unless live_digests == data.fetch("current_target_digests")
          invalid_result!(
            "target_digest_mismatch", "live target bytes do not match authoritative state",
            {"expected" => data.fetch("current_target_digests"), "current" => live_digests}
          )
        end

        result_value = deep_copy(payload)
        result_bytes = JSON.generate(result_value) + "\n"
        result_sha = Digest::SHA256.hexdigest(result_bytes)
        task_sha = Digest::SHA256.hexdigest(task_bytes)
        summary = apply_result_to_data!(data, task, schema_name, result_value, manifest)
        data.fetch("ingested_results")[task_id] = {
          "sha256" => result_sha,
          "task_sha256" => task_sha,
          "schema" => schema_name,
          "round" => task.fetch("round", data.fetch("revise_round"))
        }
        if execution_record
          accepted_record = deep_copy(execution_record).merge(
            "task_sha256" => task_sha, "result_sha256" => result_sha
          )
          existing = data.fetch("execution").fetch("tasks")[task_id]
          if existing && existing != accepted_record
            raise Error.new(
              "execution_record_conflict", "accepted task execution evidence is immutable",
              {"task_id" => task_id}, 3
            )
          end
          data.fetch("execution").fetch("tasks")[task_id] = accepted_record
        end
        self.class.validate_snapshot!(manifest, data)

        created_result = false
        state_published = false
        begin
          Atomic.with_relative_directory(
            run_directory, "results",
            code: "unsafe_result_path",
            expected_identity: @results_identity
          ) do |results_directory|
            name = "#{task_id}.json"
            if Atomic.reject_relative_nonregular(results_directory, name, "result_collision")
              orphan, orphan_bytes = read_json_bytes_relative!(
                results_directory, name, "invalid_result_file"
              )
              unless orphan == result_value && orphan_bytes == result_bytes
                invalid_result!(
                  "result_collision", "existing result bytes belong to a different payload",
                  {"task_id" => task_id}
                )
              end
            else
              Atomic.write_new_json(results_directory, name, result_value)
              created_result = true
            end
          end
          Atomic.write_json_relative(
            run_directory, "state.json", data,
            on_publish: -> { state_published = true }
          )
        rescue StandardError => error
          if state_published
            @manifest = manifest
            @data = data
            raise Error.new(
              "durability_uncertain",
              "state and result are visible but directory durability could not be confirmed",
              {"task_id" => task_id, "cause" => error.class.name, "message" => error.message}, 3
            )
          end
          raise
        ensure
          if created_result && !state_published
            Atomic.with_relative_directory(
              run_directory, "results",
              code: "unsafe_result_path",
              expected_identity: @results_identity
            ) do |results_directory|
              Atomic.unlink_relative(results_directory, "#{task_id}.json")
              results_directory.fsync
            end
          end
        end
        @manifest = manifest
        @data = data
      end
      deep_freeze(deep_copy(summary))
    end

    def transition_to(next_stage)
      mutate! do |data, manifest|
        current = data.fetch("stage")
        unless TRANSITIONS.fetch(current, []).include?(next_stage)
          raise Error.new(
            "invalid_transition", "state transition is not allowed",
            {"from" => current, "to" => next_stage}, 3
          )
        end
        if next_stage == "fresh-sweep"
          if data.fetch("revise_round") >= 2
            raise Error.new(
              "revise_round_cap", "review cannot enter a third revise round",
              {"revise_round" => data.fetch("revise_round")}, 3
            )
          end
          data["revise_round"] += 1
          data["fresh_sweep_required"] = true
          data["fresh_sweep_completed"] = false
        elsif next_stage == "culling-new-findings" && %w[fresh-sweep deduplicating].include?(current)
          data["fresh_sweep_completed"] = true
        end
        if next_stage == "complete"
          if manifest.key?("repository")
            live_digests = live_target_digests!(manifest)
            unless live_digests == data.fetch("current_target_digests")
              invalid_result!(
                "target_digest_mismatch", "live target bytes do not match authoritative state",
                {"expected" => data.fetch("current_target_digests"), "current" => live_digests}
              )
            end
          end
          blockers = completion_blockers(data, from_stage: current)
          unless can_complete?(data, from_stage: current)
            raise Error.new(
              "completion_blocked", "review state does not satisfy completion invariants",
              {"blockers" => blockers}, 3
            )
          end
        end
        data["stage"] = next_stage
        data["next_action"] = NEXT_ACTIONS.fetch(next_stage)
        data.fetch("events") << {"type" => "transition", "from" => current, "to" => next_stage}
      end
      self
    end

    alias transition transition_to

    def can_complete?(data = nil, from_stage: nil)
      unless data
        refresh!
        data = @data
      end
      from_stage ||= data.fetch("stage")
      completion_blockers(data, from_stage: from_stage).empty?
    end

    def ingest_candidate(angle, attempt, finding)
      unless finding.is_a?(Hash) && (finding.keys & %w[id state angle attempt sequence candidate_ids]).empty?
        raise Error.new("invalid_finding", "candidate finding contains reserved or invalid fields", {}, 3)
      end
      unless attempt.is_a?(Integer) && attempt.positive?
        raise Error.new("invalid_attempt", "candidate attempt must be a positive integer", {"attempt" => attempt}, 3)
      end
      slug = sanitize_angle(angle)
      created = nil
      mutate! do |data|
        ensure_mutation_stage!(data, "ingest_candidate")
        sequence = data.fetch("candidates").count do |candidate|
          candidate.fetch("angle") == slug && candidate.fetch("attempt") == attempt
        end + 1
        id = "C-#{slug}-#{attempt}-#{sequence}"
        if data.fetch("candidates").any? { |candidate| candidate.fetch("id") == id }
          raise Error.new("candidate_collision", "candidate ID already exists", {"id" => id}, 3)
        end
        created = deep_copy(finding).merge(
          "id" => id,
          "state" => "candidate",
          "angle" => slug,
          "attempt" => attempt,
          "sequence" => sequence,
          "round" => data.fetch("revise_round")
        )
        data.fetch("candidates") << created
      end
      deep_freeze(deep_copy(created))
    end

    def promote(groups)
      unless groups.is_a?(Array)
        raise Error.new("invalid_promotion", "promotion groups must be an array", {}, 3)
      end
      promoted = nil
      mutate! do |data|
        ensure_mutation_stage!(data, "promote")
        promoted = apply_promotions_to_data!(data, groups)
        rerank_reported_findings!(data)
      end
      deep_freeze(deep_copy(promoted))
    end

    def candidates
      to_h.fetch("candidates")
    end

    def candidate(id)
      item = candidates.find { |candidate_item| candidate_item.fetch("id") == id }
      raise Error.new("unknown_candidate", "candidate does not exist", {"id" => id}, 3) unless item

      item
    end

    def findings
      to_h.fetch("findings")
    end

    def record_author_action(finding_id, action)
      mutate! do |data|
        ensure_mutation_stage!(data, "record_author_action")
        find_finding!(data, finding_id)
        status = action.is_a?(Hash) ? action["status"] : action
        unless %w[fixed rejected].include?(status)
          raise Error.new(
            "invalid_author_action", "author action status must be fixed or rejected",
            {"id" => finding_id, "status" => status}, 3
          )
        end
        resolution = data.fetch("resolution_checks")[finding_id]
        if self.class.terminal_pairing(action, resolution) == :invalid
          raise Error.new(
            "invalid_author_action", "author action conflicts with the recorded resolution",
            {"id" => finding_id, "status" => status, "resolution" => resolution}, 3
          )
        end
        data.fetch("author_actions")[finding_id] = deep_copy(action)
      end
      self
    end

    def record_resolution(finding_id, status)
      allowed = %w[pending resolved rejected contested stuck]
      unless allowed.include?(status)
        raise Error.new("invalid_resolution", "resolution state is invalid", {"status" => status}, 3)
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "record_resolution")
        finding = find_finding!(data, finding_id)
        if status == "stuck" && data.fetch("revise_round") < 2
          raise Error.new(
            "invalid_resolution", "a finding cannot be stuck before the revise-round cap",
            {"id" => finding_id, "revise_round" => data.fetch("revise_round")}, 3
          )
        end
        action = data.fetch("author_actions")[finding_id]
        if self.class.terminal_pairing(action, status) == :invalid
          raise Error.new(
            "invalid_resolution", "resolution conflicts with the recorded author action",
            {"id" => finding_id, "status" => status}, 3
          )
        end
        data.fetch("resolution_checks")[finding_id] = status
        finding["state"] = status
      end
      self
    end

    def record_nonblocking_evidence_gap(finding_id, rationale)
      unless rationale.is_a?(String) && !rationale.strip.empty?
        raise Error.new(
          "invalid_overflow_evidence_gap", "overflow evidence-gap rationale must be nonempty",
          {"id" => finding_id}, 3
        )
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "record_nonblocking_evidence_gap")
        finding = find_finding!(data, finding_id)
        unless finding.fetch("reported") == false &&
               %w[MEDIUM LOW].include?(finding.fetch("severity")) &&
               data.fetch("overflow").fetch("items").include?(finding_id)
          raise Error.new(
            "invalid_overflow_evidence_gap",
            "only unreported MEDIUM or LOW overflow findings may be marked nonblocking",
            {"id" => finding_id, "severity" => finding.fetch("severity"),
             "reported" => finding.fetch("reported")}, 3
          )
        end
        data.fetch("overflow_evidence_gaps")[finding_id] = {
          "rationale" => rationale.strip,
          "recorded_at_stage" => data.fetch("stage"),
          "round" => data.fetch("revise_round")
        }
      end
      self
    end

    def set_pending_arbiter_subjects(finding_ids)
      unless finding_ids.is_a?(Array) && finding_ids.all? { |id| id.is_a?(String) }
        raise Error.new("invalid_arbiter_subjects", "arbiter subjects must be finding IDs", {}, 3)
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "set_pending_arbiter_subjects")
        finding_ids.each do |id|
          known = data.fetch("findings").any? { |finding| finding.fetch("id") == id } ||
            data.fetch("candidates").any? { |candidate| candidate.fetch("id") == id } ||
            data.fetch("semantic_groups").key?(id)
          unless known
            raise Error.new("unknown_arbiter_subject", "arbiter subject does not exist", {"id" => id}, 3)
          end
        end
        data["pending_arbiter_subjects"] = finding_ids.uniq.sort
      end
      self
    end

    def require_fresh_sweep!
      mutate! do |data|
        ensure_mutation_stage!(data, "require_fresh_sweep")
        data["fresh_sweep_required"] = true
        data["fresh_sweep_completed"] = false
      end
      self
    end

    def mark_fresh_sweep_completed!
      mutate! do |data|
        ensure_mutation_stage!(data, "mark_fresh_sweep_completed")
        data["fresh_sweep_completed"] = true
      end
      self
    end

    def record_degraded_capability(capability)
      unless capability.is_a?(String) && !capability.empty?
        raise Error.new("invalid_capability", "degraded capability must be named", {}, 3)
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "record_degraded_capability")
        data.fetch("degraded_capabilities") << capability
        data.fetch("degraded_capabilities").uniq!
        data.fetch("degraded_capabilities").sort!
      end
      self
    end

    def update_current_digests(digests)
      validate_digest_set!(digests)
      mutate! do |data|
        ensure_mutation_stage!(data, "update_current_digests")
        unless digests.keys.sort == data.fetch("current_target_digests").keys.sort
          raise Error.new("target_digest_mismatch", "target digest paths changed", {"current" => digests}, 3)
        end
        snapshot = deep_copy(digests)
        data["current_target_digests"] = snapshot
        data.fetch("target_digest_history") << deep_copy(snapshot)
      end
      self
    end

    def pin_executor!(executor)
      unless Manifest::EXECUTORS.include?(executor) && executor != "auto"
        raise Error.new("invalid_executor", "selected executor is invalid", {"executor" => executor}, 3)
      end
      mutate! do |data|
        execution = data.fetch("execution")
        selected = execution.fetch("selected_executor")
        if execution.fetch("executor_pinned")
          next if selected == executor
          raise Error.new(
            "executor_already_pinned", "selected executor cannot change after it is pinned",
            {"selected_executor" => selected, "requested" => executor}, 3
          )
        end
        unless executor == selected || executor == "generic"
          raise Error.new(
            "invalid_executor_pin", "unbound executor may pin only its selected candidate or generic fallback",
            {"selected_executor" => selected, "requested" => executor}, 3
          )
        end
        execution["selected_executor"] = executor
        execution["executor_pinned"] = true
      end
      self
    end

    def begin_selection_intent!(task_id:, requested_executor:, candidate_executor:, vendor:,
                                model:, effort:, stage:)
      validate_task_id!(task_id)
      intent = {
        "status" => "active", "requested_executor" => requested_executor,
        "candidate_executor" => candidate_executor, "vendor" => vendor,
        "model" => model, "effort" => effort, "stage" => stage,
        "task_id" => task_id, "external_attempts" => 0,
        "outcome_executor" => nil, "error_code" => nil, "phase" => nil
      }
      mutate! do |data, manifest|
        execution = data.fetch("execution")
        unless requested_executor == manifest.fetch("requested_executor") &&
               candidate_executor == execution.fetch("selected_executor") &&
               vendor == candidate_executor && candidate_executor != "generic" &&
               Manifest::EXECUTORS.include?(candidate_executor) &&
               model == manifest.fetch("requested_model") &&
               effort == manifest.fetch("requested_effort") && stage == data.fetch("stage")
          raise Error.new("invalid_selection_intent", "executor selection intent does not match the run", {}, 3)
        end
        existing = execution["selection_intent"]
        if existing
          next if existing == intent
          raise Error.new("selection_intent_conflict", "executor selection intent is immutable", {}, 3)
        end
        execution["selection_intent"] = intent
      end
      self
    end

    def mark_selection_call_started!(task_id)
      validate_task_id!(task_id)
      mutate! do |data|
        intent = data.dig("execution", "selection_intent")
        unless intent.is_a?(Hash) && intent["status"] == "active" &&
               intent["task_id"] == task_id && data.fetch("emitted_tasks").key?(task_id)
          raise Error.new("selection_call_not_authorized", "external selection call lacks durable intent and task", {}, 3)
        end
        intent["external_attempts"] += 1
      end
      self
    end

    def finalize_selection_intent!(task_id:, executor:, status:, error_code:, phase:,
                                   content_sent:, prompt_bytes:, selected_executor:)
      validate_task_id!(task_id)
      validate_dispatch_attempt!(task_id: task_id, executor: executor, status: status,
                                 error_code: error_code, phase: phase,
                                 content_sent: content_sent, prompt_bytes: prompt_bytes)
      mutate! do |data|
        execution = data.fetch("execution")
        intent = execution["selection_intent"]
        unless intent.is_a?(Hash) && intent["task_id"] == task_id &&
               intent["candidate_executor"] == executor
          raise Error.new("selection_intent_missing", "selection result lacks its durable intent", {}, 3)
        end
        if intent["status"] == "terminal"
          next if intent["outcome_executor"] == selected_executor
          raise Error.new("selection_intent_conflict", "terminal selection outcome is immutable", {}, 3)
        end
        unless intent["status"] == "active" &&
               [executor, "generic"].include?(selected_executor) &&
               (selected_executor != "generic" ||
                (intent["requested_executor"] == "auto" &&
                 intent["external_attempts"] == 1 && status == "fallback" &&
                 !content_sent && %w[probe preflight].include?(phase)))
          raise Error.new("invalid_selection_outcome", "selection outcome is not eligible", {}, 3)
        end
        if execution.fetch("executor_pinned") && execution.fetch("selected_executor") != selected_executor
          raise Error.new("executor_already_pinned", "selected executor cannot change after it is pinned", {}, 3)
        end
        execution["selected_executor"] = selected_executor
        execution["executor_pinned"] = true
        intent["status"] = "terminal"
        intent["outcome_executor"] = selected_executor
        intent["error_code"] = error_code
        intent["phase"] = phase
        execution.fetch("dispatch_attempts") << dispatch_attempt_record(
          task_id: task_id, executor: executor, status: status, error_code: error_code,
          phase: phase, content_sent: content_sent, prompt_bytes: prompt_bytes
        )
      end
      self
    end

    def record_dispatch_attempt!(task_id:, executor:, status:, error_code:, phase:,
                                 content_sent:, prompt_bytes:)
      validate_dispatch_attempt!(task_id: task_id, executor: executor, status: status,
                                 error_code: error_code, phase: phase,
                                 content_sent: content_sent, prompt_bytes: prompt_bytes)
      mutate! do |data|
        data.fetch("execution").fetch("dispatch_attempts") << dispatch_attempt_record(
          task_id: task_id, executor: executor, status: status, error_code: error_code,
          phase: phase, content_sent: content_sent, prompt_bytes: prompt_bytes
        )
      end
      self
    end

    def claim_dispatch!(task_id, owner_token)
      validate_task_id!(task_id)
      unless owner_token.is_a?(String) && owner_token.match?(/\A[0-9a-f]{32}\z/)
        raise Error.new("invalid_dispatch_claim", "dispatch owner token is malformed", {}, 3)
      end
      mutate! do |data|
        unless data.fetch("emitted_tasks").key?(task_id)
          raise Error.new("unknown_task", "dispatch claim task was not emitted", {"task_id" => task_id}, 3)
        end
        data.fetch("execution").fetch("dispatch_claims")[task_id] = owner_token
      end
      self
    end

    def release_dispatch_claim!(task_id, owner_token)
      validate_task_id!(task_id)
      mutate! do |data|
        claims = data.fetch("execution").fetch("dispatch_claims")
        claims.delete(task_id) if claims[task_id] == owner_token
      end
      self
    end

    def record_task_execution(task_id, authority:, capabilities:, usage:, attempts:,
                              runtime_provenance:)
      record = build_execution_record!(
        task_id, authority: authority, capabilities: capabilities, usage: usage,
        attempts: attempts, runtime_provenance: runtime_provenance
      )
      mutate! do |data|
        unless data.fetch("emitted_tasks").key?(task_id)
          raise Error.new("unknown_task", "execution record task was not emitted", {"task_id" => task_id}, 3)
        end
        existing = data.fetch("execution").fetch("tasks")[task_id]
        if existing && existing != record
          raise Error.new("execution_record_conflict", "task execution evidence is immutable", {"task_id" => task_id}, 3)
        end
        data.fetch("execution").fetch("tasks")[task_id] = record
      end
      self
    rescue Capabilities::Error => error
      raise Error.new("invalid_execution_record", error.message, {}, 3)
    end

    def record_result_repair!(task_id, reason:)
      validate_task_id!(task_id)
      unless reason == "missing_required_checks"
        raise Error.new("invalid_repair", "result repair reason is unsupported", {}, 3)
      end
      mutate! do |data|
        unless data.fetch("emitted_tasks").key?(task_id) &&
               !data.fetch("ingested_results").key?(task_id)
          raise Error.new("unknown_task", "result repair requires a pending emitted task",
                          {"task_id" => task_id}, 3)
        end
        if data.fetch("result_repairs").key?(task_id)
          raise Error.new("repair_exhausted", "task already consumed its one result repair",
                          {"task_id" => task_id}, 3)
        end
        data.fetch("result_repairs")[task_id] = {
          "count" => 1, "reason" => reason
        }
      end
      1
    end

    def refresh_targets_after_actions!
      result = nil
      mutate! do |data, manifest|
        unless data.fetch("stage") == "awaiting-author"
          raise Error.new("invalid_stage", "target refresh requires awaiting-author", {"stage" => data.fetch("stage")}, 3)
        end
        actionable_ids = data.fetch("findings").select { |finding| finding.fetch("reported") }
                             .map { |finding| finding.fetch("id") }
        missing = actionable_ids.reject { |finding_id| data.fetch("author_actions").key?(finding_id) }
        unless missing.empty?
          raise Error.new("missing_author_actions", "target refresh requires complete parent actions", {"finding_ids" => missing}, 3)
        end
        target_paths = manifest.fetch("targets").map { |target| target.fetch("path") }
        fixed_actions = data.fetch("author_actions").values.select do |action|
          action.is_a?(Hash) && action.fetch("status") == "fixed"
        end
        declared = fixed_actions.flat_map { |action| action.fetch("changed_paths", []) }.uniq.sort
        live = live_target_digests!(manifest)
        changed = target_paths.select do |path|
          live.fetch(path) != data.fetch("current_target_digests").fetch(path)
        end.sort
        unless changed == declared && (fixed_actions.empty? || !changed.empty?)
          raise Error.new(
            "author_change_mismatch", "live target changes do not match declared parent action paths",
            {"changed_targets" => changed, "declared_target_paths" => declared}, 3
          )
        end
        unless changed.empty?
          data["current_target_digests"] = deep_copy(live)
          data.fetch("target_digest_history") << deep_copy(live)
          data["fresh_sweep_required"] = true
          data["fresh_sweep_completed"] = false
        end
        data.fetch("events") << {"type" => "target-refresh", "changed_targets" => changed}
        result = {"changed_targets" => changed, "current_target_digests" => deep_copy(live)}
      end
      deep_freeze(deep_copy(result))
    end

    def persist_summary!(summary)
      Reporting.chat_payload(summary)
      mutate! do |data|
        existing = data.fetch("summary")
        if existing && existing != summary
          raise Error.new("summary_conflict", "terminal summary is immutable", {}, 3)
        end
        data["summary"] = deep_copy(summary)
      end
      self
    rescue Reporting::Error => error
      raise Error.new(error.code, error.message, error.details, error.exit_status)
    end

    def check_current_digests!(digests)
      validate_digest_set!(digests)
      refresh!
      return true if @data.fetch("current_target_digests") == digests

      raise Error.new(
        "target_digest_mismatch", "observed target digests do not match current state",
        {"expected" => @data.fetch("current_target_digests"), "current" => digests}, 3
      )
    end

    def apply_arbiter(finding_id, verdict)
      unless %w[author-is-right judge-is-right needs-human].include?(verdict)
        raise Error.new("invalid_arbiter_verdict", "arbiter verdict is invalid", {"verdict" => verdict}, 3)
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "apply_arbiter")
        finding = find_finding!(data, finding_id)
        case verdict
        when "author-is-right"
          finding["state"] = "rejected"
          data.fetch("resolution_checks")[finding_id] = "rejected"
          data.fetch("pending_arbiter_subjects").delete(finding_id)
        when "judge-is-right"
          state = data.fetch("revise_round") >= 2 ? "stuck" : "contested"
          finding["state"] = state
          data.fetch("resolution_checks")[finding_id] = state
          data.fetch("pending_arbiter_subjects").delete(finding_id)
        when "needs-human"
          finding["state"] = "contested"
          data.fetch("resolution_checks")[finding_id] = "contested"
          data.fetch("pending_arbiter_subjects") << finding_id
          data.fetch("pending_arbiter_subjects").uniq!
          data.fetch("pending_arbiter_subjects").sort!
        end
      end
      self
    end

    private

    def self.validate_run_id!(run_id)
      return if run_id.is_a?(String) && RUN_ID.match?(run_id) && run_id != "." && run_id != ".."

      raise Error.new("invalid_run_id", "run ID contains unsafe characters", {"run_id" => run_id})
    end

    def self.secure_run_directory(run_dir)
      expanded = Atomic.normalize_root_alias(File.expand_path(run_dir))
      Atomic.secure_directory(File.dirname(expanded))
      stat = File.lstat(expanded)
      unless stat.directory? && !stat.symlink?
        raise Error.new("unsafe_run_dir", "run directory must be a real directory", {"run_dir" => expanded})
      end
      File.realpath(expanded)
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
      raise Error.new("unsafe_run_dir", "run directory could not be opened safely", {"run_dir" => expanded, "cause" => error.class.name})
    end

    def self.validate_snapshot!(manifest, data)
      unless manifest.is_a?(Hash) && data.is_a?(Hash)
        raise Error.new("invalid_state", "manifest and state must be JSON objects", {}, 3)
      end
      required = %w[
        schema_version run_id mode stage revise_round task_attempts emitted_tasks candidates findings
        result_repairs
        ingested_results exact_duplicate_map exact_duplicate_sources semantic_groups
        judge_votes evidence_gaps overflow overflow_evidence_gaps
        author_actions resolution_checks pending_arbiter_subjects target_digest_history
        current_target_digests fresh_sweep_required fresh_sweep_completed
        degraded_capabilities execution summary events next_action
      ]
      missing = required.reject { |key| data.key?(key) }
      unless missing.empty?
        raise Error.new("invalid_state", "persisted state is incomplete", {"missing" => missing}, 3)
      end
      unless manifest["run_id"] == data["run_id"] && data["schema_version"] == 1 &&
             manifest["schema_version"] == 1 && RUN_ID.match?(data["run_id"].to_s)
        raise Error.new("invalid_state", "manifest and state identities do not match", {}, 3)
      end
      valid_stages = TRANSITIONS.keys + %w[complete did-not-converge]
      unless valid_stages.include?(data["stage"]) && %w[critique revise].include?(data["mode"]) &&
             manifest["mode"] == data["mode"] && [1, 2].include?(data["revise_round"])
        raise Error.new("invalid_state", "persisted stage, mode, or revise round is invalid", {}, 3)
      end
      unless data["next_action"] == NEXT_ACTIONS.fetch(data["stage"])
        raise Error.new("invalid_state", "persisted next action does not match the stage", {}, 3)
      end
      unless data["target_digest_history"].is_a?(Array) && !data["target_digest_history"].empty? &&
             data["target_digest_history"].all? { |entry| entry.is_a?(Hash) } &&
             data["current_target_digests"].is_a?(Hash)
        raise Error.new("invalid_state", "target digest state is invalid", {}, 3)
      end
      initial_digests = target_digests(manifest)
      unless data["target_digest_history"].first == initial_digests
        raise Error.new("invalid_state", "initial target digest history was rewritten", {}, 3)
      end
      digest_keys = initial_digests.keys.sort
      valid_history = data.fetch("target_digest_history").all? do |entry|
        valid_digest_mapping?(entry) && entry.keys.sort == digest_keys
      end
      unless valid_history && valid_digest_mapping?(data.fetch("current_target_digests")) &&
             data.fetch("current_target_digests").keys.sort == digest_keys
        raise Error.new("invalid_state", "target digest history contains invalid snapshots", {}, 3)
      end
      unless data["candidates"].is_a?(Array) && data["findings"].is_a?(Array) &&
             data["task_attempts"].is_a?(Hash) && data["emitted_tasks"].is_a?(Hash) &&
             data["result_repairs"].is_a?(Hash) &&
             data["author_actions"].is_a?(Hash) &&
             data["ingested_results"].is_a?(Hash) && data["exact_duplicate_map"].is_a?(Hash) &&
             data["exact_duplicate_sources"].is_a?(Hash) && data["semantic_groups"].is_a?(Hash) &&
             data["judge_votes"].is_a?(Hash) && data["evidence_gaps"].is_a?(Array) &&
             data["overflow"].is_a?(Hash) && data["overflow_evidence_gaps"].is_a?(Hash) &&
             data["resolution_checks"].is_a?(Hash) && data["pending_arbiter_subjects"].is_a?(Array) &&
             data["degraded_capabilities"].is_a?(Array) && data["events"].is_a?(Array) &&
             [true, false].include?(data["fresh_sweep_required"]) &&
             [true, false].include?(data["fresh_sweep_completed"])
        raise Error.new("invalid_state", "persisted state collections are invalid", {}, 3)
      end
      bounded_collections = %w[
        candidates findings task_attempts emitted_tasks ingested_results exact_duplicate_map
        result_repairs
        exact_duplicate_sources semantic_groups judge_votes evidence_gaps overflow_evidence_gaps
        author_actions resolution_checks pending_arbiter_subjects degraded_capabilities events
      ]
      unless bounded_collections.all? { |key| data.fetch(key).length <= MAX_STATE_ITEMS }
        raise Error.new("state_limit_exceeded", "persisted state collection exceeds its bound", {}, 3)
      end
      valid_repairs = data.fetch("result_repairs").all? do |task_id, repair|
        data.fetch("emitted_tasks").key?(task_id) && repair.is_a?(Hash) &&
          repair.keys.sort == %w[count reason] && repair["count"] == 1 &&
          repair["reason"] == "missing_required_checks"
      end
      unless valid_repairs
        raise Error.new("invalid_state", "persisted result repairs are invalid", {}, 3)
      end
      execution = data.fetch("execution")
      unless execution.is_a?(Hash) && execution.keys.sort == %w[dispatch_attempts dispatch_claims executor_pinned jobs metadata_required report_path selected_executor selection_intent tasks] &&
             Manifest::EXECUTORS.include?(execution["selected_executor"]) && execution["selected_executor"] != "auto" &&
             [true, false].include?(execution["executor_pinned"]) &&
             execution["jobs"].is_a?(Integer) && execution["jobs"].positive? &&
             [true, false].include?(execution["metadata_required"]) &&
             (execution["report_path"].nil? || execution["report_path"].is_a?(String)) &&
             execution["tasks"].is_a?(Hash) &&
             execution["dispatch_claims"].is_a?(Hash) &&
             (data["summary"].nil? || data["summary"].is_a?(Hash))
        raise Error.new("invalid_state", "persisted execution metadata is invalid", {}, 3)
      end
      valid_dispatch_attempts = execution.fetch("dispatch_attempts").is_a?(Array) &&
        execution.fetch("dispatch_attempts").all? do |attempt|
          attempt.is_a?(Hash) &&
            attempt.keys.sort == %w[content_sent error_code executor phase prompt_bytes status task_id] &&
            attempt["task_id"].is_a?(String) && RUN_ID.match?(attempt["task_id"]) &&
            Manifest::EXECUTORS.include?(attempt["executor"]) && attempt["executor"] != "auto" &&
            %w[complete failed fallback].include?(attempt["status"]) &&
            (attempt["error_code"].nil? ||
             (attempt["error_code"].is_a?(String) && !attempt["error_code"].empty?)) &&
            %w[probe preflight execution].include?(attempt["phase"]) &&
            [true, false].include?(attempt["content_sent"]) &&
            attempt["prompt_bytes"].is_a?(Integer) && attempt["prompt_bytes"].positive?
        end
      unless valid_dispatch_attempts
        raise Error.new("invalid_state", "persisted dispatch attempt evidence is invalid", {}, 3)
      end
      if execution.fetch("dispatch_attempts").length > MAX_STATE_ITEMS ||
         execution.fetch("tasks").length > MAX_STATE_ITEMS ||
         execution.fetch("dispatch_claims").length > MAX_STATE_ITEMS
        raise Error.new("state_limit_exceeded", "execution collection exceeds its bound", {}, 3)
      end
      valid_claims = execution.fetch("dispatch_claims").all? do |task_id, token|
        data.fetch("emitted_tasks").key?(task_id) && token.is_a?(String) &&
          token.match?(/\A[0-9a-f]{32}\z/)
      end
      unless valid_claims
        raise Error.new("invalid_state", "persisted dispatch claims are invalid", {}, 3)
      end
      intent = execution["selection_intent"]
      valid_intent = intent.nil? || (
        intent.is_a?(Hash) &&
        intent.keys.sort == %w[candidate_executor effort error_code external_attempts model outcome_executor phase requested_executor stage status task_id vendor] &&
        %w[active terminal].include?(intent["status"]) &&
        Manifest::EXECUTORS.include?(intent["requested_executor"]) &&
        intent["requested_executor"] == manifest.fetch("requested_executor") &&
        Manifest::EXECUTORS.include?(intent["candidate_executor"]) &&
        !%w[auto generic].include?(intent["candidate_executor"]) &&
        intent["vendor"] == intent["candidate_executor"] &&
        intent["model"] == manifest.fetch("requested_model") &&
        intent["effort"] == manifest.fetch("requested_effort") &&
        (TRANSITIONS.keys + %w[complete did-not-converge]).include?(intent["stage"]) &&
        intent["task_id"].is_a?(String) && RUN_ID.match?(intent["task_id"]) &&
        intent["external_attempts"].is_a?(Integer) && intent["external_attempts"] >= 0 &&
        (intent["status"] == "active" ?
          intent.values_at("outcome_executor", "error_code", "phase").all?(&:nil?) :
          (Manifest::EXECUTORS.include?(intent["outcome_executor"]) &&
           intent["outcome_executor"] != "auto" &&
           (intent["error_code"].nil? || intent["error_code"].is_a?(String)) &&
           %w[probe preflight execution].include?(intent["phase"])))
      )
      unless valid_intent
        raise Error.new("invalid_state", "persisted selection intent is invalid", {}, 3)
      end
      if execution.fetch("executor_pinned") == false &&
         manifest.fetch("requested_executor", "generic") != "auto"
        raise Error.new("invalid_state", "only auto selection may remain unpinned", {}, 3)
      end
      if execution.fetch("executor_pinned") == false
        allowed_ids = intent && intent["status"] == "active" ? [intent["task_id"]] : []
        evidence_ids = data.fetch("emitted_tasks").keys |
          data.fetch("ingested_results").keys | execution.fetch("tasks").keys |
          execution.fetch("dispatch_claims").keys
        unless (evidence_ids - allowed_ids).empty? && execution.fetch("dispatch_attempts").empty?
          raise Error.new("invalid_state", "unpinned executor state contains unauthorized task evidence", {}, 3)
        end
      end
      valid_execution_tasks = execution.fetch("tasks").all? do |task_id, record|
        base_keys = %w[attempts authority capabilities runtime_provenance usage]
        accepted_keys = base_keys + %w[result_sha256 task_sha256]
        next false unless data.fetch("emitted_tasks").key?(task_id) && record.is_a?(Hash) &&
                          [base_keys.sort, accepted_keys.sort].include?(record.keys.sort)
        if record.key?("result_sha256")
          ingestion = data.fetch("ingested_results")[task_id]
          next false unless ingestion && record["result_sha256"] == ingestion["sha256"] &&
                            record["task_sha256"] == ingestion["task_sha256"]
        end
        authority = record["authority"]
        valid_capabilities = if authority == "reviewer"
                               begin
                                 Capabilities.gate(record["capabilities"], "PASS")
                                 true
                               rescue Capabilities::Error
                                 false
                               end
                             else
                               authority == "parent" && record["capabilities"].nil?
                             end
        valid_capabilities && record["attempts"].is_a?(Integer) && record["attempts"] >= 0 &&
          record["usage"].is_a?(Hash) && record["usage"].all? do |key, value|
            key.is_a?(String) && value.is_a?(Integer) && value >= 0
          end && record["runtime_provenance"].is_a?(Hash)
      end
      unless valid_execution_tasks
        raise Error.new("invalid_state", "persisted task execution evidence is invalid", {}, 3)
      end
      valid_attempts = data.fetch("task_attempts").all? do |task_id, attempt|
        task_id.is_a?(String) && !task_id.empty? && attempt.is_a?(Integer) && !attempt.negative?
      end
      valid_emitted_tasks = data.fetch("emitted_tasks").all? do |task_id, record|
        record.is_a?(Hash) && record.keys.sort == %w[angle attempt kind round sha256 task_id] &&
          record["task_id"] == task_id && task_id.is_a?(String) && RUN_ID.match?(task_id) &&
          RESULT_SCHEMAS.include?(record["kind"]) &&
          (record["angle"].nil? || (record["angle"].is_a?(String) && !record["angle"].empty?)) &&
          [1, 2].include?(record["round"]) && record["attempt"].is_a?(Integer) &&
          record["attempt"].positive? && record["sha256"].is_a?(String) &&
          record["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
          data.fetch("task_attempts")[task_id] == record["attempt"] &&
          valid_authoritative_task_record?(task_id, record, manifest)
      end
      valid_events = data.fetch("events").all? { |event| valid_event_snapshot?(event) }
      unless valid_attempts && valid_emitted_tasks &&
             data.fetch("task_attempts").keys.sort == data.fetch("emitted_tasks").keys.sort && valid_events
        raise Error.new("invalid_state", "persisted attempts or events are invalid", {}, 3)
      end
      unless valid_ingestion_snapshot?(data)
        raise Error.new("invalid_state", "persisted result-ingestion state is invalid", {}, 3)
      end
      unless data.fetch("candidates").all? { |candidate| valid_candidate_snapshot?(candidate) }
        raise Error.new("invalid_state", "persisted candidates are invalid", {}, 3)
      end
      candidate_ids = data.fetch("candidates").map { |candidate| candidate.is_a?(Hash) ? candidate["id"] : nil }
      duplicate_candidate_id = candidate_ids.compact.group_by { |id| id }.find { |_id, ids| ids.length > 1 }
      if duplicate_candidate_id
        raise Error.new(
          "candidate_collision", "persisted candidate IDs are not unique",
          {"id" => duplicate_candidate_id.first}, 3
        )
      end
      candidates_by_id = data.fetch("candidates").each_with_object({}) do |candidate, indexed|
        indexed[candidate.fetch("id")] = candidate
      end
      unless data.fetch("findings").all? do |finding|
               valid_finding_snapshot?(finding, candidates_by_id)
             end
        raise Error.new("invalid_state", "persisted findings are invalid", {}, 3)
      end
      finding_ids = data.fetch("findings").map { |finding| finding.is_a?(Hash) ? finding["id"] : nil }
      if finding_ids.any?(&:nil?) || finding_ids.uniq.length != finding_ids.length
        raise Error.new("finding_collision", "persisted finding IDs are invalid or non-unique", {}, 3)
      end
      fingerprint = Digest::SHA256.hexdigest(data.fetch("run_id"))[0, 8]
      expected_finding_ids = finding_ids.each_index.map do |index|
        format("AR-%s-%03d", fingerprint, index + 1)
      end
      unless finding_ids == expected_finding_ids
        raise Error.new(
          "finding_collision", "persisted finding IDs do not match deterministic run order",
          {"expected" => expected_finding_ids, "current" => finding_ids}, 3
        )
      end
      findings_by_id = data.fetch("findings").each_with_object({}) do |finding, indexed|
        indexed[finding.fetch("id")] = finding
      end
      source_counts = Hash.new(0)
      data.fetch("findings").each do |finding|
        finding.fetch("candidate_ids").each { |candidate_id| source_counts[candidate_id] += 1 }
      end
      valid_candidate_ownership = candidates_by_id.all? do |candidate_id, candidate|
        count = source_counts[candidate_id]
        candidate.fetch("state") == "promoted" ? count == 1 : count.zero?
      end
      unless valid_candidate_ownership && source_counts.values.all? { |count| count == 1 }
        raise Error.new("invalid_state", "promoted candidate ownership is invalid", {}, 3)
      end
      valid_actions = data.fetch("author_actions").all? do |finding_id, action|
        findings_by_id.key?(finding_id) && valid_author_action_snapshot?(action)
      end
      valid_resolutions = data.fetch("resolution_checks").all? do |finding_id, status|
        finding = findings_by_id[finding_id]
        finding && %w[pending resolved rejected contested stuck].include?(status) &&
          finding.fetch("state") == status &&
          (status != "stuck" || data.fetch("revise_round") == 2)
      end
      valid_arbiter_subjects = data.fetch("pending_arbiter_subjects").all? do |finding_id|
        findings_by_id.key?(finding_id) || candidates_by_id.key?(finding_id) ||
          data.fetch("semantic_groups").key?(finding_id)
      end
      valid_arbiter_subjects &&=
        data.fetch("pending_arbiter_subjects").uniq == data.fetch("pending_arbiter_subjects") &&
        data.fetch("pending_arbiter_subjects").sort == data.fetch("pending_arbiter_subjects")
      valid_pairings = finding_ids.all? do |finding_id|
        terminal_pairing(
          data.fetch("author_actions")[finding_id],
          data.fetch("resolution_checks")[finding_id]
        ) != :invalid
      end
      unless valid_actions && valid_resolutions && valid_arbiter_subjects && valid_pairings
        raise Error.new("invalid_state", "persisted finding disposition maps are invalid", {}, 3)
      end
      if %w[complete did-not-converge].include?(data.fetch("stage"))
        terminal_event = data.fetch("events").last
        unless terminal_event && terminal_event["type"] == "transition" &&
               terminal_event["to"] == data.fetch("stage")
          raise Error.new("invalid_state", "terminal state is missing its terminal transition", {}, 3)
        end
        if data.fetch("stage") == "complete" &&
           !completion_blockers(data, from_stage: terminal_event.fetch("from")).empty?
          raise Error.new("invalid_state", "complete state violates completion invariants", {}, 3)
        end
      end
      true
    rescue KeyError, TypeError => error
      raise Error.new("invalid_state", "persisted state structure is invalid", {"cause" => error.message}, 3)
    end

    def self.valid_candidate_snapshot?(candidate)
      return false unless candidate.is_a?(Hash)

      angle = candidate["angle"]
      attempt = candidate["attempt"]
      sequence = candidate["sequence"]
      expected_id = "C-#{angle}-#{attempt}-#{sequence}"
      candidate["id"] == expected_id &&
        angle.is_a?(String) && angle.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) &&
        attempt.is_a?(Integer) && attempt.positive? &&
        sequence.is_a?(Integer) && sequence.positive? &&
        [1, 2].include?(candidate["round"]) &&
        %w[candidate promoted refuted unproven].include?(candidate["state"]) &&
        (!candidate.key?("arbiter_decision") ||
         (%w[PROMOTE REFUTE UNPROVEN].include?(candidate["arbiter_decision"]) &&
          candidate["arbiter_evidence"].is_a?(String) && !candidate["arbiter_evidence"].strip.empty?))
    end

    def self.valid_authoritative_task_record?(task_id, record, manifest)
      match = task_id.match(/\A(?<prefix>.+)-r(?<round>[1-9]\d*)-a(?<attempt>[1-9]\d*)\z/)
      return false unless match && record["round"] == Integer(match[:round]) &&
                          record["attempt"] == Integer(match[:attempt]) &&
                          match[:prefix].start_with?("#{record["kind"]}-")

      angle = record["angle"]
      return true unless angle

      match[:prefix] == "#{record["kind"]}-#{angle}" &&
        (!manifest["enabled_tasks"].is_a?(Array) || manifest.fetch("enabled_tasks").include?(angle))
    rescue ArgumentError
      false
    end

    def self.valid_finding_snapshot?(finding, candidates_by_id)
      return false unless finding.is_a?(Hash)

      candidate_ids = finding["candidate_ids"]
      sources = finding["sources"]
      return false unless candidate_ids.is_a?(Array) && !candidate_ids.empty? &&
                          candidate_ids.all? { |id| id.is_a?(String) && candidates_by_id.key?(id) } &&
                          candidate_ids.uniq.length == candidate_ids.length &&
                          sources.is_a?(Array) && sources.length == candidate_ids.length

      sources_valid = sources.each_with_index.all? do |source, index|
        candidate = candidates_by_id[candidate_ids[index]]
        source.is_a?(Hash) && source["candidate_id"] == candidate.fetch("id") &&
          source["angle"] == candidate.fetch("angle") &&
          source["attempt"] == candidate.fetch("attempt")
      end
      sources_valid &&
        finding["id"].is_a?(String) && finding["id"].match?(/\AAR-[0-9a-f]{8}-\d{3,}\z/) &&
        finding["group_id"].is_a?(String) && !finding["group_id"].empty? &&
        SEVERITY_RANK.key?(finding["severity"]) && finding["confidence"].is_a?(Numeric) &&
        finding["path"].is_a?(String) && !finding["path"].empty? &&
        finding["line"].is_a?(Integer) && !finding["line"].negative? &&
        [1, 2].include?(finding["round"]) &&
        [true, false].include?(finding["reported"]) &&
        %w[pending resolved rejected contested stuck].include?(finding["state"])
    end

    def self.valid_author_action_snapshot?(action)
      return %w[fixed rejected].include?(action) unless action.is_a?(Hash)
      allowed = %w[status rationale changed_paths task_id]
      return false unless (action.keys - allowed).empty? && %w[fixed rejected].include?(action["status"])
      valid_rationale = !action.key?("rationale") ||
        (action["rationale"].is_a?(String) && !action["rationale"].strip.empty?)
      valid_paths = !action.key?("changed_paths") ||
        (action["changed_paths"].is_a?(Array) &&
         action["changed_paths"].all? { |path| safe_repository_relative_path?(path) })
      valid_task = !action.key?("task_id") ||
        (action["task_id"].is_a?(String) && RUN_ID.match?(action["task_id"]))
      valid_rationale && valid_paths && valid_task
    end

    def self.safe_repository_relative_path?(path)
      return false unless path.is_a?(String) && !path.empty?
      return false if path.match?(/[\x00-\x1f\x7f]/) || path.start_with?("/", "\\")
      return false if path.match?(/\A[A-Za-z]:/)

      path.split(/[\x2f\x5c]/, -1).none? do |segment|
        segment.empty? || segment == "." || segment == ".."
      end
    end

    def self.valid_event_snapshot?(event)
      return false unless event.is_a?(Hash) && event["type"].is_a?(String) && !event["type"].empty?
      return true unless event["type"] == "transition"

      from = event["from"]
      to = event["to"]
      from.is_a?(String) && to.is_a?(String) && TRANSITIONS.fetch(from, []).include?(to)
    end

    def self.valid_ingestion_snapshot?(data)
      candidate_records = {}
      findings_by_id = data.fetch("findings").each_with_object({}) do |finding, indexed|
        indexed[finding["id"]] = finding if finding.is_a?(Hash) && finding["id"].is_a?(String)
      end
      candidate_ids = data.fetch("candidates").each_with_object({}) do |candidate, indexed|
        if candidate.is_a?(Hash) && candidate["id"].is_a?(String)
          indexed[candidate["id"]] = true
          candidate_records[candidate["id"]] = candidate
        end
      end
      valid_results = data.fetch("ingested_results").all? do |task_id, record|
        emitted = data.fetch("emitted_tasks")[task_id]
        task_id.is_a?(String) && RUN_ID.match?(task_id) && record.is_a?(Hash) &&
          record.keys.sort == %w[round schema sha256 task_sha256] &&
          RESULT_SCHEMAS.include?(record["schema"]) && [1, 2].include?(record["round"]) &&
          [record["sha256"], record["task_sha256"]].all? do |digest|
            digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          end && emitted && emitted["sha256"] == record["task_sha256"]
      end
      valid_duplicate_map = data.fetch("exact_duplicate_map").all? do |fingerprint, candidate_id|
        fingerprint.is_a?(String) && fingerprint.match?(/\A[0-9a-f]{64}\z/) &&
          candidate_ids.key?(candidate_id)
      end
      valid_sources = data.fetch("exact_duplicate_sources").all? do |candidate_id, sources|
        candidate_ids.key?(candidate_id) && sources.is_a?(Array) && !sources.empty? &&
          sources.all? do |source|
            source.is_a?(Hash) &&
              source.keys.sort == %w[angle attempt finding_index round task_id] &&
              source["task_id"].is_a?(String) && RUN_ID.match?(source["task_id"]) &&
              data.fetch("ingested_results").key?(source["task_id"]) &&
              source["angle"].is_a?(String) && !source["angle"].empty? &&
              source["attempt"].is_a?(Integer) && source["attempt"].positive? &&
              [1, 2].include?(source["round"]) &&
              source["finding_index"].is_a?(Integer) && !source["finding_index"].negative?
          end
      end
      valid_duplicate_links = data.fetch("exact_duplicate_map").values.uniq.length ==
        data.fetch("exact_duplicate_map").values.length &&
        data.fetch("exact_duplicate_map").values.sort == data.fetch("exact_duplicate_sources").keys.sort
      valid_groups = data.fetch("semantic_groups").all? do |group_id, group|
        required_group_keys = %w[candidate_ids group_id location round source_angles summary task_id]
        allowed_group_keys = required_group_keys + %w[arbiter_decision arbiter_evidence]
        location = group["location"] if group.is_a?(Hash)
        source_angles = group["source_angles"] if group.is_a?(Hash)
        group.is_a?(Hash) && group_id == group["group_id"] &&
          group_id.is_a?(String) && !group_id.strip.empty? &&
          (required_group_keys - group.keys).empty? && (group.keys - allowed_group_keys).empty? &&
          group["summary"].is_a?(String) && !group["summary"].strip.empty? &&
          location.is_a?(Hash) && location.keys.sort == %w[heading line_end line_start path] &&
          location["path"].is_a?(String) && !location["path"].strip.empty? &&
          location["heading"].is_a?(String) && !location["heading"].strip.empty? &&
          location["line_start"].is_a?(Integer) && location["line_start"] >= 1 &&
          location["line_end"].is_a?(Integer) && location["line_end"] >= location["line_start"] &&
          source_angles.is_a?(Array) && !source_angles.empty? &&
          source_angles.uniq.length == source_angles.length &&
          source_angles.all? { |angle| angle.is_a?(String) && !angle.strip.empty? } &&
          group["candidate_ids"].is_a?(Array) && !group["candidate_ids"].empty? &&
          group["candidate_ids"].uniq.length == group["candidate_ids"].length &&
          group["candidate_ids"].all? { |candidate_id| candidate_ids.key?(candidate_id) } &&
          group["candidate_ids"].map do |candidate_id|
            candidate_records.fetch(candidate_id)["angle"]
          end.uniq.sort == source_angles.sort &&
          [1, 2].include?(group["round"]) && group["task_id"].is_a?(String) &&
          data.fetch("ingested_results").key?(group["task_id"]) &&
          (!group.key?("arbiter_decision") ||
           (%w[PROMOTE REFUTE UNPROVEN].include?(group["arbiter_decision"]) &&
            group["arbiter_evidence"].is_a?(String) && !group["arbiter_evidence"].strip.empty?))
      end
      candidate_groups_valid = data.fetch("candidates").all? do |candidate|
        next false unless candidate.is_a?(Hash)

        memberships = data.fetch("semantic_groups").values.select do |group|
          group.is_a?(Hash) && group["candidate_ids"].is_a?(Array) &&
            group["candidate_ids"].include?(candidate["id"])
        end.map { |group| group["group_id"] }
        if memberships.empty?
          !candidate.key?("group_id")
        else
          memberships.length == 1 && candidate["group_id"] == memberships.first
        end
      end
      overflow = data.fetch("overflow")
      valid_overflow = overflow.keys.sort == %w[by_category_severity items total] &&
        overflow["total"].is_a?(Integer) && !overflow["total"].negative? &&
        overflow["items"].is_a?(Array) && overflow["items"].uniq == overflow["items"] &&
        overflow["items"].all? { |finding_id| finding_id.is_a?(String) } &&
        overflow["by_category_severity"].is_a?(Hash) &&
        overflow["by_category_severity"].all? do |key, count|
          key.is_a?(String) && !key.empty? && count.is_a?(Integer) && count.positive?
        end
      valid_overflow &&= overflow["total"] == overflow["by_category_severity"].values.inject(0, :+)
      unreported_ids = data.fetch("findings").select do |finding|
        finding.is_a?(Hash) && finding["reported"] == false
      end.map { |finding| finding["id"] }
      valid_overflow &&= overflow["items"].sort == unreported_ids.sort &&
        overflow["total"] == unreported_ids.length
      expected_overflow_counts = Hash.new(0)
      data.fetch("findings").each do |finding|
        next unless finding.is_a?(Hash) && finding["reported"] == false

        category = finding.fetch("category", "Uncategorized")
        expected_overflow_counts["#{category}:#{finding["severity"]}"] += 1
      end
      valid_overflow &&= overflow["by_category_severity"] == expected_overflow_counts.sort.to_h
      overflow_item_lookup = overflow["items"].each_with_object({}) do |finding_id, indexed|
        indexed[finding_id] = true
      end
      valid_overflow_gaps = data.fetch("overflow_evidence_gaps").all? do |finding_id, gap|
        finding = findings_by_id[finding_id]
        finding && finding["reported"] == false && overflow_item_lookup.key?(finding_id) &&
          %w[MEDIUM LOW].include?(finding["severity"]) && gap.is_a?(Hash) &&
          gap.keys.sort == %w[rationale recorded_at_stage round] &&
          gap["rationale"].is_a?(String) && !gap["rationale"].strip.empty? &&
          TRANSITIONS.key?(gap["recorded_at_stage"]) && [1, 2].include?(gap["round"])
      end
      valid_votes = data.fetch("judge_votes").all? do |subject_id, votes|
        referenced = candidate_ids.key?(subject_id) || data.fetch("semantic_groups").key?(subject_id)
        next false unless referenced && votes.is_a?(Array) && !votes.empty?

        identities = {}
        votes.all? do |vote|
          valid = vote.is_a?(Hash) &&
            vote.keys.sort == %w[
              candidate_id category confidence consequence disposition effective_disposition
              evidence round severity task_id vote_group_id voter_id
            ] &&
            candidate_ids.key?(vote["candidate_id"]) &&
            %w[PROMOTE REFUTE UNPROVEN].include?(vote["disposition"]) &&
            %w[PROMOTE REFUTE UNPROVEN].include?(vote["effective_disposition"]) &&
            vote["confidence"].is_a?(Numeric) && vote["confidence"] >= 0 && vote["confidence"] <= 1 &&
            SEVERITY_RANK.key?(vote["severity"]) && [1, 2].include?(vote["round"]) &&
            vote["evidence"].is_a?(String) && !vote["evidence"].strip.empty? &&
            vote["consequence"].is_a?(String) && !vote["consequence"].strip.empty? &&
            data.fetch("ingested_results").key?(vote["task_id"])
          identity = [vote["vote_group_id"], vote["voter_id"], vote["candidate_id"]]
          valid && !identities[identity] && (identities[identity] = true)
        end
      end
      valid_gaps = data.fetch("evidence_gaps").all? do |gap|
        gap.is_a?(Hash) &&
          gap.keys.sort == %w[candidate_ids evidence reason round subject_id task_id] &&
          gap["candidate_ids"].is_a?(Array) && !gap["candidate_ids"].empty? &&
          gap["candidate_ids"].uniq.length == gap["candidate_ids"].length &&
          gap["candidate_ids"].all? { |candidate_id| candidate_ids.key?(candidate_id) } &&
          gap["reason"].is_a?(String) && !gap["reason"].empty? &&
          gap["evidence"].is_a?(String) && !gap["evidence"].strip.empty? &&
          [1, 2].include?(gap["round"]) && data.fetch("ingested_results").key?(gap["task_id"])
      end
      valid_results && valid_duplicate_map && valid_sources && valid_duplicate_links && valid_groups &&
        candidate_groups_valid && valid_votes && valid_gaps && valid_overflow && valid_overflow_gaps
    rescue KeyError, NoMethodError
      false
    end

    def self.terminal_pairing(action, resolution)
      status = action.is_a?(Hash) ? action["status"] : action
      expected_resolution = TERMINAL_PAIRINGS[status]
      return :incomplete unless expected_resolution && %w[resolved rejected].include?(resolution)

      expected_resolution == resolution ? :complete : :invalid
    end

    def self.completion_blockers(data, from_stage:)
      blockers = []
      if data.dig("execution", "metadata_required")
        data.fetch("ingested_results").each_key do |task_id|
          record = data.dig("execution", "tasks", task_id)
          expected_authority = data.dig("emitted_tasks", task_id, "kind") == "author-actions" ?
            "parent" : "reviewer"
          blockers << "execution-metadata:#{task_id}" unless record && record["authority"] == expected_authority
        end
      end
      unless data.fetch("current_target_digests") == data.fetch("target_digest_history").last
        blockers << "target-digest-mismatch"
      end
      blockers << "pending-arbiter" unless data.fetch("pending_arbiter_subjects").empty?
      if data.fetch("fresh_sweep_required") && !data.fetch("fresh_sweep_completed")
        blockers << "fresh-sweep-incomplete"
      end
      blockers << "degraded-capabilities" unless data.fetch("degraded_capabilities").empty?
      blockers << "critique-not-culled" if data.fetch("mode") == "critique" && from_stage != "culling"
      if data.fetch("mode") == "critique"
        judge_tasks = data.fetch("emitted_tasks").select do |_task_id, record|
          record["kind"] == "judge" && record["round"] == data.fetch("revise_round") &&
            record["attempt"] == 1
        end.keys
        unless !judge_tasks.empty? && judge_tasks.all? { |task_id| data.fetch("ingested_results").key?(task_id) }
          blockers << "judge-roster-incomplete"
        end
      end
      data.fetch("findings").each do |finding|
        finding_id = finding.fetch("id")
        unless finding.fetch("reported")
          if %w[CRITICAL HIGH].include?(finding.fetch("severity"))
            blockers << "overflow-blocker:#{finding_id}"
          elsif !data.fetch("overflow_evidence_gaps").key?(finding_id)
            blockers << "overflow-evidence-gap:#{finding_id}"
          end
          next
        end
        action = data.fetch("author_actions")[finding_id]
        resolution = data.fetch("resolution_checks")[finding_id]
        blockers << "author-action:#{finding_id}" unless valid_author_action_snapshot?(action)
        blockers << "resolution:#{finding_id}" unless %w[resolved rejected].include?(resolution)
        blockers << "terminal-pair:#{finding_id}" if terminal_pairing(action, resolution) == :invalid
      end
      blockers
    end

    def self.canonical_missing_path(path)
      missing = []
      cursor = path
      until File.exist?(cursor) || File.symlink?(cursor)
        missing.unshift(File.basename(cursor))
        parent = File.dirname(cursor)
        raise Error.new("run_path_escape", "could not resolve the Git run root", {"path" => path}) if parent == cursor
        cursor = parent
      end
      if File.symlink?(cursor)
        raise Error.new("unsafe_path", "Git run root contains a symlink", {"path" => cursor})
      end
      File.join(Atomic.secure_directory(cursor), *missing)
    end

    def self.create_lock(path)
      Atomic.create_anchored_lock(path)
    end

    def self.capture_created_run(path)
      expected = File.lstat(path)
      unless expected.directory? && !expected.symlink?
        raise Error.new("unsafe_run_dir", "created review run is not a real directory", {"run_dir" => path})
      end
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      directory = File.open(path, flags)
      unless directory.stat.directory? && Atomic.same_identity?(expected, directory.stat)
        directory.close
        raise Error.new("unsafe_run_dir", "created review run changed while it was opened", {"run_dir" => path})
      end
      {path: path, dev: expected.dev, ino: expected.ino, directory: directory}
    end

    def self.cleanup_created_run(created)
      return unless created && created_run_at_original_path?(created)

      directory = created.fetch(:directory)
      %w[state.json manifest.json .state.lock.anchor .state.lock].each do |entry|
        return unless created_run_at_original_path?(created)

        Atomic.unlink_relative(directory, entry)
      end
      %w[tasks results events].each do |entry|
        return unless created_run_at_original_path?(created)

        Atomic.unlink_relative(directory, entry, Atomic::AT_REMOVEDIR)
      end
      directory.fsync
      return unless created_run_at_original_path?(created)

      Dir.rmdir(created.fetch(:path))
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => error
      raise Error.new(
        "cleanup_failed", "failed review creation could not remove its new run directory",
        {"run_dir" => created && created[:path], "cause" => error.class.name}
      )
    end

    def self.created_run_at_original_path?(created)
      current = File.lstat(created.fetch(:path))
      current.directory? && !current.symlink? &&
        current.dev == created.fetch(:dev) && current.ino == created.fetch(:ino)
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
      false
    end

    def self.target_digests(manifest)
      digests = manifest.fetch("targets").each_with_object({}) do |target, collected|
        path = target.fetch("path")
        digest = target.fetch("sha256")
        unless path.is_a?(String) && !path.empty? &&
               digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) &&
               !collected.key?(path)
          raise Error.new(
            "invalid_digest", "manifest target digests must be unique path-to-SHA256 mappings",
            {"path" => path, "sha256" => digest}, 3
          )
        end
        collected[path] = digest
      end
      if digests.empty?
        raise Error.new("invalid_digest", "manifest must contain at least one target digest", {}, 3)
      end
      digests
    end

    def self.valid_digest_mapping?(digests)
      digests.is_a?(Hash) && !digests.empty? && digests.all? do |path, digest|
        path.is_a?(String) && !path.empty? && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      end
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def mutate!
      lock_path = File.join(@run_dir, ".state.lock")
      Atomic.open_lock(
        lock_path,
        exclusive: true,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        verify_target_digests!(data)
        yield data, manifest
        self.class.validate_snapshot!(manifest, data)
        Atomic.write_json_relative(run_directory, "state.json", data)
        @manifest = manifest
        @data = data
      end
    end

    def completion_blockers(data, from_stage:)
      self.class.completion_blockers(data, from_stage: from_stage)
    end

    def ensure_mutation_stage!(data, operation)
      stage = data.fetch("stage")
      if %w[complete did-not-converge].include?(stage)
        raise Error.new(
          "terminal_state", "terminal review state cannot be mutated",
          {"stage" => stage, "operation" => operation}, 3
        )
      end
      allowed = MUTATION_STAGES.fetch(operation)
      return if allowed.include?(stage)

      raise Error.new(
        "invalid_stage", "review state mutation is not allowed in the current stage",
        {"stage" => stage, "operation" => operation, "allowed" => allowed}, 3
      )
    end

    def target_digests_match?(data)
      data.fetch("current_target_digests") == data.fetch("target_digest_history").last
    end

    def verify_target_digests!(data)
      return if target_digests_match?(data)

      raise Error.new(
        "target_digest_mismatch", "current target digests do not match the expected snapshot",
        {
          "expected" => data.fetch("target_digest_history").last,
          "current" => data.fetch("current_target_digests")
        }, 3
      )
    end

    def sanitize_angle(angle)
      slug = angle.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      if slug.empty?
        raise Error.new("invalid_angle", "candidate angle cannot be sanitized", {"angle" => angle}, 3)
      end
      slug
    end

    def validate_task_id!(task_id)
      return if task_id.is_a?(String) && RUN_ID.match?(task_id) && task_id != "." && task_id != ".."

      raise InvalidResult.new(
        "invalid_task_id", "task ID contains unsafe characters",
        {"task_id" => task_id, "errors" => []}
      )
    end

    def validate_dispatch_attempt!(task_id:, executor:, status:, error_code:, phase:,
                                   content_sent:, prompt_bytes:)
      validate_task_id!(task_id)
      return if Manifest::EXECUTORS.include?(executor) && executor != "auto" &&
                %w[complete failed fallback].include?(status) &&
                (error_code.nil? || (error_code.is_a?(String) && !error_code.empty?)) &&
                %w[probe preflight execution].include?(phase) &&
                [true, false].include?(content_sent) &&
                prompt_bytes.is_a?(Integer) && prompt_bytes.positive?

      raise Error.new("invalid_dispatch_attempt", "dispatch attempt evidence is malformed", {}, 3)
    end

    def build_execution_record!(task_id, authority:, capabilities:, usage:, attempts:,
                                runtime_provenance:)
      validate_task_id!(task_id)
      valid_usage = usage.is_a?(Hash) && usage.all? do |key, value|
        key.is_a?(String) && value.is_a?(Integer) && value >= 0
      end
      unless %w[reviewer parent].include?(authority) && attempts.is_a?(Integer) && attempts >= 0 &&
             valid_usage && runtime_provenance.is_a?(Hash)
        raise Error.new("invalid_execution_record", "task execution record is malformed", {}, 3)
      end
      if authority == "reviewer"
        Capabilities.gate(capabilities, "PASS")
      elsif !capabilities.nil?
        raise Error.new("invalid_execution_record", "parent authority must not claim reviewer capabilities", {}, 3)
      end
      {
        "authority" => authority, "capabilities" => deep_copy(capabilities),
        "usage" => deep_copy(usage), "attempts" => attempts,
        "runtime_provenance" => deep_copy(runtime_provenance)
      }
    rescue Capabilities::Error => error
      raise Error.new("invalid_execution_record", error.message, {}, 3)
    end

    def dispatch_attempt_record(task_id:, executor:, status:, error_code:, phase:,
                                content_sent:, prompt_bytes:)
      {
        "task_id" => task_id, "executor" => executor, "status" => status,
        "error_code" => error_code, "phase" => phase,
        "content_sent" => content_sent, "prompt_bytes" => prompt_bytes
      }
    end

    def result_schema_name!(task)
      unless task.is_a?(Hash)
        raise InvalidResult.new("invalid_task", "emitted task is not an object", {"errors" => []})
      end
      declared = task["schema_name"] || task["schema"]
      name = declared.to_s.sub(%r{\Aassets/schemas/}, "").sub(/\.json\z/, "")
      unless RESULT_SCHEMAS.include?(name)
        raise InvalidResult.new(
          "invalid_task_schema", "emitted task has an unsupported result schema",
          {"schema" => declared, "errors" => []}
        )
      end
      name
    end

    def validate_result_task!(task_id, task, schema_name, manifest, data, payload)
      unknown = task.keys - RESULT_TASK_KEYS
      unless unknown.empty?
        invalid_result!("invalid_task", "emitted task is not closed", {"unknown" => unknown.sort})
      end
      required = %w[schema_version run_id task_id artifact_digests]
      missing = required.reject { |key| task.key?(key) }
      unless missing.empty? || !(task.key?("schema") || task.key?("schema_name"))
        invalid_result!("invalid_task", "emitted task metadata is incomplete", {"missing" => missing})
      end
      unless task.fetch("schema_version") == 1 && task.fetch("run_id") == manifest.fetch("run_id") &&
             task.fetch("task_id") == task_id
        invalid_result!("result_identity_mismatch", "emitted task identity is invalid")
      end
      unless task.key?("role") || task.key?("kind")
        invalid_result!("invalid_task", "emitted task must declare its role or kind")
      end
      if task.key?("kind") && task.fetch("kind") != schema_name
        invalid_result!("invalid_task_schema", "emitted task kind does not match its result schema")
      end
      role_names = {
        "attack" => %w[attacker attack],
        "divergence" => %w[attacker divergence],
        "dedupe" => %w[dedupe deduplicator],
        "judge" => %w[judge],
        "author-actions" => %w[author author-actions],
        "resolution" => %w[resolver resolution],
        "arbiter" => %w[arbiter]
      }
      if task.key?("role") && !role_names.fetch(schema_name).include?(task.fetch("role"))
        invalid_result!("invalid_task_schema", "emitted task role does not match its result schema")
      end
      if task.key?("schema") && task.fetch("schema") != "assets/schemas/#{schema_name}.json"
        invalid_result!("invalid_task_schema", "emitted task schema path is not canonical")
      end
      if task.key?("schema_name") && task.fetch("schema_name") != schema_name
        invalid_result!("invalid_task_schema", "emitted task schema name is not canonical")
      end
      if task.key?("schema") && task.key?("schema_name")
        declared_name = task.fetch("schema").sub(%r{\Aassets/schemas/}, "").sub(/\.json\z/, "")
        unless declared_name == task.fetch("schema_name")
          invalid_result!("invalid_task_schema", "emitted schema declarations disagree")
        end
      end
      expected_digests = data.fetch("current_target_digests")
      unless task.fetch("artifact_digests") == expected_digests &&
             payload["schema_version"] == 1 && payload["run_id"] == task.fetch("run_id") &&
             payload["task_id"] == task_id && payload["artifact_digests"] == expected_digests
        invalid_result!(
          "result_identity_mismatch", "result identity or artifact digests do not match the emitted task",
          {"task_id" => task_id}
        )
      end
      if task.key?("round") && task.fetch("round") != data.fetch("revise_round")
        invalid_result!(
          "result_round_mismatch", "task round does not match authoritative state",
          {"task_round" => task.fetch("round"), "state_round" => data.fetch("revise_round")}
        )
      end
      if task.key?("attempt") &&
         (!task.fetch("attempt").is_a?(Integer) || !task.fetch("attempt").positive?)
        invalid_result!("invalid_task", "task attempt must be a positive integer")
      end
      if %w[attack divergence].include?(schema_name)
        unless task["angle"].is_a?(String) && task["attempt"].is_a?(Integer) && task["attempt"].positive? &&
               payload["angle"] == task["angle"]
          invalid_result!("result_identity_mismatch", "attack result does not match task angle or attempt")
        end
        unless manifest.fetch("enabled_tasks").include?(task.fetch("angle"))
          invalid_result!("invalid_task", "attack angle is not enabled by the manifest")
        end
      end
      true
    rescue KeyError => error
      invalid_result!("invalid_task", "emitted task metadata is incomplete", {"missing" => [error.key]})
    end

    def ensure_ingest_stage!(data, schema_name)
      stage = data.fetch("stage")
      if %w[complete did-not-converge].include?(stage)
        invalid_result!("terminal_state", "terminal review state cannot ingest results", {"stage" => stage})
      end
      allowed = INGEST_STAGES.fetch(schema_name)
      return if allowed.include?(stage)

      invalid_result!(
        "invalid_stage", "result schema cannot be applied in the current stage",
        {"stage" => stage, "schema" => schema_name, "allowed" => allowed}
      )
    end

    def invalid_result!(code, message, details = {})
      errors = details["errors"] || [
        {"code" => code, "path" => "", "message" => message}
      ]
      raise InvalidResult.new(code, message, details.merge("errors" => errors))
    end

    def read_json_bytes_relative!(directory, name, code)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = Atomic.open_relative(directory, name, flags)
      begin
        Atomic.reject_nonregular_handle(file, name, code)
        if file.stat.size > Atomic::MAX_JSON_BYTES
          invalid_result!(code, "persisted JSON exceeds the size limit", {"path" => name})
        end
        bytes = file.read(Atomic::MAX_JSON_BYTES + 1)
        if bytes.bytesize > Atomic::MAX_JSON_BYTES
          invalid_result!(code, "persisted JSON exceeds the size limit", {"path" => name})
        end
        [JSON.parse(bytes), bytes]
      ensure
        file.close if file && !file.closed?
      end
    rescue JSON::ParserError => error
      invalid_result!(code, "persisted JSON is invalid", {"path" => name, "cause" => error.message})
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      invalid_result!(code, "persisted JSON is unavailable", {"path" => name, "cause" => error.class.name})
    end

    def publish_authenticated_task!(directory, task_id, value)
      task_name = "#{task_id}.json"
      auth_name = "#{task_id}.auth.json"
      task_bytes = JSON.generate(value) + "\n"
      auth = task_authentication(task_id, task_bytes)
      auth_bytes = JSON.generate(auth) + "\n"
      task_exists = Atomic.reject_relative_nonregular(directory, task_name, "task_collision")
      auth_exists = Atomic.reject_relative_nonregular(directory, auth_name, "task_collision")

      if task_exists
        _task, existing_task_bytes = read_json_bytes_relative!(directory, task_name, "task_collision")
        unless existing_task_bytes == task_bytes
          invalid_result!(
            "task_collision", "existing task bytes belong to a different bundle",
            {"task_id" => task_id}
          )
        end
      end
      if auth_exists
        _auth, existing_auth_bytes = read_json_bytes_relative!(directory, auth_name, "task_collision")
        unless existing_auth_bytes == auth_bytes
          invalid_result!(
            "task_collision", "existing task authentication belongs to a different bundle",
            {"task_id" => task_id}
          )
        end
      end

      begin
        unless task_exists
          Atomic.write_new_json(directory, task_name, value)
        end
        unless auth_exists
          Atomic.write_new_json(directory, auth_name, auth)
        end
      rescue StandardError
        Atomic.unlink_relative(directory, auth_name) unless auth_exists
        Atomic.unlink_relative(directory, task_name) unless task_exists
        directory.fsync unless task_exists && auth_exists
        raise
      end
      {"task_created" => !task_exists, "auth_created" => !auth_exists}
    end

    def rollback_task_publication!(run_directory, task_id, publication)
      return unless publication.is_a?(Hash) && publication.values.any?

      Atomic.with_relative_directory(
        run_directory, "tasks", code: "unsafe_task_path", expected_identity: @tasks_identity
      ) do |tasks_directory|
        if publication["auth_created"]
          Atomic.unlink_relative(tasks_directory, "#{task_id}.auth.json")
        end
        if publication["task_created"]
          Atomic.unlink_relative(tasks_directory, "#{task_id}.json")
        end
        tasks_directory.fsync
      end
    end

    def read_authenticated_task!(directory, task_id)
      task_name = "#{task_id}.json"
      auth_name = "#{task_id}.auth.json"
      task, task_bytes = read_json_bytes_relative!(directory, task_name, "invalid_task")
      auth, auth_bytes = read_json_bytes_relative!(directory, auth_name, "invalid_task")
      expected = task_authentication(task_id, task_bytes)
      unless auth.is_a?(Hash) && auth.keys.sort == expected.keys.sort && auth == expected &&
             auth_bytes == JSON.generate(expected) + "\n"
        invalid_result!(
          "invalid_task", "task authentication does not match the emitted task bytes",
          {"task_id" => task_id}
        )
      end
      [task, task_bytes]
    end

    def task_authentication(task_id, task_bytes)
      {
        "schema_version" => 1,
        "task_id" => task_id,
        "sha256" => Digest::SHA256.hexdigest(task_bytes)
      }
    end

    def authoritative_task_record!(requested_id, task, task_bytes, manifest, data)
      unless task.is_a?(Hash) && task["task_id"] == requested_id
        invalid_result!(
          "invalid_task", "task ID does not match the requested bundle identity",
          {"task_id" => requested_id, "embedded_task_id" => task.is_a?(Hash) ? task["task_id"] : nil}
        )
      end
      if task.key?("run_id") && task["run_id"] != manifest.fetch("run_id")
        invalid_result!("invalid_task", "task run ID does not match the manifest", {"task_id" => requested_id})
      end
      match = requested_id.match(/\A(?<prefix>.+)-r(?<round>[1-9]\d*)-a(?<attempt>[1-9]\d*)\z/)
      unless match
        invalid_result!("invalid_task", "task ID does not encode a canonical round and attempt")
      end
      encoded_round = Integer(match[:round])
      encoded_attempt = Integer(match[:attempt])
      round = task.fetch("round", encoded_round)
      attempt = task.fetch("attempt", encoded_attempt)
      unless round == encoded_round && round == data.fetch("revise_round") &&
             attempt == encoded_attempt && attempt.is_a?(Integer) && attempt.positive?
        invalid_result!(
          "invalid_task", "task round or attempt does not match its canonical task ID",
          {"task_id" => requested_id, "round" => round, "attempt" => attempt}
        )
      end

      kind = task["kind"]
      kind = "attack" if kind.nil? && task["role"] == "attacker"
      kind ||= match[:prefix].split("-").first
      unless kind.is_a?(String) && RESULT_SCHEMAS.include?(kind) &&
             match[:prefix].start_with?("#{kind}-")
        invalid_result!("invalid_task", "task kind does not match its canonical task ID")
      end
      angle = task["angle"]
      if angle
        unless angle.is_a?(String) && !angle.empty? && match[:prefix] == "#{kind}-#{angle}" &&
               (!manifest["enabled_tasks"].is_a?(Array) || manifest.fetch("enabled_tasks").include?(angle))
          invalid_result!("invalid_task", "task angle does not match its canonical task ID or manifest")
        end
      end
      {
        "task_id" => requested_id,
        "kind" => kind,
        "angle" => angle,
        "round" => round,
        "attempt" => attempt,
        "sha256" => Digest::SHA256.hexdigest(task_bytes)
      }
    rescue KeyError, ArgumentError => error
      invalid_result!(
        "invalid_task", "task identity is incomplete or invalid",
        {"task_id" => requested_id, "cause" => error.message}
      )
    end

    def verify_authoritative_task!(task_id, task, task_bytes, manifest, data)
      expected = data.fetch("emitted_tasks")[task_id]
      current = authoritative_task_record!(task_id, task, task_bytes, manifest, data)
      unless expected && expected == current && data.fetch("task_attempts")[task_id] == current.fetch("attempt")
        invalid_result!(
          "invalid_task", "live task bytes do not match authoritative locked state",
          {"task_id" => task_id}
        )
      end
      true
    end

    def apply_result_to_data!(data, task, schema_name, payload, manifest)
      case schema_name
      when "attack", "divergence"
        apply_attack_result!(data, task, payload)
      when "dedupe"
        apply_dedupe_result!(data, task, payload)
      when "judge"
        apply_judge_result!(data, task, payload, manifest)
      when "author-actions"
        apply_author_actions_result!(data, task, payload)
      when "resolution"
        apply_resolution_result!(data, task, payload, manifest)
      when "arbiter"
        apply_arbiter_result!(data, task, payload)
      else
        invalid_result!(
          "unsupported_result", "result schema application is not implemented",
          {"schema" => schema_name}
        )
      end
    end

    def apply_arbiter_result!(data, task, payload)
      dispute_kind = task.fetch("dispute_kind")
      unless %w[candidate candidate-judgment author-resolution].include?(dispute_kind)
        invalid_result!("invalid_dispute_kind", "arbiter task has an invalid dispute kind")
      end
      decisions = payload.fetch("decisions")
      expected_subjects = task.fetch("subject_ids", data.fetch("pending_arbiter_subjects"))
      require_exact_subject_coverage!(
        expected_subjects, decisions.map { |decision| decision.fetch("subject_id") }, "arbiter"
      )
      decisions.each do |decision|
        subject_id = decision.fetch("subject_id")
        expected_mapping = arbiter_subject_mapping(data, task, subject_id)
        unless decision.fetch("mapped_candidate_ids").sort == expected_mapping.sort &&
               decision.fetch("mapped_candidate_ids").uniq.length == decision.fetch("mapped_candidate_ids").length
          invalid_result!(
            "arbiter_mapping_mismatch", "arbiter candidate mapping does not match its task",
            {"subject_id" => subject_id, "expected" => expected_mapping,
             "supplied" => decision.fetch("mapped_candidate_ids")}
          )
        end
        if dispute_kind == "author-resolution"
          apply_author_arbiter_decision!(data, subject_id, decision.fetch("decision"))
        else
          apply_candidate_arbiter_decision!(data, task, subject_id, decision, expected_mapping)
        end
      end
      {
        "schema" => "arbiter",
        "task_id" => task.fetch("task_id"),
        "subject_ids" => expected_subjects.sort,
        "pending_arbiter_subjects" => data.fetch("pending_arbiter_subjects").dup
      }
    end

    def arbiter_subject_mapping(data, task, subject_id)
      mappings = task["subject_mappings"]
      mapped = mappings[subject_id] if mappings.is_a?(Hash)
      mapped ||= task["mapped_candidate_ids"] if task["subject_ids"].to_a.length == 1
      if mapped.nil?
        finding = data.fetch("findings").find { |item| item.fetch("id") == subject_id }
        group = data.fetch("semantic_groups")[subject_id]
        mapped = if finding
                   finding.fetch("candidate_ids")
                 elsif group
                   group.fetch("candidate_ids")
                 elsif data.fetch("candidates").any? { |candidate| candidate.fetch("id") == subject_id }
                   [subject_id]
                 end
      end
      unless mapped.is_a?(Array) && !mapped.empty? && mapped.all? do |candidate_id|
               data.fetch("candidates").any? { |candidate| candidate.fetch("id") == candidate_id }
             end
        invalid_result!("arbiter_mapping_mismatch", "arbiter task mapping is invalid", {"subject_id" => subject_id})
      end
      mapped
    end

    def apply_author_arbiter_decision!(data, finding_id, decision)
      finding = data.fetch("findings").find { |item| item.fetch("id") == finding_id }
      invalid_result!("unknown_finding", "arbiter finding does not exist", {"id" => finding_id}) unless finding
      case decision
      when "RESOLVED"
        action = data.fetch("author_actions")[finding_id]
        action_status = action.is_a?(Hash) ? action["status"] : action
        unless %w[fixed rejected].include?(action_status)
          invalid_result!("invalid_arbiter_decision", "author dispute has no valid recorded action")
        end
        status = action_status == "fixed" ? "resolved" : "rejected"
        finding["state"] = status
        data.fetch("resolution_checks")[finding_id] = status
        data.fetch("pending_arbiter_subjects").delete(finding_id)
      when "UNRESOLVED"
        status = data.fetch("revise_round") >= 2 ? "stuck" : "contested"
        finding["state"] = status
        data.fetch("resolution_checks")[finding_id] = status
        data.fetch("pending_arbiter_subjects").delete(finding_id)
      else
        invalid_result!("invalid_arbiter_decision", "decision is invalid for an author dispute")
      end
    end

    def apply_candidate_arbiter_decision!(data, task, subject_id, decision, candidate_ids)
      candidate_ids.each do |candidate_id|
        candidate = find_candidate_in_data!(data, candidate_id)
        candidate["arbiter_decision"] = decision.fetch("decision")
        candidate["arbiter_evidence"] = decision.fetch("evidence")
      end
      semantic_group = data.fetch("semantic_groups")[subject_id]
      if semantic_group
        semantic_group["arbiter_decision"] = decision.fetch("decision")
        semantic_group["arbiter_evidence"] = decision.fetch("evidence")
      end
      case decision.fetch("decision")
      when "PROMOTE"
        votes = data.fetch("judge_votes").fetch(subject_id, []).select do |vote|
          vote["effective_disposition"] == "PROMOTE"
        end
        group = if votes.empty?
                  candidate = find_candidate_in_data!(data, candidate_ids.first)
                  location = candidate.fetch("location")
                  {
                    "group_id" => subject_id,
                    "candidate_ids" => candidate_ids.sort,
                    "summary" => candidate.fetch("summary"),
                    "category" => candidate.fetch("category"),
                    "severity" => "HIGH",
                    "confidence" => decision.fetch("confidence"),
                    "evidence" => decision.fetch("evidence"),
                    "consequence" => candidate.fetch("consequence"),
                    "path" => location.fetch("path"),
                    "line" => location.fetch("line_start"),
                    "location" => deep_copy(location)
                  }
                else
                  promotion_group_from_verdicts(data, subject_id, votes)
                end
        promote_with_cap!(data, [group])
        data.fetch("pending_arbiter_subjects").delete(subject_id)
      when "REFUTE"
        candidate_ids.each { |candidate_id| find_candidate_in_data!(data, candidate_id)["state"] = "refuted" }
        data.fetch("pending_arbiter_subjects").delete(subject_id)
      when "UNPROVEN"
        candidate_ids.each { |candidate_id| find_candidate_in_data!(data, candidate_id)["state"] = "unproven" }
        data.fetch("pending_arbiter_subjects").delete(subject_id)
        data.fetch("evidence_gaps") << {
          "subject_id" => subject_id,
          "candidate_ids" => candidate_ids.sort,
          "task_id" => task.fetch("task_id"),
          "round" => data.fetch("revise_round"),
          "reason" => "arbiter-unproven",
          "evidence" => decision.fetch("evidence")
        }
      else
        invalid_result!("invalid_arbiter_decision", "decision is invalid for a candidate dispute")
      end
    end

    def apply_author_actions_result!(data, task, payload)
      pending_ids = data.fetch("findings").select do |finding|
        actionable = finding.fetch("reported") || %w[CRITICAL HIGH].include?(finding.fetch("severity"))
        actionable && finding.fetch("state") == "pending" &&
          !data.fetch("author_actions").key?(finding.fetch("id"))
      end.map { |finding| finding.fetch("id") }
      actions = payload.fetch("actions")
      require_exact_subject_coverage!(
        pending_ids, actions.map { |action| action.fetch("finding_id") }, "author-actions"
      )
      actions.each do |action|
        finding_id = action.fetch("finding_id")
        data.fetch("author_actions")[finding_id] = {
          "status" => action.fetch("action").downcase,
          "rationale" => action.fetch("rationale"),
          "changed_paths" => deep_copy(action.fetch("changed_paths", [])),
          "task_id" => task.fetch("task_id")
        }
      end
      {
        "schema" => "author-actions",
        "task_id" => task.fetch("task_id"),
        "finding_ids" => pending_ids.sort
      }
    end

    def apply_resolution_result!(data, task, payload, manifest)
      relevant_ids = data.fetch("author_actions").keys.select do |finding_id|
        finding = data.fetch("findings").find { |item| item.fetch("id") == finding_id }
        finding && !%w[resolved rejected stuck].include?(finding.fetch("state"))
      end
      checks = payload.fetch("checks")
      require_exact_subject_coverage!(
        relevant_ids, checks.map { |check| check.fetch("finding_id") }, "resolution"
      )
      pending = []
      checks.each do |check|
        finding_id = check.fetch("finding_id")
        finding = data.fetch("findings").find { |item| item.fetch("id") == finding_id }
        action = data.fetch("author_actions").fetch(finding_id)
        action_status = action.is_a?(Hash) ? action.fetch("status") : action
        case check.fetch("status")
        when "RESOLVED"
          status = action_status == "fixed" ? "resolved" : "rejected"
          data.fetch("resolution_checks")[finding_id] = status
          finding["state"] = status
          data.fetch("pending_arbiter_subjects").delete(finding_id)
        when "UNRESOLVED", "REGRESSED"
          data.fetch("resolution_checks")[finding_id] = "contested"
          finding["state"] = "contested"
          pending << finding_id
        end
      end
      data.fetch("pending_arbiter_subjects").concat(pending)
      data.fetch("pending_arbiter_subjects").uniq!
      data.fetch("pending_arbiter_subjects").sort!
      new_candidate_ids = apply_resolution_findings!(
        data, task, payload.fetch("new_findings"), manifest
      )
      {
        "schema" => "resolution",
        "task_id" => task.fetch("task_id"),
        "finding_ids" => relevant_ids.sort,
        "pending_arbiter_subjects" => pending.sort,
        "candidate_ids" => new_candidate_ids
      }
    end

    def apply_resolution_findings!(data, task, findings, manifest)
      return [] if findings.empty?
      unless manifest.fetch("mode") == "revise" &&
             task.fetch("round", data.fetch("revise_round")) == data.fetch("revise_round") &&
             data.fetch("revise_round") < 2
        invalid_result!("invalid_new_findings", "new resolution findings are not allowed for this round")
      end
      angle = task.fetch("angle", "resolution")
      attempt = task.fetch("attempt", 1)
      ids = []
      findings.each_with_index do |finding, index|
        fingerprint = finding_fingerprint(finding)
        source = {
          "task_id" => task.fetch("task_id"),
          "angle" => angle,
          "attempt" => attempt,
          "round" => data.fetch("revise_round"),
          "finding_index" => index
        }
        candidate_id = data.fetch("exact_duplicate_map")[fingerprint]
        if candidate_id
          data.fetch("exact_duplicate_sources").fetch(candidate_id) << source
        else
          candidate = add_candidate_to_data!(
            data, angle, attempt, finding, round: data.fetch("revise_round") + 1
          )
          candidate_id = candidate.fetch("id")
          data.fetch("exact_duplicate_map")[fingerprint] = candidate_id
          data.fetch("exact_duplicate_sources")[candidate_id] = [source]
        end
        ids << candidate_id
      end
      data["fresh_sweep_required"] = true
      data["fresh_sweep_completed"] = false
      ids.uniq
    end

    def apply_dedupe_result!(data, task, payload)
      applicable = data.fetch("candidates").select do |candidate|
        candidate.fetch("state") == "candidate" && candidate.fetch("round") == data.fetch("revise_round")
      end
      applicable_by_id = records_by_id(applicable)
      expected_ids = applicable.map { |candidate| candidate.fetch("id") }.sort
      groups = payload.fetch("groups")
      group_ids = groups.map { |group| group.fetch("group_id") }
      duplicate_group = group_ids.group_by { |id| id }.find { |_id, values| values.length > 1 }
      if duplicate_group
        invalid_result!(
          "duplicate_group", "semantic group IDs must be unique",
          {"group_id" => duplicate_group.first}
        )
      end
      supplied_ids = groups.flat_map { |group| group.fetch("candidate_ids") }
      unless supplied_ids.sort == expected_ids && supplied_ids.uniq.length == supplied_ids.length
        invalid_result!(
          "candidate_coverage", "dedupe groups must cover applicable candidates exactly once",
          {
            "expected" => expected_ids,
            "supplied" => supplied_ids,
            "missing" => expected_ids - supplied_ids,
            "unknown" => supplied_ids - expected_ids
          }
        )
      end
      collisions = group_ids.select { |group_id| data.fetch("semantic_groups").key?(group_id) }
      unless collisions.empty?
        invalid_result!("duplicate_group", "semantic group ID already exists", {"group_ids" => collisions})
      end
      groups.each do |group|
        expected_angles = group.fetch("candidate_ids").map do |candidate_id|
          applicable_by_id.fetch(candidate_id).fetch("angle")
        end.uniq.sort
        unless group.fetch("source_angles").uniq.sort == expected_angles
          invalid_result!(
            "source_angle_mismatch", "semantic group source angles do not match its candidates",
            {"group_id" => group.fetch("group_id"), "expected" => expected_angles,
             "supplied" => group.fetch("source_angles")}
          )
        end
        record = deep_copy(group).merge(
          "round" => data.fetch("revise_round"),
          "task_id" => task.fetch("task_id")
        )
        data.fetch("semantic_groups")[group.fetch("group_id")] = record
        group.fetch("candidate_ids").each do |candidate_id|
          candidate = applicable_by_id.fetch(candidate_id)
          candidate["group_id"] = group.fetch("group_id")
        end
      end
      {
        "schema" => "dedupe",
        "task_id" => task.fetch("task_id"),
        "group_ids" => group_ids.sort,
        "candidate_ids" => supplied_ids.sort
      }
    end

    def apply_judge_result!(data, task, payload, manifest)
      return apply_ultra_judge_result!(data, task, payload) if manifest.fetch("tier", "default") == "ultra"

      applicable = applicable_judge_candidates(data)
      applicable_by_id = records_by_id(applicable)
      verdicts = payload.fetch("verdicts")
      require_exact_subject_coverage!(
        applicable.map { |candidate| candidate.fetch("id") },
        verdicts.map { |verdict| verdict.fetch("candidate_id") },
        "judge"
      )
      grouped = verdicts.group_by do |verdict|
        candidate = applicable_by_id.fetch(verdict.fetch("candidate_id"))
        candidate.fetch("group_id", candidate.fetch("id"))
      end
      promotion_groups = []
      refuted_ids = []
      unproven_ids = []
      arbitration = []
      grouped.keys.sort.each do |subject_id|
        subject_verdicts = grouped.fetch(subject_id).map do |verdict|
          validate_and_normalize_verdict!(data, task, subject_id, verdict, applicable_by_id)
        end
        data.fetch("judge_votes")[subject_id] ||= []
        data.fetch("judge_votes")[subject_id].concat(subject_verdicts)
        dispositions = subject_verdicts.map { |verdict| verdict.fetch("effective_disposition") }.uniq
        candidate_ids = subject_verdicts.map { |verdict| verdict.fetch("candidate_id") }.sort
        if dispositions.length > 1
          arbitration << subject_id
          next
        end
        case dispositions.first
        when "PROMOTE"
          promotion_groups << promotion_group_from_verdicts(
            data, subject_id, subject_verdicts, applicable_by_id
          )
        when "REFUTE"
          candidate_ids.each { |id| applicable_by_id.fetch(id)["state"] = "refuted" }
          refuted_ids.concat(candidate_ids)
        when "UNPROVEN"
          candidate_ids.each { |id| applicable_by_id.fetch(id)["state"] = "unproven" }
          unproven_ids.concat(candidate_ids)
          add_evidence_gap!(data, task, subject_id, candidate_ids, subject_verdicts)
        end
      end
      data.fetch("pending_arbiter_subjects").concat(arbitration)
      data.fetch("pending_arbiter_subjects").uniq!
      data.fetch("pending_arbiter_subjects").sort!
      promoted, overflowed, evicted, _new_findings = promote_with_cap!(data, promotion_groups)
      {
        "schema" => "judge",
        "task_id" => task.fetch("task_id"),
        "promoted_ids" => promoted.map { |finding| finding.fetch("id") },
        "refuted_candidate_ids" => refuted_ids.sort,
        "unproven_candidate_ids" => unproven_ids.sort,
        "pending_arbiter_subjects" => arbitration.sort,
        "overflow_count" => overflowed.length,
        "overflow_ids" => data.fetch("overflow").fetch("items").dup,
        "evicted_ids" => evicted
      }
    end

    def apply_ultra_judge_result!(data, task, payload)
      voter_id = task["voter_id"]
      vote_group_id = task["vote_group_id"]
      expected_voters = expected_voter_count(task)
      unless voter_id.is_a?(String) && !voter_id.strip.empty? &&
             vote_group_id.is_a?(String) && !vote_group_id.strip.empty?
        invalid_result!("invalid_vote_identity", "ultra judge task requires voter and vote-group IDs")
      end
      applicable = applicable_judge_candidates(data)
      applicable_by_id = records_by_id(applicable)
      verdicts = payload.fetch("verdicts")
      require_exact_subject_coverage!(
        applicable.map { |candidate| candidate.fetch("id") },
        verdicts.map { |verdict| verdict.fetch("candidate_id") },
        "ultra-judge"
      )
      normalized = verdicts.map do |verdict|
        candidate = applicable_by_id.fetch(verdict.fetch("candidate_id"))
        subject_id = candidate.fetch("group_id", candidate.fetch("id"))
        existing = data.fetch("judge_votes").fetch(subject_id, [])
        if existing.any? do |vote|
             vote["vote_group_id"] == vote_group_id && vote["voter_id"] == voter_id
           end
          invalid_result!(
            "duplicate_voter", "ultra judge voter has already voted in this group",
            {"subject_id" => subject_id, "voter_id" => voter_id}
          )
        end
        [subject_id, validate_and_normalize_verdict!(
          data, task, subject_id, verdict, applicable_by_id
        )]
      end
      normalized.each do |subject_id, verdict|
        data.fetch("judge_votes")[subject_id] ||= []
        data.fetch("judge_votes")[subject_id] << verdict
      end

      promotion_groups = []
      refuted_ids = []
      pending = []
      normalized.map(&:first).uniq.sort.each do |subject_id|
        votes = data.fetch("judge_votes").fetch(subject_id).select do |vote|
          vote.fetch("vote_group_id") == vote_group_id
        end
        voter_count = votes.map { |vote| vote.fetch("voter_id") }.uniq.length
        next if voter_count < expected_voters

        dispositions = votes.map { |vote| vote.fetch("effective_disposition") }.uniq
        if dispositions == ["PROMOTE"]
          promotion_groups << promotion_group_from_verdicts(
            data, subject_id, votes, applicable_by_id
          )
        elsif dispositions == ["REFUTE"]
          ids = votes.map { |vote| vote.fetch("candidate_id") }.uniq.sort
          ids.each { |id| applicable_by_id.fetch(id)["state"] = "refuted" }
          refuted_ids.concat(ids)
        else
          pending << subject_id
          add_evidence_gap!(
            data, task, subject_id,
            votes.map { |vote| vote.fetch("candidate_id") }.uniq,
            votes
          ) if votes.any? { |vote| vote.fetch("effective_disposition") == "UNPROVEN" }
        end
      end
      data.fetch("pending_arbiter_subjects").concat(pending)
      data.fetch("pending_arbiter_subjects").uniq!
      data.fetch("pending_arbiter_subjects").sort!
      promoted, overflowed, evicted, _new_findings = promote_with_cap!(data, promotion_groups)
      {
        "schema" => "judge",
        "task_id" => task.fetch("task_id"),
        "promoted_ids" => promoted.map { |finding| finding.fetch("id") },
        "refuted_candidate_ids" => refuted_ids.sort,
        "unproven_candidate_ids" => [],
        "pending_arbiter_subjects" => pending.sort,
        "overflow_count" => overflowed.length,
        "overflow_ids" => data.fetch("overflow").fetch("items").dup,
        "evicted_ids" => evicted,
        "votes_recorded" => normalized.length
      }
    end

    def expected_voter_count(task)
      if task["voter_ids"].is_a?(Array)
        voter_ids = task.fetch("voter_ids")
        unless voter_ids.length == voter_ids.uniq.length &&
               voter_ids.all? { |voter_id| voter_id.is_a?(String) && !voter_id.strip.empty? } &&
               voter_ids.include?(task["voter_id"])
          invalid_result!("invalid_vote_identity", "ultra voter list is invalid")
        end
        count = voter_ids.length
        if task.key?("expected_voters") && task.fetch("expected_voters") != count
          invalid_result!("invalid_vote_identity", "ultra voter count disagrees with voter list")
        end
      else
        count = task.fetch("expected_voters", 3)
      end
      unless count == 3
        invalid_result!("invalid_vote_identity", "ultra expected voter count must be exactly three")
      end
      count
    end

    def applicable_judge_candidates(data)
      data.fetch("candidates").select do |candidate|
        candidate.fetch("state") == "candidate" && candidate.fetch("round") == data.fetch("revise_round")
      end
    end

    def require_exact_subject_coverage!(expected, supplied, operation)
      if supplied.uniq.length != supplied.length || supplied.sort != expected.sort
        invalid_result!(
          "subject_coverage", "#{operation} result must cover applicable subjects exactly once",
          {
            "expected" => expected.sort,
            "supplied" => supplied,
            "missing" => expected - supplied,
            "unknown" => supplied - expected
          }
        )
      end
    end

    def validate_and_normalize_verdict!(data, task, subject_id, verdict, candidates_by_id = nil)
      candidate = find_candidate_in_data!(data, verdict.fetch("candidate_id"), candidates_by_id)
      disposition = verdict.fetch("disposition")
      evidence = verdict.fetch("evidence")
      consequence = verdict.fetch("consequence")
      if evidence.strip.empty? || consequence.strip.empty?
        invalid_result!("invalid_verdict_evidence", "judge evidence and consequence must not be blank")
      end
      if disposition == "REFUTE" && !genuine_refuting_evidence?(candidate, evidence)
        invalid_result!(
          "invalid_refutation", "REFUTE requires evidence distinct from the candidate assertion",
          {"candidate_id" => candidate.fetch("id")}
        )
      end
      effective = if disposition == "PROMOTE" && verdict.fetch("confidence") < 0.7
                    "UNPROVEN"
                  else
                    disposition
                  end
      deep_copy(verdict).merge(
        "task_id" => task.fetch("task_id"),
        "voter_id" => task.fetch("voter_id", task.fetch("task_id")),
        "vote_group_id" => task.fetch("vote_group_id", subject_id),
        "effective_disposition" => effective,
        "round" => data.fetch("revise_round")
      )
    end

    def genuine_refuting_evidence?(candidate, evidence)
      normalized = normalize_assertion(evidence)
      return false if normalized.empty?

      assertions = %w[summary evidence consequence].map do |key|
        normalize_assertion(candidate[key].to_s)
      end.reject(&:empty?)
      !assertions.include?(normalized)
    end

    def normalize_assertion(value)
      value.to_s.strip.downcase.gsub(/\s+/, " ")
    end

    def promotion_group_from_verdicts(data, subject_id, verdicts, candidates_by_id = nil)
      candidates_by_id ||= records_by_id(data.fetch("candidates"))
      candidates = verdicts.map do |verdict|
        find_candidate_in_data!(data, verdict.fetch("candidate_id"), candidates_by_id)
      end.uniq { |candidate| candidate.fetch("id") }
      semantic = data.fetch("semantic_groups")[subject_id]
      location = semantic ? semantic.fetch("location") : candidates.first.fetch("location")
      representative = verdicts.sort_by { |verdict| verdict.fetch("candidate_id") }.first
      {
        "group_id" => subject_id,
        "candidate_ids" => candidates.map { |candidate| candidate.fetch("id") }.sort,
        "summary" => semantic ? semantic.fetch("summary") : candidates.first.fetch("summary"),
        "category" => representative.fetch("category"),
        "severity" => verdicts.map { |verdict| verdict.fetch("severity") }.min_by { |severity| SEVERITY_RANK.fetch(severity) },
        "confidence" => verdicts.map { |verdict| verdict.fetch("confidence") }.min,
        "evidence" => verdicts.map { |verdict| verdict.fetch("evidence") }.uniq.sort.join("\n"),
        "consequence" => representative.fetch("consequence"),
        "path" => location.fetch("path"),
        "line" => location.fetch("line_start"),
        "location" => deep_copy(location)
      }
    end

    def add_evidence_gap!(data, task, subject_id, candidate_ids, verdicts)
      data.fetch("evidence_gaps") << {
        "subject_id" => subject_id,
        "candidate_ids" => candidate_ids.sort,
        "task_id" => task.fetch("task_id"),
        "round" => data.fetch("revise_round"),
        "reason" => verdicts.any? do |verdict|
          verdict.fetch("disposition") == "PROMOTE" && verdict.fetch("confidence") < 0.7
        end ? "confidence-below-floor" : "unproven",
        "evidence" => verdicts.map { |verdict| verdict.fetch("evidence") }.uniq.sort.join("\n")
      }
    end

    def promote_with_cap!(data, groups)
      previously_reported = data.fetch("findings").select do |finding|
        finding.fetch("reported")
      end.map { |finding| finding.fetch("id") }
      new_findings = apply_promotions_to_data!(data, groups)
      rerank_reported_findings!(data)
      currently_reported = data.fetch("findings").select do |finding|
        finding.fetch("reported")
      end.map { |finding| finding.fetch("id") }
      promoted = new_findings.select { |finding| finding.fetch("reported") }
      overflowed = new_findings.reject { |finding| finding.fetch("reported") }
      evicted = previously_reported - currently_reported
      [promoted, overflowed, evicted.sort, new_findings]
    end

    def rerank_reported_findings!(data)
      ordered = data.fetch("findings").sort_by do |finding|
        [
          SEVERITY_RANK.fetch(finding.fetch("severity")),
          -Float(finding.fetch("confidence")),
          finding.fetch("path", "").to_s,
          Integer(finding.fetch("line", 0)),
          finding.fetch("group_id"),
          finding.fetch("id")
        ]
      end
      reported_ids = ordered.take(50).map { |finding| finding.fetch("id") }
      reported_lookup = reported_ids.each_with_object({}) { |id, indexed| indexed[id] = true }
      data.fetch("findings").each do |finding|
        finding["reported"] = reported_lookup.key?(finding.fetch("id"))
      end
      overflow_findings = ordered.drop(50)
      counts = Hash.new(0)
      overflow_findings.each do |finding|
        category = finding.fetch("category", "Uncategorized")
        counts["#{category}:#{finding.fetch("severity")}"] += 1
      end
      data["overflow"] = {
        "total" => overflow_findings.length,
        "by_category_severity" => counts.sort.to_h,
        "items" => overflow_findings.map { |finding| finding.fetch("id") }
      }
      overflow_lookup = data.fetch("overflow").fetch("items").each_with_object({}) do |finding_id, indexed|
        indexed[finding_id] = true
      end
      data.fetch("overflow_evidence_gaps").select! do |finding_id, _gap|
        overflow_lookup.key?(finding_id)
      end
    end

    def sort_promotion_groups(groups)
      groups.sort_by do |group|
        [
          SEVERITY_RANK.fetch(group.fetch("severity")),
          -Float(group.fetch("confidence")),
          group.fetch("path", "").to_s,
          Integer(group.fetch("line", 0)),
          group.fetch("group_id")
        ]
      end
    end

    def apply_promotions_to_data!(data, groups)
      validated_groups = groups.map { |group| validate_promotion_group!(group) }
      group_ids = validated_groups.map { |group| group.fetch("group_id") }
      duplicate_group_id = group_ids.group_by { |id| id }.find { |_id, ids| ids.length > 1 }
      if duplicate_group_id
        raise Error.new(
          "invalid_promotion", "promotion group IDs must be unique",
          {"group_id" => duplicate_group_id.first}, 3
        )
      end
      ordered = sort_promotion_groups(validated_groups)
      candidates_by_id = records_by_id(data.fetch("candidates"))
      finding_ids = data.fetch("findings").each_with_object({}) do |finding, indexed|
        indexed[finding.fetch("id")] = true
      end
      seen_candidate_ids = {}
      first_number = data.fetch("findings").length + 1
      fingerprint = Digest::SHA256.hexdigest(data.fetch("run_id"))[0, 8]
      promoted = ordered.each_with_index.map do |group, index|
        candidates = group.fetch("candidate_ids").map do |candidate_id|
          if seen_candidate_ids[candidate_id]
            raise Error.new("candidate_collision", "candidate belongs to multiple promotion groups", {"id" => candidate_id}, 3)
          end
          seen_candidate_ids[candidate_id] = true
          candidate = candidates_by_id[candidate_id]
          unless candidate && candidate.fetch("state") == "candidate"
            raise Error.new("invalid_candidate", "candidate cannot be promoted", {"id" => candidate_id}, 3)
          end
          candidate
        end
        id = format("AR-%s-%03d", fingerprint, first_number + index)
        if finding_ids.key?(id)
          raise Error.new("finding_collision", "promoted finding ID already exists", {"id" => id}, 3)
        end
        candidates.each { |candidate| candidate["state"] = "promoted" }
        deep_copy(group).merge(
          "id" => id,
          "state" => "pending",
          "reported" => false,
          "round" => data.fetch("revise_round"),
          "sources" => candidates.map do |candidate|
            {
              "candidate_id" => candidate.fetch("id"),
              "angle" => candidate.fetch("angle"),
              "attempt" => candidate.fetch("attempt")
            }
          end
        )
      end
      data.fetch("findings").concat(promoted)
      promoted
    end

    def find_candidate_in_data!(data, candidate_id, candidates_by_id = nil)
      candidates_by_id ||= records_by_id(data.fetch("candidates"))
      candidate = candidates_by_id[candidate_id]
      invalid_result!("unknown_candidate", "candidate does not exist", {"id" => candidate_id}) unless candidate

      candidate
    end

    def records_by_id(records)
      records.each_with_object({}) { |record, indexed| indexed[record.fetch("id")] = record }
    end

    def apply_attack_result!(data, task, payload)
      candidate_ids = []
      duplicate_mappings = []
      sequences = Hash.new(0)
      candidate_id_index = {}
      data.fetch("candidates").each do |candidate|
        key = [candidate.fetch("angle"), candidate.fetch("attempt")]
        sequences[key] = [sequences[key], candidate.fetch("sequence")].max
        candidate_id_index[candidate.fetch("id")] = true
      end
      payload.fetch("findings").each_with_index do |finding, index|
        fingerprint = finding_fingerprint(finding)
        source = {
          "task_id" => task.fetch("task_id"),
          "angle" => task.fetch("angle"),
          "attempt" => task.fetch("attempt"),
          "round" => task.fetch("round", data.fetch("revise_round")),
          "finding_index" => index
        }
        retained_id = data.fetch("exact_duplicate_map")[fingerprint]
        if retained_id
          data.fetch("exact_duplicate_sources").fetch(retained_id) << source
          duplicate_mappings << {
            "finding_index" => index,
            "candidate_id" => retained_id,
            "fingerprint" => fingerprint
          }
          candidate_ids << retained_id
          next
        end
        candidate = add_candidate_to_data!(
          data, task.fetch("angle"), task.fetch("attempt"), finding,
          sequences: sequences, candidate_id_index: candidate_id_index
        )
        retained_id = candidate.fetch("id")
        data.fetch("exact_duplicate_map")[fingerprint] = retained_id
        data.fetch("exact_duplicate_sources")[retained_id] = [source]
        candidate_ids << retained_id
      end
      {
        "schema" => result_schema_name!(task),
        "task_id" => task.fetch("task_id"),
        "candidate_ids" => candidate_ids.uniq,
        "duplicate_mappings" => duplicate_mappings
      }
    end

    def finding_fingerprint(finding)
      canonical = %w[location category summary evidence consequence].each_with_object({}) do |key, value|
        value[key] = finding.fetch(key)
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def add_candidate_to_data!(data, angle, attempt, finding, round: data.fetch("revise_round"),
                               sequences: nil, candidate_id_index: nil)
      slug = sanitize_angle(angle)
      sequences ||= data.fetch("candidates").each_with_object(Hash.new(0)) do |candidate, index|
        key = [candidate.fetch("angle"), candidate.fetch("attempt")]
        index[key] = [index[key], candidate.fetch("sequence")].max
      end
      candidate_id_index ||= data.fetch("candidates").each_with_object({}) do |candidate, index|
        index[candidate.fetch("id")] = true
      end
      key = [slug, attempt]
      sequence = sequences[key] + 1
      id = "C-#{slug}-#{attempt}-#{sequence}"
      if candidate_id_index.key?(id)
        invalid_result!("candidate_collision", "candidate ID already exists", {"id" => id})
      end
      created = deep_copy(finding).merge(
        "id" => id,
        "state" => "candidate",
        "angle" => slug,
        "attempt" => attempt,
        "sequence" => sequence,
        "round" => round
      )
      data.fetch("candidates") << created
      sequences[key] = sequence
      candidate_id_index[id] = true
      created
    end

    def live_target_digests!(manifest)
      root = manifest.fetch("repository").fetch("root")
      canonical_root = File.realpath(root)
      unless canonical_root == root && File.directory?(canonical_root)
        invalid_result!("target_digest_mismatch", "authoritative repository root is invalid")
      end
      manifest.fetch("targets").each_with_object({}) do |target, digests|
        path = target.fetch("path")
        unless safe_relative_target_path?(path)
          invalid_result!("target_digest_mismatch", "authoritative target path is invalid")
        end
        absolute = File.expand_path(path, canonical_root)
        unless absolute.start_with?(canonical_root + File::SEPARATOR) && File.realpath(absolute) == absolute
          invalid_result!("target_digest_mismatch", "authoritative target escapes repository")
        end
        expected = File.lstat(absolute)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(absolute, flags) do |file|
          opened = file.stat
          unless opened.file? && !expected.symlink? &&
                 expected.dev == opened.dev && expected.ino == opened.ino
            invalid_result!("target_digest_mismatch", "authoritative target identity changed")
          end
          digests[path] = Digest::SHA256.hexdigest(file.read)
        end
      end
    rescue KeyError, Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP,
           Errno::EACCES, Errno::EPERM => error
      invalid_result!(
        "target_digest_mismatch", "authoritative target is unavailable",
        {"cause" => error.class.name}
      )
    end

    def safe_relative_target_path?(path)
      path.is_a?(String) && !path.empty? && !path.start_with?(File::SEPARATOR) &&
        path.split(File::SEPARATOR).none? { |part| part.empty? || part == "." || part == ".." }
    end

    def validate_promotion_group!(group)
      unless group.is_a?(Hash) && group["group_id"].is_a?(String) && !group["group_id"].empty? &&
             group["candidate_ids"].is_a?(Array) && !group["candidate_ids"].empty? &&
             SEVERITY_RANK.key?(group["severity"]) && group["confidence"].is_a?(Numeric)
        raise Error.new("invalid_promotion", "promotion group is incomplete or invalid", {"group" => group}, 3)
      end
      group
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def find_finding!(data, finding_id)
      finding = data.fetch("findings").find { |item| item.fetch("id") == finding_id }
      unless finding
        raise Error.new("unknown_finding", "promoted finding does not exist", {"id" => finding_id}, 3)
      end
      finding
    end

    def validate_digest_set!(digests)
      valid = digests.is_a?(Hash) && !digests.empty? && digests.all? do |path, digest|
        path.is_a?(String) && !path.empty? && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      end
      return if valid

      raise Error.new("invalid_digest", "target digests must be path-to-SHA256 mappings", {}, 3)
    end

    def refresh!
      Atomic.open_lock(
        File.join(@run_dir, ".state.lock"),
        exclusive: false,
        expected_directory_identity: @run_identity,
        identity_code: "unsafe_run_dir"
      ) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        self.class.validate_snapshot!(manifest, data)
        verify_ingested_files!(run_directory, data)
        @manifest = manifest
        @data = data
      end
    end

    def verify_ingested_files!(run_directory, data)
      self.class.verify_ingested_files!(
        run_directory, data,
        tasks_identity: @tasks_identity, results_identity: @results_identity
      )
    end
  end
end
