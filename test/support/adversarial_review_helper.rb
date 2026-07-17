require "fileutils"
require "tmpdir"

module AdversarialReviewHelper
  def with_repository(files: {}, commit: false)
    Dir.mktmpdir("adversarial-review-test") do |repository|
      git(repository, "init", "--quiet")
      git(repository, "config", "user.name", "Test User")
      git(repository, "config", "user.email", "test@example.invalid")

      files.each do |path, contents|
        absolute = File.join(repository, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, contents)
      end

      if commit
        git(repository, "add", ".")
        git(repository, "commit", "--quiet", "-m", "fixture")
      end

      yield repository
    end
  end

  private

  def git(repository, *arguments)
    success = system("git", "-C", repository, *arguments,
                     out: File::NULL, err: File::NULL)
    raise "git fixture command failed: #{arguments.join(" ")}" unless success
  end
end
