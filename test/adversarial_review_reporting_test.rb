require "minitest/autorun"
require "minitest/mock"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "support/adversarial_review_helper"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"

class AdversarialReviewReportingTest < Minitest::Test
  include AdversarialReviewHelper

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

  def test_did_not_converge_terminal_stage_cannot_render_passed
    source = resolved_revise_source.merge("terminal_stage" => "did-not-converge")

    summary = AdversarialReview::Reporting.summary(source)

    assert_match(/\ADID NOT CONVERGE\b/, summary.fetch("verdict"))
    assert_equal "did-not-converge", summary.fetch("terminal_stage")
  end

  def test_resolution_discovered_source_has_explicit_system_provenance
    source = summary_source
    source.dig("findings", 0, "sources", 0)["angle"] = "resolution"

    summary = AdversarialReview::Reporting.summary(source)

    assert_includes summary.dig("findings", 0, "source_angles"), "resolution"
    assert_equal ["resolution"], summary.dig("provenance", "system_sources")
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

  def test_combined_angles_require_a_nonempty_reason
    [nil, "   "].each do |missing_reason|
      source = summary_source
      angle = source.fetch("angles").first
      angle["status"] = "combined"
      angle["failure_reason"] = missing_reason

      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.summary(source)
      end

      assert_equal "invalid_angles", error.code
    end
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

  def test_reported_stable_ids_may_have_gaps_after_task_five_reranking
    source = summary_source
    source.fetch("findings").first["reported"] = false
    add_finding(source, 2, reported: true, severity: "CRITICAL")
    source["overflow"] = {
      "total" => 1,
      "by_category_severity" => {"Omission:HIGH" => 1},
      "items" => [expected_finding_id("run-report-1")]
    }

    summary = AdversarialReview::Reporting.summary(source)
    markdown = AdversarialReview::Reporting.markdown(summary)

    assert_equal [expected_finding_id("run-report-1", 2)],
                 summary.fetch("findings").map { |finding| finding.fetch("id") }
    assert_includes markdown, expected_finding_id("run-report-1", 2)
  end

  def test_revise_pass_requires_a_complete_consistent_terminal_disposition
    valid = resolved_revise_source
    finding_id = expected_finding_id("run-report-1")
    valid["author_actions"] = {finding_id => "fixed"}
    assert_equal "PASSED", AdversarialReview::Reporting.summary(valid).fetch("verdict")

    contradictory = resolved_revise_source
    contradictory["author_actions"] = {finding_id => "rejected"}
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(contradictory)
    end
    assert_equal "invalid_disposition", error.code

    missing = resolved_revise_source
    missing["author_actions"] = {}
    missing["resolution_checks"] = {}
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(missing)
    end
    assert_equal "invalid_disposition", error.code
  end

  def test_finding_state_must_match_its_terminal_resolution
    source = resolved_revise_source
    finding_id = expected_finding_id("run-report-1")
    source.fetch("findings").first["state"] = "rejected"
    source["resolution_checks"] = {finding_id => "resolved"}

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_disposition", error.code
  end

  def test_critique_renders_unproven_evidence_gaps_in_markdown_and_chat
    source = summary_source(
      "evidence_gaps" => [{
        "subject_id" => "G-unproven",
        "reason" => "UNPROVEN rollback ownership",
        "evidence" => "The reviewed section names no accountable owner."
      }]
    )

    summary = AdversarialReview::Reporting.summary(source)
    markdown = AdversarialReview::Reporting.markdown(summary)
    chat = AdversarialReview::Reporting.chat_payload(summary)

    assert_includes markdown, "## Open Questions"
    assert_includes markdown, "UNPROVEN rollback ownership"
    assert_includes markdown, "The reviewed section names no accountable owner."
    assert_equal summary.fetch("open_questions"), chat.fetch("open_questions")
  end

  def test_render_recomputes_every_derived_section_from_canonical_inputs
    source = summary_source(
      "evidence_gaps" => [{
        "subject_id" => "G-unproven",
        "reason" => "UNPROVEN rollback ownership",
        "evidence" => "No accountable owner is named."
      }]
    )
    summary = AdversarialReview::Reporting.summary(source)

    assert_equal source.fetch("evidence_gaps"), summary.fetch("evidence_gaps")

    mutations = [
      ->(value) { value["open_questions"] = [] },
      ->(value) { value["evidence_gaps"] = [] },
      ->(value) { value["changelog"] = [{"id" => "invented", "summary" => "Invented"}] },
      ->(value) { value["rejected_findings"] = [{"id" => "invented", "summary" => "Invented"}] }
    ]
    mutations.each do |mutate|
      tampered = JSON.parse(JSON.generate(summary))
      mutate.call(tampered)
      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.markdown(tampered)
      end
      assert_equal "invalid_summary", error.code
    end

    revise = AdversarialReview::Reporting.summary(summary_source("mode" => "revise"))
    revise["verdict"] = "PASSED"
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.markdown(revise)
    end
    assert_equal "invalid_summary", error.code
  end

  def test_overflow_and_nonblocking_rationales_survive_every_output
    source = summary_source
    overflow_id = add_finding(source, 2, reported: false, severity: "MEDIUM")
    source["overflow"] = {
      "total" => 1,
      "by_category_severity" => {"Omission:MEDIUM" => 1},
      "items" => [overflow_id]
    }
    source["overflow_evidence_gaps"] = {
      overflow_id => {
        "rationale" => "Reviewed and nonblocking at the report cap.",
        "recorded_at_stage" => "resolving",
        "round" => 1
      }
    }

    summary = AdversarialReview::Reporting.summary(source)
    markdown = AdversarialReview::Reporting.markdown(summary)
    chat = AdversarialReview::Reporting.chat_payload(summary)

    assert_equal 1, summary.dig("overflow", "total")
    assert_equal({"Omission:MEDIUM" => 1}, summary.dig("overflow", "by_category_severity"))
    assert_equal "Reviewed and nonblocking at the report cap.",
                 summary.dig("overflow_evidence_gaps", "representatives", 0, "rationale")
    assert_equal overflow_id, summary.dig("overflow", "representatives", 0, "id")
    assert_equal 1, summary.dig("metrics", "overflow_total")
    assert_equal summary.fetch("overflow"), chat.fetch("overflow")
    assert_equal summary.fetch("overflow_evidence_gaps"), chat.fetch("overflow_evidence_gaps")
    assert_includes markdown, "## Overflow"
    assert_includes markdown, "Omission:MEDIUM: 1"
    assert_includes markdown, "Reviewed and nonblocking at the report cap."
  end

  def test_large_overflow_is_bounded_but_retains_aggregate_integrity_and_verdict
    source = resolved_revise_source
    overflow_ids = []
    overflow_gaps = {}
    2.upto(202) do |index|
      finding_id = add_finding(source, index, reported: false, severity: "MEDIUM")
      overflow_ids << finding_id
      overflow_gaps[finding_id] = {
        "rationale" => "Reviewed overflow finding #{index} and found it nonblocking.",
        "recorded_at_stage" => "resolving",
        "round" => 1
      }
    end
    source["overflow"] = {
      "total" => overflow_ids.length,
      "by_category_severity" => {"Omission:MEDIUM" => overflow_ids.length},
      "items" => overflow_ids
    }
    source["overflow_evidence_gaps"] = overflow_gaps

    summary = AdversarialReview::Reporting.summary(source)
    markdown = AdversarialReview::Reporting.markdown(summary)
    chat = AdversarialReview::Reporting.chat_payload(summary)

    assert_equal "PASSED", summary.fetch("verdict")
    assert_equal 201, summary.dig("overflow", "total")
    assert_equal 201, summary.dig("metrics", "overflow_total")
    assert_equal 201, summary.dig("overflow_evidence_gaps", "total")
    assert_operator summary.dig("overflow", "representatives").length, :<=, 5
    assert_operator summary.dig("overflow_evidence_gaps", "representatives").length, :<=, 5
    refute summary.fetch("overflow").key?("findings")
    assert_operator JSON.generate(summary).bytesize, :<, 20_000
    assert_operator markdown.bytesize, :<, 20_000
    assert_operator JSON.generate(chat).bytesize, :<, 40_000
    expected_rows = summary.fetch("findings").length + summary.dig("overflow", "representatives").length
    assert_equal expected_rows, markdown.lines.grep(/^\| AR-/).length
    assert_operator expected_rows, :<=, 6
    assert_includes markdown, "Omission:MEDIUM: 201"
    assert_includes markdown, "Reviewed overflow finding 2 and found it nonblocking."
  end

  def test_overflow_is_required_and_must_match_unreported_findings
    missing = summary_source
    missing.delete("overflow")
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(missing)
    end
    assert_equal "invalid_summary", error.code

    mismatched = summary_source
    mismatched["overflow"] = {
      "total" => 1, "by_category_severity" => {"Omission:LOW" => 1}, "items" => ["AR-bad-001"]
    }
    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(mismatched)
    end
    assert_equal "invalid_overflow", error.code
  end

  def test_complete_source_finding_ids_must_be_contiguous
    source = summary_source
    missing_id = expected_finding_id("run-report-1", 2)
    overflow_id = add_finding(source, 3, reported: false, severity: "LOW")
    source["overflow"] = {
      "total" => 1,
      "by_category_severity" => {"Omission:LOW" => 1},
      "items" => [overflow_id]
    }

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_findings", error.code
    assert_includes error.message, "contiguous"
    refute_equal missing_id, overflow_id
  end

  def test_persisted_overflow_integrity_cannot_hide_missing_ids
    source = summary_source
    source.fetch("findings").first["reported"] = false
    add_finding(source, 2, reported: true, severity: "CRITICAL")
    source["overflow"] = {
      "total" => 1,
      "by_category_severity" => {"Omission:HIGH" => 1},
      "items" => [expected_finding_id("run-report-1")]
    }
    original = AdversarialReview::Reporting.summary(source)
    mutations = [
      ->(summary) { summary.dig("overflow", "id_integrity")["partition_sha256"] = "0" * 64 },
      ->(summary) { summary["findings"] = [] }
    ]
    mutations.each do |mutate|
      summary = JSON.parse(JSON.generate(original))
      mutate.call(summary)
      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.markdown(summary)
      end
      assert_equal "invalid_summary", error.code
    end
  end

  def test_huge_authoritative_total_is_rejected_before_partition_expansion
    summary = AdversarialReview::Reporting.summary(summary_source)
    huge_total = (AdversarialReview::Atomic::MAX_JSON_BYTES / 128) + 1
    overflow = summary.fetch("overflow")
    overflow["total"] = huge_total - summary.fetch("findings").length
    overflow["by_category_severity"] = {"Omission:LOW" => overflow.fetch("total")}
    overflow.dig("id_integrity")["authoritative_total"] = huge_total
    expanded = false
    expansion_probe = lambda do |*_arguments|
      expanded = true
      raise "partition expansion reached"
    end

    error = nil
    AdversarialReview::Reporting.stub(:overflow_id_integrity, expansion_probe) do
      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.markdown(summary)
      end
    end

    refute expanded
    assert_equal "invalid_summary", error.code
    assert_includes error.message, "maximum"
  end

  def test_reporting_rejects_more_than_fifty_reported_findings
    source = summary_source
    2.upto(51) { |index| add_finding(source, index, reported: true, severity: "LOW") }

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

  def test_rejects_an_invalid_finding_round_before_summary_returns
    source = summary_source
    source.fetch("findings").first["round"] = 3

    error = assert_raises(AdversarialReview::Reporting::Error) do
      AdversarialReview::Reporting.summary(source)
    end

    assert_equal "invalid_findings", error.code
  end

  def test_repository_dirty_metadata_and_digest_must_agree
    status = [" M docs/spec.md"]
    cases = [
      {"dirty" => false, "status" => status},
      {"dirty" => true, "status" => []},
      {"dirty" => true, "status" => status, "dirty_digest" => "0" * 64}
    ]

    cases.each do |repository_override|
      source = summary_source("repository" => repository_override)
      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.summary(source)
      end
      assert_equal "invalid_repository", error.code
    end
  end

  def test_metric_names_and_strings_cannot_inject_markdown_or_run_markers
    source = summary_source(
      "metrics" => {
        "safe\n## Injected" => "value\n<!-- adversarial-review-run:fake:v1 -->"
      }
    )

    summary = AdversarialReview::Reporting.summary(source)
    markdown = AdversarialReview::Reporting.markdown(summary)

    refute summary.dig("metrics", "values").keys.any? { |key| key.include?("\n") || key.include?("<!--") }
    refute summary.dig("metrics", "values").values.any? { |value|
      value.is_a?(String) && (value.include?("\n") || value.include?("<!--"))
    }
    refute_includes markdown, "\n## Injected"
    refute_includes markdown, "<!-- adversarial-review-run:fake:v1 -->"
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
      assert_unsafe_code "unsafe_report", error.code
      assert_equal "unchanged", File.read(outside)

      File.unlink(target)
      lock = File.join(directory, ".review.md.lock")
      File.unlink("#{lock}.anchor")
      File.unlink(lock)
      File.symlink(outside, lock)
      error = assert_raises(AdversarialReview::State::Error) do
        AdversarialReview::Reporting.append(target, AdversarialReview::Reporting.summary(summary_source))
      end
      assert_unsafe_code "unsafe_lock", error.code
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

  def test_oversized_prospective_append_is_atomic_and_does_not_poison_the_lock
    Dir.mktmpdir("adversarial-review-report") do |directory|
      path = File.join(directory, "review.md")
      first = AdversarialReview::Reporting.summary(summary_source)
      second = AdversarialReview::Reporting.summary(summary_source("run_id" => "run-report-2"))
      third = AdversarialReview::Reporting.summary(summary_source("run_id" => "run-report-3"))
      AdversarialReview::Reporting.append(path, first)
      before = File.binread(path)
      constrained_limit = before.bytesize + 32

      error = assert_raises(AdversarialReview::Reporting::Error) do
        AdversarialReview::Reporting.stub(:report_byte_limit, constrained_limit) do
          AdversarialReview::Reporting.append(path, second)
        end
      end

      assert_equal "report_too_large", error.code
      assert_equal before, File.binread(path)
      AdversarialReview::Reporting.append(path, third)
      assert_includes File.binread(path), "adversarial-review-run:run-report-3:v1"
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
            rescue StandardError => error
              # Opt-in diagnostics: a lost race here surfaces only as a failed
              # child exit, and the backend that races is the one we cannot
              # attach to locally. AR_RACE_DEBUG=1 surfaces the real error.
              if ENV["AR_RACE_DEBUG"]
                warn("#{run_id}: #{error.class}: #{error.message} " \
                     "[#{error.respond_to?(:code) ? error.code : ""}] " \
                     "#{error.respond_to?(:details) ? error.details.inspect : ""}")
                warn(error.backtrace.take(4).join("\n"))
              end
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
      "overflow" => {"total" => 0, "by_category_severity" => {}, "items" => []},
      "overflow_evidence_gaps" => {},
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

  def expected_finding_id(run_id, index = 1)
    format("AR-%s-%03d", Digest::SHA256.hexdigest(run_id)[0, 8], index)
  end

  def add_finding(source, index, reported:, severity:)
    finding = JSON.parse(JSON.generate(source.fetch("findings").first))
    finding_id = expected_finding_id(source.fetch("run_id"), index)
    finding["id"] = finding_id
    finding["group_id"] = format("G-%03d", index)
    finding["reported"] = reported
    finding["severity"] = severity
    finding["line"] = 10 + index
    finding.fetch("sources").each do |item|
      item["candidate_id"] = "#{item.fetch("candidate_id")}-#{index}"
    end
    source.fetch("findings") << finding
    source.fetch("semantic_groups")[finding.fetch("group_id")] = {
      "summary" => "Additional finding #{index}"
    }
    finding_id
  end

  def deep_merge(left, right)
    left.merge(right) do |_key, current, replacement|
      current.is_a?(Hash) && replacement.is_a?(Hash) ? deep_merge(current, replacement) : replacement
    end
  end
end
