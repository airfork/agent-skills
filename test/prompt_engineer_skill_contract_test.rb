require "minitest/autorun"
require "psych"

class PromptEngineerSkillContractTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  SKILL_DIR = File.join(REPO, "skills", "general", "prompt-engineer")
  PACKAGE_FILES = %w[
    SKILL.md
    agents/openai.yaml
    references/evaluation.md
    references/prompt-contexts.md
  ].freeze
  DEFAULT_PROMPT = "Use $prompt-engineer to diagnose and improve this prompt with the lightest evidence-backed evaluation that can support the requested claim."

  def test_runtime_package_contract
    assert File.directory?(SKILL_DIR), "missing runtime package: #{SKILL_DIR}"

    actual_files = Dir.glob(File.join(SKILL_DIR, "**", "*"))
      .select { |path| File.file?(path) }
      .map { |path| path.delete_prefix("#{SKILL_DIR}/") }
      .sort
    assert_equal PACKAGE_FILES.sort, actual_files

    skill = File.read(File.join(SKILL_DIR, "SKILL.md"))
    frontmatter, body = skill.split("\n---\n", 2)
    assert_equal "---", frontmatter.lines.first&.strip
    metadata = Psych.safe_load(frontmatter.sub("---\n", ""), aliases: false)
    assert_equal %w[description name], metadata.keys.sort
    assert_equal "prompt-engineer", metadata.fetch("name")
    description = metadata.fetch("description").downcase
    %w[
      creating improving simplifying diagnosing comparing prompts
      prompt-bearing skills handoffs ecosystems evaluations
    ].each { |term| assert_includes description, term }
    %w[
      ordinary prose edits code runtime configuration tools data permissions
      external systems
    ].each { |term| assert_includes description, term }

    assert_operator nonblank_lines(body).length, :<=, 250
    evaluation = File.read(File.join(SKILL_DIR, "references", "evaluation.md"))
    contexts = File.read(File.join(SKILL_DIR, "references", "prompt-contexts.md"))
    assert_operator nonblank_lines(evaluation).length, :<=, 300
    assert_operator nonblank_lines(contexts).length, :<=, 300
    %w[evaluation prompt-contexts].each do |reference|
      assert_includes body, "references/#{reference}.md"
    end

    package_text = [skill, evaluation, contexts].join("\n").downcase
    refute_match(/(?:always|must|required to)\s+(?:list|name|enumerate|catalog)\b.{0,100}\b(?:technique|framework|method)/, package_text)
    refute_match(/(?:never|must not|do not)\s+(?:delete|remove|reorder|restructure)\b.{0,100}\b(?:section|structure|instruction)/, package_text)
    refute_match(/\b\d+(?:\.\d+)?\s*%|\b\d+(?:\.\d+)?\s*percent(?:age)?\b/, package_text)
    refute_match(/(?:must|always)\s+(?:use|invoke|follow)\b.{0,100}\b(?:external|browser|provider|workflow|service)/, package_text)
    assert_includes package_text, "inconclusive"
    assert_includes package_text, "non-prompt"

    openai_path = File.join(SKILL_DIR, "agents", "openai.yaml")
    openai = File.read(openai_path)
    metadata = Psych.safe_load(openai, aliases: false)
    assert_equal false, metadata.dig("policy", "allow_implicit_invocation")
    assert_equal DEFAULT_PROMPT, metadata.dig("interface", "default_prompt")
    %w[display_name short_description default_prompt].each do |key|
      assert_match(/^\s+#{key}:\s+"(?:[^"\\]|\\.)*"\s*$/, openai)
    end
    assert_match(/^policy:\n\s+allow_implicit_invocation:\s+false\s*$/m, openai)
    assert_match(/\$prompt-engineer/, openai)
  end

  private

  def nonblank_lines(text)
    text.lines.reject { |line| line.strip.empty? }
  end
end
