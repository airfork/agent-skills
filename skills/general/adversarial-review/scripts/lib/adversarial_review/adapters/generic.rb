require "json"
require "securerandom"

module AdversarialReview
  module Adapters
    class Generic
      TASK_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/.freeze
      TASK_KEYS = %w[
        schema_version run_id task_id role angle round attempt artifact_digests
        targets inventory context_pointers applicable_guidance role_contract schema
        capability_declaration_template mutation_restrictions tool_restrictions prompt
      ].freeze
      SCHEMAS = %w[assets/schemas/attack.json assets/schemas/divergence.json].freeze

      class Error < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      def run(task, run_dir)
        state = State.load(run_dir)
        validate_task!(task, state.to_h.fetch("run_id"))
        canonical_run_dir = File.realpath(File.expand_path(run_dir))
        task_path = File.join(canonical_run_dir, "tasks", "#{task.fetch("task_id")}.json")
        write_new_json(task_path, task)
        {
          "status" => "awaiting-results",
          "task_path" => task_path,
          "capability_declaration_template" => task.fetch("capability_declaration_template"),
          "next_action" => "Return a schema-shaped result and parent capability declaration."
        }
      end

      def ingest_capability_declaration(declaration, task)
        template = task.fetch("capability_declaration_template")
        normalized = Capabilities.normalize(
          declaration,
          requested_model: template.fetch("model_selection").fetch("requested"),
          requested_effort: template.fetch("effort_selection").fetch("requested")
        )
        Capabilities.gate(normalized, "PASS").merge("capabilities" => normalized)
      rescue KeyError => error
        raise Error.new("invalid_task", "capability template is missing #{error.key.inspect}")
      end

      private

      def validate_task!(task, run_id)
        unless task.is_a?(Hash) && task.keys.sort == TASK_KEYS.sort
          raise Error.new("invalid_task", "task bundle is not a closed object")
        end
        unless task.fetch("schema_version") == 1 && task.fetch("run_id") == run_id
          raise Error.new("invalid_task_identity", "task identity does not match the run")
        end
        task_id = task.fetch("task_id")
        unless task_id.is_a?(String) && task_id.match?(TASK_ID)
          raise Error.new("invalid_task_id", "task ID contains unsafe characters")
        end
        angle = task.fetch("angle")
        round = task.fetch("round")
        attempt = task.fetch("attempt")
        expected_task_id = "attack-#{angle}-r#{round}-a#{attempt}"
        unless angle.is_a?(String) && !angle.empty? &&
               round.is_a?(Integer) && round.positive? &&
               attempt.is_a?(Integer) && attempt.positive? &&
               task.fetch("role") == "attacker" && task_id == expected_task_id
          raise Error.new("invalid_task_identity", "task fields do not form its canonical identity")
        end
        schema = task.fetch("schema")
        expected_schema = angle.start_with?("divergence-probe-") ?
          "assets/schemas/divergence.json" : "assets/schemas/attack.json"
        unless SCHEMAS.include?(schema) && schema == expected_schema
          raise Error.new("invalid_task_schema", "task schema does not match its role")
        end
        schema_path = File.join(AdversarialReview.root, schema)
        unless File.file?(schema_path) && File.realpath(schema_path).start_with?(AdversarialReview.root + File::SEPARATOR)
          raise Error.new("invalid_task_schema", "task schema path is unavailable")
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
      rescue KeyError => error
        raise Error.new("invalid_task", "task is missing #{error.key.inspect}")
      end

      def safe_relative_path?(path)
        path.is_a?(String) && !path.empty? && !path.start_with?(File::SEPARATOR) &&
          path.split(File::SEPARATOR).none? { |part| part.empty? || part == "." || part == ".." }
      end

      def write_new_json(path, value)
        destination_name = File.basename(path)
        temporary_name = ".#{destination_name}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
        created = false
        Atomic.with_bound_directory(File.dirname(path)) do |_parent, directory|
          begin
            if Atomic.reject_relative_nonregular(directory, destination_name)
              raise Error.new("task_collision", "task bundle already exists")
            end
            flags = File::WRONLY | File::CREAT | File::EXCL
            flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
            file = Atomic.open_relative(directory, temporary_name, flags, 0o600)
            created = true
            begin
              file.chmod(0o600)
              file.write(JSON.generate(value))
              file.write("\n")
              file.flush
              file.fsync
            ensure
              file.close unless file.closed?
            end
            Atomic.link_relative(directory, temporary_name, destination_name)
            directory.fsync
          rescue Errno::EEXIST
            raise Error.new("task_collision", "task bundle already exists")
          ensure
            Atomic.unlink_relative(directory, temporary_name) if created
          end
        end
        path
      rescue Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM => error
        raise Error.new("unsafe_task_path", "task path is unsafe: #{error.class}")
      end
    end
  end
end
