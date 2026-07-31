require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class SyncSkillsTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  SCRIPT = File.join(REPO_UNDER_TEST, "scripts", "sync-skills")

  def setup
    @tmpdir = Dir.mktmpdir("sync-skills-test")
    @repo = File.join(@tmpdir, "repo")
    @dest = File.join(@tmpdir, "codex-skills")
    FileUtils.mkdir_p(@repo)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def run_sync(*args)
    Open3.capture3("ruby", SCRIPT, "--repo-root", @repo, "--dest", @dest, *args)
  end

  def write_manifest(body)
    File.write(File.join(@repo, "skills.yaml"), body)
  end

  def create_skill(path, name: "active-skill")
    skill_dir = File.join(@repo, path)
    FileUtils.mkdir_p(skill_dir)
    File.write(
      File.join(skill_dir, "SKILL.md"),
      <<~MARKDOWN
        ---
        name: #{name}
        description: Test skill.
        ---

        # #{name}
      MARKDOWN
    )
  end

  def enabled_manifest(name:, path:)
    <<~YAML
      schema_version: 1
      skills:
        - name: #{name}
          path: #{path}
          status: active
          install:
            codex:
              enabled: true
              mode: symlink
    YAML
  end

  def test_dry_run_reports_link_without_creating_it
    create_skill("skills/general/active-skill")
    write_manifest(enabled_manifest(name: "active-skill", path: "skills/general/active-skill"))

    stdout, stderr, status = run_sync("--target", "codex", "--dry-run")

    assert status.success?, stderr
    assert_includes stdout, "Would link active-skill"
    refute File.exist?(File.join(@dest, "active-skill"))
  end

  def test_apply_creates_a_per_skill_symlink
    create_skill("skills/general/active-skill")
    write_manifest(enabled_manifest(name: "active-skill", path: "skills/general/active-skill"))

    stdout, stderr, status = run_sync("--target", "codex", "--apply")

    assert status.success?, stderr
    assert_includes stdout, "Linked active-skill"
    link_path = File.join(@dest, "active-skill")
    assert File.symlink?(link_path), "expected #{link_path} to be a symlink"
    assert_equal File.join(@repo, "skills/general/active-skill"), File.readlink(link_path)
  end

  def test_claude_target_uses_same_install_metadata
    create_skill("skills/general/claude-skill", name: "claude-skill")
    write_manifest(<<~YAML)
      schema_version: 1
      skills:
        - name: claude-skill
          path: skills/general/claude-skill
          status: active
          install:
            claude:
              enabled: true
              mode: symlink
    YAML

    stdout, stderr, status = run_sync("--target", "claude", "--apply")

    assert status.success?, stderr
    assert_includes stdout, "Linked claude-skill"
    link_path = File.join(@dest, "claude-skill")
    assert File.symlink?(link_path), "expected #{link_path} to be a symlink"
    assert_equal File.join(@repo, "skills/general/claude-skill"), File.readlink(link_path)
  end

  def test_gemini_target_uses_same_install_metadata
    create_skill("skills/general/gemini-skill", name: "gemini-skill")
    write_manifest(<<~YAML)
      schema_version: 1
      skills:
        - name: gemini-skill
          path: skills/general/gemini-skill
          status: active
          install:
            gemini:
              enabled: true
              mode: symlink
    YAML

    stdout, stderr, status = run_sync("--target", "gemini", "--apply")

    assert status.success?, stderr
    assert_includes stdout, "Linked gemini-skill"
    link_path = File.join(@dest, "gemini-skill")
    assert File.symlink?(link_path), "expected #{link_path} to be a symlink"
    assert_equal File.join(@repo, "skills/general/gemini-skill"), File.readlink(link_path)
  end

  def test_copilot_target_uses_same_install_metadata
    create_skill("skills/general/copilot-skill", name: "copilot-skill")
    write_manifest(<<~YAML)
      schema_version: 1
      skills:
        - name: copilot-skill
          path: skills/general/copilot-skill
          status: active
          install:
            copilot:
              enabled: true
              mode: symlink
    YAML

    stdout, stderr, status = run_sync("--target", "copilot", "--apply")

    assert status.success?, stderr
    assert_includes stdout, "Linked copilot-skill"
    link_path = File.join(@dest, "copilot-skill")
    assert File.symlink?(link_path), "expected #{link_path} to be a symlink"
    assert_equal File.join(@repo, "skills/general/copilot-skill"), File.readlink(link_path)
  end

  def test_skips_skills_without_explicit_target_install
    create_skill("skills/general/draft-skill", name: "draft-skill")
    write_manifest(<<~YAML)
      schema_version: 1
      skills:
        - name: draft-skill
          path: skills/general/draft-skill
          status: draft
          install:
            codex:
              enabled: false
              mode: symlink
    YAML

    stdout, stderr, status = run_sync("--target", "codex", "--apply")

    assert status.success?, stderr
    assert_includes stdout, "No codex skills selected for install"
    refute File.exist?(File.join(@dest, "draft-skill"))
  end

  def test_refuses_to_overwrite_unmanaged_directory_without_force
    create_skill("skills/general/active-skill")
    write_manifest(enabled_manifest(name: "active-skill", path: "skills/general/active-skill"))
    FileUtils.mkdir_p(File.join(@dest, "active-skill"))

    _stdout, stderr, status = run_sync("--target", "codex", "--apply")

    refute status.success?
    assert_includes stderr, "Refusing to overwrite unmanaged path"
  end

  def test_prune_removes_repo_managed_symlinks_when_no_skills_are_enabled
    create_skill("skills/general/old-skill", name: "old-skill")
    write_manifest(<<~YAML)
      schema_version: 1
      skills: []
    YAML
    FileUtils.mkdir_p(@dest)
    File.symlink(File.join(@repo, "skills/general/old-skill"), File.join(@dest, "old-skill"))

    stdout, stderr, status = run_sync("--target", "codex", "--apply", "--prune")

    assert status.success?, stderr
    assert_includes stdout, "Pruned old-skill"
    refute File.exist?(File.join(@dest, "old-skill"))
  end
end
