require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "support/milestone_orchestrator_state_helper"

class MilestoneOrchestratorRunScriptsTest < Minitest::Test
  include MilestoneOrchestratorStateHelper

  RUN_VERIFICATION = File.join(MilestoneOrchestratorStateHelper::SKILL_SCRIPTS, "run-verification")
  PREFLIGHT_LINT = File.join(MilestoneOrchestratorStateHelper::SKILL_SCRIPTS, "preflight-lint")


  # A bare "git" is not spawnable on every host, and these fixture calls were
  # unchecked, so the failure surfaced far away as a missing commit sha.
  def self.git_executable
    return @git_executable unless @git_executable.nil?

    extensions = ENV.fetch("PATHEXT", "").split(File::PATH_SEPARATOR)
    extensions = extensions.empty? ? [""] : extensions + [""]
    @git_executable = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map { |directory|
      next if directory.empty?

      extensions.filter_map { |extension|
        candidate = File.join(directory, "git#{extension}")
        candidate if File.file?(candidate) && File.executable?(candidate)
      }.first
    }.first || "git"
  end

  def git!(*arguments)
    output, status = Open3.capture2e(self.class.git_executable, "-C", @repo, *arguments)
    raise "git fixture failed: #{arguments.join(" ")}\n#{output}" unless status.success?

    output
  end

  def setup
    @repo = Dir.mktmpdir
    @milestone_dir = File.join(@repo, "docs", "milestones", "example")
    FileUtils.mkdir_p(@milestone_dir)
    git!("init", "-q")
    git!("-c", "user.email=t@example.com", "-c", "user.name=T",
         "commit", "-q", "--allow-empty", "-m", "init")
    @head = git!("rev-parse", "HEAD").strip
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def write_plan(commands, tasks: nil)
    tasks ||= {
      "TASK-001" => {
        "type" => "implementation", "depends_on" => [], "owned_paths" => ["lib/example.rb"],
        "acceptance_ids" => ["AC-001"], "verification_command_ids" => commands.keys
      }
    }
    plan = {
      "schema_version" => 1,
      "requirements" => {"AC-001" => {"summary" => "example"}},
      "tasks" => tasks,
      "verification_commands" => commands
    }
    path = File.join(@milestone_dir, "PLAN.md")
    File.write(path, "# Plan\n\n<!-- milestone-orchestrator-plan:v1 -->\n```json\n" \
                     "#{JSON.pretty_generate(plan)}\n```\n<!-- /milestone-orchestrator-plan -->\n")
    path
  end

  def write_spec(text = "# Spec\n\nAll decided.\n")
    File.write(File.join(@milestone_dir, "SPEC.md"), text)
  end

  def run_script(script, *args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, *args)
    [stdout, stderr, status.exitstatus]
  end

  # --- run-verification ---

  def test_passing_command_emits_digest_and_log
    plan = write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "puts 'line1'; puts 'ok'"],
                                       "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(RUN_VERIFICATION, plan, "verify-ok")
    assert_equal 0, exit_code
    digest = JSON.parse(stdout)
    assert_equal true, digest["pass"]
    assert_equal 0, digest["exit_code"]
    assert_equal @head, digest["sha"]
    assert File.file?(digest["log"])
    assert_includes File.read(digest["log"]), "ok"
    assert digest["tail"].any? { |l| l.include?("ok") }
    assert_kind_of Float, digest["load_1m"]
  end

  def test_failing_command_exits_one_with_fail_digest
    plan = write_plan({"verify-bad" => {"argv" => ["ruby", "-e", "warn 'boom'; exit 3"],
                                        "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(RUN_VERIFICATION, plan, "verify-bad")
    assert_equal 1, exit_code
    digest = JSON.parse(stdout)
    assert_equal false, digest["pass"]
    assert_equal 3, digest["exit_code"]
    assert digest["tail"].any? { |l| l.include?("boom") }
  end

  def test_timeout_kills_and_reports
    plan = write_plan({"verify-slow" => {"argv" => ["ruby", "-e", "sleep 60"],
                                         "cwd" => ".", "timeout_seconds" => 1}})
    stdout, _stderr, exit_code = run_script(RUN_VERIFICATION, plan, "verify-slow")
    assert_equal 1, exit_code
    digest = JSON.parse(stdout)
    assert_equal true, digest["timed_out"]
    assert_equal false, digest["pass"]
  end

  def test_unregistered_command_refused
    plan = write_plan({"verify-ok" => {"argv" => ["true"], "cwd" => ".", "timeout_seconds" => 60}})
    _stdout, stderr, exit_code = run_script(RUN_VERIFICATION, plan, "verify-rogue")
    assert_equal 3, exit_code
    assert_match(/not registered/i, stderr)
  end

  def test_expected_sha_mismatch_refused
    plan = write_plan({"verify-ok" => {"argv" => ["true"], "cwd" => ".", "timeout_seconds" => 60}})
    _stdout, stderr, exit_code = run_script(RUN_VERIFICATION, plan, "verify-ok",
                                            "--expected-sha", "f" * 40)
    assert_equal 4, exit_code
    assert_match(/does not match/i, stderr)
  end

  # --- preflight-lint ---

  def test_clean_artifacts_pass
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code, stdout
    assert_includes stdout, "0 error(s)"
  end

  def test_unresolved_markers_are_errors
    write_spec("# Spec\n\nTBD: decide storage.\n")
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 1, exit_code
    assert_match(/ERROR unresolved_marker SPEC\.md:3/, stdout)
  end

  def test_missing_executable_is_error
    write_spec
    write_plan({"verify-ok" => {"argv" => ["./scripts/definitely-not-here"], "cwd" => ".",
                                "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 1, exit_code
    assert_match(/ERROR missing_executable/, stdout)
  end

  def test_long_gate_warns_but_passes
    write_spec
    write_plan({"verify-gate" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".",
                                  "timeout_seconds" => 5400}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    assert_match(/WARN long_gate/, stdout)
    assert_match(/run-verification/, stdout)
  end

  def test_uncalibrated_gating_quantity_warns
    write_spec("# Spec\n\nThe shortfall ratio must be <= 0.75 across seeds.\n")
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    assert_match(/WARN uncalibrated_gate SPEC\.md/, stdout)
    assert_match(/SPEC\.md:3/, stdout)
  end

  def test_measurement_file_satisfies_gating_quantity_check
    write_spec("# Spec\n\nThe shortfall ratio must be <= 0.75 across seeds.\n")
    File.write(File.join(@milestone_dir, "MEASUREMENT.md"), "# Witness measurement\n\nobserved 0.44-0.85\n")
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    refute_match(/uncalibrated_gate/, stdout)
  end

  def test_measurement_section_satisfies_gating_quantity_check
    write_spec("# Spec\n\nRatio must be <= 0.75.\n\n## Baseline measurement\n\nobserved 0.44-0.85\n")
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    refute_match(/uncalibrated_gate/, stdout)
  end

  def test_prose_without_thresholds_does_not_warn
    write_spec("# Spec\n\nShip 3 components across 2 subsystems by the v14 promotion.\n")
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    refute_match(/uncalibrated_gate/, stdout)
  end

  def test_concurrent_tasks_sharing_owned_paths_is_error
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}},
               tasks: {
                 "TASK-001" => {
                   "type" => "implementation", "depends_on" => [], "owned_paths" => ["src/metrics/"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 },
                 "TASK-002" => {
                   "type" => "implementation", "depends_on" => [],
                   "owned_paths" => ["src/metrics/runner.cs"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 }
               })
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 1, exit_code
    assert_match(/ERROR concurrent_path_overlap tasks\.TASK-001\+TASK-002/, stdout)
    assert_match(/src\/metrics\//, stdout)
  end

  def test_dependency_ordered_tasks_may_share_owned_paths
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}},
               tasks: {
                 "TASK-001" => {
                   "type" => "implementation", "depends_on" => [], "owned_paths" => ["src/a.rb"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 },
                 "TASK-002" => {
                   "type" => "implementation", "depends_on" => ["TASK-001"], "owned_paths" => ["src/a.rb"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 }
               })
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code, stdout
    refute_match(/concurrent_path_overlap/, stdout)
  end

  def test_transitive_dependency_ordering_is_respected
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}},
               tasks: {
                 "TASK-001" => {
                   "type" => "implementation", "depends_on" => [], "owned_paths" => ["src/a.rb"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 },
                 "TASK-002" => {
                   "type" => "implementation", "depends_on" => ["TASK-001"], "owned_paths" => ["src/b.rb"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 },
                 "TASK-003" => {
                   "type" => "implementation", "depends_on" => ["TASK-002"], "owned_paths" => ["src/a.rb"],
                   "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
                 }
               })
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code, stdout
    refute_match(/concurrent_path_overlap/, stdout)
  end

  def predicate_task(predicate, owned_paths: ["src/a.rb"])
    {
      "TASK-001" => {
        "type" => "implementation", "depends_on" => [], "owned_paths" => owned_paths,
        "owned_paths_predicate" => predicate,
        "acceptance_ids" => ["AC-001"], "verification_command_ids" => ["verify-ok"]
      }
    }
  end

  def lint_with_predicate(predicate, owned_paths: ["src/a.rb"])
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}},
               tasks: predicate_task(predicate, owned_paths: owned_paths))
    run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
  end

  # Mirrors the field failure: the predicate finds files the frozen list missed.
  def test_predicate_emitting_unowned_path_is_error
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "puts 'src/a.rb'; puts 'src/forgotten.rb'"], "cwd" => "."}
    )
    assert_equal 1, exit_code
    assert_match(/ERROR predicate_uncovered_path tasks\.TASK-001\.owned_paths/, stdout)
    assert_match(/src\/forgotten\.rb/, stdout)
    refute_match(/src\/a\.rb"\]/, stdout)
  end

  def test_predicate_fully_covered_passes
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "puts 'src/a.rb'"], "cwd" => "."}
    )
    assert_equal 0, exit_code, stdout
    refute_match(/predicate/, stdout)
  end

  def test_directory_ownership_covers_emitted_files
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "puts 'src/metrics/one.cs'; puts 'src/metrics/two.cs'"], "cwd" => "."},
      owned_paths: ["src/metrics/"]
    )
    assert_equal 0, exit_code, stdout
    refute_match(/predicate/, stdout)
  end

  def test_owning_more_than_the_predicate_returns_is_fine
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "puts 'src/a.rb'"], "cwd" => "."},
      owned_paths: ["src/a.rb", "src/brand-new.rb"]
    )
    assert_equal 0, exit_code, stdout
    refute_match(/predicate/, stdout)
  end

  def test_predicate_matching_nothing_is_error
    stdout, _stderr, exit_code = lint_with_predicate({"argv" => ["ruby", "-e", "exit 1"], "cwd" => "."})
    assert_equal 1, exit_code
    assert_match(/ERROR predicate_failed/, stdout)
    assert_match(/matches nothing/, stdout)
  end

  def test_unrunnable_predicate_is_error
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["./definitely-not-here"], "cwd" => "."}
    )
    assert_equal 1, exit_code
    assert_match(/ERROR predicate_failed/, stdout)
  end

  def test_shell_string_predicate_is_rejected
    stdout, _stderr, exit_code = lint_with_predicate({"argv" => "grep -rl foo src/", "cwd" => "."})
    assert_equal 1, exit_code
    assert_match(/ERROR invalid_predicate/, stdout)
  end

  def test_predicate_cwd_escape_is_error
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "puts 'src/a.rb'"], "cwd" => "../.."}
    )
    assert_equal 1, exit_code
    assert_match(/ERROR path_escape tasks\.TASK-001\.owned_paths_predicate/, stdout)
  end

  def test_predicate_timeout_is_error
    stdout, _stderr, exit_code = lint_with_predicate(
      {"argv" => ["ruby", "-e", "sleep 30"], "cwd" => ".", "timeout_seconds" => 1}
    )
    assert_equal 1, exit_code
    assert_match(/ERROR predicate_failed/, stdout)
    assert_match(/exceeded 1s/, stdout)
  end

  def test_tasks_without_predicates_are_unaffected
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code, stdout
    refute_match(/predicate/, stdout)
  end

  def test_unowned_contract_file_warns
    File.write(File.join(@repo, "PROJECT_STATUS.md"), "status\n")
    git!("add", "PROJECT_STATUS.md")
    write_spec
    write_plan({"verify-ok" => {"argv" => ["ruby", "-e", "0"], "cwd" => ".", "timeout_seconds" => 60}})
    stdout, _stderr, exit_code = run_script(PREFLIGHT_LINT, @milestone_dir, "--repo", @repo)
    assert_equal 0, exit_code
    assert_match(/WARN unowned_contract_file PROJECT_STATUS\.md/, stdout)
  end
end
