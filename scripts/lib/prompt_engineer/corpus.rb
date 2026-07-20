require "digest"
require "fileutils"
require "open3"

module PromptEngineer
  module Corpus
    class Error < StandardError; end
    class LegacyLockError < Error; end

    CASE_IDS = (1..12).map { |number| format("PE-%03d", number) }.freeze
    EFFICIENCY_CASE_IDS = %w[PE-001 PE-002 PE-003 PE-005 PE-006 PE-007 PE-008 PE-010].freeze
    HOSTS = %w[codex claude].freeze
    TRIGGER_IDS = ((1..8).map { |number| format("TP-%03d", number) } + (1..8).map { |number| format("TN-%03d", number) }).freeze
    MANIFEST_KEYS = %w[schema_version corpus_version case_ids required_hosts scoring_ranges zero_tolerance_ids trigger_suite_version efficiency_case_ids tree_digest].freeze
    PUBLIC_KEYS = %w[case_id title task prompt_context public_requirements input_artifact_paths required_host_configuration allowed_tools time_budget profile primary_dimension host_coverage declared_worktree_inputs safety_classification].freeze
    PRIVATE_KEYS = %w[case_id rubric_points prohibited_behaviors zero_tolerance_gates judge_instructions].freeze
    LEGACY_LOCK_KEYS = %w[schema_version status repository commit legacy_path companion_path dependency_closure evidence].freeze
    LEGACY_EVIDENCE_KEYS = %w[status files object_ids aggregate_digest].freeze

    attr_reader :root, :manifest, :triggers, :cases, :tree_digest, :manifest_digest

    Snapshot = Struct.new(:root, :manifest, :triggers, :cases, :tree_digest)

    def self.new(root, verify_digest = true)
      snapshot = Object.new
      snapshot.extend(InstanceMethods)
      snapshot.initialize_corpus(root, verify_digest)
      snapshot
    end

    def self.load(root, verify_digest: true)
      new(root, verify_digest).load
    end

    def self.tree_digest(root)
      digest_paths(root, regular_paths(root))
    end

    def self.manifest_tree_digest(root)
      manifest_digest(root)
    end

    def self.manifest_digest(root)
      digest_paths(root, regular_paths(root)) do |relative, bytes|
        if relative == "manifest.yml"
          bytes.sub(/tree_digest: "[0-9a-f]{64}"/, 'tree_digest: "' + ("0" * 64) + '"')
        else
          bytes
        end
      end
    end

    def self.regular_paths(root)
      paths = []
      Dir.glob(File.join(root, "**", "*")).each do |path|
        next unless File.file?(path)
        raise Error, "symlink is not a corpus file: #{path}" if File.symlink?(path)

        paths << path.sub(%r{\A#{Regexp.escape(root)}/?}, "")
      end
      paths.sort_by { |path| path.b }
    end

    def self.digest_paths(root, paths)
      digest = Digest::SHA256.new
      paths.sort_by { |path| path.b }.each do |relative|
        bytes = stable_file_bytes(File.join(root, relative))
        bytes = yield(relative, bytes) if block_given?
        digest.update(relative.encode("UTF-8"))
        digest.update("\0")
        digest.update(bytes)
        digest.update("\0")
      end
      digest.hexdigest
    end

    # Path-based reads are revalidated around each read. A changed identity or
    # size makes the digest unusable instead of silently accepting a TOCTOU race.
    def self.stable_file_bytes(path)
      before = File.lstat(path)
      raise Error, "symlinked file #{path}" if before.symlink?
      bytes = File.binread(path)
      after = File.lstat(path)
      identity = [before.dev, before.ino, before.size, before.mtime, before.nlink]
      current = [after.dev, after.ino, after.size, after.mtime, after.nlink]
      raise Error, "file changed during read #{path}" unless identity == current
      bytes
    rescue Errno::ENOENT, Errno::EACCES => error
      raise Error, error.message
    end

    def self.activation_diff(left, right, path = [], output = {})
      if left.is_a?(Hash) && right.is_a?(Hash)
        (left.keys | right.keys).each do |key|
          activation_diff(left[key], right[key], path + [key], output)
        end
      elsif left.is_a?(Array) && right.is_a?(Array)
        raise Error, "activation pair array length differs at #{path.join(".")}" unless left.length == right.length
        left.each_with_index { |item, index| activation_diff(item, right[index], path + [index], output) }
      elsif left != right
        output[path] = [left, right]
      end
      output
    end

    def self.load_legacy_lock(path)
      lock = Contracts.load_yaml(path)
      validate_lock_shape(lock)
      lock
    rescue Contracts::Error => error
      raise LegacyLockError, error.message
    end

    def self.lock_for_tree(repository, commit, files)
      entries = files.map do |relative, source|
        raise LegacyLockError, "path escape" if absolute_or_escape?(relative)
        raise LegacyLockError, "missing file #{relative}" unless File.file?(source)
        {
          "path" => relative,
          "sha256" => Digest::SHA256.hexdigest(stable_file_bytes(source)),
          "mode" => (File.stat(source).mode & 0o777).to_s(8),
          "object_id" => git_object_id(source) || Digest::SHA256.hexdigest(stable_file_bytes(source))
        }
      end.sort_by { |entry| entry.fetch("path").b }
      lock = {
        "schema_version" => 1,
        "status" => "pinned",
        "repository" => repository,
        "commit" => commit,
        "legacy_path" => "skills/prompt-engineer",
        "companion_path" => "skills/scripts/skills/prompt_engineer",
        "dependency_closure" => {
          "status" => "complete",
          "reason" => "verified fixture closure",
          "paths" => entries.map { |entry| entry.fetch("path") }
        },
        "evidence" => {
          "status" => "pinned",
          "files" => entries,
          "object_ids" => entries.map { |entry| {"path" => entry.fetch("path"), "object_id" => entry.fetch("object_id")} },
          "aggregate_digest" => nil
        }
      }
      lock.fetch("evidence")["aggregate_digest"] = lock_digest(lock)
      lock
    end

    def self.verify_legacy_lock(lock, root)
      validate_lock_shape(lock)
      raise LegacyLockError, "unpinned legacy tree" unless lock.fetch("status") == "pinned"
      commit = lock.fetch("commit")
      raise LegacyLockError, "invalid commit" unless commit.is_a?(String) && commit =~ /\A[0-9a-f]{40}\z/
      raise LegacyLockError, "legacy root is not a directory" unless File.directory?(root)
      raise LegacyLockError, "legacy root is symlinked" if File.symlink?(root)

      root = File.realpath(root)
      verify_git_identity(lock, root)

      files = lock.fetch("evidence").fetch("files")
      paths = files.map { |entry| entry.fetch("path") }
      raise LegacyLockError, "duplicate locked path" unless paths.uniq.length == paths.length
      closure = lock.fetch("dependency_closure")
      raise LegacyLockError, "incomplete dependency closure" unless closure.fetch("paths").sort_by(&:b) == paths.sort_by(&:b)
      actual_files = regular_paths(root).reject { |path| path == ".git" || path.start_with?(".git/") }
      extras = actual_files - paths
      missing = paths - actual_files
      raise LegacyLockError, "extra file #{extras.first}" unless extras.empty?
      raise LegacyLockError, "missing file #{missing.first}" unless missing.empty?
      files.each do |entry|
        unless entry.keys.sort == %w[mode object_id path sha256].sort
          raise LegacyLockError, "file evidence keys are not closed"
        end
        relative = entry.fetch("path")
        raise LegacyLockError, "path escape" if absolute_or_escape?(relative)
        reject_symlink_components(root, relative)
        source = File.join(root, relative)
        raise LegacyLockError, "missing file #{relative}" unless File.file?(source)
        actual = Digest::SHA256.hexdigest(stable_file_bytes(source))
        raise LegacyLockError, "digest mismatch for #{relative}" unless actual == entry.fetch("sha256")
        mode = (File.stat(source).mode & 0o777).to_s(8)
        raise LegacyLockError, "mode mismatch for #{relative}" unless mode == entry.fetch("mode").to_s
        object_id = git_object_id(source, root) || actual
        raise LegacyLockError, "object identity mismatch for #{relative}" unless object_id == entry.fetch("object_id")
      end
      expected = lock_digest(lock)
      raise LegacyLockError, "aggregate digest mismatch" unless expected == lock.fetch("evidence").fetch("aggregate_digest")
      true
    rescue KeyError, Errno::ENOENT, Errno::EACCES => error
      raise LegacyLockError, error.message
    end

    module InstanceMethods
      attr_reader :root, :manifest, :triggers, :cases, :tree_digest

      def initialize_corpus(root, verify_digest)
        @root = File.expand_path(root)
        @verify_digest = verify_digest
      end

      def load
      raise Error, "corpus root is symlinked" if File.symlink?(@root)
      raise Error, "corpus root is not a directory" unless File.directory?(@root)
      @manifest = Contracts.load_yaml(File.join(@root, "manifest.yml"))
      validate_manifest
      @tree_digest = Corpus.tree_digest(@root)
      @manifest_digest = Corpus.manifest_digest(@root)
      if @verify_digest && @manifest.fetch("tree_digest") != @manifest_digest
        raise Error, "corpus tree digest mismatch"
      end
      @triggers = Contracts.load_yaml(File.join(@root, "triggers.yml"))
      validate_triggers
      @cases = CASE_IDS.map { |id| load_case(id) }
      self
    rescue Contracts::Error, Errno::ENOENT, Errno::EACCES => error
      raise Error, error.message
      end

      def case_ids
      manifest.fetch("case_ids")
      end

      def efficiency_case_ids
      manifest.fetch("efficiency_case_ids")
      end

      def required_hosts
      manifest.fetch("required_hosts")
      end

      def trigger_records
      triggers.fetch("positive") + triggers.fetch("negative")
      end

      def public_case(case_id)
        fetch_case(case_id).fetch("public")
      end

      def private_rubric(case_id)
        fetch_case(case_id).fetch("private")
      end

      def manifest_digest
        @manifest_digest
      end

      def activation_pair
      explicit = Contracts.load_yaml(File.join(root, "activation", "explicit", "agents", "openai.yaml"))
      implicit = Contracts.load_yaml(File.join(root, "activation", "implicit", "agents", "openai.yaml"))
      differences = Corpus.activation_diff(explicit, implicit)
      expected = [["policy", "allow_implicit_invocation"]]
      raise Error, "activation pair differs outside policy.allow_implicit_invocation" unless differences.keys == expected
      [explicit, implicit]
      end

      def fetch_case(case_id)
        index = CASE_IDS.index(case_id)
        raise Error, "unknown case #{case_id}" unless index

        cases.fetch(index)
      end

      private

      def validate_manifest
      raise Error, "manifest keys are not closed" unless manifest.keys.sort == MANIFEST_KEYS.sort
      raise Error, "unsupported corpus schema" unless manifest.fetch("schema_version") == 1
      raise Error, "unsupported corpus version" unless manifest.fetch("corpus_version") == "v1"
      raise Error, "case IDs are not frozen" unless manifest.fetch("case_ids") == CASE_IDS
      raise Error, "hosts are not frozen" unless manifest.fetch("required_hosts") == HOSTS
      raise Error, "efficiency IDs are not frozen" unless manifest.fetch("efficiency_case_ids") == EFFICIENCY_CASE_IDS
      digest = manifest.fetch("tree_digest")
      raise Error, "tree digest is not hexadecimal" unless digest.is_a?(String) && digest =~ /\A[0-9a-f]{64}\z/
      end

      def validate_triggers
      expected_keys = %w[schema_version trigger_suite_version positive negative]
      raise Error, "trigger keys are not closed" unless triggers.keys.sort == expected_keys.sort
      raise Error, "unsupported trigger schema" unless triggers.fetch("schema_version") == 1
      raise Error, "unsupported trigger suite" unless triggers.fetch("trigger_suite_version") == "v1"
      positive = triggers.fetch("positive")
      negative = triggers.fetch("negative")
      raise Error, "trigger counts are not frozen" unless positive.length == 8 && negative.length == 8
      records = positive + negative
      raise Error, "trigger IDs are not frozen" unless records.map { |record| record.fetch("id") } == TRIGGER_IDS
      records.each_with_index do |record, index|
        raise Error, "trigger record keys are not closed" unless record.keys.sort == %w[expected_activation id prompt].sort
        expected = index < 8
        raise Error, "trigger activation mismatch" unless record.fetch("expected_activation") == expected
      end
      end

      def load_case(id)
      directory = File.join(root, "cases", id)
      public = Contracts.load_yaml(File.join(directory, "public.yml"))
      private_rubric = Contracts.load_yaml(File.join(directory, "private.yml"))
      raise Error, "public keys are not closed for #{id}" unless public.keys.sort == PUBLIC_KEYS.sort
      raise Error, "private keys are not closed for #{id}" unless private_rubric.keys.sort == PRIVATE_KEYS.sort
      raise Error, "public case ID mismatch for #{id}" unless public.fetch("case_id") == id
      raise Error, "private case ID mismatch for #{id}" unless private_rubric.fetch("case_id") == id
      validate_artifacts(id, public.fetch("input_artifact_paths"))
      {"public" => public, "private" => private_rubric}
    rescue Contracts::Error, Errno::ENOENT, Errno::EACCES => error
      raise Error, "#{id}: #{error.message}"
      end

      def validate_artifacts(id, paths)
      raise Error, "artifact paths must be relative" unless paths.is_a?(Array)
      paths.each do |relative|
        raise Error, "artifact path escape for #{id}" if Corpus.send(:absolute_or_escape?, relative)
        absolute = File.expand_path(File.join(root, "cases", id, relative))
        case_root = File.expand_path(File.join(root, "cases", id))
        raise Error, "artifact path escape for #{id}" unless absolute == case_root || absolute.start_with?(case_root + File::SEPARATOR)
        Corpus.send(:reject_symlink_components, root, File.join("cases", id, relative))
        raise Error, "missing artifact #{relative} for #{id}" unless File.file?(absolute)
        raise Error, "artifact symlink for #{id}" if File.symlink?(absolute)
      end
      end
    end

    def self.validate_lock_shape(lock)
      raise LegacyLockError, "legacy lock must be an object" unless lock.is_a?(Hash)
      raise LegacyLockError, "legacy lock keys are not closed" unless lock.keys.sort == LEGACY_LOCK_KEYS.sort
      raise LegacyLockError, "unsupported legacy lock schema" unless lock.fetch("schema_version") == 1
      raise LegacyLockError, "legacy lock status is invalid" unless %w[blocked pinned].include?(lock.fetch("status"))
      closure = lock.fetch("dependency_closure")
      raise LegacyLockError, "dependency closure keys are not closed" unless closure.is_a?(Hash) && closure.keys.sort == %w[paths reason status].sort
      raise LegacyLockError, "dependency closure status is invalid" unless %w[blocked complete].include?(closure.fetch("status"))
      raise LegacyLockError, "dependency closure reason is required" unless closure.fetch("reason").is_a?(String) && !closure.fetch("reason").empty?
      raise LegacyLockError, "dependency closure paths must be an array" unless closure.fetch("paths").is_a?(Array)
      evidence = lock.fetch("evidence")
      raise LegacyLockError, "legacy evidence keys are not closed" unless evidence.is_a?(Hash) && evidence.keys.sort == LEGACY_EVIDENCE_KEYS.sort
      raise LegacyLockError, "legacy evidence files must be an array" unless evidence.fetch("files").is_a?(Array)
      raise LegacyLockError, "legacy evidence object IDs must be an array" unless evidence.fetch("object_ids").is_a?(Array)
      if lock.fetch("status") == "blocked"
        raise LegacyLockError, "blocked closure must be blocked" unless closure.fetch("status") == "blocked"
        unless evidence == {"status" => "absent", "files" => [], "object_ids" => [], "aggregate_digest" => nil}
          raise LegacyLockError, "blocked lock evidence must be explicitly empty"
        end
      else
        raise LegacyLockError, "pinned closure must be complete" unless closure.fetch("status") == "complete"
        raise LegacyLockError, "pinned evidence must have a digest" unless evidence.fetch("status") == "pinned" && evidence.fetch("aggregate_digest").is_a?(String)
      end
      true
    end

    def self.lock_digest(lock)
      copy = Marshal.load(Marshal.dump(lock))
      copy.fetch("evidence")["aggregate_digest"] = nil
      Canonical.digest(copy).strip
    end

    def self.verify_git_identity(lock, root)
      git_directory = File.join(root, ".git")
      raise LegacyLockError, "repository identity unavailable" unless File.directory?(git_directory)

      actual_commit = git_output(root, "rev-parse", "HEAD")
      raise LegacyLockError, "commit identity mismatch" unless actual_commit == lock.fetch("commit")
      repository = lock.fetch("repository")
      return true if repository.start_with?("fixture://")

      actual_repository = git_output(root, "remote", "get-url", "origin")
      raise LegacyLockError, "repository identity mismatch" unless actual_repository == repository
      true
    rescue Errno::ENOENT
      raise LegacyLockError, "repository identity unavailable"
    end

    def self.git_output(root, *arguments)
      output, _error, status = Open3.capture3("git", "-C", root, *arguments)
      raise LegacyLockError, "repository identity unavailable" unless status.success?

      output.strip
    end

    def self.git_object_id(path, root = nil)
      root ||= find_git_root(File.dirname(path))
      return nil unless root
      output, _error, status = Open3.capture3("git", "-C", root, "hash-object", "--no-filters", path)
      status.success? ? output.strip : nil
    end

    def self.find_git_root(path)
      current = File.realpath(path)
      loop do
        return current if File.directory?(File.join(current, ".git"))
        parent = File.dirname(current)
        return nil if parent == current
        current = parent
      end
    rescue Errno::ENOENT
      nil
    end

    def self.absolute_or_escape?(path)
      path.to_s.start_with?("/") || path.to_s.split("/").include?("..")
    end
    private_class_method :absolute_or_escape?

    def self.reject_symlink_components(root, relative)
      current = File.expand_path(root)
      raise Error, "symlinked artifact ancestor #{root}" if File.symlink?(current)
      relative.to_s.split("/").each do |component|
        next if component == "." || component.empty?
        raise Error, "artifact path escape" if component == ".."
        current = File.join(current, component)
        begin
          raise Error, "symlinked artifact ancestor #{current}" if File.symlink?(current)
        rescue Errno::ENOENT
          break
        end
      end
    end
    private_class_method :reject_symlink_components

    def absolute_or_escape?(path)
      self.class.send(:absolute_or_escape?, path)
    end
  end
end
