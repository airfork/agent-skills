require "fileutils"
require "tmpdir"

module PromptEngineerTestHelper
  REPO = File.expand_path("../..", __dir__).freeze
  FIXTURES = File.join(REPO, "test", "fixtures", "prompt-engineer").freeze
  CORPUS = File.join(FIXTURES, "v1").freeze

  def fixture(path)
    File.join(FIXTURES, path)
  end

  def copy_fixture_tree
    destination = Dir.mktmpdir("prompt-engineer-fixture")
    FileUtils.cp_r(CORPUS, File.join(destination, "v1"))
    destination
  end

  def with_fixture_tree
    destination = copy_fixture_tree
    yield File.join(destination, "v1")
  ensure
    FileUtils.rm_rf(destination) if destination
  end

  def assert_contract_error(error_class, message = nil, &block)
    error = assert_raises(error_class, &block)
    assert_includes(error.message, message) if message
    error
  end
end
