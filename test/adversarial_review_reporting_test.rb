require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"

class AdversarialReviewReportingTest < Minitest::Test
  def test_builds_a_deterministic_summary_with_complete_provenance
    summary = AdversarialReview::Reporting.summary(summary_source)

    assert_equal expected_finding_id("run-report-1"), summary.dig("findings", 0, "id")
    assert_equal ["assumptions-checker", "traceability"],
                 summary.dig("findings", 0, "source_angles")
    assert_equal Digest::SHA256.hexdigest(JSON.generate([" M docs/spec.md"])),
                 summary.dig("provenance", "repository", "dirty_digest")
    assert_equal "codex", summary.dig("provenance", "executor", "selected")
    assert_equal "gpt-review", summary.dig("provenance", "model", "observed")
    assert_equal 321, summary.dig("provenance", "usage", "total_tokens")
    assert_equal %w[assumptions-checker traceability],
                 summary.dig("provenance", "angles").map { |angle| angle.fetch("name") }
  end

  def test_uses_the_authoritative_normalized_capability_contract
    source = summary_source(
      "capabilities" => capability_declaration,
      "degraded_capabilities" => []
    )

    summary = AdversarialReview::Reporting.summary(source)

    assert_equal AdversarialReview::Capabilities::FIELDS.sort,
                 summary.dig("provenance", "capabilities").keys.sort
    repository_access = summary.dig("provenance", "capabilities", "repository_access")
    assert_equal true, repository_access.fetch("requested")
    assert_equal "enforced", repository_access.fetch("status")
    assert_equal "fixture attestation", repository_access.fetch("evidence")
    assert_equal "test fixture", repository_access.fetch("source")
    markdown = AdversarialReview::Reporting.markdown(summary)
    assert_includes markdown, "| Capability | Requested | Status | Evidence | Source |"
    assert_includes markdown,
                    "| repository_access | true | enforced | fixture attestation | test fixture |"
  end

  def test_capability_gate_suppresses_an_ordinary_pass
    source = resolved_revise_source
    declaration = capability_declaration
    declaration.fetch("fresh_context")["status"] = "behavioral"
    source["capabilities"] = declaration
    source["degraded_capabilities"] = ["fresh_context"]

    summary = AdversarialReview::Reporting.summary(source)

    assert_equal "DEGRADED CAPABILITIES", summary.fetch("verdict")
    assert_equal ["fresh_context"], summary.fetch("degraded_capabilities")
  end

  def test_each_behavioral_or_unavailable_safety_boundary_suppresses_pass
    AdversarialReview::Capabilities::SAFETY_BOUNDARIES.product(
      %w[behavioral unavailable]
    ).each do |field, status|
      source = resolved_revise_source
      declaration = capability_declaration
      declaration.fetch(field)["status"] = status
      source["capabilities"] = declaration
      source["degraded_capabilities"] = [field]

      summary = AdversarialReview::Reporting.summary(source)

      assert_equal "DEGRADED CAPABILITIES", summary.fetch("verdict"), "#{field}=#{status}"
    end
  end

  def test_requires_enabled_angle_inventory_and_exact_coverage
    source = summary_source
    source.delete("enabled_tasks")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_summary", error.code
    assert_includes error.details.fetch("missing"), "enabled_tasks"

    incomplete = summary_source
    incomplete.fetch("angles").pop
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(incomplete)
    end
    assert_equal "invalid_angles", error.code
  end

  def test_every_angle_requires_explicit_failure_status_data
    source = summary_source
    source.fetch("angles").first.delete("failure_reason")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_angles", error.code
  end

  def test_rejects_a_finding_source_angle_outside_the_recorded_inventory
    source = summary_source
    source.dig("findings", 0, "sources", 0)["angle"] = "invented-angle"

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_findings", error.code
  end

  def test_retries_require_one_recorded_reason_per_retry
    source = summary_source
    source.fetch("angles").find { |angle| angle.fetch("retries").positive? }
          .delete("retry_reasons")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_angles", error.code
  end

  def test_schema_version_is_present_in_markdown_provenance_and_chat
    summary = AdversarialReview::Reporting.summary(summary_source)
    markdown = AdversarialReview::Reporting.markdown(summary)
    chat = AdversarialReview::Reporting.chat_payload(summary)

    assert_match(/\| Run ID \| run-report-1 \|\n\| Schema version \| 1 \|/, markdown)
    assert_equal 1, chat.fetch("schema_version")
  end

  def test_rejects_incomplete_or_malformed_provenance
    missing = summary_source
    missing.delete("ended_at")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(missing)
    end
    assert_equal "invalid_summary", error.code
    assert_includes error.details.fetch("missing"), "ended_at"

    malformed = summary_source("usage" => summary_source.fetch("usage").merge("total_tokens" => -1))
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(malformed)
    end
    assert_equal "invalid_usage", error.code
  end

  def test_rejects_malformed_unreported_findings_instead_of_hiding_them
    source = summary_source
    source.fetch("findings").first["reported"] = false
    source.fetch("findings").first.delete("severity")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_findings", error.code
  end

  def test_normalizes_low_level_shape_errors_into_actionable_reporting_errors
    source = summary_source("repository" => {"root" => "bad\0root"})

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_summary", error.code
    assert_includes error.details.fetch("cause"), "null byte"
  end

  def test_renders_critique_and_revise_sections_with_markdown_escaping
    critique = AdversarialReview::Reporting.summary(summary_source)
    critique_markdown = AdversarialReview::Reporting.markdown(critique)

    assert_includes critique_markdown, "REPORT ONLY - 1 finding"
    assert_includes critique_markdown, "## Findings"
    refute_includes critique_markdown, "## Changelog"
    assert_includes critique_markdown, "pipe \\| newline<br>next"
    assert_equal 1, critique_markdown.scan("| ID | Category | Severity | Location | Sources | Summary |").length

    revise_source = summary_source(
      "mode" => "revise",
      "author_actions" => {
        expected_finding_id("run-report-1") => {
          "status" => "fixed", "rationale" => "Added an explicit owner.",
          "changed_paths" => ["docs/spec.md"]
        }
      },
      "resolution_checks" => {expected_finding_id("run-report-1") => "resolved"}
    )
    revise_source.fetch("findings").first["state"] = "resolved"
    revise = AdversarialReview::Reporting.summary(revise_source)
    revise_markdown = AdversarialReview::Reporting.markdown(revise)

    assert_includes revise_markdown, "PASSED"
    assert_includes revise_markdown, "## Changelog"
    assert_includes revise_markdown, "Added an explicit owner."
    assert_includes revise_markdown, "## Rejected Findings"
    assert_includes revise_markdown, "## Open Questions"
  end

  def test_discloses_degraded_capabilities_and_requested_observed_runtime
    capabilities = capability_declaration
    capabilities.fetch("usage_metrics")["status"] = "unavailable"
    capabilities.fetch("usage_metrics")["evidence"] = "CLI omitted usage"
    source = summary_source(
      "degraded_capabilities" => ["usage_metrics"],
      "capabilities" => capabilities
    )
    markdown = AdversarialReview::Reporting.markdown(
      AdversarialReview::Reporting.summary(source)
    )

    assert_includes markdown, "DEGRADED CAPABILITIES"
    assert_includes markdown, "requested: gpt-review; observed: gpt-review"
    assert_includes markdown, "requested: xhigh; observed: xhigh"
    assert_includes markdown, "usage_metrics"
    assert_includes markdown, "CLI omitted usage"
  end

  def test_chat_and_file_rendering_share_the_same_finding_payload_bytes
    summary = AdversarialReview::Reporting.summary(summary_source)
    chat = AdversarialReview::Reporting.chat_payload(summary)

    assert_equal JSON.generate(summary.fetch("findings")),
                 JSON.generate(chat.fetch("findings"))
    assert_equal AdversarialReview::Reporting.markdown(summary), chat.fetch("markdown")
  end

  def test_rendering_fails_closed_on_tampered_nested_summary_shape
    summary = AdversarialReview::Reporting.summary(summary_source)
    summary.dig("provenance", "targets", 0).delete("sha256")

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.markdown(summary)
    end

    assert_equal "invalid_summary", error.code
    assert_includes error.message, "render summary"
  end

  def test_append_uses_exact_markers_refuses_duplicate_ids_and_keeps_lock_identity
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      summary = AdversarialReview::Reporting.summary(summary_source)

      AdversarialReview::Reporting.append(path, summary)
      lock = File.join(directory, ".review.md.lock")
      lock_identity = File.stat(lock).ino
      contents = File.binread(path)

      assert_includes contents, "<!-- adversarial-review-run:run-report-1:v1 -->"
      assert_includes contents, "<!-- /adversarial-review-run:run-report-1 -->"
      assert_equal 0o600, File.stat(path).mode & 0o777
      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.append(path, summary)
      end
      assert_equal "duplicate_run", error.code
      assert_equal contents, File.binread(path)
      assert_equal lock_identity, File.stat(lock).ino
    end
  end

  def test_re_review_append_is_compact_and_preserves_both_runs
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      first = AdversarialReview::Reporting.summary(summary_source)
      second = AdversarialReview::Reporting.summary(summary_source("run_id" => "run-report-2"))

      AdversarialReview::Reporting.append(path, first)
      AdversarialReview::Reporting.append(path, second)
      contents = File.binread(path)

      assert_equal 1, contents.scan("# Adversarial Review\n").length
      assert_includes contents, "## Re-review run-report-2"
      assert_equal 2, contents.scan(/<!-- adversarial-review-run:/).length
      assert_equal 2, contents.scan(/<!-- \/adversarial-review-run:/).length
    end
  end

  def test_append_rejects_symlink_target_and_symlink_lock
    Dir.mktmpdir("adversarial-review-report") do |directory|
      outside = File.join(directory, "outside.md")
      File.write(outside, "unchanged")
      target = File.join(directory, "review.md")
      File.symlink(outside, target)

      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Reporting.append(target, AdversarialReview::Reporting.summary(summary_source))
      end
      assert_equal "unsafe_report", error.code
      assert_equal "unchanged", File.read(outside)

      File.unlink(target)
      lock = File.join(directory, ".review.md.lock")
      File.unlink("#{lock}.anchor")
      File.unlink(lock)
      File.symlink(outside, lock)
      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Reporting.append(target, AdversarialReview::Reporting.summary(summary_source))
      end
      assert_equal "unsafe_lock", error.code
      refute File.exist?(target)
    end
  end

  def test_interrupted_append_leaves_the_original_report_byte_identical
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      first = AdversarialReview::Reporting.summary(summary_source)
      second = AdversarialReview::Reporting.summary(summary_source("run_id" => "run-report-2"))
      AdversarialReview::Reporting.append(path, first)
      before = File.binread(path)

      failure = ->(*_arguments) { raise IOError, "simulated interrupted rename" }
      assert_raises(IOError) do
        AdversarialReview::Atomic.stub(:rename_relative, failure) do
          AdversarialReview::Reporting.append(path, second)
        end
      end

      assert_equal before, File.binread(path)
      assert_empty Dir.children(directory).grep(/\.tmp-/)
    end
  end

  def test_concurrent_appends_do_not_lose_a_completed_run
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      seed = AdversarialReview::Reporting.summary(summary_source)
      AdversarialReview::Reporting.append(path, seed)

      pids = %w[run-report-2 run-report-3].map do |run_id|
        Process.fork do
          begin
            source = summary_source("run_id" => run_id)
            AdversarialReview::Reporting.append(
              path, AdversarialReview::Reporting.summary(source)
            )
            exit! 0
          rescue StandardError
            exit! 1
          end
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }

      assert statuses.all?(&:success?), "a concurrent append failed"
      contents = File.binread(path)
      %w[run-report-1 run-report-2 run-report-3].each do |run_id|
        assert_equal 1, contents.scan("<!-- adversarial-review-run:#{run_id}:v1 -->").length
      end
    end
  end

  def test_concurrent_first_appends_publish_the_lock_without_a_bootstrap_race
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    10.times do
      Dir.mktmpdir("adversarial-review-report") do |directory|
        path = File.join(directory, "review.md")
        ready_read, ready_write = IO.pipe
        start_read, start_write = IO.pipe
        pids = %w[run-report-1 run-report-2].map do |run_id|
          Process.fork do
            ready_read.close
            start_write.close
            ready_write.write("r")
            ready_write.close
            start_read.read(1)
            start_read.close
            begin
              AdversarialReview::Reporting.append(
                path,
                AdversarialReview::Reporting.summary(summary_source("run_id" => run_id))
              )
              exit! 0
            rescue StandardError
              exit! 1
            end
          end
        end
        ready_write.close
        start_read.close
        ready_read.read(2)
        ready_read.close
        2.times { start_write.write("g") }
        start_write.close
        statuses = pids.map { |pid| Process.wait2(pid).last }

        assert statuses.all?(&:success?), "concurrent first append hit the lock bootstrap race"
        contents = File.binread(path)
        %w[run-report-1 run-report-2].each do |run_id|
          assert_equal 1, contents.scan("<!-- adversarial-review-run:#{run_id}:v1 -->").length
        end
      end
    end
  end

  def test_append_refuses_a_run_id_already_present_in_an_end_marker
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      File.write(path, "<!-- /adversarial-review-run:run-report-1 -->\n")
      File.chmod(0o600, path)

      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.append(
          path, AdversarialReview::Reporting.summary(summary_source)
        )
      end

      assert_equal "duplicate_run", error.code
    end
  end

  def test_marker_text_inside_a_finding_does_not_impersonate_a_run_boundary
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      first_source = summary_source
      first_source.dig("semantic_groups", "G-001")["summary"] =
        "Literal <!-- adversarial-review-run:run-report-2:v1 --> text"
      first = AdversarialReview::Reporting.summary(first_source)
      second = AdversarialReview::Reporting.summary(summary_source("run_id" => "run-report-2"))

      AdversarialReview::Reporting.append(path, first)
      AdversarialReview::Reporting.append(path, second)

      assert_includes File.binread(path), "## Re-review run-report-2"
    end
  end

  private

  def summary_source(overrides = {})
    run_id = overrides.fetch("run_id", "run-report-1")
    finding_id = expected_finding_id(run_id)
    source = {
      "schema_version" => 1,
      "run_id" => run_id,
      "targets" => [{
        "role" => "spec", "path" => "docs/spec.md", "sha256" => "a" * 64
      }],
      "repository" => {
        "root" => "/tmp/repository", "head" => "b" * 40, "dirty" => true,
        "status" => [" M docs/spec.md"]
      },
      "started_at" => "2026-07-17T12:00:00Z",
      "ended_at" => "2026-07-17T12:01:00Z",
      "tier" => "high",
      "mode" => "critique",
      "output" => "both",
      "requested_executor" => "auto",
      "selected_executor" => "codex",
      "cli" => {"realpath" => "/usr/local/bin/codex", "version" => "codex 1.2.3"},
      "requested_model" => "gpt-review",
      "observed_model" => "gpt-review",
      "requested_effort" => "xhigh",
      "observed_effort" => "xhigh",
      "angles" => [
        {
          "name" => "traceability", "status" => "completed", "failure_reason" => nil,
          "retries" => 1, "retry_reasons" => ["First response failed schema validation"]
        },
        {
          "name" => "assumptions-checker", "status" => "completed", "failure_reason" => nil,
          "retries" => 0, "retry_reasons" => []
        }
      ],
      "enabled_tasks" => ["traceability", "assumptions-checker"],
      "capabilities" => capability_declaration,
      "degraded_capabilities" => [],
      "usage" => {
        "prompt_bytes" => 900, "input_tokens" => 200, "cached_input_tokens" => 20,
        "output_tokens" => 90, "reasoning_tokens" => 31, "total_tokens" => 321
      },
      "findings" => [{
        "id" => finding_id,
        "group_id" => "G-001",
        "category" => "Omission",
        "severity" => "HIGH",
        "confidence" => 0.94,
        "path" => "docs/spec.md",
        "line" => 12,
        "round" => 1,
        "reported" => true,
        "state" => "pending",
        "consequence" => "Release can stall.",
        "sources" => [
          {"candidate_id" => "C-assumptions-checker-1-1", "angle" => "assumptions-checker", "attempt" => 1},
          {"candidate_id" => "C-traceability-1-1", "angle" => "traceability", "attempt" => 1}
        ]
      }],
      "semantic_groups" => {
        "G-001" => {"summary" => "pipe | newline\nnext"}
      },
      "author_actions" => {},
      "resolution_checks" => {},
      "evidence_gaps" => [],
      "metrics" => {"tbd_count" => 2, "coverage_percent" => 87.5, "document_lines" => 120}
    }
    deep_merge(source, overrides)
  end

  def capability_declaration(status = "enforced")
    AdversarialReview::Capabilities::FIELDS.each_with_object({}) do |field, declarations|
      requested = case field
                  when "model_selection" then "gpt-review"
                  when "effort_selection" then "xhigh"
                  else true
                  end
      declarations[field] = {
        "requested" => requested,
        "status" => status,
        "evidence" => "fixture attestation",
        "source" => "test fixture"
      }
    end
  end

  def resolved_revise_source
    finding_id = expected_finding_id("run-report-1")
    source = summary_source(
      "mode" => "revise",
      "author_actions" => {
        finding_id => {
          "status" => "fixed", "rationale" => "Added an explicit owner.",
          "changed_paths" => ["docs/spec.md"]
        }
      },
      "resolution_checks" => {finding_id => "resolved"}
    )
    source.fetch("findings").first["state"] = "resolved"
    source
  end

  def expected_finding_id(run_id)
    "AR-#{Digest::SHA256.hexdigest(run_id)[0, 8]}-001"
  end

  def deep_merge(left, right)
    left.merge(right) do |_key, current, replacement|
      current.is_a?(Hash) && replacement.is_a?(Hash) ? deep_merge(current, replacement) : replacement
    end
  end
end
