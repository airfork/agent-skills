require "json"

module AdversarialReview
  module Adapters
    class Codex < Base
      REQUIRED_HELP_TOKENS = %w[
        --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox
        --model --cd --json --output-schema --output-last-message
      ].freeze
      CREDENTIAL_VARIABLES = %w[OPENAI_API_KEY CODEX_API_KEY].freeze

      def initialize(**options)
        configure_direct(**options)
      end

      def credential_variables
        CREDENTIAL_VARIABLES
      end

      def help_argv
        [@pinned_executable.path, "exec", "--help"]
      end

      def required_help_tokens
        REQUIRED_HELP_TOKENS
      end

      def invoke(repair)
        prompt = repair ? repair_prompt(@prompt) : @prompt
        invoke_prompt(prompt)
      end

      def invoke_prompt(prompt)
        @invocation_sequence = @invocation_sequence.to_i + 1
        output_path = File.join(@direct_root, "codex-final-#{@invocation_sequence}.json")
        repository = active_repository
        argv = [
          @pinned_executable.path, "exec", "--ephemeral", "--ignore-user-config",
          "--ignore-rules", "--strict-config", "--sandbox", "read-only",
          "--model", @requested_model, "-c",
          "model_reasoning_effort=#{@requested_effort.inspect}",
          "--cd", repository, "--json", "--output-schema", active_schema_path,
          "--output-last-message", output_path, "-"
        ]
        result = run_direct(argv: argv, stdin_data: prompt)
        [result, parse_result(result, output_path)]
      ensure
        File.unlink(output_path) if output_path && File.file?(output_path)
      end

      def valid_payload?(payload)
        Schema.new(@role_schema, @schema_name).validate(payload).empty?
      end

      private

      def parse_result(result, output_path)
        return nil unless result.is_a?(Runner::Result) && result.exit_status == 0 && !result.timed_out

        events = parse_json_line_objects(result.stdout, "Codex")
        runtime = events.reverse.find { |event| event["type"] == "runtime.start" }
        completed = events.reverse.find { |event| event["type"] == "turn.completed" }
        payload = read_private_json(output_path)
        usage = completed.is_a?(Hash) ? completed["usage"] : nil
        terminal = runtime_terminal(runtime)
        capabilities = runtime_capabilities(runtime, payload, usage)
        {
          "payload" => payload,
          "terminal" => terminal,
          "usage" => usage,
          "capabilities" => capabilities,
          "provenance" => runtime_provenance_record(runtime)
        }
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, Errno::EPERM,
             Errno::ELOOP, Errno::ENOTDIR, IOError
        nil
      end

      def read_private_json(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.euid &&
               (stat.mode & 0o077).zero?
          raise Errno::EACCES, path
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          unless opened.dev == stat.dev && opened.ino == stat.ino && opened.size == stat.size
            raise Errno::EACCES, path
          end
          JSON.parse(file.read)
        end
      end

      def runtime_terminal(runtime)
        return nil unless runtime.is_a?(Hash)
        {
          "terminal" => true,
          "model" => runtime["model"],
          "effort" => runtime["effort"],
          "session_id" => runtime["session_id"],
          "independent_vote" => false
        }
      end

      def runtime_capabilities(runtime, payload, usage)
        runtime ||= {}
        session_id = runtime["session_id"]
        fresh = runtime["fresh"] == true && nonempty_text?(session_id)
        workdir_matches = runtime["workdir"] == active_repository
        read_only = runtime["sandbox"] == "read-only"
        model_matches = runtime["model"] == @requested_model
        effort_matches = runtime["effort"] == @requested_effort
        structured = payload.is_a?(Hash)
        metered = valid_usage?(usage)
        direct_capabilities(
          source: "Codex runtime event",
          fresh_context: [fresh, "fresh ephemeral session #{session_id.inspect}"],
          repository_access: [workdir_matches, "runtime workdir #{runtime["workdir"].inspect}"],
          read_only: [read_only, "runtime sandbox #{runtime["sandbox"].inspect}"],
          model_selection: [model_matches, "runtime model #{runtime["model"].inspect}"],
          effort_selection: [effort_matches, "runtime effort #{runtime["effort"].inspect}"],
          structured_output: [structured, "machine JSON object received; role schema checked separately"],
          usage_metrics: [metered, "turn.completed usage event"]
        )
      end

      def runtime_provenance_record(runtime)
        return {} unless runtime.is_a?(Hash)
        {
          "adapter" => "codex",
          "cli_version" => @cli_version,
          "executable" => @pinned_executable.path,
          "workdir" => runtime["workdir"],
          "requested_model" => @requested_model,
          "observed_model" => runtime["model"],
          "requested_effort" => @requested_effort,
          "observed_effort" => runtime["effort"],
          "session_id" => runtime["session_id"],
          "fresh" => runtime["fresh"],
          "sandbox" => runtime["sandbox"]
        }
      end

      def repair_prompt(prompt)
        "#{prompt}\n\nThe prior response was schema-invalid or omitted a required check. Return one corrected JSON response only."
      end
    end
  end
end
