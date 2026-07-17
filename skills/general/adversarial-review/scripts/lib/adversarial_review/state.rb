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

    RUN_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/.freeze
    TRANSITIONS = {
      "prepared" => %w[attacking].freeze,
      "attacking" => %w[deduplicating].freeze,
      "deduplicating" => %w[culling].freeze,
      "culling" => %w[awaiting-author complete].freeze,
      "awaiting-author" => %w[resolving].freeze,
      "resolving" => %w[fresh-sweep arbitrating complete did-not-converge].freeze,
      "fresh-sweep" => %w[culling-new-findings].freeze,
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
    TERMINAL_PAIRINGS = {
      "fixed" => "resolved",
      "rejected" => "rejected"
    }.freeze
    MUTATION_STAGES = {
      "ingest_candidate" => %w[attacking fresh-sweep].freeze,
      "promote" => %w[culling culling-new-findings].freeze,
      "record_author_action" => %w[awaiting-author].freeze,
      "record_resolution" => %w[resolving].freeze,
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
      end
      new(
        canonical_run_dir, data, manifest,
        run_identity: run_identity, tasks_identity: tasks_identity
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
      Atomic.open_lock(lock_path, exclusive: false) do |_lock, run_directory|
        manifest = Atomic.read_json_relative(run_directory, "manifest.json")
        data = Atomic.read_json_relative(run_directory, "state.json")
        validate_snapshot!(manifest, data)
        run_identity = run_directory.stat
        Atomic.with_relative_directory(run_directory, "tasks") do |tasks_directory|
          tasks_identity = tasks_directory.stat
        end
      end
      new(
        canonical_run_dir, data, manifest,
        run_identity: run_identity, tasks_identity: tasks_identity
      )
    end

    def initialize(run_dir, data, manifest, run_identity:, tasks_identity:)
      @run_dir = run_dir
      @data = data
      @manifest = manifest
      @run_identity = run_identity
      @tasks_identity = tasks_identity
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
        value = yield(
          deep_freeze(deep_copy(manifest)),
          deep_freeze(deep_copy(data))
        )
        Atomic.with_relative_directory(
          run_directory, "tasks",
          code: "unsafe_task_path",
          expected_identity: @tasks_identity
        ) do |tasks_directory|
          Atomic.write_new_json(tasks_directory, File.basename(task_path), value)
        end
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
        Atomic.with_relative_directory(
          run_directory, "tasks",
          code: "unsafe_task_path",
          expected_identity: @tasks_identity
        ) do |tasks_directory|
          emitted = Atomic.read_json_relative(
            tasks_directory, File.basename(task_path),
            code: "invalid_task", unsafe_code: "invalid_task", unsafe_exit_status: 3
          )
          result = yield(
            deep_freeze(deep_copy(manifest)),
            deep_freeze(deep_copy(data)),
            deep_freeze(emitted)
          )
        end
      end
      result
    end

    def transition_to(next_stage)
      mutate! do |data|
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
        elsif current == "fresh-sweep" && next_stage == "culling-new-findings"
          data["fresh_sweep_completed"] = true
        end
        if next_stage == "complete"
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
        validated_groups = groups.map { |group| validate_promotion_group!(group) }
        group_ids = validated_groups.map { |group| group.fetch("group_id") }
        duplicate_group_id = group_ids.group_by { |id| id }.find { |_id, ids| ids.length > 1 }
        if duplicate_group_id
          raise Error.new(
            "invalid_promotion", "promotion group IDs must be unique",
            {"group_id" => duplicate_group_id.first}, 3
          )
        end
        ordered = validated_groups.sort_by do |group|
          [
            SEVERITY_RANK.fetch(group.fetch("severity")),
            -Float(group.fetch("confidence")),
            group.fetch("path", "").to_s,
            Integer(group.fetch("line", 0)),
            group.fetch("group_id")
          ]
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
            candidate = data.fetch("candidates").find { |item| item.fetch("id") == candidate_id }
            unless candidate && candidate.fetch("state") == "candidate"
              raise Error.new("invalid_candidate", "candidate cannot be promoted", {"id" => candidate_id}, 3)
            end
            candidate
          end
          id = format("AR-%s-%03d", fingerprint, first_number + index)
          if data.fetch("findings").any? { |finding| finding.fetch("id") == id }
            raise Error.new("finding_collision", "promoted finding ID already exists", {"id" => id}, 3)
          end
          candidates.each { |candidate| candidate["state"] = "promoted" }
          deep_copy(group).merge(
            "id" => id,
            "state" => "pending",
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

    def set_pending_arbiter_subjects(finding_ids)
      unless finding_ids.is_a?(Array) && finding_ids.all? { |id| id.is_a?(String) }
        raise Error.new("invalid_arbiter_subjects", "arbiter subjects must be finding IDs", {}, 3)
      end
      mutate! do |data|
        ensure_mutation_stage!(data, "set_pending_arbiter_subjects")
        finding_ids.each { |id| find_finding!(data, id) }
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
        schema_version run_id mode stage revise_round task_attempts candidates findings
        author_actions resolution_checks pending_arbiter_subjects target_digest_history
        current_target_digests fresh_sweep_required fresh_sweep_completed
        degraded_capabilities events next_action
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
             data["task_attempts"].is_a?(Hash) && data["author_actions"].is_a?(Hash) &&
             data["resolution_checks"].is_a?(Hash) && data["pending_arbiter_subjects"].is_a?(Array) &&
             data["degraded_capabilities"].is_a?(Array) && data["events"].is_a?(Array) &&
             [true, false].include?(data["fresh_sweep_required"]) &&
             [true, false].include?(data["fresh_sweep_completed"])
        raise Error.new("invalid_state", "persisted state collections are invalid", {}, 3)
      end
      valid_attempts = data.fetch("task_attempts").all? do |task_id, attempt|
        task_id.is_a?(String) && !task_id.empty? && attempt.is_a?(Integer) && !attempt.negative?
      end
      valid_events = data.fetch("events").all? { |event| valid_event_snapshot?(event) }
      unless valid_attempts && valid_events
        raise Error.new("invalid_state", "persisted attempts or events are invalid", {}, 3)
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
        findings_by_id.key?(finding_id)
      end
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
        %w[candidate promoted refuted unproven].include?(candidate["state"])
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
        finding["id"].is_a?(String) && finding["id"].match?(/\AAR-[0-9a-f]{8}-\d{3}\z/) &&
        finding["group_id"].is_a?(String) && !finding["group_id"].empty? &&
        SEVERITY_RANK.key?(finding["severity"]) && finding["confidence"].is_a?(Numeric) &&
        finding["path"].is_a?(String) && !finding["path"].empty? &&
        finding["line"].is_a?(Integer) && !finding["line"].negative? &&
        [1, 2].include?(finding["round"]) &&
        %w[pending resolved rejected contested stuck].include?(finding["state"])
    end

    def self.valid_author_action_snapshot?(action)
      status = action.is_a?(Hash) ? action["status"] : action
      %w[fixed rejected].include?(status)
    end

    def self.valid_event_snapshot?(event)
      return false unless event.is_a?(Hash) && event["type"].is_a?(String) && !event["type"].empty?
      return true unless event["type"] == "transition"

      from = event["from"]
      to = event["to"]
      from.is_a?(String) && to.is_a?(String) && TRANSITIONS.fetch(from, []).include?(to)
    end

    def self.terminal_pairing(action, resolution)
      status = action.is_a?(Hash) ? action["status"] : action
      expected_resolution = TERMINAL_PAIRINGS[status]
      return :incomplete unless expected_resolution && %w[resolved rejected].include?(resolution)

      expected_resolution == resolution ? :complete : :invalid
    end

    def self.completion_blockers(data, from_stage:)
      blockers = []
      unless data.fetch("current_target_digests") == data.fetch("target_digest_history").last
        blockers << "target-digest-mismatch"
      end
      blockers << "pending-arbiter" unless data.fetch("pending_arbiter_subjects").empty?
      if data.fetch("fresh_sweep_required") && !data.fetch("fresh_sweep_completed")
        blockers << "fresh-sweep-incomplete"
      end
      blockers << "degraded-capabilities" unless data.fetch("degraded_capabilities").empty?
      blockers << "critique-not-culled" if data.fetch("mode") == "critique" && from_stage != "culling"
      data.fetch("findings").each do |finding|
        finding_id = finding.fetch("id")
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
        verify_target_digests!(data)
        yield data
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
        @manifest = manifest
        @data = data
      end
    end
  end
end
