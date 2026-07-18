require "json"

module AdversarialReview
  module Adapters
    class Claude < Base
      REQUIRED_HELP_TOKENS = %w[
        -p --bare --no-session-persistence --permission-mode --tools --model
        --effort --verbose --output-format --json-schema
      ].freeze
      CREDENTIAL_VARIABLES = %w[
        ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
      ].freeze
      ALLOWED_TOOLS = %w[Read Grep Glob].freeze

      def initialize(**options)
        configure_direct(**options)
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
        argv = [
          @pinned_executable.path, "-p", "--bare", "--no-session-persistence",
          "--permission-mode", "plan", "--tools", ALLOWED_TOOLS.join(","),
          "--model", @requested_model, "--effort", @requested_effort,
          "--verbose", "--output-format", "stream-json", "--json-schema",
          JSON.generate(active_schema), prompt
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

        events = parse_json_line_objects(result.stdout, "Claude")
        runtime, final = parse_protocol(events)
        verify_event_bindings!(runtime, events.drop(1))
        payload = final.is_a?(Hash) ? final["structured_output"] : nil
        usage = final.is_a?(Hash) ? final["usage"] : nil
        terminal = runtime_terminal(runtime)
        capabilities = runtime_capabilities(runtime, payload, usage)
        {
          "payload" => payload,
          "terminal" => terminal,
          "usage" => usage,
          "capabilities" => capabilities,
          "provenance" => runtime_provenance_record(runtime)
        }
      rescue JSON::ParserError
        nil
      end

      def parse_protocol(events)
        state = :startup
        runtime = final = nil
        events.each do |event|
          case state
          when :startup
            unless event["type"] == "system" && event["subtype"] == "init"
              raise JSON::ParserError, "Claude event arrived before system/init"
            end
            runtime = event
            state = :running
          when :running
            if event["type"] == "system" && event["subtype"] == "init"
              raise JSON::ParserError, "duplicate Claude system/init"
            elsif event["type"] == "result"
              unless event["subtype"] == "success"
                raise JSON::ParserError, "Claude terminal result was not successful"
              end
              final = event
              state = :terminal
            end
          when :terminal
            raise JSON::ParserError, "Claude event arrived after result"
          end
        end
        raise JSON::ParserError, "Claude result is missing" unless final
        [runtime, final]
      end

      def verify_event_bindings!(runtime, events)
        events.each do |event|
          %w[session_id run_id thread_id].each do |field|
            next unless event.key?(field)
            unless nonempty_text?(event[field]) && runtime[field] == event[field]
              raise JSON::ParserError, "Claude event #{field} does not match startup"
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
          "independent_vote" => runtime["independent_vote"]
        }
      end

      def runtime_capabilities(runtime, payload, usage)
        runtime ||= {}
        session_id = runtime["session_id"]
        fresh = runtime["fresh"] == true && nonempty_text?(session_id)
        workdir_matches = runtime["cwd"] == active_repository
        restricted = runtime["permissionMode"] == "plan" && runtime["tools"] == ALLOWED_TOOLS
        model_matches = runtime["model"] == @requested_model
        effort_matches = runtime["effort"] == @requested_effort
        structured = payload.is_a?(Hash)
        metered = valid_usage?(usage)
        direct_capabilities(
          source: "Claude runtime event",
          fresh_context: [fresh, "fresh non-persistent session #{session_id.inspect}"],
          repository_access: [workdir_matches, "runtime cwd #{runtime["cwd"].inspect}"],
          read_only: [restricted, "plan permission with tools #{runtime["tools"].inspect}"],
          model_selection: [model_matches, "runtime model #{runtime["model"].inspect}"],
          effort_selection: [effort_matches, "runtime effort #{runtime["effort"].inspect}"],
          structured_output: [structured, "machine JSON object received; role schema checked separately"],
          usage_metrics: [metered, "Claude result usage event"]
        )
      end

      def runtime_provenance_record(runtime)
        return {} unless runtime.is_a?(Hash)
        {
          "adapter" => "claude",
          "cli_version" => @cli_version,
          "executable" => @pinned_executable.path,
          "workdir" => runtime["cwd"],
          "requested_model" => @requested_model,
          "observed_model" => runtime["model"],
          "requested_effort" => @requested_effort,
          "observed_effort" => runtime["effort"],
          "session_id" => runtime["session_id"],
          "fresh" => runtime["fresh"],
          "permission_mode" => runtime["permissionMode"],
          "tools" => runtime["tools"],
          "independent_vote" => runtime["independent_vote"]
        }
      end

      def repair_prompt(prompt)
        "#{prompt}\n\nThe prior response was schema-invalid or omitted a required check. Return one corrected structured response only."
      end
    end
  end
end
