require "minitest/autorun"
require_relative "../scripts/lib/prompt_engineer"

class PromptEngineerFinalReviewGatesTest < Minitest::Test
  def test_behavioral_run_store_arms_are_unassisted_and_not_implicit
    assert_equal %w[legacy replacement unassisted], PromptEngineer::RunStore::ARMS
    refute_includes PromptEngineer::RunStore::ARMS, "implicit"
  end

  def test_release_decision_requires_all_negative_triggers_to_pass
    evidence = release_evidence

    evidence["negative_triggers"] = {"unexpected_activation" => 1, "total" => 16}

    assert_equal "NOT_QUALIFIED", PromptEngineer::Scoring.release_decision(evidence).fetch("decision")
  end

  def test_cutover_requires_exact_capabilities_and_a_scorer_decision
    blocked = PromptEngineer::Cutover.evaluate(
      qualification: "PASS",
      capabilities: {},
      runtime: "ruby-2.6",
      sandbox: "supported"
    )

    assert_equal "BLOCKED", blocked.fetch("decision")
    refute blocked.fetch("mutations_permitted")

    ready = PromptEngineer::Cutover.evaluate(
      qualification: "QUALIFIED_EXPLICIT",
      capabilities: capabilities,
      runtime: "ruby-2.6",
      sandbox: "supported"
    )

    assert_equal "BLOCKED", ready.fetch("decision")
    refute ready.fetch("mutations_permitted")
    assert_includes ready.fetch("reasons"), "capability evidence authenticity is unproven"

    invalid = PromptEngineer::Cutover.evaluate(
      qualification: "PASS",
      capabilities: capabilities,
      runtime: "ruby-2.6",
      sandbox: "supported"
    )
    assert_equal "BLOCKED", invalid.fetch("decision")
  end

  def test_cli_docs_describe_only_commands_that_exist
    commands = File.binread(File.expand_path("../COMMANDS.md", __dir__))
    usage = File.binread(File.expand_path("../USAGE.md", __dir__))

    refute_includes commands, "Planned/deferred until implementation commits land"
    refute_includes commands, "scripts/prompt-engineer-cutover"
    refute_includes usage, "scripts/prompt-engineer-cutover rollback"
    assert_includes usage, "Cutover evaluation is currently fail-closed"
  end

  private

  def capabilities
    %w[codex claude].each_with_object({}) do |host, result|
      result[host] = {
        "host" => host,
        "status" => "supported",
        "normalizer" => "native",
        "reason" => "verified native evidence",
        "evidence" => {
          "root" => "/tmp/prompt-engineer-evidence",
          "artifact" => "#{host}/export-capabilities.json",
          "pointer" => "#/",
          "sha256" => "a" * 64
        }
      }
    end
  end

  def release_evidence
    comparisons = %w[codex claude].flat_map do |host|
      (1..12).map do |number|
        {
          "host" => host,
          "case_id" => format("PE-%03d", number),
          "status" => "comparable",
          "replacement" => score(4, 3, 2, 2, 2),
          "legacy" => score(3, 3, 2, 2, 2)
        }
      end
    end
    {
      "host_status" => {"codex" => "supported", "claude" => "supported"},
      "comparisons" => comparisons,
      "zero_tolerance_failures" => [],
      "efficiency" => {
        "codex" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}},
        "claude" => {"replacement" => {"turns" => 1, "characters" => 10}, "legacy" => {"turns" => 2, "characters" => 20}}
      },
      "explicit_triggers" => {"passed" => 16, "total" => 16},
      "negative_triggers" => {"unexpected_activation" => 0, "total" => 16},
      "inconclusives" => []
    }
  end

  def score(task_success, requirement_preservation, diagnosis_correctness, evaluation_quality, minimality)
    {
      "task_success" => task_success,
      "requirement_preservation" => requirement_preservation,
      "diagnosis_correctness" => diagnosis_correctness,
      "evaluation_quality" => evaluation_quality,
      "minimality" => minimality
    }
  end
end
