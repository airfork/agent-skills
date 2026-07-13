require "minitest/autorun"
require "yaml"

class ModelTierContractTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  EXPECTED_CODEX_MODELS = {
    "fast" => "GPT-5.6 Luna",
    "standard" => "GPT-5.6 Terra",
    "deep" => "GPT-5.6 Sol",
  }.freeze
  EXPECTED_HUMAN_ROWS = {
    "README.md" => {
      "fast" => "| `fast` | GPT-5.6 Luna | Sonnet medium | Gemini low-effort/default | Small edits, simple transforms, quick checks. |",
      "standard" => "| `standard` | GPT-5.6 Terra | Sonnet high | Gemini default | Normal skill execution and repo-aware work. |",
      "deep" => "| `deep` | GPT-5.6 Sol | Opus 4.8 high | Gemini highest available reasoning model | Broad reviews, ambiguous planning, architecture, high-risk work. |",
    },
    "CATALOG.md" => {
      "fast" => "| `fast` | GPT-5.6 Luna, Claude Sonnet medium, or Gemini low-effort/default. |",
      "standard" => "| `standard` | GPT-5.6 Terra, Claude Sonnet high, or Gemini default. |",
      "deep" => "| `deep` | GPT-5.6 Sol, Claude Opus 4.8 high, or Gemini's highest available reasoning model. |",
    },
  }.freeze
  ACTIVE_METADATA = %w[README.md CATALOG.md skills.yaml].freeze

  def read(path)
    File.read(File.join(REPO_UNDER_TEST, path))
  end

  def test_manifest_uses_the_approved_codex_model_family
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    actual = manifest.fetch("model_tiers").slice(*EXPECTED_CODEX_MODELS.keys)
      .transform_values { |tier| tier.fetch("codex") }

    assert_equal EXPECTED_CODEX_MODELS, actual
  end

  def test_human_guidance_matches_the_manifest_mapping
    EXPECTED_HUMAN_ROWS.each do |path, rows|
      text = read(path)

      rows.each_value do |row|
        assert_includes text, row, path
      end
    end
  end

  def active_codex_skill_files
    manifest = YAML.load_file(File.join(REPO_UNDER_TEST, "skills.yaml"))
    manifest.fetch("skills")
      .select { |skill| skill.dig("install", "codex", "enabled") }
      .flat_map do |skill|
        Dir.glob(File.join(REPO_UNDER_TEST, skill.fetch("path"), "**", "*"))
          .select { |path| File.file?(path) }
      end
  end

  def test_active_guidance_does_not_reference_retired_codex_models
    paths = ACTIVE_METADATA.map { |path| File.join(REPO_UNDER_TEST, path) }

    (paths + active_codex_skill_files).each do |path|
      refute_match(/GPT-5\.[45]/i, File.read(path), path)
    end
  end
end
