require "minitest/autorun"
require "json"
require "tmpdir"
require "thread"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"
require_relative "support/adversarial_review_helper"

class AdversarialReviewAdaptersTest < Minitest::Test
  include AdversarialReviewHelper

  def test_adapter_base_owns_shared_eligibility_error_vocabulary
    %w[
      capability_probe_failed version_probe_failed unsupported_tier
      unsupported_version_contract unsupported_effort_contract capabilities_degraded
      runtime_selection_mismatch structured_output_unattested
      runtime_attestation_missing session_reused
    ].each do |code|
      assert AdversarialReview::Adapters::Base.eligibility_error?(code), code
    end
    %w[invalid_result process_failed process_output_truncated adapter_error].each do |code|
      refute AdversarialReview::Adapters::Base.eligibility_error?(code), code
    end
  end

  def test_cursor_adapter_constant_is_loaded
    assert_equal "AdversarialReview::Adapters::Cursor",
                 AdversarialReview::Adapters::Cursor.name
  end

  def test_gemini_adapter_constant_is_loaded
    assert_equal "AdversarialReview::Adapters::Gemini",
                 AdversarialReview::Adapters::Gemini.name
  end

  def test_runner_uses_an_argv_array_and_preserves_stdin
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-bin") do |bin|
        log = File.join(bin, "log.jsonl")
        fake = write_fake_executable(bin)
        result = AdversarialReview::Runner.run(
          argv: [fake, "$(touch pwned)", "; echo bad", "--output-format", "json"],
          stdin_data: "prompt\nwith data",
          timeout_seconds: 2,
          chdir: repository,
          env: {"FAKE_CLI_LOG" => log}
        )

        assert_equal 0, result.exit_status
        record = fake_cli_records(log).fetch(0)
        assert_equal ["$(touch pwned)", "; echo bad", "--output-format", "json"], record.fetch("argv")
        assert_equal "prompt\nwith data", record.fetch("stdin")
        refute File.exist?(File.join(repository, "pwned"))
      end
    end
  end

  def test_runner_resolves_once_from_parent_path_but_does_not_forward_path
    Dir.mktmpdir("adversarial-review-path") do |bin|
      log = File.join(bin, "log.jsonl")
      write_fake_executable(bin, name: "fake-from-path")
      previous_path = ENV["PATH"]
      ENV["PATH"] = [bin, previous_path].compact.join(File::PATH_SEPARATOR)
      result = AdversarialReview::Runner.run(
        argv: ["fake-from-path"], stdin_data: "", timeout_seconds: 2,
        env: {"FAKE_CLI_LOG" => log}
      )

      assert_equal 0, result.exit_status
      refute fake_cli_records(log).fetch(0).fetch("env").key?("PATH")
    ensure
      ENV["PATH"] = previous_path
    end
  end

  def test_runner_captures_bounded_output_without_deadlock
    result = AdversarialReview::Runner.run(
      argv: ruby_script('STDOUT.write("o" * 200_000); STDERR.write("e" * 200_000)'),
      stdin_data: "",
      timeout_seconds: 2,
      max_output_bytes: 4096
    )

    assert_equal 0, result.exit_status
    assert_equal 4096, result.stdout.bytesize
    assert_equal 4096, result.stderr.bytesize
    assert_equal true, result.stdout_truncated
    assert_equal true, result.stderr_truncated
  end

  def test_runner_returns_nonzero_exit_and_monotonic_duration
    result = AdversarialReview::Runner.run(
      argv: ruby_script('STDERR.write("nope"); exit 23'),
      stdin_data: "",
      timeout_seconds: 2
    )

    assert_equal 23, result.exit_status
    assert_equal "nope", result.stderr
    assert_operator result.duration_ms, :>=, 0
    assert_equal false, result.timed_out
  end

  def test_base_returns_complete_capability_objects
    base = AdversarialReview::Adapters::Base.new
    record = base.capabilities(
      requested_model: "model-x",
      requested_effort: "high",
      observations: {
        "fresh_context" => ["enforced", "new process", "runtime event"],
        "model_selection" => ["enforced", "model-x", "runtime event"]
      }
    )

    assert_equal AdversarialReview::Capabilities::FIELDS.sort, record.keys.sort
    record.each do |field, declaration|
      assert_equal %w[evidence requested source status], declaration.keys.sort, field
      assert_includes AdversarialReview::Capabilities::STATUSES, declaration.fetch("status")
    end
    assert_equal "model-x", record.dig("model_selection", "requested")
    assert_equal "high", record.dig("effort_selection", "requested")
    assert_equal "unavailable", record.dig("read_only", "status")
  end

  def test_no_silent_downgrade_contract_is_table_driven_for_registered_adapters
    contracts = AdversarialReview::Adapters::Base.direct_contracts
    assert_kind_of Array, contracts
    refute_empty contracts
    assert_equal [
      ["claude", "default"], ["claude", "high"], ["claude", "ultra"],
      ["codex", "default"], ["codex", "high"], ["codex", "ultra"],
      ["cursor", "default"], ["cursor", "high"], ["cursor", "ultra"],
      ["gemini", "default"], ["gemini", "high"], ["gemini", "ultra"]
    ], contracts.map { |entry| [entry.fetch("adapter"), entry.fetch("tier")] }.sort

    contracts.each do |contract|
      exact = AdversarialReview::Adapters::Base.runtime_decision(
        adapter: contract.fetch("adapter"), tier: contract.fetch("tier"),
        requested_model: "model-x", requested_effort: "high",
        observed_model: "model-x", observed_effort: "high"
      )
      expected_status = contract.fetch("direct_supported") ? "direct" : "generic"
      assert_equal expected_status, exact.status, contract.inspect
      assert_equal contract.fetch("direct_supported"), exact.execution_allowed, contract.inspect
      assert_equal contract.fetch("direct_supported"), exact.ordinary_result, contract.inspect

      [[nil, "high"], ["model-x", nil], ["different", "high"],
       ["model-x", "medium"]].each do |observed_model, observed_effort|
        degraded = AdversarialReview::Adapters::Base.runtime_decision(
          adapter: contract.fetch("adapter"), tier: contract.fetch("tier"),
          requested_model: "model-x", requested_effort: "high",
          observed_model: observed_model, observed_effort: observed_effort
        )
        assert_equal "generic", degraded.status, contract.inspect
        assert_equal false, degraded.execution_allowed, contract.inspect
        assert_equal false, degraded.ordinary_result, contract.inspect
      end
    end
  end

  def test_ultra_direct_support_is_claude_only_and_still_requires_attestation
    %w[codex claude cursor gemini].each do |adapter|
      exact = AdversarialReview::Adapters::Base.runtime_decision(
        adapter: adapter, tier: "ultra",
        requested_model: "model-x", requested_effort: "high",
        observed_model: "model-x", observed_effort: "high"
      )
      if adapter == "claude"
        assert_equal "direct", exact.status
        assert_equal true, exact.execution_allowed
        missing = AdversarialReview::Adapters::Base.runtime_decision(
          adapter: adapter, tier: "ultra",
          requested_model: "model-x", requested_effort: "high",
          observed_model: nil, observed_effort: nil
        )
        assert_equal "generic", missing.status
        assert_equal false, missing.execution_allowed
        assert_equal false, missing.ordinary_result
      else
        assert_equal "generic", exact.status, adapter
        assert_equal false, exact.execution_allowed, adapter
        assert_equal false, exact.ordinary_result, adapter
      end
    end
  end

  def test_unknown_adapter_does_not_inherit_a_vendor_contract
    adapter = Class.new(AdversarialReview::Adapters::Base).new

    assert_equal "unknown", adapter.adapter_name
    decision = AdversarialReview::Adapters::Base.runtime_decision(
      adapter: adapter.adapter_name, tier: "default",
      requested_model: "model-x", requested_effort: "high",
      observed_model: "model-x", observed_effort: "high"
    )
    assert_equal "generic", decision.status
    assert_equal false, decision.execution_allowed
  end

  def test_base_builds_a_minimal_documented_child_environment
    klass = Class.new(AdversarialReview::Adapters::Base) do
      def credential_variables
        ["VENDOR_API_KEY"]
      end
    end
    source = {
      "LANG" => "en_US.UTF-8", "LC_ALL" => "C", "PATH" => "/unsafe",
      "RUBYOPT" => "-runsafe", "SECRET" => "hidden", "HOME" => "/real-home",
      "VENDOR_API_KEY" => "credential"
    }

    AdversarialReview::Runner.with_isolated_directory do |home|
      AdversarialReview::Runner.with_isolated_directory do |config|
        env = klass.new.child_environment(
          source_env: source, isolated_home: home, isolated_config_root: config
        )

        assert_equal({
          "HOME" => File.realpath(home), "LANG" => "en_US.UTF-8", "LC_ALL" => "C",
          "VENDOR_API_KEY" => "credential",
          "XDG_CONFIG_HOME" => File.realpath(config)
        }, env)
      end
    end
  end

  def test_child_environment_accepts_the_default_env_mapping_on_ruby_2_6
    env = AdversarialReview::Adapters::Base.new.child_environment

    assert_equal [], env.keys - AdversarialReview::Adapters::Base::LOCALE_VARIABLES
    env.each do |key, value|
      assert_kind_of String, key
      assert_kind_of String, value
    end
    refute env.key?("PATH")
    refute env.key?("RUBYOPT")
  end

  def test_child_environment_accepts_a_read_only_each_pair_mapping
    mapping = Object.new
    mapping.define_singleton_method(:each_pair) do |&block|
      [["LANG", "C"], ["PATH", "/not-forwarded"]].each(&block)
    end

    env = AdversarialReview::Adapters::Base.new.child_environment(source_env: mapping)

    assert_equal({"LANG" => "C"}, env)
  end

  def test_child_environment_accepts_a_read_only_to_h_mapping
    mapping = Object.new
    mapping.define_singleton_method(:to_h) do
      {"LC_ALL" => "C", "RUBYOPT" => "not-forwarded"}.freeze
    end

    env = AdversarialReview::Adapters::Base.new.child_environment(source_env: mapping)

    assert_equal({"LC_ALL" => "C"}, env)
  end

  def test_child_environment_rejects_noncanonical_or_insecure_isolated_roots
    Dir.mktmpdir("adversarial-review-home") do |parent|
      insecure = File.join(parent, "insecure")
      Dir.mkdir(insecure, 0o755)
      symlink = File.join(parent, "home-link")
      File.symlink(insecure, symlink)
      base = AdversarialReview::Adapters::Base.new

      assert_raises(ArgumentError) { base.child_environment(isolated_home: insecure) }
      assert_raises(ArgumentError) { base.child_environment(isolated_home: symlink) }
      assert_raises(ArgumentError) do
        base.child_environment(isolated_config_root: File.join(parent, "missing"))
      end
    end
  end

  def test_one_repair_for_invalid_format_and_usage_capture
    adapter = harness_adapter([
      {"payload" => "not-an-object", "terminal" => runtime_event,
       "usage" => {"total_tokens" => 12}},
      {"payload" => valid_payload, "terminal" => runtime_event,
       "usage" => {"total_tokens" => 7}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "complete", result.status
    assert_equal 2, result.attempts
    assert_equal 19, result.usage.fetch("total_tokens")
    assert_equal valid_payload, result.payload
  end

  def test_fake_cli_records_exactly_one_repair_process
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-repair") do |bin|
        log = File.join(bin, "calls.jsonl")
        body = <<~RUBY
          \#!#{RbConfig.ruby}
          require "json"
          log = ENV.fetch("FAKE_CLI_LOG")
          calls = File.exist?(log) ? File.readlines(log).length : 0
          input = STDIN.read
          File.open(log, "a", 0600) { |file| file.puts(JSON.generate({"stdin" => input})) }
          payload = calls.zero? ? "malformed" : {
            "checks" => ["assumption-coverage"], "findings" => []
          }
          capabilities = #{JSON.generate(enforced_capabilities)}
          puts JSON.generate({
            "payload" => payload,
            "terminal" => {"terminal" => true, "model" => "model-x", "effort" => "high"},
            "usage" => {"total_tokens" => 1}, "capabilities" => capabilities
          })
        RUBY
        fake = write_fake_executable(bin, body: body)
        pinned = AdversarialReview::Runner.resolve_executable(fake)
        klass = Class.new(AdversarialReview::Adapters::Base) do
          define_method(:initialize) do |path, executable, cwd, log_path|
            super()
            @path = path
            @executable = executable
            @cwd = cwd
            @log_path = log_path
          end
          define_method(:invoke) do |repair|
            run = AdversarialReview::Runner.run(
              argv: [@path], stdin_data: repair ? "repair" : "initial",
              timeout_seconds: 2, chdir: @cwd, repository: @cwd,
              executable: @executable, env: {"FAKE_CLI_LOG" => @log_path}
            )
            [run, JSON.parse(run.stdout)]
          end
          define_method(:valid_payload?) do |payload|
            payload.is_a?(Hash) && payload["checks"].is_a?(Array)
          end
          define_method(:adapter_name) { "codex" }
        end

        result = klass.new(pinned.path, pinned, repository, log).execute_with_one_repair(
          requested_model: "model-x", requested_effort: "high",
          required_checks: ["assumption-coverage"]
        )

        assert_equal "complete", result.status
        assert_equal 2, result.attempts
        assert_equal ["initial", "repair"], fake_cli_records(log).map { |entry| entry.fetch("stdin") }
        assert_equal 2, result.usage.fetch("total_tokens")
      end
    end
  end

  def test_one_repair_for_missing_required_check
    first = valid_payload.merge("checks" => [])
    adapter = harness_adapter([
      {"payload" => first, "terminal" => runtime_event, "usage" => {}},
      {"payload" => valid_payload, "terminal" => runtime_event, "usage" => {}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "complete", result.status
    assert_equal 2, result.attempts
  end

  def test_one_repair_for_an_invented_extra_check
    first = valid_payload.merge(
      "checks" => ["assumption-coverage", "invented-unassigned-check"]
    )
    adapter = harness_adapter([
      {"payload" => first, "terminal" => runtime_event, "usage" => {}},
      {"payload" => valid_payload, "terminal" => runtime_event, "usage" => {}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "complete", result.status
    assert_equal 2, result.attempts
  end

  def test_valid_low_finding_result_is_not_repaired
    payload = valid_payload.merge("findings" => [])
    adapter = harness_adapter([
      {"payload" => payload, "terminal" => runtime_event, "usage" => {}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "complete", result.status
    assert_equal 1, result.attempts
    assert_equal [], result.payload.fetch("findings")
  end

  def test_missing_terminal_event_falls_back_without_repair
    adapter = harness_adapter([
      {"payload" => valid_payload, "terminal" => nil,
       "usage" => {"total_tokens" => 11}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "runtime_attestation_missing", result.error_code
    assert_equal 1, result.attempts
    assert_equal false, result.ordinary_result
    assert_equal 11, result.usage.fetch("total_tokens")
  end

  def test_missing_capability_attestation_falls_back_without_repair
    adapter = harness_adapter([
      {"payload" => valid_payload, "terminal" => runtime_event,
       "usage" => {"total_tokens" => 13},
       "capabilities" => {}}
    ], add_capabilities: false)

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "capabilities_degraded", result.error_code
    assert_equal 1, result.attempts
    assert_equal false, result.ordinary_result
    assert_equal 13, result.usage.fetch("total_tokens")
  end

  def test_runtime_model_or_effort_mismatch_falls_back_without_repair
    [["different", "high"], ["model-x", "medium"]].each do |model, effort|
      adapter = harness_adapter([
        {"payload" => valid_payload,
         "terminal" => runtime_event.merge("model" => model, "effort" => effort),
         "usage" => {"total_tokens" => 17}}
      ])

      result = adapter.execute_with_one_repair(
        requested_model: "model-x", requested_effort: "high",
        required_checks: ["assumption-coverage"]
      )

      assert_equal "generic", result.status
      assert_equal "runtime_selection_mismatch", result.error_code
      assert_equal 1, result.attempts
      assert_equal 17, result.usage.fetch("total_tokens")
    end
  end

  def test_nonzero_runner_result_is_not_repaired
    adapter = harness_adapter([], runner_results: [
      AdversarialReview::Runner::Result.new(
        stdout: "", stderr: "failed", exit_status: 9, duration_ms: 1,
        timed_out: false, stdout_truncated: false, stderr_truncated: false
      )
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high", required_checks: []
    )

    assert_equal "generic", result.status
    assert_equal "process_failed", result.error_code
    assert_equal 1, result.attempts
  end

  def test_truncated_process_output_is_not_accepted_or_repaired
    truncated = AdversarialReview::Runner::Result.new(
      stdout: "{}", stderr: "", exit_status: 0, duration_ms: 1,
      timed_out: false, stdout_truncated: true, stderr_truncated: false
    )
    adapter = harness_adapter([], runner_results: [[truncated, {
      "payload" => valid_payload, "terminal" => runtime_event,
      "usage" => {"total_tokens" => 999}, "capabilities" => enforced_capabilities
    }]])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "process_output_truncated", result.error_code
    assert_equal 1, result.attempts
    assert_equal({}, result.usage)
  end

  def test_malformed_envelope_cannot_inject_usage
    adapter = harness_adapter(["not-a-parsed-envelope"])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high", required_checks: []
    )

    assert_equal "runtime_attestation_missing", result.error_code
    assert_equal({}, result.usage)
    assert_equal 1, result.attempts
  end

  def test_usage_telemetry_rejects_unknown_nested_and_non_integer_values
    adapter = AdversarialReview::Adapters::Base.new
    valid = {
      "input_tokens" => 3, "cached_input_tokens" => 1,
      "cache_read_input_tokens" => 2, "cache_creation_input_tokens" => 4,
      "output_tokens" => 5, "reasoning_tokens" => 6, "total_tokens" => 8
    }

    assert_equal valid, adapter.send(:valid_usage, valid)
    assert_equal({}, adapter.send(:valid_usage, valid.merge("unknown" => 9)))
    assert_equal({}, adapter.send(:valid_usage, {"input_tokens" => {"nested" => 1}}))
    assert_equal({}, adapter.send(:valid_usage, {"input_tokens" => 1.0}))
    assert_equal({}, adapter.send(:valid_usage, {"input_tokens" => Float::INFINITY}))
    assert_equal({}, adapter.send(:valid_usage, {"input_tokens" => -1}))
  end

  def test_repair_is_bounded_when_both_results_are_invalid
    adapter = harness_adapter([
      {"payload" => "invalid", "terminal" => runtime_event, "usage" => {}},
      {"payload" => {"checks" => []}, "terminal" => runtime_event, "usage" => {}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "invalid_result", result.error_code
    assert_equal 2, result.attempts
    assert_equal false, result.ordinary_result
  end

  def test_repair_must_repeat_runtime_and_capability_attestation
    invalid = {
      "payload" => "invalid", "terminal" => runtime_event, "usage" => {},
      "capabilities" => enforced_capabilities
    }
    bad_runtime = harness_adapter([
      invalid,
      {"payload" => valid_payload,
       "terminal" => runtime_event.merge("effort" => "medium"), "usage" => {}}
    ]).execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )
    assert_equal "runtime_selection_mismatch", bad_runtime.error_code
    assert_equal 2, bad_runtime.attempts

    bad_capabilities = harness_adapter([
      invalid,
      {"payload" => valid_payload, "terminal" => runtime_event, "usage" => {},
       "capabilities" => {}}
    ], add_capabilities: false).execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )
    assert_equal "capabilities_degraded", bad_capabilities.error_code
    assert_equal 2, bad_capabilities.attempts
    assert_equal false, bad_capabilities.ordinary_result
  end

  def test_direct_adapter_fixtures_are_sanitized_and_labelled
    %w[codex claude cursor gemini].each do |provider|
      metadata = JSON.parse(File.read(adapter_fixture(provider, "metadata.json")))
      assert_equal true, metadata.fetch("sanitized"), provider
      assert_includes metadata.fetch("fixture_kind"), "contract", provider
      assert_kind_of String, metadata.fetch("capture_command"), provider
      fixtures = {
        "codex" => %w[accepted.jsonl missing-attestation.jsonl],
        "claude" => %w[accepted-contract.jsonl claude-2.1.212-missing-attestation.jsonl],
        "cursor" => %w[accepted-contract.jsonl missing-attestation.jsonl current-help-probe.json],
        "gemini" => %w[accepted-contract.json missing-attestation.json current-help-probe.json]
      }.fetch(provider)
      fixtures.each do |fixture|
        refute_empty File.read(adapter_fixture(provider, fixture)), "#{provider}/#{fixture}"
      end
    end
  end

  def test_installed_cursor_and_gemini_probe_fixtures_fail_closed_without_runtime_attestation
    cursor = JSON.parse(File.read(adapter_fixture("cursor", "current-help-probe.json")))
    gemini = JSON.parse(File.read(adapter_fixture("gemini", "current-help-probe.json")))

    assert_equal "2026.07.16-899851b", cursor.fetch("captured_version")
    assert_equal false, cursor.fetch("direct_eligible")
    assert_includes cursor.fetch("missing_contracts"), "machine-readable runtime effort attestation"
    assert_equal false, gemini.fetch("installed")
    assert_equal false, gemini.fetch("direct_eligible")
  end

  def test_installed_cursor_help_surface_is_ineligible_before_review_content
    current_help = "-p --mode --sandbox --workspace --model --output-format"
    result, records = run_direct_adapter_case(
      "cursor", help_text: current_help, cli_version: "2026.07.16-899851b"
    )

    assert_equal "generic", result.status
    assert_equal "capability_probe_failed", result.error_code
    assert_equal ["help"], records.map { |record| record.fetch("kind") }
    records.each do |record|
      refute_includes record.fetch("argv").join(" "), "REVIEWED SECRET"
    end
  end

  def test_authoritative_plan_matches_the_claude_2_1_212_stream_json_argv
    plan = File.read(File.join(
      __dir__, "..", "docs", "plans",
      "2026-07-17-adversarial-review-portable-control-plane-implementation-plan.md"
    ))
    expected = <<~RUBY.strip
      [claude_realpath, "-p", "--bare", "--no-session-persistence",
       "--permission-mode", "plan", "--tools", "Read,Grep,Glob",
       "--model", model, "--effort", effort, "--verbose",
       "--output-format", "stream-json", "--json-schema",
       JSON.generate(role_schema), prompt]
    RUBY

    assert_includes plan, expected
    assert_includes plan, "Claude Code 2.1.212 requires `--verbose` with print-mode `stream-json`."
    assert_includes plan,
                    "Direct execution requires a caller-supplied `dispatch_capability` observation; adapters never infer or fabricate parallel dispatch."
    assert_includes plan,
                    "Codex final-message output must update the precreated `0600` file in place. Atomic replacement, symlinks, identity changes, and oversized output are rejected fail closed."
  end

  def test_cursor_adapter_probes_then_runs_with_exact_argv_and_provenance
    with_repository(files: {"docs/spec.md" => "# Reviewed secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-bin") do |bin|
        log = File.join(bin, "cursor-calls.jsonl")
        payload = direct_role_payload
        fake = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: payload,
          stream: File.read(adapter_fixture("cursor", "accepted-contract.jsonl")),
          observed_model: "cursor-model-x", observed_effort: "high"
        )
        prompt = "REVIEWED SECRET: inspect docs/spec.md"
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: fake, repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: prompt, tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(
          required_checks: ["assumption-coverage"],
          dispatch_capability: observed_dispatch
        )

        assert_equal "complete", result.status
        assert_equal payload, result.payload
        assert_equal 80, result.usage.fetch("total_tokens")
        assert_normalized_capabilities(result.capabilities, "cursor complete")
        records = fake_cli_records(log)
        assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
        preflight, execution = records.select { |record| record.fetch("kind") == "run" }
        refute_includes preflight.fetch("argv").join(" "), "REVIEWED SECRET"
        assert_equal false, preflight.fetch("relative_review_visible")
        assert_equal prompt, execution.fetch("argv").last
        assert_equal [
          "-p", "--mode", "ask", "--sandbox", "enabled", "--workspace",
          File.realpath(repository), "--model", "cursor-model-x", "--output-format",
          "stream-json", "--effort", "high", prompt
        ], execution.fetch("argv")
        provenance = result.runtime_provenance.fetch("executions").fetch(0)
        assert_equal "cursor-agent contract-vNext", provenance.fetch("cli_version")
        assert_equal "cursor-session-2", provenance.fetch("session_id")
        assert_equal File.realpath(repository), provenance.fetch("workdir")
      end
    end
  end

  def test_gemini_adapter_uses_exact_argv_and_private_ephemeral_configuration
    with_repository(files: {"docs/spec.md" => "# Reviewed secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-gemini-bin") do |bin|
        log = File.join(bin, "gemini-calls.jsonl")
        payload = direct_role_payload
        fake = write_direct_adapter_fake(
          bin, provider: "gemini", log: log, payload: payload,
          stream: File.read(adapter_fixture("gemini", "accepted-contract.json")),
          observed_model: "gemini-model-x", observed_effort: "high"
        )
        prompt = "REVIEWED SECRET: inspect docs/spec.md"
        adapter = AdversarialReview::Adapters::Gemini.new(
          executable: fake, repository: repository, model: "gemini-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: prompt, tier: "high", timeout_seconds: 2,
          source_env: {"GEMINI_API_KEY" => "test-key", "TOP_SECRET" => "must-not-leak"}
        )

        result = adapter.execute(
          required_checks: ["assumption-coverage"],
          dispatch_capability: observed_dispatch
        )

        assert_equal "complete", result.status
        assert_equal payload, result.payload
        assert_equal 80, result.usage.fetch("total_tokens")
        assert_normalized_capabilities(result.capabilities, "gemini complete")
        records = fake_cli_records(log)
        assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
        preflight, execution = records.select { |record| record.fetch("kind") == "run" }
        refute_includes preflight.fetch("argv").join(" "), "REVIEWED SECRET"
        assert_equal false, preflight.fetch("relative_review_visible")
        assert_equal [
          "--prompt", prompt, "--model", "gemini-model-x",
          "--output-format", "json", "--sandbox"
        ], execution.fetch("argv")
        assert_equal({
          "agents" => {"active" => "adversarial-review", "ephemeral" => true},
          "model" => {"effort" => "high", "name" => "gemini-model-x"},
          "output" => {"format" => "json"},
          "sandbox" => true,
          "tools" => {"allowed" => %w[read_file search_file_content glob]},
          "workspace" => File.realpath(repository)
        }, execution.fetch("settings"))
        assert_equal({
          "description" => "Read-only adversarial review role",
          "instructions" => "Inspect repository content without modifying files or running commands.",
          "name" => "adversarial-review",
          "tools" => %w[read_file search_file_content glob]
        }, execution.fetch("agent_definition"))
        assert_equal 0o700, execution.fetch("config_mode")
        assert_equal 0o600, execution.fetch("settings_mode")
        assert_equal 0o600, execution.fetch("agent_mode")
        refute execution.fetch("env").key?("TOP_SECRET")
        assert_equal "test-key", execution.fetch("env").fetch("GEMINI_API_KEY")
        provenance = result.runtime_provenance.fetch("executions").fetch(0)
        assert_equal "gemini-cli contract-vNext", provenance.fetch("cli_version")
        assert_equal "gemini-session-2", provenance.fetch("session_id")
      end
    end
  end

  def test_cursor_and_gemini_fall_back_before_review_content_for_each_unattested_property
    cursor = accepted_direct_stream("cursor")
    gemini = accepted_direct_stream("gemini")
    cases = {
      "cursor" => {
        "fresh" => {stream: cursor.sub('"fresh":true', '"fresh":false')},
        "workspace" => {stream: cursor.sub('"workspace":"$CWD"', '"workspace":"/wrong"')},
        "mode" => {stream: cursor.sub('"mode":"ask"', '"mode":"agent"')},
        "sandbox" => {stream: cursor.sub('"sandbox":"enabled"', '"sandbox":"disabled"')},
        "read only" => {stream: cursor.sub('"read_only":true', '"read_only":false')},
        "model" => {stream: cursor, observed_model: "wrong-model"},
        "effort" => {stream: cursor, observed_effort: "low"},
        "output format" => {stream: cursor.sub('"output_format":"stream-json"', '"output_format":"text"')},
        "structured output" => {stream: cursor, payloads: [{"ok" => false}]},
        "usage" => {stream: without_usage(cursor)}
      },
      "gemini" => {
        "fresh" => {stream: gemini.sub('"fresh":true', '"fresh":false')},
        "workspace" => {stream: gemini.sub('"workspace":"$CWD"', '"workspace":"/wrong"')},
        "sandbox" => {stream: gemini.sub('"sandbox":true', '"sandbox":false')},
        "config root" => {stream: gemini.sub('"config_root":"$CONFIG_ROOT"', '"config_root":"/wrong"')},
        "ephemeral agents" => {stream: gemini.sub('"agents_ephemeral":true', '"agents_ephemeral":false')},
        "agent" => {stream: gemini.sub('"agent":"adversarial-review"', '"agent":"other"')},
        "tools" => {stream: gemini.sub('["read_file","search_file_content","glob"]', '["read_file","run_shell_command"]')},
        "model" => {stream: gemini, observed_model: "wrong-model"},
        "effort" => {stream: gemini, observed_effort: "low"},
        "output format" => {stream: gemini.sub('"output_format":"json"', '"output_format":"text"')},
        "structured output" => {stream: gemini, payloads: [{"ok" => false}]},
        "usage" => {stream: without_usage(gemini)}
      }
    }

    cases.each do |provider, provider_cases|
      provider_cases.each do |property, options|
        assert_direct_preflight_fallback(provider, property, options)
      end
    end
  end

  def test_cursor_protocol_rejects_duplicates_order_mixed_sessions_and_event_overflow
    startup, terminal = accepted_direct_stream("cursor").lines
    progress = JSON.generate("type" => "progress") + "\n"
    malformed = {
      "duplicate startup" => startup + startup + terminal,
      "duplicate terminal" => startup + terminal + terminal,
      "terminal first" => terminal + startup,
      "event after terminal" => startup + terminal + progress,
      "mixed terminal session" => startup + terminal.sub('"$SESSION_ID"', '"other-session"'),
      "event overflow" => startup + (progress * 1_025) + terminal
    }

    malformed.each do |label, stream|
      result, records = run_direct_adapter_case("cursor", stream: stream)
      assert_equal "generic", result.status, label
      assert_equal "runtime_attestation_missing", result.error_code, label
      assert_equal %w[help version run], records.map { |record| record.fetch("kind") }, label
    end
  end

  def test_cursor_terminal_requires_complete_binding_to_initialization
    accepted = accepted_direct_stream("cursor")
    malformed = {
      "missing terminal session" => accepted.sub(/,"session_id":"\$SESSION_ID"(?=,"model")/, ""),
      "missing terminal model" => accepted.sub(/,"model":"\$OBSERVED_MODEL"(?=,"effort")/, ""),
      "missing terminal effort" => accepted.sub(/,"effort":"\$OBSERVED_EFFORT"(?=,"structured_output")/, ""),
      "terminal model mismatch" => accepted.sub(
        /"model":"\$OBSERVED_MODEL"(?=,"effort":"\$OBSERVED_EFFORT","structured_output")/,
        '"model":"other-model"'
      )
    }

    malformed.each do |label, stream|
      result, records = run_direct_adapter_case("cursor", stream: stream)

      assert_equal "generic", result.status, label
      assert_equal "runtime_attestation_missing", result.error_code, label
      assert_equal %w[help version run], records.map { |record| record.fetch("kind") }, label
    end
  end

  def test_cursor_rejects_duplicate_attestation_keys_even_when_values_match
    startup, terminal = accepted_direct_stream("cursor").lines
    duplicate = startup.sub(/}\s*\z/, ',"effort":"$OBSERVED_EFFORT"}') + "\n" + terminal

    result, records = run_direct_adapter_case("cursor", stream: duplicate)

    assert_equal "generic", result.status
    assert_equal "runtime_attestation_missing", result.error_code
    assert_equal %w[help version run], records.map { |record| record.fetch("kind") }
  end

  def test_cursor_event_limit_is_checked_before_parsing_a_later_line
    adapter = AdversarialReview::Adapters::Cursor.allocate
    valid_lines = Array.new(AdversarialReview::Adapters::Cursor::MAX_EVENTS, "{}\n").join
    poison = "{this line must not be parsed}\n"

    error = assert_raises(JSON::ParserError) do
      adapter.send(
        :parse_json_line_objects, valid_lines + poison, "Cursor",
        max_objects: AdversarialReview::Adapters::Cursor::MAX_EVENTS
      )
    end

    assert_equal "Cursor event limit exceeded", error.message
  end

  def test_gemini_protocol_rejects_duplicate_keys_shape_mixed_sessions_and_output_overflow
    accepted = accepted_direct_stream("gemini")
    malformed = {
      "duplicate startup" => accepted.sub(/\A\{/, '{"startup":{},'),
      "missing startup" => accepted.sub('"type":"startup"', '"type":"other"'),
      "mixed response session" => accepted.sub(
        '"response":{"session_id":"$SESSION_ID"',
        '"response":{"session_id":"other-session"'
      ),
      "mixed stats session" => accepted.sub(
        '"stats":{"session_id":"$SESSION_ID"',
        '"stats":{"session_id":"other-session"'
      ),
      "unexpected envelope field" => accepted.sub(/}\s*\z/, ',"extra":true}'),
      "output overflow" => accepted.sub(/}\s*\z/, ",\"padding\":\"#{"x" * 1_048_576}\"}")
    }

    malformed.each do |label, stream|
      result, records = run_direct_adapter_case("gemini", stream: stream)
      assert_equal "generic", result.status, label
      assert_includes %w[runtime_attestation_missing process_output_truncated], result.error_code, label
      assert_equal %w[help version run], records.map { |record| record.fetch("kind") }, label
    end
  end

  def test_cursor_and_gemini_require_version_fixtured_effort_contracts
    {"cursor" => "cursor-agent 9.9.9", "gemini" => "gemini-cli 9.9.9"}.each do |provider, version|
      result, records = run_direct_adapter_case(provider, cli_version: version)

      assert_equal "generic", result.status, provider
      assert_equal "unsupported_version_contract", result.error_code, provider
      assert_equal %w[help version], records.map { |record| record.fetch("kind") }, provider
    end
  end

  def test_cursor_and_gemini_accept_every_version_fixtured_supported_tier
    %w[cursor gemini].each do |provider|
      {"default" => "medium", "high" => "high"}.each do |tier, effort|
        result, records = run_direct_adapter_case(
          provider, tier: tier, requested_effort: effort, observed_effort: effort
        )

        assert_equal "complete", result.status, "#{provider}: #{tier}"
        execution = records.select { |record| record.fetch("kind") == "run" }.last
        if provider == "cursor"
          assert_equal ["--effort", effort], execution.fetch("argv")[-3, 2], tier
        else
          mapped = tier == "default" ? "balanced" : "high"
          assert_equal mapped, execution.dig("settings", "model", "effort"), tier
        end
      end
    end
  end

  def test_cursor_and_gemini_reject_unfixtured_effort_for_each_supported_tier_before_run
    %w[cursor gemini].each do |provider|
      %w[default high].each do |tier|
        result, records = run_direct_adapter_case(
          provider, tier: tier, requested_effort: "arbitrary",
          observed_effort: "arbitrary"
        )

        assert_equal "generic", result.status, "#{provider}: #{tier}"
        assert_equal "unsupported_effort_contract", result.error_code, "#{provider}: #{tier}"
        assert_equal %w[help version], records.map { |record| record.fetch("kind") },
                     "#{provider}: #{tier}"
        assert_normalized_capabilities(result.capabilities, "#{provider}: #{tier}")
      end
    end
  end

  def test_cursor_and_gemini_missing_help_capabilities_do_not_execute
    {"cursor" => "-p --model", "gemini" => "--prompt --model"}.each do |provider, help|
      result, records = run_direct_adapter_case(provider, help_text: help)

      assert_equal "generic", result.status, provider
      assert_equal "capability_probe_failed", result.error_code, provider
      assert_equal ["help"], records.map { |record| record.fetch("kind") }, provider
    end
  end

  def test_cursor_falls_back_from_unqualified_agent_to_secure_cursor_agent_candidate
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-fallback") do |bin|
        log = File.join(bin, "calls.jsonl")
        accepted = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        File.rename(accepted, File.join(bin, "cursor-agent"))
        write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high", help_text: "-p --model"
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", result.status
        records = fake_cli_records(log)
        assert_equal %w[help help version run run], records.map { |record| record.fetch("kind") }
        assert_equal File.realpath(File.join(bin, "cursor-agent")),
                     result.runtime_provenance.fetch("executions").fetch(0).fetch("executable")
        attempts = result.runtime_provenance.fetch("candidate_attempts")
        assert_equal 2, attempts.length
        assert_equal ["rejected", "selected"], attempts.map { |attempt| attempt.fetch("status") }
        assert_equal "capability_probe_failed", attempts.fetch(0).fetch("error_code")
        assert_equal File.realpath(File.join(bin, "agent")), attempts.fetch(0).fetch("executable")
        assert_equal File.realpath(File.join(bin, "cursor-agent")), attempts.fetch(1).fetch("executable")
        refute_includes records.fetch(0).fetch("argv").join(" "), "REVIEWED SECRET"
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_does_not_retry_alias_after_review_content_submission
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-no-post-content-fallback") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        File.rename(alias_path, File.join(bin, "cursor-agent"))
        primary_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        klass = Class.new(AdversarialReview::Adapters::Cursor) do
          attr_reader :content_attempts

          private

          def adapter_name
            "cursor"
          end

          def run_direct(argv:, stdin_data:)
            result = super
            if argv.last == @prompt
              @content_attempts = @content_attempts.to_i + 1
              raise AdversarialReview::Runner::Error.new(
                "post_content_transport_failure", "transport failed after content submission"
              )
            end
            result
          end
        end
        adapter = klass.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", result.status
        assert_equal "runner_error", result.error_code
        assert_equal 40, result.usage.fetch("total_tokens")
        assert_equal 3, result.runner_results.length
        assert_equal 1, adapter.content_attempts
        records = fake_cli_records(log)
        assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
        assert_equal 1, records.count { |record| record.fetch("argv").include?("REVIEWED SECRET") }
        assert records.all? { |record| record.fetch("executable") == File.realpath(primary_path) }
        attempts = result.runtime_provenance.fetch("candidate_attempts")
        assert_equal 1, attempts.length
        assert_equal "selected", attempts.fetch(0).fetch("status")
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_can_reject_primary_private_preflight_then_select_alias_before_content
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-preflight-fallback") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        File.rename(alias_path, File.join(bin, "cursor-agent"))
        primary_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor").sub(
            '"read_only":true', '"read_only":false'
          ), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", result.status
        assert_equal 120, result.usage.fetch("total_tokens")
        records = fake_cli_records(log)
        assert_equal %w[help version run help version run run],
                     records.map { |record| record.fetch("kind") }
        content_records = records.select { |record| record.fetch("argv").include?("REVIEWED SECRET") }
        assert_equal 1, content_records.length
        assert_equal File.realpath(File.join(bin, "cursor-agent")),
                     content_records.fetch(0).fetch("executable")
        attempts = result.runtime_provenance.fetch("candidate_attempts")
        assert_equal ["rejected", "selected"], attempts.map { |attempt| attempt.fetch("status") }
        assert_equal File.realpath(primary_path), attempts.fetch(0).fetch("executable")
        assert_equal "capabilities_degraded", attempts.fetch(0).fetch("error_code")
        assert_equal "observed", attempts.fetch(0).dig("preflight", "status")
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_can_reject_primary_version_contract_then_select_supported_alias
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-version-fallback") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        File.rename(alias_path, File.join(bin, "cursor-agent"))
        write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high", cli_version: "cursor-agent unsupported-primary"
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", result.status
        records = fake_cli_records(log)
        assert_equal %w[help version help version run run],
                     records.map { |record| record.fetch("kind") }
        assert_equal 1, records.count { |record| record.fetch("argv").include?("REVIEWED SECRET") }
        attempts = result.runtime_provenance.fetch("candidate_attempts")
        assert_equal ["unsupported_version_contract", nil],
                     attempts.map { |attempt| attempt["error_code"] }
        assert_equal ["rejected", "selected"], attempts.map { |attempt| attempt.fetch("status") }
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_can_reject_primary_effort_contract_then_select_supported_alias
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-effort-fallback") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        File.rename(alias_path, File.join(bin, "cursor-agent"))
        write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high"
        )
        klass = Class.new(AdversarialReview::Adapters::Cursor) do
          private

          def adapter_name
            "cursor"
          end

          def version_contract_error
            return "unsupported_effort_contract" if File.basename(@pinned_executable.path) == "agent"
            super
          end
        end
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = klass.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", result.status
        assert_equal %w[help version help version run run],
                     fake_cli_records(log).map { |record| record.fetch("kind") }
        attempt_errors = result.runtime_provenance.fetch("candidate_attempts").map do |attempt|
          attempt["error_code"]
        end
        assert_equal ["unsupported_effort_contract", nil], attempt_errors
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_all_unsupported_candidates_return_bounded_generic_provenance
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-all-unsupported") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high", cli_version: "cursor-agent unsupported-alias"
        )
        File.rename(alias_path, File.join(bin, "cursor-agent"))
        write_direct_adapter_fake(
          bin, provider: "cursor", log: log, payload: direct_role_payload,
          stream: accepted_direct_stream("cursor"), observed_model: "cursor-model-x",
          observed_effort: "high", cli_version: "cursor-agent unsupported-primary"
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", result.status
        assert_equal "unsupported_version_contract", result.error_code
        assert_normalized_capabilities(result.capabilities, "all Cursor candidates unsupported")
        assert_equal %w[help version help version],
                     fake_cli_records(log).map { |record| record.fetch("kind") }
        attempts = result.runtime_provenance.fetch("candidate_attempts")
        assert_equal 2, attempts.length
        assert attempts.all? { |attempt| attempt.fetch("status") == "rejected" }
        assert attempts.all? do |attempt|
          attempt.fetch("error_code") == "unsupported_version_contract"
        end
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_candidate_failure_does_not_leak_primary_capabilities_and_next_execute_is_fresh
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-cursor-candidate-reset") do |bin|
        log = File.join(bin, "calls.jsonl")
        alias_path = write_direct_adapter_fake(
          bin, provider: "cursor", executable_name: "cursor-agent", log: log,
          payload: direct_role_payload, stream: accepted_direct_stream("cursor"),
          observed_model: "cursor-model-x", observed_effort: "high",
          help_text: "-p --model", session_ids: %w[candidate-session candidate-execution]
        )
        primary_path = write_direct_adapter_fake(
          bin, provider: "cursor", executable_name: "agent", log: log,
          payload: direct_role_payload, stream: accepted_direct_stream("cursor"),
          observed_model: "cursor-model-x", observed_effort: "high",
          payloads: [direct_role_payload],
          session_ids: %w[candidate-session candidate-execution]
        )
        original_path = ENV["PATH"]
        ENV["PATH"] = [bin, original_path].compact.join(File::PATH_SEPARATOR)
        adapter = AdversarialReview::Adapters::Cursor.new(
          executable: "agent", repository: repository, model: "cursor-model-x",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        failure = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", failure.status
        assert_equal "capability_probe_failed", failure.error_code
        assert_normalized_capabilities(failure.capabilities, "terminal candidate failure")
        assert failure.capabilities.values.all? do |declaration|
          declaration.fetch("status") == "unavailable"
        end
        assert_nil adapter.capability_probe
        assert_nil failure.runtime_provenance.fetch("preflight")
        attempts = failure.runtime_provenance.fetch("candidate_attempts")
        assert_equal 2, attempts.length
        assert_equal ["structured_output_unattested", "capability_probe_failed"],
                     attempts.map { |attempt| attempt.fetch("error_code") }
        assert_equal File.realpath(primary_path), attempts.fetch(0).fetch("executable")
        assert_equal File.realpath(alias_path), attempts.fetch(1).fetch("executable")
        assert_equal "observed", attempts.fetch(0).dig("preflight", "status")

        write_direct_adapter_fake(
          bin, provider: "cursor", executable_name: "cursor-agent", log: log,
          payload: direct_role_payload, stream: accepted_direct_stream("cursor"),
          observed_model: "cursor-model-x", observed_effort: "high",
          session_ids: %w[candidate-session candidate-execution]
        )
        success = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", success.status
        assert_equal 120, success.usage.fetch("total_tokens")
        assert_equal File.realpath(File.join(bin, "cursor-agent")),
                     adapter.capability_probe.fetch("executable")
        success_statuses = success.runtime_provenance.fetch("candidate_attempts").map do |attempt|
          attempt.fetch("status")
        end
        assert_equal ["rejected", "selected"], success_statuses
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_cursor_and_gemini_never_downgrade_ultra_to_high
    %w[cursor gemini].each do |provider|
      result, records = run_direct_adapter_case(provider, tier: "ultra")

      assert_equal "generic", result.status, provider
      assert_equal "unsupported_tier", result.error_code, provider
      assert_empty records, provider
    end
  end

  def test_cursor_and_gemini_require_caller_observed_dispatch
    %w[cursor gemini].each do |provider|
      result, records = run_direct_adapter_case(provider, dispatch_capability: nil)

      assert_equal "generic", result.status, provider
      assert_equal "capabilities_degraded", result.error_code, provider
      assert_equal "unavailable", result.capabilities.dig("parallel_dispatch", "status"), provider
      assert_equal %w[help version run], records.map { |record| record.fetch("kind") }, provider
    end
  end

  def test_codex_adapter_probes_then_runs_with_exact_argv_and_provenance
    with_repository(files: {"docs/spec.md" => "# Reviewed secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-codex-bin") do |bin|
        log = File.join(bin, "codex-calls.jsonl")
        payload = direct_role_payload
        fake = write_direct_adapter_fake(
          bin, provider: "codex", log: log, payload: payload,
          stream: File.read(adapter_fixture("codex", "accepted.jsonl")),
          observed_model: "gpt-5.6-sol", observed_effort: "xhigh"
        )
        schema = attack_role_schema
        prompt = "REVIEWED SECRET: inspect docs/spec.md"
        adapter = AdversarialReview::Adapters::Codex.new(
          executable: fake, repository: repository, model: "gpt-5.6-sol",
          effort: "xhigh", role_schema: schema, schema_name: "attack",
          prompt: prompt, tier: "high", timeout_seconds: 2,
          source_env: {"LANG" => "C", "TOP_SECRET" => "must-not-leak"}
        )

        result = adapter.execute(
          required_checks: ["assumption-coverage"],
          dispatch_capability: observed_dispatch
        )

        assert_equal "complete", result.status
        assert_normalized_capabilities(result.capabilities, "codex complete")
        assert_equal payload, result.payload
        assert_equal 114, result.usage.fetch("total_tokens")
        execution_provenance = adapter.runtime_provenance.fetch("executions").fetch(0)
        assert_equal "codex-cli contract-vNext", execution_provenance.fetch("cli_version")
        assert_equal "codex-session-2", execution_provenance.fetch("session_id")
        assert_equal File.realpath(fake), execution_provenance.fetch("executable")
        assert_equal File.realpath(repository), execution_provenance.fetch("workdir")
        assert_equal "gpt-5.6-sol", execution_provenance.fetch("observed_model")
        assert_equal "xhigh", execution_provenance.fetch("observed_effort")

        records = fake_cli_records(log)
        assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
        preflight, execution = records.select { |record| record.fetch("kind") == "run" }
        refute_includes preflight.fetch("stdin"), "REVIEWED SECRET"
        refute_equal File.realpath(repository), preflight.fetch("cwd")
        assert_equal false, preflight.fetch("relative_review_visible")
        assert_equal true, preflight.fetch("git_repository")
        refute_includes preflight.fetch("argv").join(" "), File.realpath(repository)
        assert_equal ["ok"], preflight.fetch("schema_payload").fetch("required")
        refute_equal schema, preflight.fetch("schema_payload")
        assert_equal prompt, execution.fetch("stdin")
        assert_equal schema, execution.fetch("schema_payload")
        refute execution.fetch("env").key?("TOP_SECRET")
        refute execution.fetch("env").key?("PATH")
        schema_path = execution.fetch("argv").fetch(15)
        output_path = execution.fetch("argv").fetch(17)
        assert_equal true, execution.fetch("output_preexisting")
        assert_equal 0o600, execution.fetch("output_mode")
        assert_equal [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--strict-config", "--sandbox", "read-only", "--model", "gpt-5.6-sol",
          "-c", 'model_reasoning_effort="xhigh"', "--cd", File.realpath(repository),
          "--json", "--output-schema", schema_path, "--output-last-message", output_path, "-"
        ], execution.fetch("argv")
        assert_equal 1, execution.fetch("argv").count("--output-schema")
      end
    end
  end

  def test_codex_missing_runtime_attestation_falls_back_before_review_content
    with_repository(files: {"docs/spec.md" => "# Secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-codex-bin") do |bin|
        log = File.join(bin, "codex-calls.jsonl")
        fake = write_direct_adapter_fake(
          bin, provider: "codex", log: log, payload: direct_role_payload,
          stream: File.read(adapter_fixture("codex", "missing-attestation.jsonl")),
          observed_model: "gpt-5.6-sol", observed_effort: "xhigh"
        )
        adapter = AdversarialReview::Adapters::Codex.new(
          executable: fake, repository: repository, model: "gpt-5.6-sol",
          effort: "xhigh", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(
          required_checks: ["assumption-coverage"],
          dispatch_capability: observed_dispatch
        )

        assert_equal "generic", result.status
        assert_normalized_capabilities(result.capabilities, "codex preflight fallback")
        assert_equal "runtime_attestation_missing", result.error_code
        records = fake_cli_records(log)
        assert_equal %w[help version run], records.map { |record| record.fetch("kind") }
        records.each do |record|
          refute_includes record.fetch("stdin"), "REVIEWED SECRET"
          refute_includes record.fetch("argv").join(" "), "REVIEWED SECRET"
        end
      end
    end
  end

  def test_codex_missing_help_capability_falls_back_without_execution
    with_repository(files: {"docs/spec.md" => "# Secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-codex-bin") do |bin|
        log = File.join(bin, "codex-calls.jsonl")
        fake = write_direct_adapter_fake(
          bin, provider: "codex", log: log, payload: direct_role_payload,
          stream: File.read(adapter_fixture("codex", "accepted.jsonl")),
          help_text: "Usage: codex exec --ephemeral --json\n",
          observed_model: "gpt-5.6-sol", observed_effort: "xhigh"
        )
        adapter = AdversarialReview::Adapters::Codex.new(
          executable: fake, repository: repository, model: "gpt-5.6-sol",
          effort: "xhigh", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", result.status
        assert_equal "capability_probe_failed", result.error_code
        assert_normalized_capabilities(result.capabilities, "codex help fallback")
        assert_equal ["help"], fake_cli_records(log).map { |record| record.fetch("kind") }
      end
    end
  end

  def test_claude_ultra_adapter_uses_exact_argv_and_attested_independent_vote
    with_repository(files: {"docs/spec.md" => "# Reviewed secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-claude-bin") do |bin|
        log = File.join(bin, "claude-calls.jsonl")
        payload = direct_role_payload
        fake = write_direct_adapter_fake(
          bin, provider: "claude", log: log, payload: payload,
          stream: File.read(adapter_fixture("claude", "accepted-contract.jsonl")),
          observed_model: "claude-opus-4-8", observed_effort: "high"
        )
        schema = attack_role_schema
        prompt = "REVIEWED SECRET: inspect docs/spec.md"
        adapter = AdversarialReview::Adapters::Claude.new(
          executable: fake, repository: repository, model: "claude-opus-4-8",
          effort: "high", role_schema: schema, schema_name: "attack",
          prompt: prompt, tier: "ultra", timeout_seconds: 2,
          source_env: {"LC_ALL" => "C", "TOP_SECRET" => "must-not-leak"}
        )

        result = adapter.execute(
          required_checks: ["assumption-coverage"],
          dispatch_capability: observed_dispatch
        )

        assert_equal "complete", result.status
        assert_normalized_capabilities(result.capabilities, "claude complete")
        assert_equal payload, result.payload
        assert_equal 100, result.usage.fetch("total_tokens")
        execution_provenance = adapter.runtime_provenance.fetch("executions").fetch(0)
        assert_equal "Claude Code contract-vNext", execution_provenance.fetch("cli_version")
        assert_equal true, execution_provenance.fetch("independent_vote")
        assert_equal "claude-session-2", execution_provenance.fetch("session_id")

        records = fake_cli_records(log)
        assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
        preflight, execution = records.select { |record| record.fetch("kind") == "run" }
        refute_includes preflight.fetch("argv").last, "REVIEWED SECRET"
        refute_equal File.realpath(repository), preflight.fetch("cwd")
        assert_equal false, preflight.fetch("relative_review_visible")
        assert_equal true, preflight.fetch("git_repository")
        refute_includes preflight.fetch("argv").join(" "), File.realpath(repository)
        preflight_schema = JSON.parse(preflight.fetch("argv").fetch(15))
        assert_equal ["ok"], preflight_schema.fetch("required")
        refute_equal schema, preflight_schema
        assert_equal prompt, execution.fetch("argv").last
        schema_json = JSON.generate(schema)
        assert_equal [
          "-p", "--bare", "--no-session-persistence", "--permission-mode", "plan",
          "--tools", "Read,Grep,Glob", "--model", "claude-opus-4-8", "--effort", "high",
          "--verbose", "--output-format", "stream-json", "--json-schema", schema_json, prompt
        ], execution.fetch("argv")
        assert_equal 1, execution.fetch("argv").count("--json-schema")
        assert_equal schema_json, execution.fetch("argv").fetch(15)
        assert_equal "", execution.fetch("stdin")
        refute execution.fetch("env").key?("TOP_SECRET")
      end
    end
  end

  def test_claude_ultra_without_independent_vote_attestation_falls_back_before_content
    with_repository(files: {"docs/spec.md" => "# Secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-claude-bin") do |bin|
        log = File.join(bin, "claude-calls.jsonl")
        stream = File.read(adapter_fixture("claude", "accepted-contract.jsonl")).sub(
          '"independent_vote":true', '"independent_vote":false'
        )
        fake = write_direct_adapter_fake(
          bin, provider: "claude", log: log, payload: direct_role_payload,
          stream: stream, observed_model: "claude-opus-4-8", observed_effort: "high"
        )
        adapter = AdversarialReview::Adapters::Claude.new(
          executable: fake, repository: repository, model: "claude-opus-4-8",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "ultra", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", result.status
        assert_normalized_capabilities(result.capabilities, "claude ultra fallback")
        assert_equal "independent_vote_unattested", result.error_code
        records = fake_cli_records(log)
        assert_equal %w[help version run], records.map { |record| record.fetch("kind") }
        records.each do |record|
          refute_includes record.fetch("argv").join(" "), "REVIEWED SECRET"
        end
      end
    end
  end

  def test_claude_missing_runtime_attestation_falls_back_before_review_content
    with_repository(files: {"docs/spec.md" => "# Secret\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-claude-bin") do |bin|
        log = File.join(bin, "claude-calls.jsonl")
        fake = write_direct_adapter_fake(
          bin, provider: "claude", log: log, payload: direct_role_payload,
          stream: File.read(adapter_fixture("claude", "claude-2.1.212-missing-attestation.jsonl")),
          observed_model: "claude-sonnet-4-8", observed_effort: "high",
          cli_version: "2.1.212 (Claude Code)"
        )
        adapter = AdversarialReview::Adapters::Claude.new(
          executable: fake, repository: repository, model: "claude-sonnet-4-8",
          effort: "high", role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET", tier: "high", timeout_seconds: 2
        )

        result = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "generic", result.status
        assert_normalized_capabilities(result.capabilities, "claude current fallback")
        assert_equal "runtime_selection_mismatch", result.error_code
        records = fake_cli_records(log)
        assert_equal %w[help version run], records.map { |record| record.fetch("kind") }
        records.each do |record|
          refute_includes record.fetch("argv").join(" "), "REVIEWED SECRET"
        end
      end
    end
  end

  def test_direct_adapters_fail_closed_for_each_unattested_property
    codex = File.read(adapter_fixture("codex", "accepted.jsonl"))
    claude = File.read(adapter_fixture("claude", "accepted-contract.jsonl"))
    cases = {
      "codex" => {
        "fresh missing" => {stream: codex.sub('"fresh":true,', "")},
        "fresh false" => {stream: codex.sub('"fresh":true', '"fresh":false')},
        "workdir" => {stream: codex.sub('"workdir":"$CWD"', '"workdir":"/wrong"')},
        "sandbox" => {stream: codex.sub('"sandbox":"read-only"', '"sandbox":"workspace-write"')},
        "model" => {stream: codex, observed_model: "wrong-model"},
        "effort" => {stream: codex, observed_effort: "low"},
        "structured output" => {stream: codex, payloads: [{"ok" => false}]},
        "usage" => {stream: without_usage(codex)}
      },
      "claude" => {
        "fresh missing" => {stream: claude.sub('"fresh":true,', "")},
        "fresh false" => {stream: claude.sub('"fresh":true', '"fresh":false')},
        "workdir" => {stream: claude.sub('"cwd":"$CWD"', '"cwd":"/wrong"')},
        "permission" => {stream: claude.sub('"permissionMode":"plan"', '"permissionMode":"default"')},
        "tools" => {stream: claude.sub('["Read","Grep","Glob"]', '["Read","Grep","Glob","Bash"]')},
        "model" => {stream: claude, observed_model: "wrong-model"},
        "effort" => {stream: claude, observed_effort: "low"},
        "structured output" => {stream: claude, payloads: [{"ok" => false}]},
        "usage" => {stream: without_usage(claude)},
        "ultra independence" => {
          stream: claude.sub('"independent_vote":true', '"independent_vote":false'),
          tier: "ultra"
        }
      }
    }

    cases.each do |provider, provider_cases|
      provider_cases.each do |property, options|
        assert_direct_preflight_fallback(provider, property, options)
      end
    end
  end

  def test_direct_adapter_requires_caller_observed_parallel_dispatch
    %w[codex claude cursor gemini].each do |provider|
      missing, missing_records = run_direct_adapter_case(
        provider, dispatch_capability: nil
      )
      unavailable, unavailable_records = run_direct_adapter_case(
        provider,
        dispatch_capability: observed_dispatch.merge("status" => "unavailable")
      )

      [missing, unavailable].each do |result|
        assert_equal "generic", result.status, provider
        assert_equal "capabilities_degraded", result.error_code, provider
        assert_equal "unavailable", result.capabilities.dig("parallel_dispatch", "status"), provider
        assert_equal false, result.ordinary_result, provider
      end
      assert_equal %w[help version run], missing_records.map { |entry| entry.fetch("kind") }, provider
      assert_equal %w[help version run], unavailable_records.map { |entry| entry.fetch("kind") }, provider
    end
  end

  def test_direct_adapter_accepts_a_normalized_caller_dispatch_record
    %w[codex claude cursor gemini].each do |provider|
      result, = run_direct_adapter_case(
        provider, dispatch_capability: enforced_capabilities
      )

      assert_equal "complete", result.status, provider
      assert_equal "enforced", result.capabilities.dig("parallel_dispatch", "status"), provider
    end
  end

  def test_direct_protocol_rejects_duplicates_out_of_order_and_mixed_sessions
    %w[codex claude].each do |provider|
      startup, terminal = accepted_direct_stream(provider).lines
      terminal_with_other_session = terminal.sub(/}\s*\z/, ',"session_id":"other-session"}')
      intermediate_with_other_session = JSON.generate(
        "type" => "progress", "session_id" => "other-session"
      ) + "\n"
      malformed_streams = {
        "duplicate startup" => startup + startup + terminal,
        "duplicate terminal" => startup + terminal + terminal,
        "terminal before startup" => terminal + startup,
        "event after terminal" => startup + terminal + JSON.generate("type" => "late") + "\n",
        "mixed terminal session" => startup + terminal_with_other_session + "\n",
        "mixed intermediate session" => startup + intermediate_with_other_session + terminal
      }

      malformed_streams.each do |label, stream|
        result, records = run_direct_adapter_case(provider, stream: stream)

        assert_equal "generic", result.status, "#{provider}: #{label}"
        assert_equal "runtime_attestation_missing", result.error_code, "#{provider}: #{label}"
        assert_equal %w[help version run], records.map { |entry| entry.fetch("kind") },
                     "#{provider}: #{label}"
      end
    end
  end

  def test_valid_preflight_usage_survives_attestation_failure
    %w[codex claude cursor gemini].each do |provider|
      result, = run_direct_adapter_case(
        provider, stream: accepted_direct_stream(provider), observed_model: "wrong-model"
      )

      assert_equal "generic", result.status, provider
      expected = {"codex" => 57, "claude" => 50, "cursor" => 40, "gemini" => 40}.fetch(provider)
      assert_equal expected, result.usage.fetch("total_tokens"), provider
    end
  end

  def test_preflight_execution_and_repair_usage_are_counted_once_each
    %w[codex claude cursor gemini].each do |provider|
      accepted = accepted_direct_stream(provider)
      invalid = direct_role_payload.merge("schema_version" => 2)
      result, = run_direct_adapter_case(
        provider, streams: [accepted, accepted, accepted],
        session_ids: %w[preflight execution repair],
        payloads: [{"ok" => true}, invalid, direct_role_payload]
      )

      expected = {"codex" => 171, "claude" => 150, "cursor" => 120, "gemini" => 120}.fetch(provider)
      assert_equal "complete", result.status, provider
      assert_equal expected, result.usage.fetch("total_tokens"), provider
    end
  end

  def test_codex_final_response_rejects_oversize_replacement_and_symlink
    adapter = AdversarialReview::Adapters::Codex.allocate
    Dir.mktmpdir("adversarial-review-final") do |directory|
      %w[oversize replacement symlink].each do |attack|
        path = File.join(directory, "#{attack}.json")
        identity = adapter.send(:prepare_final_response, path)
        case attack
        when "oversize"
          File.open(path, File::WRONLY | File::TRUNC) do |file|
            file.write("x" * (AdversarialReview::Adapters::Codex::MAX_FINAL_RESPONSE_BYTES + 1))
          end
        when "replacement"
          File.unlink(path)
          AdversarialReview::Runner.write_private_file(path, JSON.generate("ok" => true))
        when "symlink"
          target = File.join(directory, "target.json")
          AdversarialReview::Runner.write_private_file(target, JSON.generate("ok" => true))
          File.unlink(path)
          File.symlink(target, path)
        end

        error = assert_raises(AdversarialReview::Runner::SecurityError, attack) do
          adapter.send(:read_private_json, path, identity)
        end
        assert_includes %w[final_response_changed final_response_oversize], error.code, attack
      end
    end
  end

  def test_codex_final_response_rejects_in_place_truncation_during_read
    opened = Queue.new
    resume = Queue.new
    klass = Class.new(AdversarialReview::Adapters::Codex) do
      define_method(:initialize) { |opened_queue, resume_queue| @opened_queue = opened_queue; @resume_queue = resume_queue }
      define_method(:read_final_response_bytes) do |file|
        @opened_queue << true
        @resume_queue.pop
        super(file)
      end
      private :read_final_response_bytes
    end
    adapter = klass.new(opened, resume)

    Dir.mktmpdir("adversarial-review-final-race") do |directory|
      path = File.join(directory, "final.json")
      identity = adapter.send(:prepare_final_response, path)
      File.open(path, File::WRONLY | File::TRUNC) { |file| file.write(JSON.generate("ok" => true)) }
      reader = Thread.new do
        adapter.send(:read_private_json, path, identity)
      rescue StandardError => error
        error
      end
      opened.pop
      File.open(path, File::WRONLY | File::TRUNC) { |file| file.write(JSON.generate("no" => true)) }
      resume << true

      error = reader.value
      assert_kind_of AdversarialReview::Runner::SecurityError, error
      assert_equal "final_response_changed", error.code
    end
  end

  def test_direct_adapter_serializes_overlapping_execute_calls
    refute_includes AdversarialReview::Adapters::Base.public_instance_methods, :execute_serial
    assert_includes AdversarialReview::Adapters::Base.private_instance_methods, :execute_serial

    %w[codex claude cursor gemini].each do |provider|
      with_direct_adapter(
        provider, streams: Array.new(4, accepted_direct_stream(provider)),
        session_ids: %w[preflight-one execution-one preflight-two execution-two],
        payloads: [{"ok" => true}, direct_role_payload, {"ok" => true}, direct_role_payload],
        run_delay: 0.15
      ) do |adapter, log, _fake|
        first = Thread.new do
          adapter.execute(required_checks: ["assumption-coverage"], dispatch_capability: observed_dispatch)
        end
        wait_for_run_record(log)
        second = Thread.new do
          adapter.execute(required_checks: ["assumption-coverage"], dispatch_capability: observed_dispatch)
        end
        results = [first.value, second.value]

        assert_equal [["complete", nil], ["complete", nil]],
                     results.map { |result| [result.status, result.error_code] }, provider
        assert_equal 4, fake_cli_records(log).count { |entry| entry.fetch("kind") == "run" }, provider
      end
    end
  end

  def test_serial_early_failure_cannot_expose_prior_execution_state
    %w[codex claude cursor gemini].each do |provider|
      with_direct_adapter(provider) do |adapter, _log, fake|
        success = adapter.execute(
          required_checks: ["assumption-coverage"], dispatch_capability: observed_dispatch
        )
        File.chmod(0o600, fake)
        failure = adapter.execute(dispatch_capability: observed_dispatch)

        assert_equal "complete", success.status, provider
        assert_equal "generic", failure.status, provider
        assert_equal "runner_error", failure.error_code, provider
        provenance = failure.runtime_provenance
        assert_equal provenance, adapter.runtime_provenance, provider
        assert_nil provenance.fetch("preflight"), provider
        assert_empty provenance.fetch("executions"), provider
        assert_equal "runner_error", provenance.dig("failure", "error_code"), provider
        attempts = provenance.fetch("candidate_attempts")
        assert_equal 1, attempts.length, provider
        assert_equal "rejected", attempts.fetch(0).fetch("status"), provider
        assert_equal "runner_error", attempts.fetch(0).fetch("error_code"), provider
        assert_nil adapter.capability_probe, provider
        assert failure.capabilities.values.all? { |entry| entry.fetch("status") == "unavailable" }, provider
      end
    end
  end

  def test_direct_adapters_return_normalized_capabilities_on_version_failure
    %w[codex claude cursor gemini].each do |provider|
      result, records = run_direct_adapter_case(provider, version_text: "")

      assert_equal "generic", result.status, provider
      assert_equal "version_probe_failed", result.error_code, provider
      assert_normalized_capabilities(result.capabilities, "#{provider} version fallback")
      assert_equal %w[help version], records.map { |record| record.fetch("kind") }, provider
    end
  end

  def test_unsupported_direct_tier_returns_normalized_unavailable_capabilities
    result, records = run_direct_adapter_case("codex", tier: "ultra")

    assert_equal "generic", result.status
    assert_equal "unsupported_tier", result.error_code
    assert_normalized_capabilities(result.capabilities, "unsupported tier")
    assert result.capabilities.values.all? { |entry| entry.fetch("status") == "unavailable" }
    assert_empty records
  end

  def test_claude_current_init_shape_is_parsed_but_unreported_controls_fail_closed
    stream = File.read(
      adapter_fixture("claude", "claude-2.1.212-missing-attestation.jsonl")
    )

    assert_direct_preflight_fallback(
      "claude", "Claude Code 2.1.212 unreported effort and freshness",
      stream: stream, tier: "high", expected_error: "runtime_selection_mismatch",
      cli_version: "2.1.212 (Claude Code)"
    )
  end

  def test_claude_ultra_requires_independence_on_every_execution_attempt
    accepted = File.read(adapter_fixture("claude", "accepted-contract.jsonl"))
    execution_without_independence = accepted.sub(
      '"independent_vote":true', '"independent_vote":false'
    )
    result, records = run_direct_adapter_case(
      "claude", streams: [accepted, execution_without_independence], tier: "ultra"
    )

    assert_equal "generic", result.status
    assert_equal "independent_vote_unattested", result.error_code
    assert_equal 1, result.attempts
    assert_equal %w[help version run run], records.map { |record| record.fetch("kind") }
  end

  def test_claude_ultra_requires_independence_again_on_a_repair_attempt
    accepted = File.read(adapter_fixture("claude", "accepted-contract.jsonl"))
    repair_without_independence = accepted.sub(
      '"independent_vote":true', '"independent_vote":false'
    )
    invalid = direct_role_payload.merge("schema_version" => 2)
    result, records = run_direct_adapter_case(
      "claude", streams: [accepted, accepted, repair_without_independence],
      session_ids: %w[preflight execution repair],
      payloads: [{"ok" => true}, invalid, direct_role_payload], tier: "ultra"
    )

    assert_equal "generic", result.status
    assert_equal "independent_vote_unattested", result.error_code
    assert_equal 2, result.attempts
    assert_equal 3, records.count { |record| record.fetch("kind") == "run" }
    assert_equal 2, result.runtime_provenance.fetch("failure").fetch("attempt")
  end

  def test_direct_adapter_rejects_a_reused_execution_session
    %w[codex claude cursor gemini].each do |provider|
      stream = accepted_direct_stream(provider)
      result, = run_direct_adapter_case(
        provider, streams: [stream, stream], session_ids: %w[reused reused],
        tier: provider == "claude" ? "high" : "high"
      )

      assert_equal "generic", result.status, provider
      assert_equal "session_reused", result.error_code, provider
      assert_equal false, result.ordinary_result, provider
    end
  end

  def test_repair_attempt_must_use_a_third_fresh_session
    %w[codex claude cursor gemini].each do |provider|
      stream = accepted_direct_stream(provider)
      invalid = direct_role_payload.merge("schema_version" => 2)
      result, records = run_direct_adapter_case(
        provider, streams: [stream, stream, stream],
        session_ids: ["preflight", "execution", "execution"],
        payloads: [{"ok" => true}, invalid, direct_role_payload],
        tier: "high"
      )

      assert_equal "generic", result.status, provider
      assert_equal "session_reused", result.error_code, provider
      assert_equal 2, result.attempts, provider
      assert_equal 3, records.count { |record| record.fetch("kind") == "run" }, provider
    end
  end

  def test_failed_execution_provenance_keeps_preflight_separate_and_names_attempt
    %w[codex claude cursor gemini].each do |provider|
      accepted = accepted_direct_stream(provider)
      missing = missing_direct_stream(provider)
      result, = run_direct_adapter_case(
        provider, streams: [accepted, missing], tier: "high"
      )

      assert_equal "generic", result.status, provider
      provenance = result.runtime_provenance
      assert_equal "preflight", provenance.fetch("preflight").fetch("phase"), provider
      assert_equal "execution", provenance.fetch("failure").fetch("phase"), provider
      assert_equal 1, provenance.fetch("failure").fetch("attempt"), provider
      execution = provenance.fetch("executions").fetch(0)
      assert_equal "execution", execution.fetch("phase"), provider
      assert_equal 1, execution.fetch("attempt"), provider
      refute_equal provenance.fetch("preflight").fetch("session_id"), execution["session_id"], provider
    end
  end

  private

  def without_usage(stream)
    stream.sub(/"usage":\{[^}]*\}/, '"usage":null')
  end

  def accepted_direct_stream(provider)
    name = {
      "codex" => "accepted.jsonl",
      "claude" => "accepted-contract.jsonl",
      "cursor" => "accepted-contract.jsonl",
      "gemini" => "accepted-contract.json"
    }.fetch(provider)
    File.read(adapter_fixture(provider, name))
  end

  def missing_direct_stream(provider)
    name = {
      "codex" => "missing-attestation.jsonl",
      "claude" => "claude-2.1.212-missing-attestation.jsonl",
      "cursor" => "missing-attestation.jsonl",
      "gemini" => "missing-attestation.json"
    }.fetch(provider)
    File.read(adapter_fixture(provider, name))
  end

  def assert_direct_preflight_fallback(provider, property, options)
    arguments = options.dup
    expected_error = arguments.delete(:expected_error)
    result, records = run_direct_adapter_case(provider, **arguments)
    assert_equal "generic", result.status, "#{provider}: #{property}"
    assert_equal false, result.ordinary_result, "#{provider}: #{property}"
    assert_normalized_capabilities(result.capabilities, "#{provider}: #{property}")
    assert_equal expected_error, result.error_code, "#{provider}: #{property}" if expected_error
    assert_equal %w[help version run], records.map { |record| record.fetch("kind") },
                 "#{provider}: #{property}"
    records.each do |record|
      refute_includes record.fetch("stdin"), "REVIEWED SECRET", "#{provider}: #{property}"
      refute_includes record.fetch("argv").join(" "), "REVIEWED SECRET", "#{provider}: #{property}"
    end
  end

  def assert_normalized_capabilities(record, label)
    assert_equal AdversarialReview::Capabilities::FIELDS.sort, record.keys.sort, label
    record.each do |field, declaration|
      assert_equal %w[evidence requested source status], declaration.keys.sort,
                   "#{label}: #{field}"
      assert_includes AdversarialReview::Capabilities::STATUSES,
                      declaration.fetch("status"), "#{label}: #{field}"
      refute_empty declaration.fetch("evidence"), "#{label}: #{field}"
      refute_empty declaration.fetch("source"), "#{label}: #{field}"
    end
  end

  def run_direct_adapter_case(provider, stream: nil, streams: nil, tier: "high",
                              observed_model: nil, observed_effort: nil,
                              observed_models: nil, observed_efforts: nil,
                              session_ids: nil, payloads: nil, cli_version: nil,
                              version_text: nil, help_text: nil,
                              requested_effort: nil, dispatch_capability: :observed)
    requested_models = {
      "codex" => "gpt-5.6-sol", "claude" => "claude-opus-4-8",
      "cursor" => "cursor-model-x", "gemini" => "gemini-model-x"
    }
    requested_efforts = {
      "codex" => "xhigh", "claude" => "high", "cursor" => "high", "gemini" => "high"
    }
    requested_efforts[provider] = requested_effort if requested_effort
    classes = {
      "codex" => AdversarialReview::Adapters::Codex,
      "claude" => AdversarialReview::Adapters::Claude,
      "cursor" => AdversarialReview::Adapters::Cursor,
      "gemini" => AdversarialReview::Adapters::Gemini
    }
    selected_model = observed_model || requested_models.fetch(provider)
    selected_effort = observed_effort || requested_efforts.fetch(provider)
    selected_streams = streams || [stream || accepted_direct_stream(provider)]
    captured = nil
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-#{provider}-matrix") do |bin|
        log = File.join(bin, "calls.jsonl")
        fake = write_direct_adapter_fake(
          bin, provider: provider, log: log, payload: direct_role_payload,
          stream: selected_streams.fetch(0), streams: selected_streams,
          observed_model: selected_model, observed_effort: selected_effort,
          observed_models: observed_models, observed_efforts: observed_efforts,
          session_ids: session_ids, payloads: payloads, cli_version: cli_version,
          version_text: version_text, help_text: help_text
        )
        klass = classes.fetch(provider)
        adapter = klass.new(
          executable: fake, repository: repository, model: requested_models.fetch(provider),
          effort: requested_efforts.fetch(provider),
          role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET: inspect docs/spec.md", tier: tier,
          timeout_seconds: 2
        )
        dispatch = dispatch_capability == :observed ? observed_dispatch : dispatch_capability
        result = adapter.execute(
          required_checks: ["assumption-coverage"], dispatch_capability: dispatch
        )
        captured = [result, fake_cli_records(log), adapter]
      end
    end
    captured
  end

  def with_direct_adapter(provider, stream: nil, streams: nil, session_ids: nil,
                          payloads: nil, run_delay: 0)
    selected_streams = streams || [stream || accepted_direct_stream(provider)]
    with_repository(files: {"docs/spec.md" => "# REVIEWED SECRET\n"}) do |repository|
      Dir.mktmpdir("adversarial-review-#{provider}-instance") do |bin|
        log = File.join(bin, "calls.jsonl")
        fake = write_direct_adapter_fake(
          bin, provider: provider, log: log, payload: direct_role_payload,
          stream: selected_streams.fetch(0), streams: selected_streams,
          observed_model: {
            "codex" => "gpt-5.6-sol", "claude" => "claude-opus-4-8",
            "cursor" => "cursor-model-x", "gemini" => "gemini-model-x"
          }.fetch(provider),
          observed_effort: provider == "codex" ? "xhigh" : "high",
          session_ids: session_ids, payloads: payloads, run_delay: run_delay
        )
        klass = {
          "codex" => AdversarialReview::Adapters::Codex,
          "claude" => AdversarialReview::Adapters::Claude,
          "cursor" => AdversarialReview::Adapters::Cursor,
          "gemini" => AdversarialReview::Adapters::Gemini
        }.fetch(provider)
        adapter = klass.new(
          executable: fake, repository: repository,
          model: {
            "codex" => "gpt-5.6-sol", "claude" => "claude-opus-4-8",
            "cursor" => "cursor-model-x", "gemini" => "gemini-model-x"
          }.fetch(provider),
          effort: provider == "codex" ? "xhigh" : "high",
          role_schema: attack_role_schema, schema_name: "attack",
          prompt: "REVIEWED SECRET: inspect docs/spec.md", tier: "high",
          timeout_seconds: 2
        )
        yield adapter, log, fake
      end
    end
  end

  def wait_for_run_record(log)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.exist?(log) && fake_cli_records(log).any? { |entry| entry.fetch("kind") == "run" }
      raise "timed out waiting for fake run" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end

  def observed_dispatch
    {
      "status" => "behavioral",
      "evidence" => "caller observed concurrent isolated role scheduling",
      "source" => "test coordinator observation"
    }
  end

  def adapter_fixture(provider, name)
    File.join(__dir__, "fixtures", "adversarial-review", provider, name)
  end

  def attack_role_schema
    JSON.parse(File.read(File.join(SKILL, "assets", "schemas", "attack.json")))
  end

  def direct_role_payload
    {
      "schema_version" => 1,
      "run_id" => "20260717T120000Z-a1b2c3d4",
      "task_id" => "attack-tester-r1-a1",
      "angle" => "tester",
      "artifact_digests" => {"docs/spec.md" => "a" * 64},
      "checks_completed" => ["assumption-coverage"],
      "findings" => [],
      "metrics" => {},
      "notes" => []
    }
  end

  def write_direct_adapter_fake(directory, provider:, log:, payload:, stream:, help_text: nil,
                                observed_model:, observed_effort:, streams: nil,
                                observed_models: nil, observed_efforts: nil,
                                session_ids: nil, payloads: nil, cli_version: nil,
                                version_text: nil, run_delay: 0, run_exit_statuses: nil,
                                executable_name: nil)
    default_help = case provider
    when "codex"
      "--ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox --model --cd --json --output-schema --output-last-message"
    when "claude"
      "  -p, --print\n  --bare\n  --no-session-persistence\n  --permission-mode\n  --tools\n  --model\n  --effort\n  --verbose\n  --output-format\n  --json-schema\n"
    when "cursor"
      "-p --mode --sandbox --workspace --model --output-format --effort"
    when "gemini"
      "--prompt --model --output-format --sandbox"
    else
      raise ArgumentError, "unknown fake direct provider: #{provider}"
    end
    default_versions = {
      "codex" => "codex-cli contract-vNext",
      "claude" => "Claude Code contract-vNext",
      "cursor" => "cursor-agent contract-vNext",
      "gemini" => "gemini-cli contract-vNext"
    }
    version = cli_version || default_versions.fetch(provider)
    name = executable_name || {"codex" => "codex", "claude" => "claude",
                               "cursor" => "agent", "gemini" => "gemini"}.fetch(provider)
    body = <<~RUBY
      \#!#{RbConfig.ruby}
      require "json"
      provider = #{provider.inspect}
      log = #{log.inspect}
      role_payload = #{JSON.generate(payload).inspect}
      templates = #{(streams || [stream]).inspect}
      observed_models = #{(observed_models || [observed_model]).inspect}
      observed_efforts = #{(observed_efforts || [observed_effort]).inspect}
      configured_sessions = #{(session_ids || []).inspect}
      configured_payloads = #{(payloads || []).map { |item| JSON.generate(item) }.inspect}
      run_exit_statuses = #{(run_exit_statuses || []).inspect}
      help_text = #{(help_text || default_help).inspect}
      version_text = #{version_text.nil? ? version.inspect : version_text.inspect}
      help_call = (provider == "codex" && ARGV == ["exec", "--help"]) ||
                  (%w[claude cursor gemini].include?(provider) && ARGV == ["--help"])
      version_call = ARGV == ["--version"]
      kind = help_call ? "help" : (version_call ? "version" : "run")
      stdin_text = STDIN.read
      executable_path = File.realpath($0)
      prior_runs = if File.exist?(log)
        File.readlines(log).count do |line|
          entry = JSON.parse(line)
          entry["kind"] == "run" && entry["executable"] == executable_path
        end
      else
        0
      end
      template = templates.fetch([prior_runs, templates.length - 1].min)
      observed_model = observed_models.fetch([prior_runs, observed_models.length - 1].min)
      observed_effort = observed_efforts.fetch([prior_runs, observed_efforts.length - 1].min)
      payload = if configured_payloads.empty?
        prior_runs.zero? ? JSON.generate({"ok" => true}) : role_payload
      else
        configured_payloads.fetch([prior_runs, configured_payloads.length - 1].min)
      end
      session_id = if configured_sessions.empty?
        prefix = File.basename($0) == "cursor-agent" ? "cursor-alias" : provider
        "\#{prefix}-session-\#{prior_runs + 1}"
      else
        configured_sessions.fetch([prior_runs, configured_sessions.length - 1].min)
      end
      git_repository = system(
        "/usr/bin/git", "-C", Dir.pwd, "rev-parse", "--is-inside-work-tree",
        out: File::NULL, err: File::NULL
      )
      schema_payload = nil
      output_preexisting = nil
      output_mode = nil
      if git_repository && provider == "codex" && (schema_index = ARGV.index("--output-schema"))
        schema_payload = JSON.parse(File.read(ARGV.fetch(schema_index + 1)))
        output_index = ARGV.index("--output-last-message")
        output_path = ARGV.fetch(output_index + 1)
        output_preexisting = File.file?(output_path)
        output_mode = File.stat(output_path).mode & 0o777 if output_preexisting
        exit 79 unless output_preexisting && output_mode == 0o600
        File.open(output_path, File::WRONLY | File::TRUNC) { |file| file.write(payload) }
      end
      relative_review_contents = begin
        File.read(File.join("docs", "spec.md"))
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        nil
      end
      settings = agent_definition = nil
      config_mode = settings_mode = agent_mode = nil
      if provider == "gemini" && ENV["GEMINI_CLI_HOME"]
        config_root = ENV.fetch("GEMINI_CLI_HOME")
        settings_path = File.join(config_root, "settings.json")
        agent_path = File.join(config_root, "agents", "adversarial-review.json")
        settings = JSON.parse(File.read(settings_path)) if File.file?(settings_path)
        agent_definition = JSON.parse(File.read(agent_path)) if File.file?(agent_path)
        config_mode = File.stat(config_root).mode & 0o777
        settings_mode = File.stat(settings_path).mode & 0o777 if File.file?(settings_path)
        agent_mode = File.stat(agent_path).mode & 0o777 if File.file?(agent_path)
      end
      record = {
        "kind" => kind, "argv" => ARGV, "stdin" => stdin_text,
        "executable" => executable_path,
        "env" => ENV.to_h, "cwd" => Dir.pwd, "schema_payload" => schema_payload,
        "relative_review_visible" => !relative_review_contents.nil?,
        "git_repository" => git_repository,
        "output_preexisting" => output_preexisting, "output_mode" => output_mode,
        "settings" => settings, "agent_definition" => agent_definition,
        "config_mode" => config_mode, "settings_mode" => settings_mode,
        "agent_mode" => agent_mode
      }
      File.open(log, "a", 0o600) { |file| file.puts(JSON.generate(record)) }
      if !git_repository
        exit 78
      elsif help_call
        puts help_text
      elsif version_call
        puts version_text
      else
        sleep #{run_delay.inspect}
        exit_status = run_exit_statuses.fetch([prior_runs, run_exit_statuses.length - 1].min, 0)
        exit(exit_status) unless exit_status.zero?
        rendered = template.gsub("$CWD", Dir.pwd)
                           .gsub("$OBSERVED_MODEL", observed_model)
                           .gsub("$OBSERVED_EFFORT", observed_effort)
                           .gsub("$SESSION_ID", session_id)
                           .gsub("$CONFIG_ROOT", ENV.fetch("GEMINI_CLI_HOME", ""))
                           .gsub("$ROLE_RESPONSE", payload)
        STDOUT.write(rendered)
      end
    RUBY
    write_fake_executable(directory, name: name, body: body)
  end

  def valid_payload
    {"checks" => ["assumption-coverage"], "findings" => [{"title" => "gap"}]}
  end

  def runtime_event
    {"model" => "model-x", "effort" => "high", "terminal" => true}
  end

  def enforced_capabilities
    AdversarialReview::Capabilities::FIELDS.each_with_object({}) do |field, record|
      record[field] = {
        "status" => "enforced", "evidence" => "fake runtime attestation",
        "source" => "fake terminal event"
      }
    end
  end

  def harness_adapter(envelopes, runner_results: nil, add_capabilities: true)
    items = envelopes.map do |envelope|
      if add_capabilities && envelope.is_a?(Hash) && !envelope.key?("capabilities")
        envelope.merge("capabilities" => enforced_capabilities)
      else
        envelope
      end
    end
    klass = Class.new(AdversarialReview::Adapters::Base) do
      define_method(:initialize) do |items, results|
        super()
        @items = items
        @results = results
      end

      define_method(:invoke) do |_repair|
        if @results && !@results.empty?
          item = @results.shift
          item.is_a?(Array) ? item : [item, nil]
        else
          result = AdversarialReview::Runner::Result.new(
            stdout: "", stderr: "", exit_status: 0, duration_ms: 1,
            timed_out: false, stdout_truncated: false, stderr_truncated: false
          )
          [result, @items.shift]
        end
      end

      define_method(:valid_payload?) { |payload| payload.is_a?(Hash) && payload["checks"].is_a?(Array) }
      define_method(:adapter_name) { "codex" }
    end
    klass.new(items, runner_results && runner_results.dup)
  end
end
