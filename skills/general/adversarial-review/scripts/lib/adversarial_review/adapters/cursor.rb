require "json"

module AdversarialReview
  module Adapters
    class Cursor < Base
      REQUIRED_HELP_TOKENS = %w[
        -p --mode --sandbox --workspace --model --output-format --effort
      ].freeze
      CREDENTIAL_VARIABLES = %w[CURSOR_API_KEY].freeze
      VERSION_EFFORT_FLAGS = {
        "cursor-agent contract-vNext" => ["--effort"]
      }.freeze
      MAX_EVENTS = 1_024

      def initialize(executable: "agent", **options)
        @cursor_configuration = options.merge(executable: executable)
        @cursor_fallback_candidate = executable == "agent" ? "cursor-agent" : nil
        @cursor_selection_mutex = Mutex.new
        configure_direct(**@cursor_configuration)
      end

      def execute(required_checks: [], dispatch_capability: nil)
        @cursor_selection_mutex.synchronize do
          result = super
          return result unless @cursor_fallback_candidate &&
                               %w[runner_error capability_probe_failed version_probe_failed].include?(result.error_code)

          fallback = @cursor_fallback_candidate
          @cursor_fallback_candidate = nil
          @cursor_configuration = @cursor_configuration.merge(executable: fallback)
          configure_direct(**@cursor_configuration)
          super
        end
      end

      def credential_variables
        CREDENTIAL_VARIABLES
      end

      def help_argv
        [@pinned_executable.path, "--help"]
      end

      def required_help_tokens
        REQUIRED_HELP_TOKENS
      end

      def invoke(repair)
        prompt = repair ? repair_prompt(@prompt) : @prompt
        invoke_prompt(prompt)
      end

      def invoke_prompt(prompt)
        effort_flags = VERSION_EFFORT_FLAGS[@cli_version]
        return [nil, nil] unless effort_flags

        argv = [
          @pinned_executable.path, "-p", "--mode", "ask", "--sandbox", "enabled",
          "--workspace", active_repository, "--model", @requested_model,
          "--output-format", "stream-json", *effort_flags, @requested_effort, prompt
        ]
        result = run_direct(argv: argv, stdin_data: "")
        [result, parse_result(result)]
      end

      def valid_payload?(payload)
        Schema.new(@role_schema, @schema_name).validate(payload).empty?
      end

      private

      def parse_result(result)
        return nil unless result.is_a?(Runner::Result) && result.exit_status == 0 && !result.timed_out

        events = parse_json_line_objects(result.stdout, "Cursor")
        raise JSON::ParserError, "Cursor event limit exceeded" if events.length > MAX_EVENTS
        runtime, final = parse_protocol(events)
        verify_event_bindings!(runtime, events.drop(1))
        payload = final["structured_output"]
        usage = final["usage"]
        {
          "payload" => payload,
          "terminal" => runtime_terminal(runtime),
          "usage" => usage,
          "capabilities" => runtime_capabilities(runtime, payload, usage),
          "provenance" => runtime_provenance_record(runtime)
        }
      rescue JSON::ParserError
        nil
      end

      def parse_protocol(events)
        runtime = final = nil
        state = :startup
        events.each do |event|
          case state
          when :startup
            unless event["type"] == "system" && event["subtype"] == "init"
              raise JSON::ParserError, "Cursor event arrived before system/init"
            end
            runtime = event
            state = :running
          when :running
            if event["type"] == "system" && event["subtype"] == "init"
              raise JSON::ParserError, "duplicate Cursor system/init"
            elsif event["type"] == "result"
              unless event["subtype"] == "success"
                raise JSON::ParserError, "Cursor terminal result was not successful"
              end
              final = event
              state = :terminal
            end
          when :terminal
            raise JSON::ParserError, "Cursor event arrived after result"
          end
        end
        raise JSON::ParserError, "Cursor result is missing" unless final
        [runtime, final]
      end

      def verify_event_bindings!(runtime, events)
        events.each do |event|
          %w[session_id run_id thread_id].each do |field|
            next unless event.key?(field)
            unless nonempty_text?(event[field]) && runtime[field] == event[field]
              raise JSON::ParserError, "Cursor event #{field} does not match startup"
            end
          end
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
        workdir_matches = runtime["workspace"] == active_repository
        read_only = runtime["mode"] == "ask" && runtime["sandbox"] == "enabled" &&
                    runtime["read_only"] == true
        model_matches = runtime["model"] == @requested_model
        effort_matches = runtime["effort"] == @requested_effort
        structured = runtime["output_format"] == "stream-json" && payload.is_a?(Hash)
        metered = valid_usage?(usage)
        direct_capabilities(
          source: "Cursor initialization event",
          fresh_context: [fresh, "fresh print session #{session_id.inspect}"],
          repository_access: [workdir_matches, "runtime workspace #{runtime["workspace"].inspect}"],
          read_only: [read_only, "ask mode with enabled sandbox and read-only attestation"],
          model_selection: [model_matches, "runtime model #{runtime["model"].inspect}"],
          effort_selection: [effort_matches, "runtime effort #{runtime["effort"].inspect}"],
          structured_output: [structured, "stream-json structured output"],
          usage_metrics: [metered, "Cursor terminal usage event"]
        )
      end

      def runtime_provenance_record(runtime)
        return {} unless runtime.is_a?(Hash)
        {
          "adapter" => "cursor",
          "cli_version" => @cli_version,
          "executable" => @pinned_executable.path,
          "workdir" => runtime["workspace"],
          "requested_model" => @requested_model,
          "observed_model" => runtime["model"],
          "requested_effort" => @requested_effort,
          "observed_effort" => runtime["effort"],
          "session_id" => runtime["session_id"],
          "fresh" => runtime["fresh"],
          "mode" => runtime["mode"],
          "sandbox" => runtime["sandbox"],
          "read_only" => runtime["read_only"]
        }
      end

      def repair_prompt(prompt)
        "#{prompt}\n\nThe prior response was schema-invalid or omitted a required check. Return one corrected structured response only."
      end
    end
  end
end
