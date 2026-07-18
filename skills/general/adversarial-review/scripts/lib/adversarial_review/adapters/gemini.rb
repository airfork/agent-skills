require "json"

module AdversarialReview
  module Adapters
    class Gemini < Base
      class DuplicateRejectingHash < Hash
        def []=(key, value)
          raise JSON::ParserError, "duplicate Gemini JSON key #{key.inspect}" if key?(key)
          super
        end
      end

      REQUIRED_HELP_TOKENS = %w[--prompt --model --output-format --sandbox].freeze
      CREDENTIAL_VARIABLES = %w[
        GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GENAI_USE_VERTEXAI
        GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION
      ].freeze
      ALLOWED_TOOLS = %w[read_file search_file_content glob].freeze
      VERSION_EFFORT_CONTRACTS = {
        "gemini-cli contract-vNext" => {
          "default" => {"medium" => {"config_effort" => "balanced"}},
          "high" => {"high" => {"config_effort" => "high"}}
        }
      }.freeze
      AGENT_DEFINITION = {
        "description" => "Read-only adversarial review role",
        "instructions" => "Inspect repository content without modifying files or running commands.",
        "name" => "adversarial-review",
        "tools" => ALLOWED_TOOLS
      }.freeze

      def initialize(**options)
        configure_direct(**options)
      end

      def credential_variables
        CREDENTIAL_VARIABLES
      end

      def child_environment(source_env: ENV, isolated_home: nil, isolated_config_root: nil)
        environment = super
        root = @active_gemini_cli_home || isolated_config_root
        environment["GEMINI_CLI_HOME"] = validated_isolated_root(root, "Gemini config root") if root
        environment
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
        prepare_invocation_config
        argv = [
          @pinned_executable.path, "--prompt", prompt, "--model", @requested_model,
          "--output-format", "json", "--sandbox"
        ]
        result = run_direct(argv: argv, stdin_data: "")
        [result, parse_result(result)]
      end

      def valid_payload?(payload)
        Schema.new(@role_schema, @schema_name).validate(payload).empty?
      end

      private

      def reset_execution_state!
        super
        @active_gemini_cli_home = nil
      end

      def version_contract_error
        version = VERSION_EFFORT_CONTRACTS[@cli_version]
        return "unsupported_version_contract" unless version
        return "unsupported_effort_contract" unless version.dig(tier, @requested_effort)
        nil
      end

      def prepare_invocation_config
        @invocation_sequence = @invocation_sequence.to_i + 1
        @active_gemini_cli_home = File.join(
          @isolated_config_root, "gemini-invocation-#{@invocation_sequence}"
        )
        agents = File.join(@active_gemini_cli_home, "agents")
        Dir.mkdir(@active_gemini_cli_home, 0o700)
        Dir.mkdir(agents, 0o700)
        effort_contract = VERSION_EFFORT_CONTRACTS.fetch(@cli_version)
                                                   .fetch(tier)
                                                   .fetch(@requested_effort)
        settings = {
          "agents" => {"active" => "adversarial-review", "ephemeral" => true},
          "model" => {
            "effort" => effort_contract.fetch("config_effort"),
            "name" => @requested_model
          },
          "output" => {"format" => "json"},
          "sandbox" => true,
          "tools" => {"allowed" => ALLOWED_TOOLS},
          "workspace" => active_repository
        }
        Runner.write_private_file(
          File.join(@active_gemini_cli_home, "settings.json"), JSON.generate(settings)
        )
        Runner.write_private_file(
          File.join(agents, "adversarial-review.json"), JSON.generate(AGENT_DEFINITION)
        )
      end

      def parse_result(result)
        return nil unless result.is_a?(Runner::Result) && result.exit_status == 0 && !result.timed_out

        envelope = JSON.parse(result.stdout, object_class: DuplicateRejectingHash)
        unless envelope.is_a?(Hash) && envelope.keys.sort == %w[response startup stats]
          raise JSON::ParserError, "Gemini response envelope is invalid"
        end
        startup = envelope["startup"]
        unless startup.is_a?(Hash) && startup["type"] == "startup"
          raise JSON::ParserError, "Gemini startup attestation is missing"
        end
        response = envelope["response"]
        stats = envelope["stats"]
        session_id = startup["session_id"]
        unless response.is_a?(Hash) && response.keys.sort == %w[session_id structured_output] &&
               stats.is_a?(Hash) && stats.keys.sort == %w[session_id usage] &&
               nonempty_text?(session_id) && response["session_id"] == session_id &&
               stats["session_id"] == session_id
          raise JSON::ParserError, "Gemini response or stats session binding is invalid"
        end
        payload = response["structured_output"]
        usage = stats["usage"]
        {
          "payload" => payload,
          "terminal" => runtime_terminal(startup),
          "usage" => usage,
          "capabilities" => runtime_capabilities(startup, payload, usage),
          "provenance" => runtime_provenance_record(startup)
        }
      rescue JSON::ParserError
        nil
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
        isolated = runtime["config_root"] == @active_gemini_cli_home &&
                   runtime["agents_ephemeral"] == true &&
                   runtime["agent"] == "adversarial-review"
        restricted = runtime["sandbox"] == true && runtime["tools"] == ALLOWED_TOOLS && isolated
        model_matches = runtime["model"] == @requested_model
        effort_matches = runtime["effort"] == @requested_effort
        structured = runtime["output_format"] == "json" && payload.is_a?(Hash)
        metered = valid_usage?(usage)
        direct_capabilities(
          source: "Gemini startup envelope",
          fresh_context: [fresh, "fresh Gemini session #{session_id.inspect}"],
          repository_access: [workdir_matches, "runtime workspace #{runtime["workspace"].inspect}"],
          read_only: [restricted, "sandboxed ephemeral agent with read/search-only tools"],
          model_selection: [model_matches, "runtime model #{runtime["model"].inspect}"],
          effort_selection: [effort_matches, "runtime effort #{runtime["effort"].inspect}"],
          structured_output: [structured, "JSON response envelope"],
          usage_metrics: [metered, "Gemini stats envelope"]
        )
      end

      def runtime_provenance_record(runtime)
        return {} unless runtime.is_a?(Hash)
        {
          "adapter" => "gemini",
          "cli_version" => @cli_version,
          "executable" => @pinned_executable.path,
          "workdir" => runtime["workspace"],
          "requested_model" => @requested_model,
          "observed_model" => runtime["model"],
          "requested_effort" => @requested_effort,
          "observed_effort" => runtime["effort"],
          "session_id" => runtime["session_id"],
          "fresh" => runtime["fresh"],
          "sandbox" => runtime["sandbox"],
          "config_root" => runtime["config_root"],
          "agent" => runtime["agent"],
          "tools" => runtime["tools"]
        }
      end

      def repair_prompt(prompt)
        "#{prompt}\n\nThe prior response was schema-invalid or omitted a required check. Return one corrected JSON response only."
      end
    end
  end
end
