require "minitest/autorun"
require "digest"
require "open3"

SKILL = File.expand_path("../skills/general/adversarial-review", __dir__) unless defined?(SKILL)
$LOAD_PATH.unshift(File.join(SKILL, "scripts", "lib"))
require "adversarial_review"
require_relative "support/adversarial_review_helper"

class AdversarialReviewManifestTest < Minitest::Test
  include AdversarialReviewHelper
  CommandStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def test_builds_a_spec_only_manifest
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      manifest = AdversarialReview::Manifest.build(
        repository: repository,
        spec: "docs/spec.md",
        tier: "default",
        mode: "critique",
        output: "chat",
        executor: "generic"
      )

      assert_equal [{"role" => "spec", "path" => "docs/spec.md"}],
                   manifest.fetch("targets").map { |target| target.slice("role", "path") }
    end
  end

  def test_plan_only_uses_the_base_task_roster
    with_repository(files: {"docs/plan.md" => "# Delivery plan\n"}) do |repository|
      manifest = build_manifest(repository, plan: "docs/plan.md")

      assert_equal base_tasks, manifest.fetch("enabled_tasks")
    end
  end

  def test_high_spec_and_plan_add_traceability_then_three_divergence_probes
    files = {
      "docs/spec.md" => "# Product spec\n",
      "docs/plan.md" => "# Delivery plan\n"
    }
    with_repository(files: files) do |repository|
      manifest = build_manifest(
        repository,
        spec: "docs/spec.md",
        plan: "docs/plan.md",
        tier: "high"
      )

      assert_equal base_tasks + %w[
        traceability divergence-probe-1 divergence-probe-2 divergence-probe-3
      ], manifest.fetch("enabled_tasks")
      assert_equal %w[spec plan], manifest.fetch("targets").map { |target| target.fetch("role") }
    end
  end

  def test_high_plan_only_skips_divergence_probes
    with_repository(files: {"docs/plan.md" => "# Plan\n"}) do |repository|
      manifest = build_manifest(repository, plan: "docs/plan.md", tier: "high")

      assert_equal base_tasks, manifest.fetch("enabled_tasks")
    end
  end

  def test_ultra_retains_the_high_spec_roster
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      manifest = build_manifest(repository, spec: "docs/spec.md", tier: "ultra")

      assert_equal base_tasks + %w[
        divergence-probe-1 divergence-probe-2 divergence-probe-3
      ], manifest.fetch("enabled_tasks")
    end
  end

  def test_persists_requested_invocation_values
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      manifest = build_manifest(
        repository,
        spec: "docs/spec.md",
        tier: "ultra",
        mode: "revise",
        output: "both",
        executor: "claude",
        model: "reviewer-model",
        effort: "high"
      )

      assert_equal 1, manifest.fetch("schema_version")
      assert_equal "ultra", manifest.fetch("tier")
      assert_equal "revise", manifest.fetch("mode")
      assert_equal "both", manifest.fetch("output")
      assert_equal "claude", manifest.fetch("requested_executor")
      assert_equal "reviewer-model", manifest.fetch("requested_model")
      assert_equal "high", manifest.fetch("requested_effort")
    end
  end

  def test_records_actual_digests_and_repository_metadata
    files = {"docs/spec.md" => "# Product spec\n"}
    with_repository(files: files, commit: true) do |repository|
      File.open(File.join(repository, "docs/spec.md"), "a") { |file| file << "dirty change\n" }
      manifest = build_manifest(repository, spec: "docs/spec.md")
      target = manifest.fetch("targets").first
      head, status = Open3.capture2e("git", "-C", repository, "rev-parse", "HEAD")
      assert status.success?

      assert_equal Digest::SHA256.file(File.join(repository, "docs/spec.md")).hexdigest,
                   target.fetch("sha256")
      assert_equal File.realpath(repository), manifest.dig("repository", "root")
      assert_equal head.strip, manifest.dig("repository", "head")
      assert_equal true, manifest.dig("repository", "dirty")
      assert manifest.dig("repository", "status").any? { |line| line.end_with?("docs/spec.md") }
    end
  end

  def test_rejects_failed_git_head_metadata
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      manifest_class = manifest_with_git_results(repository, head_success: false)

      error = assert_manifest_error("git_command_failed") do
        build_manifest_with(manifest_class, repository, spec: "docs/spec.md")
      end
      assert_equal "repository_head", error.details.fetch("context")
      assert_equal %w[rev-parse HEAD], error.details.fetch("arguments")
    end
  end

  def test_rejects_failed_git_status_metadata_instead_of_reporting_clean
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      manifest_class = manifest_with_git_results(repository, status_success: false)

      error = assert_manifest_error("git_command_failed") do
        build_manifest_with(manifest_class, repository, spec: "docs/spec.md")
      end
      assert_equal "repository_status", error.details.fetch("context")
      assert_equal ["status", "--porcelain=v1", "--untracked-files=all"],
                   error.details.fetch("arguments")
    end
  end

  def test_normalizes_a_missing_git_executable_to_a_structured_error
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      original_path = ENV["PATH"]
      ENV["PATH"] = File.join(repository, "missing-bin")

      error = assert_manifest_error("git_error") do
        build_manifest(repository, spec: "docs/spec.md")
      end

      assert_equal "git_spawn", error.details.fetch("context")
      assert_equal [
        "git", "-C", File.expand_path(repository),
        "rev-parse", "--show-toplevel"
      ], error.details.fetch("command")
      assert_equal Errno::ENOENT::Errno, error.details.fetch("errno")
    ensure
      ENV["PATH"] = original_path
    end
  end

  def test_normalizes_a_permission_denied_git_spawn_to_a_structured_error
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      spawn_failure = lambda do |*_arguments|
        raise Errno::EACCES, "Permission denied - git"
      end

      Open3.stub(:capture2e, spawn_failure) do
        error = assert_manifest_error("git_error") do
          build_manifest(repository, spec: "docs/spec.md")
        end

        assert_equal "git_spawn", error.details.fetch("context")
        assert_equal [
          "git", "-C", File.expand_path(repository),
          "rev-parse", "--show-toplevel"
        ], error.details.fetch("command")
        assert_equal Errno::EACCES::Errno, error.details.fetch("errno")
      end
    end
  end

  def test_rejects_a_target_swapped_after_canonical_resolution
    with_repository(files: {"docs/spec.md" => "# Original\n"}) do |repository|
      Dir.mktmpdir("outside-swap") do |outside|
        outside_path = File.join(outside, "replacement.md")
        File.write(outside_path, "# Replacement\n")
        swapping_manifest = Class.new(AdversarialReview::Manifest) do
          define_method(:before_target_open) do |_role, _path, absolute_path|
            File.unlink(absolute_path)
            File.symlink(outside_path, absolute_path)
          end
          private :before_target_open
        end

        error = assert_manifest_error("target_changed") do
          build_manifest_with(swapping_manifest, repository, spec: "docs/spec.md")
        end
        assert_equal "spec", error.details.fetch("role")
      end
    end
  end

  def test_assigns_well_formed_collision_resistant_run_ids
    with_repository(files: {"docs/spec.md" => "# Product spec\n"}) do |repository|
      first = build_manifest(repository, spec: "docs/spec.md").fetch("run_id")
      second = build_manifest(repository, spec: "docs/spec.md").fetch("run_id")

      assert_match(/\Aar-[0-9]{8}T[0-9]{12}Z-[a-f0-9]{8}\z/, first)
      refute_equal first, second
    end
  end

  def test_builds_a_compact_inventory_without_counting_fenced_placeholders
    document = <<~MARKDOWN
      # Product
      Introductory words.
      ## Requirements
      REQ-1: Implement `src/widget.rb`.
      TODO: assign an owner.
      ```sh
      TODO is a literal example
      bundle exec ruby test/widget_test.rb
      ```
      - [ ] TASK-2 run `bin/check --fast`
    MARKDOWN
    with_repository(files: {"docs/spec.md" => document}) do |repository|
      manifest = build_manifest(repository, spec: "docs/spec.md")
      inventory = manifest.fetch("inventory").first
      markdown = inventory.fetch("markdown")

      assert_includes markdown, "L1 Product"
      assert_includes markdown, "L3 Product > Requirements"
      assert_includes markdown, "REQ-1 (L4)"
      assert_includes markdown, "TASK-2 (L10)"
      assert_includes markdown, "`src/widget.rb`"
      assert_includes markdown, "`bin/check --fast`"
      assert_includes markdown, "`bundle exec ruby test/widget_test.rb`"
      assert_includes markdown, "- Unresolved placeholder count: 1"
      assert_equal [{"kind" => "todo", "line" => 5}],
                   inventory.fetch("unresolved_placeholders")
      assert_equal 1, inventory.fetch("placeholder_count")
      assert_equal document.lines.length, inventory.fetch("line_count")
      assert_operator inventory.fetch("word_count"), :>, 10
      refute_includes markdown, "TODO is a literal example"
    end
  end

  def test_context_paths_include_guidance_references_and_explicit_paths
    files = {
      "AGENTS.md" => "root guidance\n",
      "docs/AGENTS.md" => "docs guidance\n",
      "docs/spec.md" => "See `src/widget.rb`.\n",
      "src/widget.rb" => "class Widget; end\n",
      "notes/context.md" => "context\n"
    }
    with_repository(files: files) do |repository|
      manifest = build_manifest(
        repository,
        spec: "docs/spec.md",
        context_paths: ["notes/context.md", "src/widget.rb", "notes/context.md"]
      )

      assert_equal %w[AGENTS.md docs/AGENTS.md notes/context.md src/widget.rb],
                   manifest.fetch("context_paths")
    end
  end

  def test_context_paths_exclude_guidance_symlinks_that_escape_the_repository
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      Dir.mktmpdir("outside-guidance") do |outside|
        guidance = File.join(outside, "AGENTS.md")
        File.write(guidance, "outside guidance\n")
        File.symlink(guidance, File.join(repository, "AGENTS.md"))

        manifest = build_manifest(repository, spec: "docs/spec.md")
        assert_equal [], manifest.fetch("context_paths")
      end
    end
  end

  def test_context_paths_exclude_invalid_implicit_symlink_pointers
    with_repository(files: {"docs/spec.md" => "See `loop.md`.\n"}) do |repository|
      File.symlink("loop.md", File.join(repository, "loop.md"))
      File.symlink("AGENTS.md", File.join(repository, "AGENTS.md"))

      manifest = build_manifest(repository, spec: "docs/spec.md")
      assert_equal [], manifest.fetch("context_paths")
    end
  end

  def test_inventory_detects_supported_placeholder_forms_in_prose
    document = <<~MARKDOWN
      TODO owner
      TBD schedule
      FIXME rollback
      ??? decision
      {{OWNER}}
      [PLACEHOLDER]
      <placeholder>
      Ordinary prose about a template is resolved.
    MARKDOWN
    with_repository(files: {"docs/spec.md" => document}) do |repository|
      inventory = build_manifest(repository, spec: "docs/spec.md").fetch("inventory").first

      assert_equal %w[todo tbd fixme question template template template],
                   inventory.fetch("unresolved_placeholders").map { |item| item.fetch("kind") }
    end
  end

  def test_inventory_ignores_placeholders_in_tilde_fenced_code
    document = <<~MARKDOWN
      ~~~text
      FIXME is a literal example
      ~~~
      TBD owner
    MARKDOWN
    with_repository(files: {"docs/spec.md" => document}) do |repository|
      placeholders = build_manifest(repository, spec: "docs/spec.md")
                     .fetch("inventory").first.fetch("unresolved_placeholders")

      assert_equal [{"kind" => "tbd", "line" => 4}], placeholders
    end
  end

  def test_inventory_applies_commonmark_fence_indentation_limits
    document = <<~MARKDOWN
          ```
      TODO visible after an invalid four-space opener
          ```
         ```
      FIXME fenced
          ```
      ??? still fenced after an invalid four-space closer
      ```
      ~~~
      TBD fenced
      ~~~
      TODO genuine prose
    MARKDOWN
    with_repository(files: {"docs/spec.md" => document}) do |repository|
      placeholders = build_manifest(repository, spec: "docs/spec.md")
                     .fetch("inventory").first.fetch("unresolved_placeholders")

      assert_equal [
        {"kind" => "todo", "line" => 2},
        {"kind" => "todo", "line" => 12}
      ], placeholders
    end
  end

  def test_inventory_normalizes_large_template_placeholders_without_content_leakage
    sentinel = "DO_NOT_COPY_#{"x" * 10_000}"
    document = "{{#{sentinel}}}\n"
    with_repository(files: {"docs/spec.md" => document}) do |repository|
      inventory = build_manifest(repository, spec: "docs/spec.md").fetch("inventory").first
      rendered = inventory.inspect

      assert_equal [{"kind" => "template", "line" => 1}],
                   inventory.fetch("unresolved_placeholders")
      assert_equal 1, inventory.fetch("placeholder_count")
      assert_includes inventory.fetch("markdown"), "template (L1)"
      refute_includes rendered, sentinel
      assert_operator rendered.bytesize, :<, 1_000
    end
  end

  def test_inventory_caps_sections_and_redacts_captured_template_content
    sentinel = "DO_NOT_COPY_SECRET"
    lines = []
    100.times do |index|
      lines << "# Heading #{index} {{#{sentinel}}} #{"x" * 300}"
      lines << "REQ-#{index}: `src/file#{index}.rb`"
      lines << "TASK-#{index}: `git show #{index} {{#{sentinel}}}`"
    end
    document = lines.join("\n") + "\n"

    with_repository(files: {"docs/spec.md" => document}) do |repository|
      manifest = build_manifest(repository, spec: "docs/spec.md")
      inventory = manifest.fetch("inventory").first
      markdown = inventory.fetch("markdown")

      assert_operator markdown.length, :<=, 16_384
      refute_includes manifest.inspect, sentinel
      assert_includes markdown, "- Unresolved placeholder count: 200"
      counts = inventory.fetch("entry_counts")
      {
        "headings" => 100,
        "requirements" => 100,
        "tasks" => 100,
        "paths" => 100,
        "commands" => 100,
        "placeholders" => 200
      }.each do |section, total|
        assert_equal total, counts.fetch(section).fetch("total_count"), section
        assert_equal true, counts.fetch(section).fetch("truncated"), section
        assert_operator counts.fetch(section).fetch("retained_count"), :<, total, section
      end
      refute_includes markdown,
                      "x" * (AdversarialReview::Manifest::Inventory::MAX_ENTRY_CHARS + 1)
      assert_operator manifest.inspect.bytesize, :<, 50_000
    end
  end

  def test_starting_metrics_aggregate_target_inventory
    files = {
      "docs/spec.md" => "one two\nTODO owner\n",
      "docs/plan.md" => "three four five\n"
    }
    with_repository(files: files) do |repository|
      manifest = build_manifest(repository, spec: "docs/spec.md", plan: "docs/plan.md")

      assert_equal({
        "target_count" => 2,
        "word_count" => 7,
        "line_count" => 3,
        "unresolved_placeholder_count" => 1
      }, manifest.fetch("starting_metrics"))
    end
  end

  def test_rejects_invocations_without_a_review_target
    with_repository do |repository|
      error = assert_raises(AdversarialReview::Manifest::Error) do
        build_manifest(repository)
      end

      assert_equal "missing_target", error.code
      assert_equal "at least one of spec or plan is required", error.message
      assert_equal({}, error.details)
      assert_equal 2, error.exit_status
    end
  end

  def test_rejects_an_invalid_tier
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      error = assert_manifest_error("invalid_tier") do
        build_manifest(repository, spec: "docs/spec.md", tier: "quick")
      end

      assert_equal({"value" => "quick", "allowed" => %w[default high ultra]}, error.details)
    end
  end

  def test_rejects_an_invalid_mode
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      error = assert_manifest_error("invalid_mode") do
        build_manifest(repository, spec: "docs/spec.md", mode: "edit")
      end

      assert_equal "edit", error.details.fetch("value")
    end
  end

  def test_rejects_an_invalid_output
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      error = assert_manifest_error("invalid_output") do
        build_manifest(repository, spec: "docs/spec.md", output: "stdout")
      end

      assert_equal "stdout", error.details.fetch("value")
    end
  end

  def test_rejects_an_invalid_executor
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      error = assert_manifest_error("invalid_executor") do
        build_manifest(repository, spec: "docs/spec.md", executor: "shell")
      end

      assert_equal "shell", error.details.fetch("value")
    end
  end

  def test_ultra_rejects_non_claude_direct_executors_but_allows_portable_routes
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      %w[codex cursor gemini].each do |executor|
        error = assert_manifest_error("incompatible_options") do
          build_manifest(
            repository,
            spec: "docs/spec.md",
            tier: "ultra",
            executor: executor
          )
        end
        assert_equal({"tier" => "ultra", "executor" => executor}, error.details)
      end

      %w[claude auto generic].each do |executor|
        manifest = build_manifest(
          repository,
          spec: "docs/spec.md",
          tier: "ultra",
          executor: executor
        )
        assert_equal executor, manifest.fetch("requested_executor")
      end
    end
  end

  def test_rejects_a_missing_target_file
    with_repository do |repository|
      error = assert_manifest_error("missing_file") do
        build_manifest(repository, spec: "docs/missing.md")
      end

      assert_equal({"role" => "spec", "path" => "docs/missing.md"}, error.details)
    end
  end

  def test_rejects_a_target_outside_the_repository
    with_repository do |repository|
      Dir.mktmpdir("outside-target") do |outside|
        path = File.join(outside, "spec.md")
        File.write(path, "# Outside\n")

        error = assert_manifest_error("outside_repository") do
          build_manifest(repository, spec: path)
        end
        assert_equal "spec", error.details.fetch("role")
      end
    end
  end

  def test_rejects_a_target_symlink_that_escapes_the_repository
    with_repository do |repository|
      Dir.mktmpdir("outside-symlink-target") do |outside|
        outside_spec = File.join(outside, "spec.md")
        File.write(outside_spec, "# Outside\n")
        File.symlink(outside_spec, File.join(repository, "spec-link.md"))

        assert_manifest_error("outside_repository") do
          build_manifest(repository, spec: "spec-link.md")
        end
      end
    end
  end

  def test_normalizes_a_target_symlink_loop_to_a_structured_error
    with_repository do |repository|
      File.symlink("loop.md", File.join(repository, "loop.md"))

      error = assert_manifest_error("invalid_path") do
        build_manifest(repository, spec: "loop.md")
      end
      assert_equal "spec", error.details.fetch("role")
    end
  end

  def test_rejects_an_explicit_context_path_outside_the_repository
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      Dir.mktmpdir("outside-context") do |outside|
        context = File.join(outside, "context.md")
        File.write(context, "outside context\n")

        error = assert_manifest_error("outside_repository") do
          build_manifest(repository, spec: "docs/spec.md", context_paths: [context])
        end
        assert_equal "context", error.details.fetch("role")
      end
    end
  end

  def test_normalizes_an_explicit_context_symlink_loop_to_a_structured_error
    with_repository(files: {"docs/spec.md" => "# Spec\n"}) do |repository|
      File.symlink("context-loop.md", File.join(repository, "context-loop.md"))

      error = assert_manifest_error("invalid_path") do
        build_manifest(
          repository,
          spec: "docs/spec.md",
          context_paths: ["context-loop.md"]
        )
      end
      assert_equal "context", error.details.fetch("role")
    end
  end

  def test_rejects_one_file_assigned_to_both_roles
    with_repository(files: {"docs/review.md" => "# Review target\n"}) do |repository|
      error = assert_manifest_error("ambiguous_role") do
        build_manifest(
          repository,
          spec: "docs/review.md",
          plan: "docs/../docs/review.md"
        )
      end

      assert_equal %w[spec plan], error.details.fetch("roles")
    end
  end

  def test_rejects_distinct_paths_with_the_same_file_identity_for_both_roles
    with_repository(files: {"docs/review.md" => "# Review target\n"}) do |repository|
      source = File.join(repository, "docs/review.md")
      hard_link = File.join(repository, "docs/review-plan.md")
      File.link(source, hard_link)

      error = assert_manifest_error("ambiguous_role") do
        build_manifest(
          repository,
          spec: "docs/review.md",
          plan: "docs/review-plan.md"
        )
      end
      assert_equal %w[spec plan], error.details.fetch("roles")

      case_alias = File.join(repository, "docs/REVIEW.md")
      if File.exist?(case_alias) && File.identical?(source, case_alias)
        assert_manifest_error("ambiguous_role") do
          build_manifest(
            repository,
            spec: "docs/review.md",
            plan: "docs/REVIEW.md"
          )
        end
      end
    end
  end

  def test_rejects_an_unresolved_repository_root
    Dir.mktmpdir("not-a-repository") do |directory|
      File.write(File.join(directory, "spec.md"), "# Spec\n")

      error = assert_manifest_error("repository_root_unresolved") do
        build_manifest(directory, spec: "spec.md")
      end
      assert_equal File.expand_path(directory), error.details.fetch("repository")
      assert_equal "repository_root", error.details.fetch("context")
    end
  end

  private

  def build_manifest(repository, overrides = {})
    build_manifest_with(AdversarialReview::Manifest, repository, overrides)
  end

  def build_manifest_with(manifest_class, repository, overrides = {})
    manifest_class.build(
      **{
        repository: repository,
        tier: "default",
        mode: "critique",
        output: "chat",
        executor: "generic"
      }.merge(overrides)
    )
  end

  def base_tasks
    %w[
      implementer tester user assumptions-checker pre-mortem
      consistency-smells feasibility
    ]
  end

  def manifest_with_git_results(repository, head_success: true, status_success: true)
    success_status = CommandStatus.new(true)
    failed_status = CommandStatus.new(false)
    Class.new(AdversarialReview::Manifest) do
      define_method(:run_git) do |_directory, *arguments|
        case arguments
        when ["rev-parse", "--show-toplevel"]
          ["#{repository}\n", success_status]
        when ["rev-parse", "HEAD"]
          [head_success ? "a" * 40 : "fatal: head failed", head_success ? success_status : failed_status]
        when ["status", "--porcelain=v1", "--untracked-files=all"]
          [status_success ? "" : "fatal: status failed", status_success ? success_status : failed_status]
        else
          raise "unexpected git arguments: #{arguments.inspect}"
        end
      end
      private :run_git
    end
  end


  def assert_manifest_error(code, &block)
    error = assert_raises(AdversarialReview::Manifest::Error, &block)
    assert_equal code, error.code
    assert_equal 2, error.exit_status
    error
  end
end
