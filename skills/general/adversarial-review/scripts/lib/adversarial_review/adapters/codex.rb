require "json"

module AdversarialReview
  module Adapters
    class Codex < Base
      MAX_FINAL_RESPONSE_BYTES = 1_048_576
# `birthtime` is what distinguishes an in-place write (legitimate: Codex
# writes the final message) from an unlink-and-recreate (an attack). Inode
# numbers alone cannot: filesystems that reuse inodes eagerly, ext4 among
# them, can hand the replacement the same dev/ino/uid/mode. It is nil where
# the platform does not report a creation time, which weakens the check
# rather than breaking it.
FinalResponseIdentity = Struct.new(
  :device, :inode, :uid, :mode, :birthtime, keyword_init: true
)
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
        output_identity = prepare_final_response(output_path)
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
        [result, parse_result(result, output_path, output_identity)]
      ensure
        File.unlink(output_path) if output_path && File.file?(output_path)
      end

      def valid_payload?(payload)
        Schema.new(@role_schema, @schema_name).validate(payload).empty?
      end

      private

      def parse_result(result, output_path, output_identity)
        return nil unless result.is_a?(Runner::Result) && result.exit_status == 0 && !result.timed_out

        events = parse_json_line_objects(result.stdout, "Codex")
        runtime, completed = parse_protocol(events)
        verify_event_bindings!(runtime, events.drop(1))
        payload = read_private_json(output_path, output_identity)
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
      rescue JSON::ParserError, IOError
        nil
      end

      def parse_protocol(events)
        state = :startup
        runtime = completed = nil
        events.each do |event|
          case state
          when :startup
            unless event["type"] == "runtime.start"
              raise JSON::ParserError, "Codex event arrived before runtime.start"
            end
            runtime = event
            state = :running
          when :running
            if event["type"] == "runtime.start"
              raise JSON::ParserError, "duplicate Codex runtime.start"
            elsif event["type"] == "turn.completed"
              completed = event
              state = :terminal
            end
          when :terminal
            raise JSON::ParserError, "Codex event arrived after turn.completed"
          end
        end
        raise JSON::ParserError, "Codex turn.completed is missing" unless completed
        [runtime, completed]
      end

      def verify_event_bindings!(runtime, events)
        events.each do |event|
          %w[session_id run_id thread_id].each do |field|
            next unless event.key?(field)
            unless nonempty_text?(event[field]) && runtime[field] == event[field]
              raise JSON::ParserError, "Codex event #{field} does not match startup"
            end
          end
        end
      end

      def prepare_final_response(path)
        Runner.write_private_file(path, "")
        stat = File.lstat(path)
        unless private_final_response?(stat)
          raise Runner::SecurityError.new(
            "final_response_changed", "Codex final-response file was not created privately"
          )
        end
        FinalResponseIdentity.new(
          device: stat.dev, inode: stat.ino, uid: stat.uid, mode: stat.mode,
          birthtime: creation_time(stat)
        )
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
             Errno::ELOOP, Errno::EEXIST
        raise Runner::SecurityError.new(
          "final_response_changed", "Codex final-response file could not be created safely"
        )
      end

      def read_private_json(path, identity)
        path_before = File.lstat(path)
        verify_final_response_identity!(path_before, identity)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        contents = nil
        File.open(path, flags) do |file|
          before_read = file.stat
          verify_final_response_identity!(before_read, identity)
          contents = read_final_response_bytes(file)
          after_read = file.stat
          verify_final_response_identity!(after_read, identity)
          unless stable_final_response?(before_read, after_read)
            raise Runner::SecurityError.new(
              "final_response_changed", "Codex final response changed while it was read"
            )
          end
        end
        path_after = File.lstat(path)
        verify_final_response_identity!(path_after, identity)
        JSON.parse(contents)
      rescue Runner::SecurityError
        raise
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM,
             Errno::ELOOP, IOError
        raise Runner::SecurityError.new(
          "final_response_changed", "Codex final response became unavailable"
        )
      end

      def read_final_response_bytes(file)
        contents = file.read(MAX_FINAL_RESPONSE_BYTES + 1) || ""
        if contents.bytesize > MAX_FINAL_RESPONSE_BYTES
          raise Runner::SecurityError.new(
            "final_response_oversize", "Codex final response exceeded the fixed byte limit"
          )
        end
        contents
      end

      def verify_final_response_identity!(stat, identity)
        observed_birthtime = creation_time(stat)
        birthtime_matches = identity.is_a?(FinalResponseIdentity) &&
                            (identity.birthtime.nil? || observed_birthtime.nil? ||
                             observed_birthtime == identity.birthtime)
        unless identity.is_a?(FinalResponseIdentity) && private_final_response?(stat) &&
               stat.dev == identity.device && stat.ino == identity.inode &&
               stat.uid == identity.uid && stat.mode == identity.mode &&
               birthtime_matches
          raise Runner::SecurityError.new(
            "final_response_changed", "Codex final-response identity or permissions changed"
          )
        end
      end

      # nil where the platform cannot report a creation time.
      def creation_time(stat)
        stat.birthtime
      rescue NotImplementedError, NoMethodError
        nil
      end

      def private_final_response?(stat)
        stat.file? && !stat.symlink? && stat.uid == Process.euid &&
          (stat.mode & 0o777) == 0o600
      end

      def stable_final_response?(before_read, after_read)
        before_read.dev == after_read.dev && before_read.ino == after_read.ino &&
          before_read.mode == after_read.mode && before_read.uid == after_read.uid &&
          before_read.size == after_read.size && before_read.mtime == after_read.mtime &&
          before_read.ctime == after_read.ctime
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
