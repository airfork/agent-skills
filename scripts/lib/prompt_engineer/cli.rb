require "digest"
require "json"

module PromptEngineer
  module CLI
    class Error < StandardError
      attr_reader :code, :exit_status

      def initialize(code, message, exit_status = 3)
        @code = code
        @exit_status = exit_status
        super(message)
      end
    end

    class UsageError < Error
      def initialize(message)
        super("usage_error", message, 2)
      end
    end

    class UnsupportedError < Error
      def initialize(message)
        super("unsupported", message, 3)
      end
    end

    SUBCOMMANDS = %w[
      choices policy prepare next ingest judge-packet judge-ingest score status close report
    ].freeze
    LIVE_OPERATION_STATUS = {
      "launch" => "unsupported",
      "codex" => "unsupported",
      "claude" => "unsupported",
      "shell" => "unsupported",
      "network" => "unsupported"
    }.freeze

    def self.host_choice_schema
      {
        "type" => "object",
        "required" => %w[model effort timeout_seconds],
        "additionalProperties" => false,
        "properties" => {
          "model" => {"type" => "string", "minLength" => 1},
          "effort" => {"type" => "string", "enum" => %w[low medium high]},
          "timeout_seconds" => {"type" => "integer", "minimum" => 1}
        }
      }
    end

    CHOICES_SCHEMA = {
      "type" => "object",
      "required" => %w[schema_version codex claude money_limit_usd provider_cap_partition],
      "additionalProperties" => false,
      "properties" => {
        "schema_version" => {"type" => "integer", "const" => 1},
        "codex" => host_choice_schema,
        "claude" => host_choice_schema,
        "money_limit_usd" => {"type" => "number", "minimum" => 0.01},
        "provider_cap_partition" => {
          "type" => "object",
          "required" => %w[codex claude],
          "additionalProperties" => false,
          "properties" => {
            "codex" => {"type" => "number", "minimum" => 0},
            "claude" => {"type" => "number", "minimum" => 0}
          }
        }
      }
    }.freeze

    class << self
      def run(argv, stdout: $stdout, stderr: $stderr)
        runner = Object.new
        runner.extend(PromptEngineer::CLI)
        runner.send(:initialize, stdout: stdout, stderr: stderr)
        runner.dispatch(Array(argv))
      rescue Error => error
        emit_error(stderr, error)
        error.exit_status
      rescue StandardError => original
        known = [
          PromptEngineer::Contracts::Error,
          PromptEngineer::Corpus::Error,
          PromptEngineer::RunStore::Error,
          PromptEngineer::Scoring::Error,
          ArgumentError,
          KeyError,
          TypeError,
          Errno::ENOENT,
          Errno::EACCES,
          Errno::EEXIST
        ].any? { |klass| original.is_a?(klass) }
        raise unless known

        error = Error.new("invalid_input", original.message, 2)
        emit_error(stderr, error)
        error.exit_status
      end

      private

      def emit_error(stderr, error)
        stderr.write(PromptEngineer::Canonical.json(
          "error" => {"code" => error.code, "message" => error.message}
        ))
      end
    end

    def initialize(stdout:, stderr:)
      @stdout = stdout
      @stderr = stderr
    end

    def dispatch(argv)
      command = argv.shift
      raise UsageError, "subcommand is required" unless command
      raise UsageError, "unknown subcommand: #{command}" unless SUBCOMMANDS.include?(command)

      payload = send("command_#{command.tr('-', '_')}", argv)
      emit(payload)
      0
    end

    private

    def command_choices(argv)
      options = parse_options(argv, %w[
        codex-model codex-effort claude-model claude-effort codex-timeout
        claude-timeout max-usd codex-cap-usd claude-cap-usd output
      ])
      required = options.keys
      required_options = %w[
        codex-model codex-effort claude-model claude-effort codex-timeout
        claude-timeout max-usd codex-cap-usd claude-cap-usd output
      ]
      missing = required_options - required
      raise UsageError, "missing options: #{missing.map { |name| "--#{name}" }.join(", ")}" unless missing.empty?

      money_limit = decimal(options.fetch("max-usd"), "max-usd")
      partition = {
        "codex" => decimal(options.fetch("codex-cap-usd"), "codex-cap-usd"),
        "claude" => decimal(options.fetch("claude-cap-usd"), "claude-cap-usd")
      }
      if partition.values.sum > money_limit
        raise Error.new("budget_partition_exceeds_limit", "provider cap partition exceeds money limit", 2)
      end

      record = {
        "schema_version" => 1,
        "codex" => {
          "model" => options.fetch("codex-model"),
          "effort" => options.fetch("codex-effort"),
          "timeout_seconds" => positive_integer(options.fetch("codex-timeout"), "codex-timeout")
        },
        "claude" => {
          "model" => options.fetch("claude-model"),
          "effort" => options.fetch("claude-effort"),
          "timeout_seconds" => positive_integer(options.fetch("claude-timeout"), "claude-timeout")
        },
        "money_limit_usd" => money_limit,
        "provider_cap_partition" => partition
      }
      PromptEngineer::Contracts.validate!(record, CHOICES_SCHEMA)
      write_json(options.fetch("output"), record)
      record
    end

    def command_status(argv)
      options = parse_options(argv, ["run-dir"])
      result = {
        "status" => "inconclusive",
        "live_operations" => LIVE_OPERATION_STATUS,
        "capabilities" => PromptEngineer::Capabilities.report,
        "reason" => "native host evidence is unavailable; live launch is not authorized"
      }
      if options["run-dir"]
        store = PromptEngineer::RunStore.open(options.fetch("run-dir"))
        events = store.events
        result["run"] = {
          "run_id" => store.run_id,
          "run_dir" => store.root,
          "closed" => store.closed?,
          "pending" => store.pending_tasks.length,
          "events" => events.length,
          "ingested" => store.ingested_records.length,
          "manifest_digest" => store.manifest_digest
        }
      end
      result
    end

    def command_prepare(argv)
      options = parse_options(argv, %w[
        corpus candidate-root legacy-root legacy-lock run-dir qualification-policy
        environment output
      ], repeatable: ["environment"])
      require_options!(options, %w[corpus candidate-root legacy-lock run-dir qualification-policy])
      environment = Array(options["environment"]).each_with_object({}) do |entry, values|
        key, value = entry.split("=", 2)
        raise UsageError, "environment must use KEY=VALUE" unless key && value

        values[key] = value
      end
      store = PromptEngineer::RunStore.prepare(
        run_root: options.fetch("run-dir"),
        corpus: PromptEngineer::Corpus.load(options.fetch("corpus")),
        package_root: options.fetch("candidate-root"),
        qualification_policy: load_document(options.fetch("qualification-policy")),
        legacy_lock: load_document(options.fetch("legacy-lock")),
        legacy_root: options["legacy-root"],
        environment: environment
      )
      result = {"run_id" => store.run_id, "run_dir" => store.root, "manifest_digest" => store.manifest_digest}
      write_json(options.fetch("output"), result) if options["output"]
      result
    end

    def command_policy(_argv)
      raise UnsupportedError, "policy construction requires proven native capability evidence"
    end

    def command_next(_argv)
      raise UnsupportedError, "live host execution is unsupported; no launch packet was emitted"
    end

    def command_ingest(_argv)
      raise UnsupportedError, "native export ingestion is unsupported without a native host normalizer"
    end

    def command_judge_packet(_argv)
      raise UnsupportedError, "judge packet creation is unavailable until executor evidence is ingested"
    end

    def command_judge_ingest(_argv)
      raise UnsupportedError, "judge ingestion is unsupported without a native judge host"
    end

    def command_score(argv)
      options = parse_options(argv, %w[evidence output])
      require_options!(options, ["evidence"])
      evidence = load_document(options.fetch("evidence"))
      decision = PromptEngineer::Scoring.release_decision(evidence)
      result = {"decision" => decision, "evidence_digest" => PromptEngineer::Canonical.digest(evidence)}
      write_json(options.fetch("output"), result) if options["output"]
      result
    end

    def command_close(argv)
      options = parse_options(argv, %w[run-dir reason evidence])
      require_options!(options, %w[run-dir reason evidence])
      evidence_digest = Digest::SHA256.file(options.fetch("evidence")).hexdigest
      store = PromptEngineer::RunStore.open(options.fetch("run-dir"))
      store.close!("#{options.fetch("reason")} [evidence=#{evidence_digest}]")
      {"closed" => true, "run_id" => store.run_id, "evidence_digest" => evidence_digest}
    end

    def command_report(argv)
      options = parse_options(argv, %w[evidence output])
      require_options!(options, %w[evidence output])
      markdown = PromptEngineer::Reporting.render(load_document(options.fetch("evidence")))
      write_bytes(options.fetch("output"), markdown)
      {"report_path" => File.expand_path(options.fetch("output")), "report_digest" => Digest::SHA256.hexdigest(markdown)}
    end

    def parse_options(argv, allowed, repeatable: [])
      options = {}
      args = Array(argv).dup
      until args.empty?
        flag = args.shift
        raise UsageError, "options must use --name=value or --name value" unless flag.start_with?("--")

        name, inline = flag[2..-1].split("=", 2)
        raise UsageError, "unknown option: --#{name}" unless allowed.include?(name)
        value = inline || args.shift
        raise UsageError, "missing value for --#{name}" unless value && !value.start_with?("--")
        if repeatable.include?(name)
          options[name] ||= []
          options[name] << value
        elsif options.key?(name)
          raise UsageError, "duplicate option: --#{name}"
        else
          options[name] = value
        end
      end
      options
    end

    def require_options!(options, names)
      missing = names.reject { |name| options.key?(name) }
      raise UsageError, "missing options: #{missing.map { |name| "--#{name}" }.join(", ")}" unless missing.empty?
    end

    def positive_integer(value, name)
      raise UsageError, "#{name} must be a positive integer" unless value.to_s.match?(/\A[1-9][0-9]*\z/)

      value.to_i
    end

    def decimal(value, name)
      raise UsageError, "#{name} must be a positive decimal" unless value.to_s.match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/)

      number = Float(value)
      raise UsageError, "#{name} must be positive" unless number.finite? && number > 0

      number
    end

    def load_document(path)
      bytes = File.binread(path)
      begin
        JSON.parse(bytes)
      rescue JSON::ParserError
        PromptEngineer::Contracts.parse_yaml(bytes)
      end
    end

    def emit(payload)
      @stdout.write(PromptEngineer::Canonical.json(payload))
    end

    def write_json(path, value)
      write_bytes(path, PromptEngineer::Canonical.json(value))
    end

    def write_bytes(path, bytes)
      raise UsageError, "output path is required" unless path.is_a?(String) && !path.empty?
      if path == "-"
        @stdout.write(bytes)
        return
      end
      raise Error.new("output_exists", "output already exists: #{path}", 2) if File.exist?(path) || File.symlink?(path)

      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      raise Error.new("output_exists", "output already exists: #{path}", 2)
    end
  end
end
