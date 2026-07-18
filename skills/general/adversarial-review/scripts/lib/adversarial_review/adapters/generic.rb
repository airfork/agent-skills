require "digest"

module AdversarialReview
  module Adapters
    class Generic
      TASK_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/.freeze

      class Error < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      def run(task, run_dir)
        state = State.load(run_dir)
        task_path = state.create_task_bundle(task.fetch("task_id")) do |manifest, state_data|
          current_digests = state_data.fetch("current_target_digests")
          canonical_task = validate_task!(task, manifest, state_data)
          live_digests = live_target_digests(manifest)
          unless live_digests == current_digests &&
                 task.fetch("artifact_digests") == current_digests
            raise Error.new(
              "target_digest_mismatch",
              "live target digests do not match the authoritative run snapshot"
            )
          end
          canonical_task
        end
        {
          "status" => "awaiting-results",
          "task_path" => task_path,
          "dispatch" => {
            "cwd" => task.fetch("repository_root"),
            "schema_path" => task.fetch("schema_path"),
            "schema_sha256" => task.fetch("schema_sha256")
          },
          "capability_declaration_template" => task.fetch("capability_declaration_template"),
          "next_action" => "Return a schema-shaped result and parent capability declaration."
        }
      rescue State::Error => error
        code = case error.code
               when "unsafe_path" then "unsafe_task_path"
               else error.code
               end
        raise Error.new(code, error.message)
      end

      def ingest_capability_declaration(declaration, task, run_dir)
        unless task.is_a?(Hash) && task["task_id"].is_a?(String)
          raise Error.new("invalid_task", "capability declaration task identity is invalid")
        end
        state = State.load(run_dir)
        state.read_task_bundle(task.fetch("task_id")) do |manifest, state_data, emitted|
          current_digests = state_data.fetch("current_target_digests")
          validate_task!(emitted, manifest, state_data)
          unless emitted == task && live_target_digests(manifest) == current_digests &&
                 emitted.fetch("artifact_digests") == current_digests
            raise Error.new("invalid_task", "capability declaration task is not authoritative")
          end
          template = emitted.fetch("capability_declaration_template")
          normalized = Capabilities.normalize(
            declaration,
            requested_model: template.fetch("model_selection").fetch("requested"),
            requested_effort: template.fetch("effort_selection").fetch("requested")
          )
          Capabilities.gate(normalized, "PASS").merge("capabilities" => normalized)
        end
      rescue KeyError => error
        raise Error.new("invalid_task", "capability template is missing #{error.key.inspect}")
      rescue State::Error => error
        raise Error.new("invalid_task", error.message)
      end

      private

      def validate_task!(task, manifest, state_data)
        unless task.is_a?(Hash)
          raise Error.new("invalid_task", "task bundle must be an object")
        end
        unless task.fetch("schema_version") == 1 &&
               task.fetch("run_id") == manifest.fetch("run_id")
          raise Error.new("invalid_task_identity", "task identity does not match the run")
        end
        task_id = task.fetch("task_id")
        unless task_id.is_a?(String) && task_id.match?(TASK_ID)
          raise Error.new("invalid_task_id", "task ID contains unsafe characters")
        end
        round = task.fetch("round")
        attempt = task.fetch("attempt")
        unless round.is_a?(Integer) && round.positive? &&
               attempt.is_a?(Integer) && attempt.positive?
          raise Error.new("invalid_task_identity", "task fields do not form its canonical identity")
        end
        schema = task.fetch("schema")
        skill_root = File.realpath(AdversarialReview.root)
        schema_path = File.realpath(File.join(skill_root, schema))
        declared_schema_path = task.fetch("schema_path")
        unless File.file?(schema_path) && schema_path.start_with?(skill_root + File::SEPARATOR) &&
               declared_schema_path == schema_path && File.realpath(declared_schema_path) == schema_path &&
               task.fetch("schema_sha256") == Digest::SHA256.file(schema_path).hexdigest
          raise Error.new("invalid_task_schema", "task schema path is unavailable")
        end
        repository_root = manifest.fetch("repository").fetch("root")
        unless task.fetch("repository_root") == repository_root &&
               File.realpath(task.fetch("repository_root")) == repository_root
          raise Error.new("invalid_task", "task repository root is not authoritative")
        end
        checks = task.fetch("required_checks")
        unless checks.is_a?(Array) && checks.uniq.length == checks.length &&
               checks.all? { |check| check.is_a?(String) && !check.empty? }
          raise Error.new("invalid_task", "task required checks are malformed")
        end
        targets = task.fetch("targets")
        digests = task.fetch("artifact_digests")
        unless targets.is_a?(Array) && !targets.empty? && digests.is_a?(Hash)
          raise Error.new("invalid_task_digests", "task targets and digests are malformed")
        end
        expected_digests = targets.each_with_object({}) do |target, result|
          unless target.is_a?(Hash) && target.keys.sort == %w[path role sha256] &&
                 %w[spec plan].include?(target.fetch("role")) &&
                 safe_relative_path?(target.fetch("path")) &&
                 target.fetch("sha256").is_a?(String) &&
                 target.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
            raise Error.new("invalid_task_digests", "task target record is malformed")
          end
          result[target.fetch("path")] = target.fetch("sha256")
        end
        unless expected_digests.length == targets.length && expected_digests == digests
          raise Error.new("invalid_task_digests", "task artifact digests do not match targets")
        end
        expected_task = Prompts.canonical_task(manifest, state_data, task)
        unless task == expected_task
          raise Error.new("invalid_task", "task does not match the authoritative run manifest")
        end
        expected_task
      rescue KeyError => error
        raise Error.new("invalid_task", "task is missing #{error.key.inspect}")
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, Errno::EACCES, Errno::EPERM
        raise Error.new("invalid_task_schema", "task handoff path is unavailable")
      rescue Prompts::Error => error
        raise Error.new("invalid_task", "authoritative task could not be rebuilt: #{error.message}")
      end

      def live_target_digests(manifest)
        root = manifest.fetch("repository").fetch("root")
        canonical_root = File.realpath(root)
        unless canonical_root == root && File.directory?(canonical_root)
          raise Error.new("target_digest_mismatch", "authoritative repository root is invalid")
        end
        manifest.fetch("targets").each_with_object({}) do |target, digests|
          path = target.fetch("path")
          unless safe_relative_path?(path)
            raise Error.new("target_digest_mismatch", "authoritative target path is invalid")
          end
          absolute = File.expand_path(path, canonical_root)
          unless absolute.start_with?(canonical_root + File::SEPARATOR) &&
                 File.realpath(absolute) == absolute
            raise Error.new("target_digest_mismatch", "authoritative target escapes repository")
          end
          expected = File.lstat(absolute)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          File.open(absolute, flags) do |file|
            opened = file.stat
            unless opened.file? && !expected.symlink? &&
                   expected.dev == opened.dev && expected.ino == opened.ino
              raise Error.new("target_digest_mismatch", "authoritative target identity changed")
            end
            digests[path] = Digest::SHA256.hexdigest(file.read)
          end
        end
      rescue KeyError, Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP,
             Errno::EACCES, Errno::EPERM => error
        raise Error.new("target_digest_mismatch", "authoritative target is unavailable: #{error.class}")
      end

      def safe_relative_path?(path)
        path.is_a?(String) && !path.empty? && !path.start_with?(File::SEPARATOR) &&
          path.split(File::SEPARATOR).none? { |part| part.empty? || part == "." || part == ".." }
      end

    end
  end
end
