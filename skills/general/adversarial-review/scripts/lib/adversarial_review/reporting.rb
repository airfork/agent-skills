require "digest"
require "json"
require "securerandom"
require "time"

module AdversarialReview
  module Reporting
    class Error < StandardError
      attr_reader :code, :details, :exit_status

      def initialize(code, message, details = {}, exit_status = 3)
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

    REQUIRED_SOURCE_KEYS = %w[
      schema_version run_id targets repository started_at ended_at tier mode output
      requested_executor selected_executor cli requested_model observed_model
      requested_effort observed_effort enabled_tasks angles capabilities degraded_capabilities usage
      findings semantic_groups author_actions resolution_checks evidence_gaps metrics
    ].freeze
    USAGE_KEYS = %w[
      prompt_bytes input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens
    ].freeze
    ANGLE_STATUSES = %w[completed failed skipped combined].freeze
    SEVERITIES = %w[CRITICAL HIGH MEDIUM LOW].freeze
    MAX_REPORT_BYTES = 64 * 1024 * 1024

    module_function

    def summary(source)
      require_hash!(source, "summary source")
      missing = REQUIRED_SOURCE_KEYS.reject { |key| source.key?(key) }
      invalid!("invalid_summary", "summary source is incomplete", {"missing" => missing}) unless missing.empty?
      invalid!("invalid_summary", "unsupported summary schema version") unless source["schema_version"] == 1

      run_id = validate_run_id!(source.fetch("run_id"))
      mode = validate_enum!("mode", source.fetch("mode"), %w[critique revise])
      tier = validate_enum!("tier", source.fetch("tier"), %w[default high ultra])
      output = validate_enum!("output", source.fetch("output"), %w[chat file both])
      started_at = validate_timestamp!("started_at", source.fetch("started_at"))
      ended_at = validate_timestamp!("ended_at", source.fetch("ended_at"))
      if Time.iso8601(ended_at) < Time.iso8601(started_at)
        invalid!("invalid_timestamps", "review end timestamp precedes its start timestamp")
      end

      targets = canonical_targets(source.fetch("targets"))
      repository = canonical_repository(source.fetch("repository"))
      executor = {
        "requested" => nonempty_string!(source.fetch("requested_executor"), "requested_executor"),
        "selected" => nonempty_string!(source.fetch("selected_executor"), "selected_executor")
      }
      cli = canonical_cli(source.fetch("cli"))
      model = observed_pair(source, "model")
      effort = observed_pair(source, "effort")
      enabled_tasks = canonical_enabled_tasks(source.fetch("enabled_tasks"))
      angles = canonical_angles(source.fetch("angles"), enabled_tasks)
      capabilities = canonical_capabilities(
        source.fetch("capabilities"),
        requested_model: source.fetch("requested_model"),
        requested_effort: source.fetch("requested_effort")
      )
      usage = canonical_usage(source.fetch("usage"))
      findings = canonical_findings(source, run_id, angles.map { |angle| angle.fetch("name") })
      actions = canonical_actions(source.fetch("author_actions"), findings)
      resolution_checks = canonical_resolutions(source.fetch("resolution_checks"), findings)
      evidence_gaps = canonical_evidence_gaps(source.fetch("evidence_gaps"))
      ordinary_verdict = verdict_for(mode, findings, evidence_gaps)
      capability_gate = Capabilities.gate(
        capabilities, ordinary_verdict == "PASSED" ? "PASS" : ordinary_verdict
      )
      degraded = capability_gate.fetch("degraded_capabilities")
      disclosed = source.fetch("degraded_capabilities")
      unless disclosed.is_a?(Array) && disclosed.all? { |name| name.is_a?(String) } &&
             disclosed.uniq.sort == degraded.sort
        invalid!(
          "invalid_capabilities",
          "degraded capability disclosure does not match the authoritative gate",
          {"expected" => degraded.sort, "observed" => disclosed}
        )
      end
      verdict = capability_gate.fetch("verdict") == "PASS" ? "PASSED" : capability_gate.fetch("verdict")

      result = {
        "schema_version" => 1,
        "run_id" => run_id,
        "mode" => mode,
        "tier" => tier,
        "output" => output,
        "verdict" => verdict,
        "findings" => findings,
        "metrics" => canonical_metrics(source.fetch("metrics"), findings),
        "changelog" => changelog(actions, findings),
        "rejected_findings" => rejected_findings(actions, findings),
        "open_questions" => open_questions(findings, actions, evidence_gaps),
        "degraded_capabilities" => degraded,
        "provenance" => {
          "schema_version" => 1,
          "run_id" => run_id,
          "targets" => targets,
          "repository" => repository,
          "started_at" => started_at,
          "ended_at" => ended_at,
          "tier" => tier,
          "mode" => mode,
          "output" => output,
          "executor" => executor,
          "cli" => cli,
          "model" => model,
          "effort" => effort,
          "enabled_tasks" => enabled_tasks,
          "angles" => angles,
          "capabilities" => capabilities,
          "retries" => angles.sum { |angle| angle.fetch("retries") },
          "usage" => usage
        },
        "resolution_checks" => resolution_checks
      }
      deep_copy(result)
    rescue Error
      raise
    rescue KeyError => error
      invalid!("invalid_summary", "summary source is structurally incomplete", {"field" => error.key})
    rescue ArgumentError, TypeError, NoMethodError, JSON::GeneratorError => error
      invalid!(
        "invalid_summary", "summary source contains an invalid value",
        {"cause" => error.message, "cause_class" => error.class.name}
      )
    end

    def markdown(value, compact: false)
      validate_render_summary!(value)
      lines = []
      lines << (compact ? "## Re-review #{value.fetch("run_id")}" : "# Adversarial Review")
      lines << ""
      lines << value.fetch("verdict")
      lines << ""
      append_findings(lines, value)
      append_metrics(lines, value.fetch("metrics"))
      if value.fetch("mode") == "revise"
        append_item_section(lines, "Changelog", value.fetch("changelog"))
        append_item_section(lines, "Rejected Findings", value.fetch("rejected_findings"))
        append_item_section(lines, "Open Questions", value.fetch("open_questions"))
      end
      append_provenance(lines, value)
      lines.join("\n").rstrip + "\n"
    rescue Error
      raise
    rescue KeyError, TypeError, NoMethodError => error
      invalid!(
        "invalid_summary", "render summary is structurally invalid",
        {"cause" => error.message}
      )
    end

    def chat_payload(value)
      validate_render_summary!(value)
      {
        "schema_version" => value.fetch("schema_version"),
        "run_id" => value.fetch("run_id"),
        "verdict" => value.fetch("verdict"),
        "findings" => deep_copy(value.fetch("findings")),
        "metrics" => deep_copy(value.fetch("metrics")),
        "degraded_capabilities" => deep_copy(value.fetch("degraded_capabilities")),
        "provenance" => deep_copy(value.fetch("provenance")),
        "markdown" => markdown(value)
      }
    end

    def append(path, value)
      validate_render_summary!(value)
      unless path.is_a?(String) && !path.empty? && !path.include?("\0")
        invalid!("unsafe_report", "report path must be a non-empty string", {"path" => path}, 2)
      end
      expanded = File.expand_path(path)
      parent = File.dirname(expanded)
      name = File.basename(expanded)
      Atomic.validate_relative_name!(name)
      lock_path = File.join(parent, ".#{name}.lock")
      ensure_report_lock!(lock_path)

      Atomic.open_lock(lock_path, exclusive: true, identity_code: "unsafe_lock") do |_lock, directory|
        existing = read_report(directory, name)
        run_id = value.fetch("run_id")
        marker = "<!-- adversarial-review-run:#{run_id}:v1 -->"
        duplicate_marker = /^<!-- (?:\/)?adversarial-review-run:#{Regexp.escape(run_id)}(?::v1)? -->$/
        if existing.match?(duplicate_marker)
          invalid!(
            "duplicate_run", "report already contains this adversarial review run",
            {"run_id" => value.fetch("run_id"), "path" => expanded}
          )
        end
        rendered = markdown(value, compact: !existing.strip.empty?)
        section = [marker, rendered.rstrip,
                   "<!-- /adversarial-review-run:#{value.fetch("run_id")} -->"].join("\n") + "\n"
        bytes = existing.empty? ? section : existing.rstrip + "\n\n" + section
        write_report(directory, name, bytes)
      end
      expanded
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise State::Error.new(
        "unsafe_report", "report path is unsafe",
        {"path" => path, "cause" => error.class.name}, 2
      )
    end

    def canonical_targets(targets)
      unless targets.is_a?(Array) && !targets.empty?
        invalid!("invalid_targets", "targets must be a non-empty array")
      end
      canonical = targets.map do |target|
        require_hash!(target, "target")
        role = validate_enum!("target role", target.fetch("role"), %w[spec plan])
        path = nonempty_string!(target.fetch("path"), "target path")
        reject_control_characters!(path, "target path")
        sha = target.fetch("sha256")
        unless sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)
          invalid!("invalid_targets", "target SHA-256 is invalid", {"path" => path})
        end
        {"role" => role, "path" => path, "sha256" => sha}
      rescue KeyError => error
        invalid!("invalid_targets", "target provenance is incomplete", {"field" => error.key})
      end
      paths = canonical.map { |target| target.fetch("path") }
      invalid!("invalid_targets", "target paths must be unique") unless paths.uniq.length == paths.length
      canonical.sort_by { |target| [target.fetch("role"), target.fetch("path")] }
    end

    def canonical_repository(repository)
      require_hash!(repository, "repository")
      root = nonempty_string!(repository.fetch("root"), "repository root")
      invalid!("invalid_repository", "repository root must be absolute") unless File.absolute_path(root) == root
      head = repository.fetch("head")
      unless head.is_a?(String) && head.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
        invalid!("invalid_repository", "repository HEAD is invalid")
      end
      dirty = repository.fetch("dirty")
      invalid!("invalid_repository", "repository dirty flag must be boolean") unless [true, false].include?(dirty)
      status = repository.fetch("status")
      unless status.is_a?(Array) && status.all? { |line| line.is_a?(String) && !line.include?("\0") }
        invalid!("invalid_repository", "repository status must be an array of strings")
      end
      dirty_digest = repository["dirty_digest"] || Digest::SHA256.hexdigest(JSON.generate(status))
      unless dirty_digest.is_a?(String) && dirty_digest.match?(/\A[0-9a-f]{64}\z/)
        invalid!("invalid_repository", "repository dirty-state digest is invalid")
      end
      {"root" => root, "head" => head, "dirty" => dirty,
       "dirty_digest" => dirty_digest, "status" => status.dup}
    rescue KeyError => error
      invalid!("invalid_repository", "repository provenance is incomplete", {"field" => error.key})
    end

    def canonical_cli(cli)
      require_hash!(cli, "cli")
      realpath = nonempty_string!(cli.fetch("realpath"), "CLI realpath")
      invalid!("invalid_cli", "CLI realpath must be absolute") unless File.absolute_path(realpath) == realpath
      {"realpath" => realpath, "version" => nonempty_string!(cli.fetch("version"), "CLI version")}
    rescue KeyError => error
      invalid!("invalid_cli", "CLI provenance is incomplete", {"field" => error.key})
    end

    def observed_pair(source, kind)
      requested = source.fetch("requested_#{kind}")
      observed = source.fetch("observed_#{kind}")
      [requested, observed].each do |value|
        next if value.nil? || (value.is_a?(String) && !value.strip.empty?)

        invalid!("invalid_runtime", "#{kind} provenance must be a non-empty string or null")
      end
      {"requested" => requested, "observed" => observed}
    end

    def canonical_enabled_tasks(enabled_tasks)
      unless enabled_tasks.is_a?(Array) && !enabled_tasks.empty? &&
             enabled_tasks.all? { |name| name.is_a?(String) && name.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/) } &&
             enabled_tasks.uniq.length == enabled_tasks.length
        invalid!("invalid_angles", "enabled angle inventory must contain unique normalized names")
      end
      enabled_tasks.sort
    end

    def canonical_angles(angles, enabled_tasks)
      unless angles.is_a?(Array) && !angles.empty?
        invalid!("invalid_angles", "angle provenance must be a non-empty array")
      end
      records = angles.map do |angle|
        require_hash!(angle, "angle")
        name = nonempty_string!(angle.fetch("name"), "angle name")
        status = validate_enum!("angle status", angle.fetch("status"), ANGLE_STATUSES)
        retries = angle.fetch("retries")
        unless retries.is_a?(Integer) && retries >= 0
          invalid!("invalid_angles", "angle retries must be a non-negative integer", {"name" => name})
        end
        reason = angle.fetch("failure_reason")
        unless reason.nil? || (reason.is_a?(String) && !reason.strip.empty?)
          invalid!("invalid_angles", "angle failure reason must be a non-empty string or null", {"name" => name})
        end
        if %w[failed skipped combined].include?(status) && reason.nil?
          invalid!(
            "invalid_angles", "failed, skipped, and combined angles require a reason",
            {"name" => name}
          )
        end
        retry_reasons = angle.fetch("retry_reasons")
        unless retry_reasons.is_a?(Array) && retry_reasons.length == retries &&
               retry_reasons.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
          invalid!(
            "invalid_angles", "each retry requires one recorded non-empty reason",
            {"name" => name, "retries" => retries}
          )
        end
        {
          "name" => name, "status" => status, "failure_reason" => reason,
          "retries" => retries, "retry_reasons" => retry_reasons.dup
        }
      rescue KeyError => error
        invalid!("invalid_angles", "angle provenance is incomplete", {"field" => error.key})
      end
      names = records.map { |record| record.fetch("name") }
      invalid!("invalid_angles", "angle names must be unique") unless names.uniq.length == names.length
      unless enabled_tasks == names.sort
        invalid!("invalid_angles", "angle provenance does not cover every enabled angle")
      end
      records.sort_by { |record| record.fetch("name") }
    end

    def canonical_capabilities(capabilities, requested_model:, requested_effort:)
      Capabilities.normalize(
        capabilities,
        requested_model: requested_model,
        requested_effort: requested_effort
      )
    rescue Capabilities::Error => error
      invalid!(
        "invalid_capabilities", "capability provenance does not match the shared contract",
        {"cause" => error.message}
      )
    end

    def canonical_usage(usage)
      require_hash!(usage, "usage")
      unless usage.keys.sort == USAGE_KEYS.sort
        invalid!("invalid_usage", "usage provenance keys are incomplete", {"expected" => USAGE_KEYS.sort})
      end
      USAGE_KEYS.each_with_object({}) do |key, canonical|
        value = usage.fetch(key)
        unless value.nil? || (value.is_a?(Integer) && value >= 0)
          invalid!("invalid_usage", "usage values must be non-negative integers or null", {"field" => key})
        end
        canonical[key] = value
      end
    end

    def canonical_findings(source, run_id, recorded_angles)
      findings = source.fetch("findings")
      groups = source.fetch("semantic_groups")
      unless findings.is_a?(Array) && groups.is_a?(Hash)
        invalid!("invalid_findings", "findings and semantic groups have invalid shapes")
      end
      fingerprint = Digest::SHA256.hexdigest(run_id)[0, 8]
      canonical = findings.each_with_index.map do |finding, index|
        require_hash!(finding, "finding")
        expected_id = format("AR-%s-%03d", fingerprint, index + 1)
        unless finding.fetch("id") == expected_id
          invalid!(
            "invalid_findings", "finding ID is not deterministic for this run",
            {"expected" => expected_id, "observed" => finding["id"]}
          )
        end
        reported = finding.fetch("reported")
        invalid!("invalid_findings", "finding reported flag must be boolean") unless [true, false].include?(reported)

        severity = validate_enum!("finding severity", finding.fetch("severity"), SEVERITIES)
        confidence = finding.fetch("confidence")
        unless confidence.is_a?(Numeric) && confidence >= 0 && confidence <= 1
          invalid!("invalid_findings", "finding confidence is outside 0..1", {"id" => expected_id})
        end
        path = nonempty_string!(finding.fetch("path"), "finding path")
        line = finding.fetch("line")
        invalid!("invalid_findings", "finding line must be a non-negative integer") unless line.is_a?(Integer) && line >= 0
        sources = finding.fetch("sources")
        unless sources.is_a?(Array) && !sources.empty? && sources.all? do |item|
                 item.is_a?(Hash) && item["angle"].is_a?(String) && !item["angle"].strip.empty?
               end
          invalid!("invalid_findings", "finding sources are incomplete", {"id" => expected_id})
        end
        source_angles = sources.map { |item| item.fetch("angle") }.uniq.sort
        unless (source_angles - recorded_angles).empty?
          invalid!(
            "invalid_findings", "finding source angle is absent from run provenance",
            {"id" => expected_id, "unknown_angles" => source_angles - recorded_angles}
          )
        end
        group = groups.fetch(finding.fetch("group_id"))
        require_hash!(group, "semantic group")
        text = nonempty_string!(group.fetch("summary"), "finding summary")
        canonical_finding = {
          "id" => expected_id,
          "category" => nonempty_string!(finding.fetch("category"), "finding category"),
          "severity" => severity,
          "location" => "#{path}:#{line}",
          "path" => path,
          "line" => line,
          "summary" => text,
          "consequence" => nonempty_string!(finding.fetch("consequence"), "finding consequence"),
          "confidence" => confidence,
          "source_angles" => source_angles,
          "round" => finding.fetch("round"),
          "state" => validate_enum!(
            "finding state", finding.fetch("state"), %w[pending resolved rejected contested stuck]
          )
        }
        reported ? canonical_finding : nil
      rescue KeyError => error
        invalid!("invalid_findings", "finding provenance is incomplete", {"field" => error.key})
      end.compact
      canonical.sort_by { |finding| finding.fetch("id") }
    end

    def canonical_actions(actions, findings)
      require_hash!(actions, "author actions")
      known = findings.map { |finding| finding.fetch("id") }
      actions.each_with_object({}) do |(finding_id, action), canonical|
        invalid!("invalid_actions", "author action refers to an unknown reported finding") unless known.include?(finding_id)
        require_hash!(action, "author action")
        status = validate_enum!("author action", action.fetch("status"), %w[fixed rejected])
        canonical[finding_id] = {
          "status" => status,
          "rationale" => optional_string(action["rationale"]),
          "changed_paths" => canonical_string_array(action.fetch("changed_paths", []), "changed paths")
        }
      rescue KeyError => error
        invalid!("invalid_actions", "author action is incomplete", {"field" => error.key})
      end.sort.to_h
    end

    def canonical_resolutions(resolutions, findings)
      require_hash!(resolutions, "resolution checks")
      known = findings.map { |finding| finding.fetch("id") }
      resolutions.each_with_object({}) do |(finding_id, status), canonical|
        invalid!("invalid_resolutions", "resolution refers to an unknown reported finding") unless known.include?(finding_id)
        canonical[finding_id] = validate_enum!(
          "resolution", status, %w[pending resolved rejected contested stuck]
        )
      end.sort.to_h
    end

    def canonical_evidence_gaps(gaps)
      invalid!("invalid_evidence_gaps", "evidence gaps must be an array") unless gaps.is_a?(Array)
      gaps.map do |gap|
        require_hash!(gap, "evidence gap")
        {
          "subject_id" => nonempty_string!(gap.fetch("subject_id"), "evidence gap subject"),
          "reason" => nonempty_string!(gap.fetch("reason"), "evidence gap reason"),
          "evidence" => nonempty_string!(gap.fetch("evidence"), "evidence gap evidence")
        }
      rescue KeyError => error
        invalid!("invalid_evidence_gaps", "evidence gap is incomplete", {"field" => error.key})
      end.sort_by { |gap| gap.fetch("subject_id") }
    end

    def canonical_metrics(metrics, findings)
      require_hash!(metrics, "metrics")
      metrics.each do |key, value|
        unless key.is_a?(String) && (value.nil? || value.is_a?(Numeric) || value.is_a?(String) || [true, false].include?(value))
          invalid!("invalid_metrics", "metric values must be scalar", {"field" => key})
        end
      end
      by_severity = SEVERITIES.each_with_object({}) do |severity, counts|
        counts[severity] = findings.count { |finding| finding.fetch("severity") == severity }
      end
      {
        "reported_findings" => findings.length,
        "by_severity" => by_severity,
        "values" => metrics.keys.sort.each_with_object({}) { |key, result| result[key] = metrics[key] }
      }
    end

    def verdict_for(mode, findings, evidence_gaps)
      return "REPORT ONLY - #{findings.length} #{findings.length == 1 ? "finding" : "findings"}" if mode == "critique"

      open = findings.count { |finding| %w[pending contested stuck].include?(finding.fetch("state")) }
      return "DID NOT CONVERGE - #{open} findings remain open" if open.positive?
      return "PASSED WITH OPEN QUESTIONS" unless evidence_gaps.empty?

      "PASSED"
    end

    def changelog(actions, findings)
      by_id = findings.each_with_object({}) { |finding, result| result[finding.fetch("id")] = finding }
      actions.select { |_id, action| action.fetch("status") == "fixed" }.map do |finding_id, action|
        {
          "id" => finding_id,
          "summary" => by_id.fetch(finding_id).fetch("summary"),
          "rationale" => action.fetch("rationale") || "Fixed",
          "changed_paths" => action.fetch("changed_paths")
        }
      end
    end

    def rejected_findings(actions, findings)
      by_id = findings.each_with_object({}) { |finding, result| result[finding.fetch("id")] = finding }
      actions.select { |_id, action| action.fetch("status") == "rejected" }.map do |finding_id, action|
        {
          "id" => finding_id,
          "summary" => by_id.fetch(finding_id).fetch("summary"),
          "rationale" => action.fetch("rationale") || "Rejected without rationale"
        }
      end
    end

    def open_questions(findings, actions, evidence_gaps)
      questions = findings.select do |finding|
        %w[contested stuck].include?(finding.fetch("state"))
      end.map do |finding|
        action = actions[finding.fetch("id")]
        {
          "id" => finding.fetch("id"),
          "question" => finding.fetch("summary"),
          "judge_position" => finding.fetch("consequence"),
          "author_position" => action && action.fetch("rationale")
        }
      end
      questions + evidence_gaps.map do |gap|
        {
          "id" => gap.fetch("subject_id"),
          "question" => gap.fetch("reason"),
          "judge_position" => gap.fetch("evidence"),
          "author_position" => nil
        }
      end
    end

    def append_findings(lines, value)
      findings = value.fetch("findings")
      lines << "## Findings"
      lines << ""
      if value.fetch("mode") == "critique"
        lines << "| ID | Category | Severity | Location | Sources | Summary |"
        lines << "|---|---|---|---|---|---|"
        findings.each do |finding|
          lines << table_row([
            finding.fetch("id"), finding.fetch("category"), finding.fetch("severity"),
            finding.fetch("location"), finding.fetch("source_angles").join(", "), finding.fetch("summary")
          ])
        end
      else
        lines << "| ID | Category | Severity | Location | Sources | Summary | Resolution |"
        lines << "|---|---|---|---|---|---|---|"
        findings.each do |finding|
          lines << table_row([
            finding.fetch("id"), finding.fetch("category"), finding.fetch("severity"),
            finding.fetch("location"), finding.fetch("source_angles").join(", "),
            finding.fetch("summary"), finding.fetch("state")
          ])
        end
      end
      lines << ""
    end

    def append_metrics(lines, metrics)
      lines << "## Metrics"
      lines << ""
      lines << "- Reported findings: #{metrics.fetch("reported_findings")}"
      metrics.fetch("by_severity").each do |severity, count|
        lines << "- #{severity}: #{count}"
      end
      metrics.fetch("values").each { |name, value| lines << "- #{name}: #{display(value)}" }
      lines << ""
    end

    def append_item_section(lines, heading, items)
      lines << "## #{heading}"
      lines << ""
      if items.empty?
        lines << "- None"
      else
        items.each do |item|
          description = item["rationale"] || item["question"] || item["summary"]
          lines << "- #{item.fetch("id")}: #{markdown_text(description)}"
          lines << "  - Judge: #{markdown_text(item["judge_position"])}" if item.key?("judge_position")
          lines << "  - Author: #{markdown_text(item["author_position"])}" if item.key?("author_position")
          if item["changed_paths"] && !item.fetch("changed_paths").empty?
            lines << "  - Paths: #{item.fetch("changed_paths").map { |path| markdown_text(path) }.join(", ")}"
          end
        end
      end
      lines << ""
    end

    def append_provenance(lines, value)
      provenance = value.fetch("provenance")
      degraded = value.fetch("degraded_capabilities")
      unless degraded.empty?
        lines << "## DEGRADED CAPABILITIES"
        lines << ""
        lines << degraded.join(", ")
        lines << ""
      end
      lines << "## Provenance"
      lines << ""
      lines << "| Field | Value |"
      lines << "|---|---|"
      lines << table_row(["Run ID", provenance.fetch("run_id")])
      lines << table_row(["Schema version", provenance.fetch("schema_version")])
      lines << table_row(["Started", provenance.fetch("started_at")])
      lines << table_row(["Ended", provenance.fetch("ended_at")])
      lines << table_row(["Tier", provenance.fetch("tier")])
      lines << table_row(["Mode", provenance.fetch("mode")])
      lines << table_row(["Output", provenance.fetch("output")])
      lines << table_row(["Executor", requested_observed(provenance.fetch("executor"), observed_key: "selected")])
      lines << table_row(["CLI", "#{provenance.dig("cli", "realpath")} (#{provenance.dig("cli", "version")})"])
      lines << table_row(["Model", requested_observed(provenance.fetch("model"))])
      lines << table_row(["Effort", requested_observed(provenance.fetch("effort"))])
      repository = provenance.fetch("repository")
      lines << table_row(["Repository HEAD", repository.fetch("head")])
      lines << table_row(["Repository dirty digest", repository.fetch("dirty_digest")])
      provenance.fetch("targets").each do |target|
        lines << table_row(["Target #{target.fetch("role")}", "#{target.fetch("path")} sha256=#{target.fetch("sha256")}"])
      end
      lines << table_row(["Retries", provenance.fetch("retries")])
      lines << ""
      lines << "### Angles"
      lines << ""
      lines << "| Angle | Status | Retries | Retry reasons | Failure reason |"
      lines << "|---|---|---|---|---|"
      provenance.fetch("angles").each do |angle|
        lines << table_row([
          angle.fetch("name"), angle.fetch("status"), angle.fetch("retries"),
          angle.fetch("retry_reasons").join("; "),
          angle.fetch("failure_reason")
        ])
      end
      lines << ""
      lines << "### Capabilities"
      lines << ""
      lines << "| Capability | Requested | Status | Evidence | Source |"
      lines << "|---|---|---|---|---|"
      provenance.fetch("capabilities").each do |name, capability|
        lines << table_row([
          name, capability.fetch("requested"), capability.fetch("status"),
          capability.fetch("evidence"), capability.fetch("source")
        ])
      end
      lines << ""
      lines << "### Usage"
      lines << ""
      lines << "| Metric | Value |"
      lines << "|---|---|"
      provenance.fetch("usage").each do |metric, amount|
        lines << table_row([metric, amount])
      end
      lines << ""
    end

    def ensure_report_lock!(lock_path)
      lock_name = File.basename(lock_path)
      Atomic.with_bound_directory(File.dirname(lock_path), code: "unsafe_lock") do |parent, directory|
        locked = false
        begin
          unless directory.flock(File::LOCK_EX)
            raise State::Error.new(
              "unsafe_lock", "report lock bootstrap could not lock its parent directory",
              {"path" => lock_path}, 2
            )
          end
          locked = true
          Atomic.verify_directory_identity!(parent, directory, code: "unsafe_lock")
          unless Atomic.reject_relative_nonregular(directory, lock_name, "unsafe_lock")
            Atomic.create_anchored_lock(lock_path)
          end
          Atomic.verify_directory_identity!(parent, directory, code: "unsafe_lock")
        ensure
          directory.flock(File::LOCK_UN) if locked && !directory.closed?
        end
      end
      lock_path
    rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise State::Error.new(
        "unsafe_lock", "report lock path is unsafe",
        {"path" => lock_path, "cause" => error.class.name}, 2
      )
    end

    def read_report(directory, name)
      return "" unless Atomic.reject_relative_nonregular(directory, name, "unsafe_report")

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = Atomic.open_relative(directory, name, flags)
      begin
        Atomic.reject_nonregular_handle(file, name, "unsafe_report")
        if file.stat.size > MAX_REPORT_BYTES
          raise State::Error.new(
            "report_too_large", "existing report exceeds the size limit",
            {"path" => name, "max_bytes" => MAX_REPORT_BYTES}, 3
          )
        end
        bytes = file.read(MAX_REPORT_BYTES + 1)
        if bytes.bytesize > MAX_REPORT_BYTES
          raise State::Error.new("report_too_large", "existing report exceeds the size limit", {"path" => name}, 3)
        end
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise State::Error.new("invalid_report", "existing report is not valid UTF-8", {"path" => name}, 3)
        end
        text
      ensure
        file.close if file && !file.closed?
      end
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise State::Error.new(
        "unsafe_report", "report target is unsafe",
        {"path" => name, "cause" => error.class.name}, 2
      )
    end

    def write_report(directory, destination_name, bytes)
      temporary_name = ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      created = false
      published = false
      begin
        Atomic.reject_relative_nonregular(directory, destination_name, "unsafe_report")
        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = Atomic.open_relative(directory, temporary_name, flags, 0o600)
        created = true
        begin
          file.binmode
          file.chmod(0o600)
          file.write(bytes)
          file.flush
          file.fsync
        ensure
          file.close unless file.closed?
        end
        Atomic.reject_relative_nonregular(directory, destination_name, "unsafe_report")
        Atomic.rename_relative(directory, temporary_name, destination_name)
        created = false
        published = true
        directory.fsync
      rescue StandardError => error
        if published
          raise Error.new(
            "durability_uncertain",
            "report is visible but parent-directory durability could not be confirmed",
            {"path" => destination_name, "cause" => error.class.name, "message" => error.message}
          )
        end
        raise
      ensure
        Atomic.unlink_relative(directory, temporary_name) if created
      end
      destination_name
    rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
      raise State::Error.new(
        "unsafe_report", "report target is unsafe",
        {"path" => destination_name, "cause" => error.class.name}, 2
      )
    end

    def validate_render_summary!(value)
      require_hash!(value, "summary")
      required = %w[
        schema_version run_id mode tier output verdict findings metrics changelog
        rejected_findings open_questions degraded_capabilities provenance resolution_checks
      ]
      missing = required.reject { |key| value.key?(key) }
      invalid!("invalid_summary", "render summary is incomplete", {"missing" => missing}) unless missing.empty?
      invalid!("invalid_summary", "render summary schema is unsupported") unless value["schema_version"] == 1
      run_id = validate_run_id!(value.fetch("run_id"))
      mode = validate_enum!("mode", value.fetch("mode"), %w[critique revise])
      validate_enum!("tier", value.fetch("tier"), %w[default high ultra])
      validate_enum!("output", value.fetch("output"), %w[chat file both])
      findings = validate_render_findings!(value.fetch("findings"), run_id)
      validate_render_metrics!(value.fetch("metrics"), findings)
      %w[changelog rejected_findings open_questions].each do |collection|
        unless value.fetch(collection).is_a?(Array) && value.fetch(collection).all? { |entry| entry.is_a?(Hash) }
          invalid!("invalid_summary", "render summary #{collection} must be an array of objects")
        end
      end
      unless value.fetch("resolution_checks").is_a?(Hash)
        invalid!("invalid_summary", "render summary resolution checks must be an object")
      end
      provenance = value.fetch("provenance")
      require_hash!(provenance, "provenance")
      unless provenance["schema_version"] == value["schema_version"] &&
             provenance["run_id"] == value["run_id"] && provenance["mode"] == value["mode"] &&
             provenance["tier"] == value["tier"] && provenance["output"] == value["output"]
        invalid!("invalid_summary", "render summary identity and provenance disagree")
      end
      canonical_target_records = canonical_targets(provenance.fetch("targets"))
      unless provenance.fetch("targets") == canonical_target_records
        invalid!("invalid_summary", "render summary target order is not canonical")
      end
      canonical_repository(provenance.fetch("repository"))
      started_at = validate_timestamp!("started_at", provenance.fetch("started_at"))
      ended_at = validate_timestamp!("ended_at", provenance.fetch("ended_at"))
      if Time.iso8601(ended_at) < Time.iso8601(started_at)
        invalid!("invalid_summary", "render summary end timestamp precedes its start")
      end
      canonical_cli(provenance.fetch("cli"))
      executor = provenance.fetch("executor")
      require_hash!(executor, "executor provenance")
      nonempty_string!(executor.fetch("requested"), "requested executor")
      nonempty_string!(executor.fetch("selected"), "selected executor")
      %w[model effort].each do |kind|
        pair = provenance.fetch(kind)
        require_hash!(pair, "#{kind} provenance")
        %w[requested observed].each do |field|
          observed = pair.fetch(field)
          unless observed.nil? || (observed.is_a?(String) && !observed.strip.empty?)
            invalid!("invalid_summary", "render summary #{kind} #{field} is invalid")
          end
        end
      end
      enabled_tasks = canonical_enabled_tasks(provenance.fetch("enabled_tasks"))
      unless provenance.fetch("enabled_tasks") == enabled_tasks
        invalid!("invalid_summary", "render summary enabled angle order is not canonical")
      end
      angles = canonical_angles(provenance.fetch("angles"), enabled_tasks)
      unless provenance.fetch("angles") == angles
        invalid!("invalid_summary", "render summary angle order is not canonical")
      end
      recorded_angles = angles.map { |angle| angle.fetch("name") }
      findings.each do |finding|
        unknown = finding.fetch("source_angles") - recorded_angles
        unless unknown.empty?
          invalid!(
            "invalid_summary", "render finding source angle is absent from run provenance",
            {"id" => finding.fetch("id"), "unknown_angles" => unknown}
          )
        end
      end
      capabilities = canonical_capabilities(
        provenance.fetch("capabilities"),
        requested_model: provenance.dig("model", "requested"),
        requested_effort: provenance.dig("effort", "requested")
      )
      unless provenance.fetch("capabilities") == capabilities
        invalid!("invalid_summary", "render summary capability order is not canonical")
      end
      canonical_usage(provenance.fetch("usage"))
      unless provenance.fetch("usage").keys == USAGE_KEYS
        invalid!("invalid_summary", "render summary usage order is not canonical")
      end
      retries = provenance.fetch("retries")
      unless retries.is_a?(Integer) && retries == angles.sum { |angle| angle.fetch("retries") }
        invalid!("invalid_summary", "render summary retry total is invalid")
      end
      ordinary_verdict = if mode == "critique"
                           "REPORT ONLY - #{findings.length} #{findings.length == 1 ? "finding" : "findings"}"
                         else
                           open = findings.count do |finding|
                             %w[pending contested stuck].include?(finding.fetch("state"))
                           end
                           if open.positive?
                             "DID NOT CONVERGE - #{open} findings remain open"
                           elsif value.fetch("open_questions").empty?
                             "PASSED"
                           else
                             "PASSED WITH OPEN QUESTIONS"
                           end
                         end
      gate = Capabilities.gate(
        capabilities, ordinary_verdict == "PASSED" ? "PASS" : ordinary_verdict
      )
      expected_degraded = gate.fetch("degraded_capabilities")
      unless value.fetch("degraded_capabilities") == expected_degraded
        invalid!("invalid_summary", "render summary degraded capability disclosure is invalid")
      end
      expected_verdict = gate.fetch("verdict") == "PASS" ? "PASSED" : gate.fetch("verdict")
      invalid!("invalid_summary", "render summary verdict is inconsistent") unless value["verdict"] == expected_verdict
      true
    rescue Error => error
      raise if error.code == "invalid_summary"

      invalid!(
        "invalid_summary", "render summary is structurally invalid",
        {"cause_code" => error.code, "cause" => error.message}
      )
    rescue KeyError, TypeError, NoMethodError => error
      invalid!("invalid_summary", "render summary is structurally invalid", {"cause" => error.message})
    end

    def validate_render_findings!(findings, run_id)
      invalid!("invalid_summary", "render summary findings must be an array") unless findings.is_a?(Array)
      fingerprint = Digest::SHA256.hexdigest(run_id)[0, 8]
      findings.each_with_index do |finding, index|
        require_hash!(finding, "render finding")
        expected_id = format("AR-%s-%03d", fingerprint, index + 1)
        invalid!("invalid_summary", "render finding ID is invalid") unless finding.fetch("id") == expected_id
        %w[category location path summary consequence state].each do |field|
          nonempty_string!(finding.fetch(field), "render finding #{field}")
        end
        validate_enum!("finding severity", finding.fetch("severity"), SEVERITIES)
        validate_enum!("finding state", finding.fetch("state"), %w[pending resolved rejected contested stuck])
        line = finding.fetch("line")
        invalid!("invalid_summary", "render finding line is invalid") unless line.is_a?(Integer) && line >= 0
        unless finding.fetch("location") == "#{finding.fetch("path")}:#{line}"
          invalid!("invalid_summary", "render finding location is inconsistent")
        end
        confidence = finding.fetch("confidence")
        unless confidence.is_a?(Numeric) && confidence >= 0 && confidence <= 1
          invalid!("invalid_summary", "render finding confidence is invalid")
        end
        angles = finding.fetch("source_angles")
        unless angles.is_a?(Array) && !angles.empty? &&
               angles.all? { |angle| angle.is_a?(String) && !angle.strip.empty? } &&
               angles == angles.uniq.sort
          invalid!("invalid_summary", "render finding source angles are invalid")
        end
        invalid!("invalid_summary", "render finding round is invalid") unless [1, 2].include?(finding.fetch("round"))
      end
      findings
    end

    def validate_render_metrics!(metrics, findings)
      require_hash!(metrics, "render metrics")
      unless metrics.fetch("reported_findings") == findings.length
        invalid!("invalid_summary", "render metric finding total is inconsistent")
      end
      by_severity = metrics.fetch("by_severity")
      require_hash!(by_severity, "render severity metrics")
      expected = SEVERITIES.each_with_object({}) do |severity, counts|
        counts[severity] = findings.count { |finding| finding.fetch("severity") == severity }
      end
      invalid!("invalid_summary", "render severity metrics are inconsistent") unless by_severity == expected
      values = metrics.fetch("values")
      require_hash!(values, "render metric values")
      values.each do |key, value|
        unless key.is_a?(String) && (value.nil? || value.is_a?(Numeric) || value.is_a?(String) || [true, false].include?(value))
          invalid!("invalid_summary", "render metric value is invalid", {"field" => key})
        end
      end
      true
    end

    def validate_run_id!(run_id)
      unless run_id.is_a?(String) && State::RUN_ID.match?(run_id) && !%w[. ..].include?(run_id)
        invalid!("invalid_run_id", "run ID contains unsafe characters", {"run_id" => run_id})
      end
      run_id
    end

    def validate_timestamp!(name, value)
      nonempty_string!(value, name)
      Time.iso8601(value)
      value
    rescue ArgumentError
      invalid!("invalid_timestamps", "#{name} must be an ISO-8601 timestamp", {"value" => value})
    end

    def validate_enum!(name, value, allowed)
      return value if allowed.include?(value)

      invalid!("invalid_summary", "#{name} is invalid", {"value" => value, "allowed" => allowed})
    end

    def require_hash!(value, name)
      return value if value.is_a?(Hash)

      invalid!("invalid_summary", "#{name} must be an object")
    end

    def nonempty_string!(value, name)
      return value if value.is_a?(String) && !value.strip.empty?

      invalid!("invalid_summary", "#{name} must be a non-empty string")
    end

    def optional_string(value)
      return nil if value.nil?
      return value if value.is_a?(String) && !value.strip.empty?

      invalid!("invalid_summary", "optional text must be a non-empty string or null")
    end

    def canonical_string_array(value, name)
      unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
        invalid!("invalid_summary", "#{name} must be an array of non-empty strings")
      end
      value.uniq.sort
    end

    def reject_control_characters!(value, name)
      return value unless value.match?(/[\x00-\x1f\x7f]/)

      invalid!("invalid_summary", "#{name} contains control characters")
    end

    def requested_observed(pair, observed_key: "observed")
      "requested: #{display(pair.fetch("requested"))}; observed: #{display(pair.fetch(observed_key))}"
    end

    def table_row(values)
      "| #{values.map { |value| table_cell(value) }.join(" | ")} |"
    end

    def table_cell(value)
      display(value).gsub("\\", "\\\\").gsub("|", "\\|").gsub(/\r\n?|\n/, "<br>")
    end

    def markdown_text(value)
      display(value).gsub(/\r\n?|\n/, " ")
    end

    def display(value)
      value.nil? ? "unavailable" : value.to_s
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def invalid!(code, message, details = {}, exit_status = 3)
      raise Error.new(code, message, details, exit_status)
    end
  end
end
