# Canonical JSON block extraction and validation for milestone-orchestrator
# STATE.md and PLAN.md documents. Dependency-free; targets Ruby 2.6.
require "json"

module MilestoneOrchestrator
  class StateDocument
    STATE_OPEN = /<!--\s*milestone-orchestrator-state:v(\d+)\s*-->/
    STATE_CLOSE = "<!-- /milestone-orchestrator-state -->".freeze
    PLAN_OPEN = /<!--\s*milestone-orchestrator-plan:v(\d+)\s*-->/
    PLAN_CLOSE = "<!-- /milestone-orchestrator-plan -->".freeze

    SUPPORTED_SCHEMA_VERSION = 1

    RUN_PHASES = %w[preparing prepared running publishing aborting blocked closed].freeze
    ADAPTERS = %w[orca codex claude].freeze
    TASK_TYPES = %w[implementation review verification integration cleanup].freeze
    TASK_STAGES = %w[pending implemented reviewed verified integrated closed].freeze
    TASK_CONDITIONS = %w[active blocked failed circuit-open cleanup-pending retained].freeze
    ATTEMPT_STATUSES = %w[created dispatched completed failed blocked abandoned].freeze
    RESOURCE_KINDS = %w[worktree terminal browser-tab].freeze
    RESOURCE_STATUSES = %w[active cleaned retained].freeze

    REQUIRED_RUN_FIELDS = %w[
      id slug epoch phase adapter repository coordinator_id root_task_id
      task_allowlist spec_sha256 plan_sha256 base_branch base_sha
      integration_branch
    ].freeze
    REQUIRED_BUDGETS = %w[
      transient_retries task_failures review_remediation_rounds replans
      ci_wait_seconds ci_infra_retries no_progress_cycles worker_dispatches
      attempt_stall_checks
    ].freeze
    FORBIDDEN_AUTHORITY = %w[merge deploy].freeze
    REQUIRED_AUTHORITY_FIELDS = %w[
      local_checkpoint implementation_commit push draft_pr pr_ready
      assign_reviewers merge deploy remote
    ].freeze
    REQUIRED_CLOSEOUT_FIELDS = %w[
      branch head_sha pr verification ci review_rounds open_findings
      publication_actions resources open_risks next_action
    ].freeze

    Finding = Struct.new(:code, :path, :message) do
      def to_h
        {"code" => code, "path" => path, "message" => message}
      end
    end

    attr_reader :errors

    def initialize(state_markdown, plan_markdown = nil)
      @state_markdown = state_markdown
      @plan_markdown = plan_markdown
      @errors = []
    end

    def validate
      state = extract(@state_markdown, STATE_OPEN, STATE_CLOSE, "state")
      validate_state(state) if state
      if @plan_markdown
        plan = extract(@plan_markdown, PLAN_OPEN, PLAN_CLOSE, "plan")
        validate_plan(plan) if plan
      end
      @errors
    end

    def valid?
      @errors.empty?
    end

    def report
      {"valid" => valid?, "errors" => @errors.map(&:to_h)}
    end

    private

    def error(code, path, message)
      @errors << Finding.new(code, path, message)
    end

    def extract(markdown, open_re, close_marker, label)
      match = markdown.match(open_re)
      unless match
        error("missing_#{label}_block", label, "no canonical #{label} block marker found")
        return nil
      end
      tail = markdown[(match.end(0))..-1]
      close_at = tail.index(close_marker)
      unless close_at
        error("missing_#{label}_block", label, "canonical #{label} block is not closed")
        return nil
      end
      body = tail[0...close_at]
      fence = body.match(/```json\s*\n(.*?)```/m)
      unless fence
        error("missing_#{label}_block", label, "no ```json fence inside the #{label} block")
        return nil
      end
      begin
        JSON.parse(fence[1])
      rescue JSON::ParserError => e
        error("invalid_json", label, "canonical #{label} JSON does not parse: #{e.message}")
        nil
      end
    end

    def validate_state(state)
      unless state.is_a?(Hash)
        error("invalid_json", "state", "canonical state block must be a JSON object")
        return
      end
      version = state["schema_version"]
      unless version == SUPPORTED_SCHEMA_VERSION
        error("unsupported_schema_version", "schema_version",
              "schema_version #{version.inspect} is not supported; fail closed")
        return
      end

      run = require_hash(state, "run")
      authority = require_hash(state, "authority")
      budgets = require_hash(state, "budgets")
      tasks = require_hash(state, "tasks")
      resources = require_hash(state, "resources")

      validate_run(run) if run
      validate_authority(authority) if authority
      validate_budgets(budgets) if budgets
      validate_tasks(tasks) if tasks
      validate_resources(resources) if resources
      validate_phase_requirements(run, budgets) if run
      validate_template_tokens(state)

      if run && run["phase"] == "closed"
        validate_closeout(state["closeout"])
      end
    end

    def require_hash(state, key)
      value = state[key]
      return value if value.is_a?(Hash)
      error("missing_section", key, "state must contain a #{key.inspect} object")
      nil
    end

    def validate_run(run)
      REQUIRED_RUN_FIELDS.each do |field|
        if run[field].nil?
          error("missing_field", "run.#{field}", "run.#{field} is required")
        end
      end
      check_enum(run["phase"], RUN_PHASES, "run.phase")
      check_enum(run["adapter"], ADAPTERS, "run.adapter")
    end

    def validate_authority(authority)
      REQUIRED_AUTHORITY_FIELDS.each do |field|
        if authority[field].nil?
          error("missing_field", "authority.#{field}", "authority.#{field} is required")
        end
      end
      FORBIDDEN_AUTHORITY.each do |field|
        if authority[field] == true
          error("forbidden_authority", "authority.#{field}",
                "authority.#{field} must always be false; #{field} is never automated")
        end
      end
    end

    def validate_budgets(budgets)
      REQUIRED_BUDGETS.each do |field|
        value = budgets[field]
        if value.nil?
          error("missing_budget", "budgets.#{field}", "budget #{field} may not be unset")
        elsif !value.is_a?(Integer) || value < 0
          error("invalid_budget", "budgets.#{field}", "budget #{field} must be a non-negative integer")
        end
      end
    end

    # Fields that may legitimately be unresolved while phase is "preparing"
    # but are load-bearing for every later phase.
    GIT_OID = /\A[0-9a-f]{40}\z/.freeze

    def validate_phase_requirements(run, budgets)
      return if run["phase"] == "preparing"
      commit = run["checkpoint_commit"]
      unless commit.is_a?(String) && commit =~ GIT_OID
        error("missing_checkpoint_commit", "run.checkpoint_commit",
              "phase #{run["phase"].inspect} requires checkpoint_commit to be a full git OID")
      end
      dispatches = budgets && budgets["worker_dispatches"]
      if dispatches.is_a?(Integer) && dispatches < 1
        error("invalid_budget", "budgets.worker_dispatches",
              "worker_dispatches must be computed at preflight (>= 1) before phase #{run["phase"].inspect}")
      end
    end

    def validate_tasks(tasks)
      tasks.each do |task_id, task|
        unless task.is_a?(Hash)
          error("invalid_task", "tasks.#{task_id}", "task entry must be an object")
          next
        end
        check_enum(task["type"], TASK_TYPES, "tasks.#{task_id}.type")
        check_enum(task["stage"], TASK_STAGES, "tasks.#{task_id}.stage")
        check_enum(task["condition"], TASK_CONDITIONS, "tasks.#{task_id}.condition")
        check_evidence_size(task["note"], "tasks.#{task_id}.note")
        attempts = task["attempts"]
        if attempts.is_a?(Array)
          attempts.each_with_index do |attempt, index|
            next unless attempt.is_a?(Hash)
            check_enum(attempt["status"], ATTEMPT_STATUSES,
                       "tasks.#{task_id}.attempts[#{index}].status")
            check_evidence_size(attempt["evidence"],
                                "tasks.#{task_id}.attempts[#{index}].evidence")
          end
          if TASK_STAGES.index(task["stage"]).to_i > 0 &&
             attempts.none? { |a| a.is_a?(Hash) && a["status"] == "completed" }
            error("stage_without_completed_attempt", "tasks.#{task_id}.stage",
                  "stage #{task["stage"].inspect} requires at least one completed attempt")
          end
        elsif TASK_STAGES.index(task["stage"]).to_i > 0
          error("stage_without_completed_attempt", "tasks.#{task_id}.stage",
                "stage #{task["stage"].inspect} requires at least one completed attempt")
        end
      end
    end

    # Evidence in STATE is a digest plus a pointer; prose belongs in the
    # milestone's evidence/ directory. The ledger is re-read constantly, so
    # oversized entries tax every later coordinator turn.
    EVIDENCE_MAX_CHARS = 1000

    def check_evidence_size(value, path)
      return unless value.is_a?(String) && value.length > EVIDENCE_MAX_CHARS
      error("oversized_evidence", path,
            "#{value.length} chars exceeds #{EVIDENCE_MAX_CHARS}; record a short digest " \
            "plus a path into the milestone evidence/ directory instead")
    end

    def validate_resources(resources)
      resources.each do |resource_id, resource|
        unless resource.is_a?(Hash)
          error("invalid_resource", "resources.#{resource_id}", "resource entry must be an object")
          next
        end
        check_enum(resource["kind"], RESOURCE_KINDS, "resources.#{resource_id}.kind")
        check_enum(resource["status"], RESOURCE_STATUSES, "resources.#{resource_id}.status")
        if resource["created_by_run"].nil?
          error("missing_field", "resources.#{resource_id}.created_by_run",
                "resource provenance (created_by_run) is required")
        end
      end
    end

    def validate_closeout(closeout)
      unless closeout.is_a?(Hash)
        error("incomplete_closeout", "closeout",
              "phase is closed but closeout record is missing")
        return
      end
      REQUIRED_CLOSEOUT_FIELDS.each do |field|
        unless closeout.key?(field)
          error("incomplete_closeout", "closeout.#{field}",
                "closeout.#{field} is required before the run may close")
        end
      end
      findings = closeout["open_findings"]
      if findings.is_a?(Array) && !findings.empty?
        error("open_findings_at_closeout", "closeout.open_findings",
              "run may not close with open findings")
      end
    end

    def validate_template_tokens(node, path = "state")
      case node
      when Hash
        node.each { |key, value| validate_template_tokens(value, "#{path}.#{key}") }
      when Array
        node.each_with_index { |value, index| validate_template_tokens(value, "#{path}[#{index}]") }
      when String
        if node =~ /\A<[a-z0-9|\/ -]+>\z/i
          error("unresolved_template_token", path,
                "unresolved template token #{node.inspect} in an initialized state")
        end
      end
    end

    def validate_plan(plan)
      unless plan.is_a?(Hash)
        error("invalid_json", "plan", "canonical plan block must be a JSON object")
        return
      end
      unless plan["schema_version"] == SUPPORTED_SCHEMA_VERSION
        error("unsupported_schema_version", "plan.schema_version",
              "plan schema_version #{plan["schema_version"].inspect} is not supported")
        return
      end
      requirements = plan["requirements"] || {}
      tasks = plan["tasks"] || {}
      commands = plan["verification_commands"] || {}

      tasks.each do |task_id, task|
        next unless task.is_a?(Hash)
        check_enum(task["type"], TASK_TYPES, "plan.tasks.#{task_id}.type")
        (task["depends_on"] || []).each do |dep|
          unless tasks.key?(dep)
            error("dangling_reference", "plan.tasks.#{task_id}.depends_on",
                  "depends_on references unknown task #{dep.inspect}")
          end
        end
        (task["acceptance_ids"] || []).each do |ac|
          unless requirements.key?(ac)
            error("dangling_reference", "plan.tasks.#{task_id}.acceptance_ids",
                  "acceptance_ids references unknown requirement #{ac.inspect}")
          end
        end
        (task["verification_command_ids"] || []).each do |cmd|
          unless commands.key?(cmd)
            error("dangling_reference", "plan.tasks.#{task_id}.verification_command_ids",
                  "verification_command_ids references unknown command #{cmd.inspect}")
          end
        end
      end

      commands.each do |command_id, command|
        next unless command.is_a?(Hash)
        argv = command["argv"]
        unless argv.is_a?(Array) && !argv.empty? && argv.all? { |part| part.is_a?(String) }
          error("invalid_argv", "plan.verification_commands.#{command_id}.argv",
                "argv must be a non-empty array of strings, never a shell string")
        end
        cwd = command["cwd"]
        if cwd.is_a?(String) && (cwd.start_with?("/") || cwd.split("/").include?(".."))
          error("invalid_cwd", "plan.verification_commands.#{command_id}.cwd",
                "cwd must be a relative path that does not escape the repository")
        end
      end

      validate_ownership_overlap(tasks)
    end

    # Two implementation tasks that can run concurrently (neither transitively
    # depends on the other) must not share owned paths.
    def validate_ownership_overlap(tasks)
      ids = tasks.keys
      ids.combination(2).each do |a, b|
        task_a = tasks[a]
        task_b = tasks[b]
        next unless task_a.is_a?(Hash) && task_b.is_a?(Hash)
        next unless task_a["type"] == "implementation" && task_b["type"] == "implementation"
        shared = (task_a["owned_paths"] || []) & (task_b["owned_paths"] || [])
        next if shared.empty?
        next if depends_transitively?(tasks, a, b) || depends_transitively?(tasks, b, a)
        error("ownership_overlap", "plan.tasks.#{a}",
              "tasks #{a} and #{b} can run concurrently but share owned paths #{shared.inspect}")
      end
    end

    def depends_transitively?(tasks, from, target, seen = {})
      return false if seen[from]
      seen[from] = true
      deps = tasks[from].is_a?(Hash) ? (tasks[from]["depends_on"] || []) : []
      deps.any? do |dep|
        dep == target || depends_transitively?(tasks, dep, target, seen)
      end
    end

    def check_enum(value, allowed, path)
      return if allowed.include?(value)
      error("invalid_enum", path,
            "#{path} is #{value.inspect}; expected one of #{allowed.join(", ")}")
    end
  end
end
