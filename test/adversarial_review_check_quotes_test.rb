require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AdversarialReviewCheckQuotesTest < Minitest::Test
  REPO_UNDER_TEST = File.expand_path("..", __dir__)
  SCRIPT = File.join(
    REPO_UNDER_TEST, "skills", "general", "adversarial-review", "scripts", "check-quotes"
  )
  QUOTE = "The cache is invalidated on write."

  def setup
    @tmpdir = Dir.mktmpdir("check-quotes-test")
    @repo = File.join(@tmpdir, "repo")
    FileUtils.mkdir_p(File.join(@repo, "docs"))
    write_target("docs/plan.md", "line one\n#{QUOTE}\nline three\n")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def write_target(relative, contents)
    path = File.join(@repo, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
    path
  end

  def check(candidates, repository: @repo, json: false)
    args = ["ruby", SCRIPT, "--repository", repository]
    args << "--json" if json
    args << "-"
    Open3.capture3(*args, stdin_data: JSON.generate(candidates))
  end

  def finding(path: "docs/plan.md", quote: QUOTE, **rest)
    {"path" => path, "quote" => quote, "failure" => "f", "severity" => "HIGH"}.merge(rest)
  end

  def result(angle, *findings)
    {"angle" => angle, "findings" => findings}
  end

  def test_verbatim_quote_verifies
    stdout, _stderr, status = check([result("implementer", finding)])

    assert_equal 0, status.exitstatus
    assert_includes stdout, "OK   implementer#1"
    assert_includes stdout, "1 quote(s) verified"
  end

  def test_absent_quote_fails
    absent = finding(quote: "The cache is invalidated on read.")
    stdout, _stderr, status = check([result("implementer", absent)])

    assert_equal 1, status.exitstatus
    assert_includes stdout, "quote is not present in the cited file"
  end

  # A near-miss is the failure mode this script exists to catch: a model
  # paraphrasing the document it claims to be quoting.
  def test_paraphrase_fails
    paraphrase = finding(quote: "The cache is invalidated on writes.")
    _stdout, _stderr, status = check([result("tester", paraphrase)])

    assert_equal 1, status.exitstatus
  end

  # Line endings are the only normalization; a CRLF checkout must not fail an
  # otherwise exact multi-line quote.
  def test_crlf_target_matches_lf_quote
    write_target("docs/crlf.md", "alpha\r\n#{QUOTE}\r\nbeta\r\n")
    spanning = finding(path: "docs/crlf.md", quote: "#{QUOTE}\nbeta")
    _stdout, _stderr, status = check([result("feasibility", spanning)])

    assert_equal 0, status.exitstatus
  end

  def test_path_escaping_the_repository_fails
    escape = finding(path: "../outside.md", quote: "anything")
    File.binwrite(File.join(@tmpdir, "outside.md"), "anything\n")
    stdout, _stderr, status = check([result("tester", escape)])

    assert_equal 1, status.exitstatus
    assert_includes stdout, "cited path escapes the repository"
  end

  def test_unreadable_file_fails
    stdout, _stderr, status = check([result("tester", finding(path: "docs/missing.md"))])

    assert_equal 1, status.exitstatus
    assert_includes stdout, "cited file is unreadable"
  end

  def test_finding_without_quote_fails
    stdout, _stderr, status = check([result("tester", {"path" => "docs/plan.md"})])

    assert_equal 1, status.exitstatus
    assert_includes stdout, "missing path or quote"
  end

  def test_findings_are_numbered_within_their_own_angle
    stdout, _stderr, _status = check(
      [
        result("implementer", finding, finding(quote: "nope")),
        result("tester", finding(quote: "also nope"))
      ]
    )

    assert_includes stdout, "implementer#2"
    assert_includes stdout, "tester#1"
    refute_includes stdout, "tester#3"
  end

  def test_empty_findings_verify
    _stdout, _stderr, status = check([result("feasibility")])

    assert_equal 0, status.exitstatus
  end

  def test_json_output_reports_counts_and_failures
    stdout, _stderr, status = check(
      [result("implementer", finding, finding(quote: "nope"))], json: true
    )

    assert_equal 1, status.exitstatus
    payload = JSON.parse(stdout)
    assert_equal 2, payload.fetch("checked")
    assert_equal 1, payload.fetch("verified")
    assert_equal 1, payload.fetch("failed").length
  end

  def test_single_result_object_is_accepted
    _stdout, _stderr, status = check(result("implementer", finding))

    assert_equal 0, status.exitstatus
  end

  # Usage and IO problems exit 2 so a caller can tell "the review found bad
  # quotes" from "the check never ran".
  def test_invalid_json_exits_two
    _stdout, stderr, status = Open3.capture3(
      "ruby", SCRIPT, "--repository", @repo, "-", stdin_data: "not json"
    )

    assert_equal 2, status.exitstatus
    assert_includes stderr, "not valid JSON"
  end

  def test_missing_repository_exits_two
    _stdout, stderr, status = check([result("implementer", finding)],
                                    repository: File.join(@tmpdir, "absent"))

    assert_equal 2, status.exitstatus
    assert_includes stderr, "repository is unavailable"
  end
end
