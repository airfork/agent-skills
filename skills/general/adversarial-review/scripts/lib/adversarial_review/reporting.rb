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
      findings semantic_groups author_actions resolution_checks evidence_gaps
      overflow overflow_evidence_gaps metrics
    ].freeze
    USAGE_KEYS = %w[
      prompt_bytes input_tokens cached_input_tokens output_tokens reasoning_tokens total_tokens
    ].freeze
    ANGLE_STATUSES = %w[completed failed skipped combined].freeze
    CATEGORIES = ["Omission", "Ambiguity", "Inconsistency", "Incorrect fact", "Extraneous"].freeze
    SEVERITIES = %w[CRITICAL HIGH MEDIUM LOW].freeze
    SYSTEM_SOURCE_ANGLES = %w[resolution].freeze
    MAX_REPORTED_FINDINGS = 50
    OVERFLOW_REPRESENTATIVE_LIMIT = 5
    # A persisted finding's required JSON keys, scalar values, and non-empty sources
    # exceed 128 bytes even with one-character values. This intentionally low floor
    # makes the 16 MiB state-file limit an upper bound of 131,072 findings.
    MIN_VALID_FINDING_JSON_BYTES = 128
    MAX_AUTHORITATIVE_FINDINGS = Atomic::MAX_JSON_BYTES / MIN_VALID_FINDING_JSON_BYTES
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
      terminal_stage = validate_enum!(
        "terminal_stage", source.fetch("terminal_stage", "complete"),
        %w[complete did-not-converge]
      )
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
      all_findings = canonical_findings(
        source, run_id, angles.map { |angle| angle.fetch("name") } + SYSTEM_SOURCE_ANGLES
      )
      findings = all_findings.select { |finding| finding.fetch("reported") }
                             .map { |finding| finding.reject { |key, _value| key == "reported" } }
      actions = canonical_actions(source.fetch("author_actions"), all_findings)
      resolution_checks = canonical_resolutions(source.fetch("resolution_checks"), all_findings)
      validate_dispositions!(mode, all_findings, actions, resolution_checks)
      reported_ids = findings.each_with_object({}) { |finding, indexed| indexed[finding.fetch("id")] = true }
      reported_actions = actions.select { |finding_id, _action| reported_ids.key?(finding_id) }
      reported_resolutions = resolution_checks.select { |finding_id, _status| reported_ids.key?(finding_id) }
      evidence_gaps = canonical_evidence_gaps(source.fetch("evidence_gaps"))
      overflow, overflow_evidence_gaps = canonical_overflow(
        source.fetch("overflow"), source.fetch("overflow_evidence_gaps"), all_findings
      )
      ordinary_verdict = verdict_for(
        mode, findings, evidence_gaps, overflow, overflow_evidence_gaps,
        terminal_stage: terminal_stage
      )
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
        "terminal_stage" => terminal_stage,
        "verdict" => verdict,
        "findings" => findings,
        "metrics" => canonical_metrics(source.fetch("metrics"), findings, overflow),
        "author_actions" => reported_actions,
        "changelog" => changelog(reported_actions, findings),
        "rejected_findings" => rejected_findings(reported_actions, findings),
        "evidence_gaps" => evidence_gaps,
        "open_questions" => open_questions(findings, reported_actions, evidence_gaps),
        "overflow" => overflow,
        "overflow_evidence_gaps" => overflow_evidence_gaps,
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
          "filesystem" => canonical_filesystem(source["filesystem"]),
          "retries" => angles.sum { |angle| angle.fetch("retries") },
          "usage" => usage,
          "system_sources" => all_findings.flat_map { |finding| finding.fetch("source_angles") }
                                          .select { |angle| SYSTEM_SOURCE_ANGLES.include?(angle) }
                                          .uniq.sort
        },
        "resolution_checks" => reported_resolutions
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
      append_overflow(lines, value.fetch("overflow"), value.fetch("overflow_evidence_gaps"))
      if value.fetch("mode") == "revise"
        append_item_section(lines, "Changelog", value.fetch("changelog"))
        append_item_section(lines, "Rejected Findings", value.fetch("rejected_findings"))
        append_item_section(lines, "Open Questions", value.fetch("open_questions"))
      elsif !value.fetch("open_questions").empty?
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
        "terminal_stage" => value.fetch("terminal_stage"),
        "verdict" => value.fetch("verdict"),
        "findings" => deep_copy(value.fetch("findings")),
        "metrics" => deep_copy(value.fetch("metrics")),
        "evidence_gaps" => deep_copy(value.fetch("evidence_gaps")),
        "open_questions" => deep_copy(value.fetch("open_questions")),
        "overflow" => deep_copy(value.fetch("overflow")),
        "overflow_evidence_gaps" => deep_copy(value.fetch("overflow_evidence_gaps")),
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
        if bytes.bytesize > report_byte_limit
          invalid!(
            "report_too_large", "prospective report exceeds the size limit",
            {"path" => expanded, "bytes" => bytes.bytesize, "max_bytes" => report_byte_limit}
          )
        end
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
      invalid!("invalid_repository", "repository root must be absolute") unless Atomic.canonical_absolute_path?(root)
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
      unless dirty == !status.empty?
        invalid!("invalid_repository", "repository dirty flag does not match status entries")
      end
      expected_dirty_digest = Digest::SHA256.hexdigest(JSON.generate(status))
      dirty_digest = repository["dirty_digest"] || expected_dirty_digest
      unless dirty_digest.is_a?(String) && dirty_digest.match?(/\A[0-9a-f]{64}\z/)
        invalid!("invalid_repository", "repository dirty-state digest is invalid")
      end
      unless dirty_digest == expected_dirty_digest
        invalid!("invalid_repository", "repository dirty-state digest does not match status entries")
      end
      {"root" => root, "head" => head, "dirty" => dirty,
       "dirty_digest" => dirty_digest, "status" => status.dup}
    rescue KeyError => error
      invalid!("invalid_repository", "repository provenance is incomplete", {"field" => error.key})
    end

    FILESYSTEM_GUARANTEES = %w[
      descriptor_relative_paths directory_locking durable_directory_metadata
      posix_permissions inode_identity
    ].freeze

    # Which filesystem guarantees the control plane actually enforced. Defaults
    # to the running backend so a report can never omit it; an explicit value
    # lets a resumed run report the backend that produced its state rather than
    # the one rendering it.
    def canonical_filesystem(value)
      declared = value.is_a?(Hash) ? value : Atomic.guarantees
      backend = declared["backend"]
      unless %w[posix portable].include?(backend)
        invalid!("invalid_filesystem", "filesystem backend is unknown", {"backend" => backend})
      end
      guarantees = FILESYSTEM_GUARANTEES.each_with_object({}) do |name, collected|
        held = declared[name]
        unless [true, false].include?(held)
          invalid!("invalid_filesystem", "filesystem guarantee must be boolean", {"guarantee" => name})
        end
        collected[name] = held
      end
      {
        "backend" => backend,
        "guarantees" => guarantees,
        "degraded" => guarantees.reject { |_name, held| held }.keys
      }
    end

    def canonical_cli(cli)
      require_hash!(cli, "cli")
      realpath = nonempty_string!(cli.fetch("realpath"), "CLI realpath")
      invalid!("invalid_cli", "CLI realpath must be absolute") unless Atomic.canonical_absolute_path?(realpath)
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
      if findings.length > MAX_AUTHORITATIVE_FINDINGS
        invalid!("invalid_findings", "authoritative finding total exceeds the state-file maximum")
      end
      fingerprint = Digest::SHA256.hexdigest(run_id)[0, 8]
      canonical = findings.each_with_index.map do |finding, index|
        require_hash!(finding, "finding")
        finding_id = finding.fetch("id")
        expected_id = format("AR-%s-%03d", fingerprint, index + 1)
        unless finding_id == expected_id
          invalid!(
            "invalid_findings", "complete source finding IDs must be contiguous for this run",
            {"expected" => expected_id, "observed" => finding_id}
          )
        end
        reported = finding.fetch("reported")
        invalid!("invalid_findings", "finding reported flag must be boolean") unless [true, false].include?(reported)

        severity = validate_enum!("finding severity", finding.fetch("severity"), SEVERITIES)
        confidence = finding.fetch("confidence")
        unless confidence.is_a?(Numeric) && confidence >= 0 && confidence <= 1
          invalid!("invalid_findings", "finding confidence is outside 0..1", {"id" => finding_id})
        end
        path = nonempty_string!(finding.fetch("path"), "finding path")
        line = finding.fetch("line")
        invalid!("invalid_findings", "finding line must be a non-negative integer") unless line.is_a?(Integer) && line >= 0
        sources = finding.fetch("sources")
        unless sources.is_a?(Array) && !sources.empty? && sources.all? do |item|
                 item.is_a?(Hash) && item["angle"].is_a?(String) && !item["angle"].strip.empty?
               end
          invalid!("invalid_findings", "finding sources are incomplete", {"id" => finding_id})
        end
        source_angles = sources.map { |item| item.fetch("angle") }.uniq.sort
        unless (source_angles - recorded_angles).empty?
          invalid!(
            "invalid_findings", "finding source angle is absent from run provenance",
            {"id" => finding_id, "unknown_angles" => source_angles - recorded_angles}
          )
        end
        group = groups.fetch(finding.fetch("group_id"))
        require_hash!(group, "semantic group")
        text = nonempty_string!(group.fetch("summary"), "finding summary")
        round = finding.fetch("round")
        unless [1, 2].include?(round)
          invalid!("invalid_findings", "finding round must be one or two", {"id" => finding_id})
        end
        canonical_finding = {
          "id" => finding_id,
          "category" => validate_enum!("finding category", finding.fetch("category"), CATEGORIES),
          "severity" => severity,
          "location" => "#{path}:#{line}",
          "path" => path,
          "line" => line,
          "summary" => text,
          "consequence" => nonempty_string!(finding.fetch("consequence"), "finding consequence"),
          "confidence" => confidence,
          "source_angles" => source_angles,
          "round" => round,
          "state" => validate_enum!(
            "finding state", finding.fetch("state"), %w[pending resolved rejected contested stuck]
          )
        }
        canonical_finding.merge("reported" => reported)
      rescue KeyError => error
        invalid!("invalid_findings", "finding provenance is incomplete", {"field" => error.key})
      end
      if canonical.count { |finding| finding.fetch("reported") } > MAX_REPORTED_FINDINGS
        invalid!(
          "invalid_findings", "reported findings exceed the #{MAX_REPORTED_FINDINGS}-finding cap"
        )
      end
      canonical
    end

    def canonical_actions(actions, findings)
      require_hash!(actions, "author actions")
      known = findings.map { |finding| finding.fetch("id") }
      actions.each_with_object({}) do |(finding_id, action), canonical|
        invalid!("invalid_actions", "author action refers to an unknown finding") unless known.include?(finding_id)
        action = {"status" => action} if action.is_a?(String)
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
        invalid!("invalid_resolutions", "resolution refers to an unknown finding") unless known.include?(finding_id)
        canonical[finding_id] = validate_enum!(
          "resolution", status, %w[pending resolved rejected contested stuck]
        )
      end.sort.to_h
    end

    def validate_dispositions!(mode, findings, actions, resolutions)
      findings.each do |finding|
        finding_id = finding.fetch("id")
        action = actions[finding_id]
        resolution = resolutions[finding_id]
        pairing = State.terminal_pairing(action, resolution)
        if pairing == :invalid
          invalid!(
            "invalid_disposition", "author action conflicts with the finding resolution",
            {"id" => finding_id, "state" => finding.fetch("state"), "resolution" => resolution}
          )
        end
        if resolution && resolution != finding.fetch("state")
          invalid!(
            "invalid_disposition", "finding state does not match its resolution",
            {"id" => finding_id, "state" => finding.fetch("state"), "resolution" => resolution}
          )
        end
        next unless finding.fetch("reported") && %w[resolved rejected].include?(finding.fetch("state"))
        next if pairing == :complete

        invalid!(
          "invalid_disposition", "terminal reported finding lacks a complete author disposition",
          {"id" => finding_id, "mode" => mode}
        )
      end
      true
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

    def canonical_overflow(overflow, gaps, findings)
      require_hash!(overflow, "overflow")
      unless overflow.keys.sort == %w[by_category_severity items total]
        invalid!("invalid_overflow", "overflow has unexpected or missing fields")
      end
      total = overflow.fetch("total")
      items = overflow.fetch("items")
      counts = overflow.fetch("by_category_severity")
      unless total.is_a?(Integer) && total >= 0 && items.is_a?(Array) &&
             items.all? { |id| id.is_a?(String) } && counts.is_a?(Hash) &&
             counts.all? { |key, count| key.is_a?(String) && !key.empty? && count.is_a?(Integer) && count.positive? }
        invalid!("invalid_overflow", "overflow values have invalid shapes")
      end
      item_lookup = {}
      items.each do |finding_id|
        invalid!("invalid_overflow", "overflow item IDs must be unique") if item_lookup.key?(finding_id)
        item_lookup[finding_id] = true
      end
      unreported = findings.reject { |finding| finding.fetch("reported") }
      expected_ids = unreported.map { |finding| finding.fetch("id") }
      unreported_by_id = unreported.each_with_object({}) do |finding, indexed|
        indexed[finding.fetch("id")] = finding
      end
      unreported_order = expected_ids.each_with_index.to_h
      expected_counts = Hash.new(0)
      unreported.each do |finding|
        expected_counts["#{finding.fetch("category")}:#{finding.fetch("severity")}"] += 1
      end
      expected_counts = expected_counts.sort.to_h
      unless total == expected_ids.length && items.length == expected_ids.length &&
             expected_ids.all? { |finding_id| item_lookup.key?(finding_id) } &&
             counts == expected_counts && total == counts.values.inject(0, :+)
        invalid!(
          "invalid_overflow", "overflow does not match unreported promoted findings",
          {"expected_items" => expected_ids, "observed_items" => items}
        )
      end

      require_hash!(gaps, "overflow evidence gaps")
      canonical_gap_records = gaps.keys.sort_by do |finding_id|
        unreported_order.fetch(finding_id, expected_ids.length)
      end.each_with_object({}) do |finding_id, canonical|
        finding = unreported_by_id[finding_id]
        gap = gaps.fetch(finding_id)
        unless finding && %w[MEDIUM LOW].include?(finding.fetch("severity")) && gap.is_a?(Hash) &&
               gap.keys.sort == %w[rationale recorded_at_stage round]
          invalid!("invalid_overflow", "overflow evidence gap has an invalid subject or shape", {"id" => finding_id})
        end
        rationale = nonempty_string!(gap.fetch("rationale"), "overflow evidence-gap rationale")
        stage = gap.fetch("recorded_at_stage")
        round = gap.fetch("round")
        unless State::TRANSITIONS.key?(stage) && [1, 2].include?(round)
          invalid!("invalid_overflow", "overflow evidence-gap stage or round is invalid", {"id" => finding_id})
        end
        canonical[finding_id] = {
          "id" => finding_id,
          "category" => finding.fetch("category"),
          "severity" => finding.fetch("severity"),
          "rationale" => rationale,
          "recorded_at_stage" => stage,
          "round" => round
        }
      end
      representative_findings = items.take(OVERFLOW_REPRESENTATIVE_LIMIT).map do |finding_id|
        finding = unreported_by_id.fetch(finding_id)
        {
          "id" => finding_id,
          "category" => finding.fetch("category"),
          "severity" => finding.fetch("severity"),
          "location" => finding.fetch("location"),
          "summary" => finding.fetch("summary")
        }
      end
      gap_counts = Hash.new(0)
      canonical_gap_records.each_value do |gap|
        gap_counts["#{gap.fetch("category")}:#{gap.fetch("severity")}"] += 1
      end
      [
        {
          "total" => total,
          "by_category_severity" => counts.keys.sort.each_with_object({}) { |key, result| result[key] = counts[key] },
          "id_integrity" => overflow_id_integrity(
            findings.length,
            findings.select { |finding| finding.fetch("reported") }.map { |finding| finding.fetch("id") },
            expected_ids.length,
            expected_ids.first,
            expected_ids.last
          ),
          "representatives" => representative_findings
        },
        {
          "total" => canonical_gap_records.length,
          "by_category_severity" => gap_counts.sort.to_h,
          "representatives" => canonical_gap_records.values.take(OVERFLOW_REPRESENTATIVE_LIMIT)
        }
      ]
    rescue KeyError => error
      invalid!("invalid_overflow", "overflow provenance is incomplete", {"field" => error.key})
    end

    def canonical_metrics(metrics, findings, overflow)
      require_hash!(metrics, "metrics")
      normalized_values = {}
      metrics.each do |key, value|
        unless key.is_a?(String) && (value.nil? || value.is_a?(Numeric) || value.is_a?(String) || [true, false].include?(value))
          invalid!("invalid_metrics", "metric values must be scalar", {"field" => key})
        end
        normalized_key = normalize_metric_text(key)
        if normalized_key.empty? || normalized_values.key?(normalized_key)
          invalid!("invalid_metrics", "metric names collide or normalize to empty", {"field" => key})
        end
        normalized_values[normalized_key] = value.is_a?(String) ? normalize_metric_text(value) : value
      end
      by_severity = SEVERITIES.each_with_object({}) do |severity, counts|
        counts[severity] = findings.count { |finding| finding.fetch("severity") == severity }
      end
      {
        "reported_findings" => findings.length,
        "by_severity" => by_severity,
        "overflow_total" => overflow.fetch("total"),
        "overflow_by_category_severity" => deep_copy(overflow.fetch("by_category_severity")),
        "values" => normalized_values.keys.sort.each_with_object({}) do |key, result|
          result[key] = normalized_values[key]
        end
      }
    end

    def verdict_for(mode, findings, evidence_gaps, overflow, overflow_gaps, terminal_stage: "complete")
      return "REPORT ONLY - #{findings.length} #{findings.length == 1 ? "finding" : "findings"}" if mode == "critique"

      open = findings.count { |finding| %w[pending contested stuck].include?(finding.fetch("state")) }
      overflow_blockers = overflow.fetch("by_category_severity").sum do |category_severity, count|
        severity = category_severity.split(":").last
        if %w[CRITICAL HIGH].include?(severity)
          count
        else
          count - overflow_gaps.fetch("by_category_severity").fetch(category_severity, 0)
        end
      end
      open += overflow_blockers
      if terminal_stage == "did-not-converge"
        return "DID NOT CONVERGE - #{open} findings remain open" if open.positive?

        return "DID NOT CONVERGE - lifecycle invariants remain unresolved"
      end
      return "DID NOT CONVERGE - #{open} findings remain open" if open.positive?
      return "PASSED WITH OPEN QUESTIONS" unless evidence_gaps.empty?

      "PASSED"
    end

    def overflow_id_integrity(
      authoritative_total, reported_ids, overflow_total, first_unreported_id, last_unreported_id
    )
      partition = {
        "authoritative_total" => authoritative_total,
        "reported_ids" => reported_ids,
        "overflow_total" => overflow_total
      }
      {
        "algorithm" => "sha256",
        "authoritative_total" => authoritative_total,
        "first_unreported_id" => first_unreported_id,
        "last_unreported_id" => last_unreported_id,
        "partition_sha256" => Digest::SHA256.hexdigest(JSON.generate(partition))
      }
    end

    def changelog(actions, findings)
      by_id = findings.each_with_object({}) { |finding, result| result[finding.fetch("id")] = finding }
      actions.select do |finding_id, action|
        by_id.key?(finding_id) && action.fetch("status") == "fixed"
      end.map do |finding_id, action|
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
      actions.select do |finding_id, action|
        by_id.key?(finding_id) && action.fetch("status") == "rejected"
      end.map do |finding_id, action|
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
      lines << "- Overflow total: #{metrics.fetch("overflow_total")}"
      metrics.fetch("overflow_by_category_severity").each do |category_severity, count|
        lines << "- Overflow #{category_severity}: #{count}"
      end
      metrics.fetch("values").each do |name, value|
        lines << "- #{markdown_text(name)}: #{markdown_text(value)}"
      end
      lines << ""
    end

    def append_overflow(lines, overflow, gaps)
      return if overflow.fetch("total").zero?

      lines << "## Overflow"
      lines << ""
      overflow.fetch("by_category_severity").each do |category_severity, count|
        lines << "- #{markdown_text(category_severity)}: #{count}"
      end
      lines << ""
      lines << "| ID | Category | Severity | Location | Summary |"
      lines << "|---|---|---|---|---|"
      overflow.fetch("representatives").each do |finding|
        lines << table_row([
          finding.fetch("id"), finding.fetch("category"), finding.fetch("severity"),
          finding.fetch("location"), finding.fetch("summary")
        ])
      end
      lines << ""
      unless gaps.fetch("representatives").empty?
        lines << "### Representative nonblocking rationales"
        lines << ""
        gaps.fetch("representatives").each do |gap|
          lines << "- #{gap.fetch("id")}: #{markdown_text(gap.fetch("rationale"))}"
        end
        lines << ""
      end
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
      # Reduced filesystem hardening is a property of the control plane, not of
      # the reviewer, so it is disclosed separately from the capability gate and
      # never changes the verdict.
      filesystem = provenance["filesystem"]
      if filesystem && !filesystem.fetch("degraded").empty?
        lines << "## DEGRADED FILESYSTEM HARDENING"
        lines << ""
        lines << "Backend `#{filesystem.fetch("backend")}` did not enforce: " \
                 "#{filesystem.fetch("degraded").join(", ")}."
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
      filesystem = provenance["filesystem"]
      if filesystem
        degraded_guarantees = filesystem.fetch("degraded")
        summary = if degraded_guarantees.empty?
                    "#{filesystem.fetch("backend")} (all guarantees enforced)"
                  else
                    "#{filesystem.fetch("backend")} (not enforced: #{degraded_guarantees.join(", ")})"
                  end
        lines << table_row(["Filesystem backend", summary])
      end
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
          # The portable backend cannot lock a directory; bootstrap then relies
          # on create_anchored_lock's O_EXCL create, and the run declares
          # `directory_locking` false rather than implying this lock was held.
          if directory.supports_directory_lock?
            unless directory.flock(File::LOCK_EX)
              raise State::Error.new(
                "unsafe_lock", "report lock bootstrap could not lock its parent directory",
                {"path" => lock_path}, 2
              )
            end
            locked = true
          end
          Atomic.verify_directory_identity!(parent, directory, code: "unsafe_lock")
          publish_report_lock!(directory, lock_path, lock_name)
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

    # A directory lock makes bootstrap atomic for observers: no other process can
    # see the lock file between its creation and its anchor being linked. The
    # portable backend has no such lock, so a concurrent first appender can
    # observe a half-published pair, and `create_anchored_lock` can lose the
    # create race outright. Both are transient, so wait for the winner to finish
    # rather than failing a run over it.
    BOOTSTRAP_RACE_ATTEMPTS = 100
    BOOTSTRAP_RACE_INTERVAL = 0.01

    def publish_report_lock!(directory, lock_path, lock_name)
      if directory.supports_directory_lock?
        # The directory lock guarantees no half-published pair is observable, so
        # the lock file alone is proof the pair is complete.
        return lock_path if Atomic.reject_relative_nonregular(directory, lock_name, "unsafe_lock")
      elsif await_published_report_lock(directory, lock_name)
        return lock_path
      end

      bootstrap_report_lock!(directory, lock_path, lock_name)
    end

    def bootstrap_report_lock!(directory, lock_path, lock_name)
      Atomic.create_anchored_lock(lock_path)
    rescue State::Error => error
      raise if directory.supports_directory_lock?
      raise unless error.code == "unsafe_lock"
      raise unless await_published_report_lock(directory, lock_name, require_lock: true)

      lock_path
    end

    # True once both lock names are present. With `require_lock` false, a missing
    # lock file means "nobody has started bootstrap", which is not something to
    # wait for; only a lock without its anchor is a race worth outwaiting.
    def await_published_report_lock(directory, lock_name, require_lock: false)
      BOOTSTRAP_RACE_ATTEMPTS.times do
        lock_present = Atomic.reject_relative_nonregular(directory, lock_name, "unsafe_lock")
        return false if !lock_present && !require_lock

        if lock_present &&
           Atomic.reject_relative_nonregular(directory, "#{lock_name}.anchor", "unsafe_lock")
          return true
        end

        sleep BOOTSTRAP_RACE_INTERVAL
      end
      false
    end

    def read_report(directory, name)
      return "" unless Atomic.reject_relative_nonregular(directory, name, "unsafe_report")

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      file = Atomic.open_relative(directory, name, flags)
      begin
        Atomic.reject_nonregular_handle(file, name, "unsafe_report")
        if file.stat.size > report_byte_limit
          raise State::Error.new(
            "report_too_large", "existing report exceeds the size limit",
            {"path" => name, "max_bytes" => report_byte_limit}, 3
          )
        end
        bytes = file.read(report_byte_limit + 1)
        if bytes.bytesize > report_byte_limit
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
        schema_version run_id mode tier output terminal_stage verdict findings metrics changelog
        author_actions rejected_findings evidence_gaps open_questions overflow overflow_evidence_gaps
        degraded_capabilities provenance resolution_checks
      ]
      missing = required.reject { |key| value.key?(key) }
      invalid!("invalid_summary", "render summary is incomplete", {"missing" => missing}) unless missing.empty?
      invalid!("invalid_summary", "render summary schema is unsupported") unless value["schema_version"] == 1
      run_id = validate_run_id!(value.fetch("run_id"))
      mode = validate_enum!("mode", value.fetch("mode"), %w[critique revise])
      validate_enum!("tier", value.fetch("tier"), %w[default high ultra])
      validate_enum!("output", value.fetch("output"), %w[chat file both])
      terminal_stage = validate_enum!(
        "terminal_stage", value.fetch("terminal_stage"), %w[complete did-not-converge]
      )
      findings = validate_render_findings!(value.fetch("findings"), run_id, "reported")
      if findings.length > MAX_REPORTED_FINDINGS
        invalid!("invalid_summary", "render findings exceed the reporting cap")
      end
      overflow, overflow_evidence_gaps = validate_render_overflow!(
        value.fetch("overflow"), value.fetch("overflow_evidence_gaps"), findings, run_id
      )
      reported_findings = findings.map { |finding| finding.merge("reported" => true) }
      actions = canonical_actions(value.fetch("author_actions"), reported_findings)
      resolutions = canonical_resolutions(value.fetch("resolution_checks"), reported_findings)
      unless value.fetch("author_actions") == actions && value.fetch("resolution_checks") == resolutions
        invalid!("invalid_summary", "render dispositions are not canonical")
      end
      validate_dispositions!(mode, reported_findings, actions, resolutions)
      validate_render_metrics!(value.fetch("metrics"), findings, overflow)
      evidence_gaps = canonical_evidence_gaps(value.fetch("evidence_gaps"))
      unless value.fetch("evidence_gaps") == evidence_gaps
        invalid!("invalid_summary", "render evidence gaps are not canonical")
      end
      expected_derived = {
        "changelog" => changelog(actions, findings),
        "rejected_findings" => rejected_findings(actions, findings),
        "open_questions" => open_questions(findings, actions, evidence_gaps)
      }
      expected_derived.each do |section, expected|
        unless value.fetch(section) == expected
          invalid!("invalid_summary", "render summary #{section} is inconsistent")
        end
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
      system_sources = provenance.fetch("system_sources")
      unless system_sources.is_a?(Array) && system_sources == system_sources.uniq.sort &&
             (system_sources - SYSTEM_SOURCE_ANGLES).empty?
        invalid!("invalid_summary", "render summary system sources are invalid")
      end
      recorded_angles = angles.map { |angle| angle.fetch("name") } + system_sources
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
      ordinary_verdict = verdict_for(
        mode, findings, evidence_gaps, overflow, overflow_evidence_gaps,
        terminal_stage: terminal_stage
      )
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

    def validate_render_findings!(findings, run_id, collection)
      invalid!("invalid_summary", "render #{collection} findings must be an array") unless findings.is_a?(Array)
      previous_suffix = 0
      findings.each do |finding|
        require_hash!(finding, "render finding")
        suffix = finding_id_suffix(finding.fetch("id"), run_id)
        unless suffix > previous_suffix
          invalid!("invalid_summary", "render finding IDs must have stable ascending suffixes")
        end
        previous_suffix = suffix
        %w[location path summary consequence state].each do |field|
          nonempty_string!(finding.fetch(field), "render finding #{field}")
        end
        validate_enum!("finding category", finding.fetch("category"), CATEGORIES)
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

    def validate_render_overflow!(overflow, gaps, findings, run_id)
      require_hash!(overflow, "render overflow")
      unless overflow.keys.sort == %w[by_category_severity id_integrity representatives total]
        invalid!("invalid_summary", "render overflow has unexpected or missing fields")
      end
      integrity = overflow.fetch("id_integrity")
      require_hash!(integrity, "render overflow ID integrity")
      unless integrity.keys.sort == %w[
        algorithm authoritative_total first_unreported_id last_unreported_id partition_sha256
      ]
        invalid!("invalid_summary", "render overflow ID integrity has invalid fields")
      end
      authoritative_total = integrity.fetch("authoritative_total")
      unless authoritative_total.is_a?(Integer) && authoritative_total >= 0
        invalid!("invalid_summary", "render overflow authoritative total is invalid")
      end
      if authoritative_total > MAX_AUTHORITATIVE_FINDINGS
        invalid!("invalid_summary", "render overflow authoritative total exceeds the state-file maximum")
      end
      total = validate_render_aggregate!(
        overflow.fetch("by_category_severity"), overflow.fetch("total"), "overflow"
      )
      validate_render_count_dimensions!(overflow.fetch("by_category_severity"), SEVERITIES)
      unless authoritative_total == findings.length + total
        invalid!("invalid_summary", "render overflow authoritative total is inconsistent")
      end
      reported_ids = findings.map { |finding| finding.fetch("id") }
      reported_suffixes = reported_ids.each_with_object({}) do |finding_id, indexed|
        suffix = finding_id_suffix(finding_id, run_id)
        if suffix > authoritative_total
          invalid!("invalid_summary", "render reported IDs exceed the authoritative finding range")
        end
        indexed[suffix] = true
      end
      first_unreported_id = implicit_unreported_boundary(
        run_id, authoritative_total, reported_suffixes, :first
      )
      last_unreported_id = implicit_unreported_boundary(
        run_id, authoritative_total, reported_suffixes, :last
      )
      expected_integrity = overflow_id_integrity(
        authoritative_total, reported_ids, total, first_unreported_id, last_unreported_id
      )
      unless integrity == expected_integrity
        invalid!("invalid_summary", "render overflow ID integrity is inconsistent")
      end

      representatives = overflow.fetch("representatives")
      unless representatives.is_a?(Array) &&
             representatives.length == [total, OVERFLOW_REPRESENTATIVE_LIMIT].min
        invalid!("invalid_summary", "render overflow representatives are not bounded and complete")
      end
      representative_ids = representatives.map do |representative|
        validate_render_overflow_representative!(
          representative, run_id, authoritative_total, reported_suffixes,
          overflow.fetch("by_category_severity")
        )
      end
      unless representative_ids.uniq == representative_ids
        invalid!("invalid_summary", "render overflow representative IDs must be unique")
      end

      require_hash!(gaps, "render overflow evidence gaps")
      unless gaps.keys.sort == %w[by_category_severity representatives total]
        invalid!("invalid_summary", "render overflow evidence gaps have invalid fields")
      end
      gap_total = validate_render_aggregate!(
        gaps.fetch("by_category_severity"), gaps.fetch("total"), "overflow evidence gaps"
      )
      validate_render_count_dimensions!(gaps.fetch("by_category_severity"), %w[MEDIUM LOW])
      invalid!("invalid_summary", "render overflow evidence-gap total is invalid") if gap_total > total
      gaps.fetch("by_category_severity").each do |category_severity, count|
        _category, separator, severity = category_severity.rpartition(":")
        unless separator == ":" && %w[MEDIUM LOW].include?(severity) &&
               count <= overflow.fetch("by_category_severity").fetch(category_severity, 0)
          invalid!("invalid_summary", "render overflow evidence-gap counts are inconsistent")
        end
      end
      gap_representatives = gaps.fetch("representatives")
      unless gap_representatives.is_a?(Array) &&
             gap_representatives.length == [gap_total, OVERFLOW_REPRESENTATIVE_LIMIT].min
        invalid!("invalid_summary", "render overflow evidence-gap representatives are invalid")
      end
      gap_ids = gap_representatives.map do |gap|
        require_hash!(gap, "render overflow evidence-gap representative")
        unless gap.keys.sort == %w[category id rationale recorded_at_stage round severity]
          invalid!("invalid_summary", "render overflow evidence-gap representative has invalid fields")
        end
        finding_id = gap.fetch("id")
        category = validate_enum!("overflow evidence-gap category", gap.fetch("category"), CATEGORIES)
        severity = validate_enum!("overflow evidence-gap severity", gap.fetch("severity"), %w[MEDIUM LOW])
        unless implicit_unreported_id?(finding_id, run_id, authoritative_total, reported_suffixes) &&
               gaps.fetch("by_category_severity").fetch("#{category}:#{severity}", 0).positive?
          invalid!("invalid_summary", "render overflow evidence-gap representative is inconsistent")
        end
        nonempty_string!(gap.fetch("rationale"), "overflow evidence-gap rationale")
        unless State::TRANSITIONS.key?(gap.fetch("recorded_at_stage")) && [1, 2].include?(gap.fetch("round"))
          invalid!("invalid_summary", "render overflow evidence-gap representative stage or round is invalid")
        end
        finding_id
      end
      unless gap_ids.uniq == gap_ids
        invalid!("invalid_summary", "render overflow evidence-gap representative IDs must be unique")
      end
      representative_by_id = representatives.each_with_object({}) do |representative, indexed|
        indexed[representative.fetch("id")] = representative
      end
      gap_representatives.each do |gap|
        finding = representative_by_id[gap.fetch("id")]
        next unless finding
        unless finding.fetch("category") == gap.fetch("category") &&
               finding.fetch("severity") == gap.fetch("severity")
          invalid!("invalid_summary", "render overflow representative metadata disagrees")
        end
      end
      [overflow, gaps]
    end

    def validate_render_aggregate!(counts, total, name)
      unless total.is_a?(Integer) && total >= 0 && counts.is_a?(Hash) &&
             counts.keys == counts.keys.sort && counts.all? do |key, count|
               key.is_a?(String) && !key.empty? && count.is_a?(Integer) && count.positive?
             end && counts.values.sum == total
        invalid!("invalid_summary", "render #{name} aggregate is invalid")
      end
      total
    end

    def validate_render_count_dimensions!(counts, severities)
      counts.each_key do |category_severity|
        category, separator, severity = category_severity.rpartition(":")
        unless separator == ":" && CATEGORIES.include?(category) && severities.include?(severity)
          invalid!("invalid_summary", "render aggregate category or severity is invalid")
        end
      end
      true
    end

    def validate_render_overflow_representative!(
      representative, run_id, authoritative_total, reported_suffixes, counts
    )
      require_hash!(representative, "render overflow representative")
      unless representative.keys.sort == %w[category id location severity summary]
        invalid!("invalid_summary", "render overflow representative has invalid fields")
      end
      finding_id = representative.fetch("id")
      category = validate_enum!("overflow representative category", representative.fetch("category"), CATEGORIES)
      severity = validate_enum!("overflow representative severity", representative.fetch("severity"), SEVERITIES)
      unless implicit_unreported_id?(finding_id, run_id, authoritative_total, reported_suffixes) &&
             counts.fetch("#{category}:#{severity}", 0).positive?
        invalid!("invalid_summary", "render overflow representative is inconsistent")
      end
      nonempty_string!(representative.fetch("location"), "overflow representative location")
      nonempty_string!(representative.fetch("summary"), "overflow representative summary")
      finding_id
    end

    def implicit_unreported_id?(finding_id, run_id, authoritative_total, reported_suffixes)
      suffix = finding_id_suffix(finding_id, run_id)
      suffix <= authoritative_total && !reported_suffixes.key?(suffix)
    end

    def implicit_unreported_boundary(run_id, authoritative_total, reported_suffixes, direction)
      return nil if authoritative_total == reported_suffixes.length

      suffix = direction == :first ? 1 : authoritative_total
      step = direction == :first ? 1 : -1
      suffix += step while reported_suffixes.key?(suffix)
      fingerprint = Digest::SHA256.hexdigest(run_id)[0, 8]
      format("AR-%s-%03d", fingerprint, suffix)
    end

    def validate_render_metrics!(metrics, findings, overflow)
      require_hash!(metrics, "render metrics")
      values = metrics.fetch("values")
      expected = canonical_metrics(values, findings, overflow)
      invalid!("invalid_summary", "render metrics are inconsistent or unsafe") unless metrics == expected
      true
    end

    def finding_id_suffix(finding_id, run_id)
      fingerprint = Digest::SHA256.hexdigest(run_id)[0, 8]
      match = finding_id.match(/\AAR-#{Regexp.escape(fingerprint)}-(\d{3,})\z/) if finding_id.is_a?(String)
      suffix = match && Integer(match[1], 10)
      unless suffix&.positive?
        invalid!("invalid_summary", "render finding ID is invalid", {"id" => finding_id})
      end
      suffix
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

    def normalize_metric_text(value)
      value.gsub(/[\x00-\x1f\x7f]+/, " ")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub(/\s+/, " ")
           .strip
    end

    def display(value)
      value.nil? ? "unavailable" : value.to_s
    end

    def report_byte_limit
      MAX_REPORT_BYTES
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def invalid!(code, message, details = {}, exit_status = 3)
      raise Error.new(code, message, details, exit_status)
    end
  end
end
