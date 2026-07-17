require "minitest/autorun"
require "json"
require "tmpdir"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"
require_relative "support/adversarial_review_helper"

class AdversarialReviewAdaptersTest < Minitest::Test
  include AdversarialReviewHelper

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
      ["codex", "default"], ["codex", "high"],
      ["cursor", "default"], ["cursor", "high"],
      ["gemini", "default"], ["gemini", "high"]
    ], contracts.map { |entry| [entry.fetch("adapter"), entry.fetch("tier")] }.sort

    contracts.each do |contract|
      exact = AdversarialReview::Adapters::Base.runtime_decision(
        adapter: contract.fetch("adapter"), tier: contract.fetch("tier"),
        requested_model: "model-x", requested_effort: "high",
        observed_model: "model-x", observed_effort: "high"
      )
      assert_equal "direct", exact.status, contract.inspect
      assert_equal true, exact.execution_allowed, contract.inspect

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

    env = klass.new.child_environment(
      source_env: source, isolated_home: "/isolated/home"
    )

    assert_equal({
      "HOME" => "/isolated/home", "LANG" => "en_US.UTF-8", "LC_ALL" => "C",
      "VENDOR_API_KEY" => "credential"
    }, env)
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
      {"payload" => valid_payload, "terminal" => nil, "usage" => {}}
    ])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "runtime_attestation_missing", result.error_code
    assert_equal 1, result.attempts
    assert_equal false, result.ordinary_result
  end

  def test_missing_capability_attestation_falls_back_without_repair
    adapter = harness_adapter([
      {"payload" => valid_payload, "terminal" => runtime_event, "usage" => {},
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
  end

  def test_runtime_model_or_effort_mismatch_falls_back_without_repair
    [["different", "high"], ["model-x", "medium"]].each do |model, effort|
      adapter = harness_adapter([
        {"payload" => valid_payload,
         "terminal" => runtime_event.merge("model" => model, "effort" => effort),
         "usage" => {}}
      ])

      result = adapter.execute_with_one_repair(
        requested_model: "model-x", requested_effort: "high",
        required_checks: ["assumption-coverage"]
      )

      assert_equal "generic", result.status
      assert_equal "runtime_selection_mismatch", result.error_code
      assert_equal 1, result.attempts
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
      "usage" => {}, "capabilities" => enforced_capabilities
    }]])

    result = adapter.execute_with_one_repair(
      requested_model: "model-x", requested_effort: "high",
      required_checks: ["assumption-coverage"]
    )

    assert_equal "generic", result.status
    assert_equal "process_output_truncated", result.error_code
    assert_equal 1, result.attempts
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

  private

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
