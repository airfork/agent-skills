require "digest"
require "open3"
require "pathname"
require "securerandom"

module AdversarialReview
  class Manifest
    TIERS = %w[default high ultra].freeze
    MODES = %w[critique revise].freeze
    OUTPUTS = %w[chat file both].freeze
    EXECUTORS = %w[auto codex claude cursor gemini generic].freeze

    BASE_TASKS = %w[
      implementer tester user assumptions-checker pre-mortem
      consistency-smells feasibility
    ].freeze

    class Error < StandardError
      attr_reader :code, :details, :exit_status

      def initialize(code, message, details = {})
        @code = code
        @details = details
        @exit_status = 2
        super(message)
      end

      def to_h
        {"code" => code, "message" => message, "details" => details}
      end
    end

    class Inventory
      PLACEHOLDER = /\b(?:TODO|TBD|FIXME)\b|\?\?\?|\{\{[^}\n]+\}\}|<(?:[^>\n]*placeholder[^>\n]*)>|\[(?:PLACEHOLDER|INSERT[^\]\n]*|YOUR [^\]\n]+)\]/i
      REQUIREMENT = /\b(?:REQ(?:UIREMENT)?[-_ ]?\d+|R\d+)\b/i
      TASK = /\bTASK[-_ ]?\d+\b/i
      COMMAND = /\A(?:\.?\/?(?:bin|scripts)\/|git\s|bundle\s|ruby\s|rake\s|npm\s|pnpm\s|yarn\s|make(?:\s|\z)|cargo\s|go\s)/
      PLACEHOLDER_DISPLAY_LIMIT = 16

      def self.build(role, path, absolute_path)
        new(role, path, File.read(absolute_path)).build
      end

      def initialize(role, path, contents)
        @role = role
        @path = path
        @contents = contents
      end

      def build
        headings = []
        requirements = []
        tasks = []
        paths = []
        commands = []
        placeholders = []
        ancestry = []
        fence_character = nil
        fence_length = nil

        @contents.lines.each_with_index do |line, index|
          line_number = index + 1
          if fence_character
            closing_fence = /^\s*#{Regexp.escape(fence_character)}{#{fence_length},}\s*$/
            if line.match?(closing_fence)
              fence_character = nil
              fence_length = nil
              next
            end
            candidate = line.strip
            commands << candidate if command?(candidate)
            next
          end

          opening_fence = line.match(/^\s*(`{3,}|~{3,})/)
          if opening_fence
            fence_character = opening_fence[1][0]
            fence_length = opening_fence[1].length
            next
          end

          heading = line.match(/\A\s*(\#{1,6})\s+(.+?)\s*\#*\s*\z/)
          if heading
            level = heading[1].length
            ancestry = ancestry.first(level - 1)
            ancestry[level - 1] = heading[2]
            headings << [line_number, ancestry.compact.join(" > ")]
          end

          line.scan(REQUIREMENT) { |label| requirements << [label, line_number] }
          line.scan(TASK) { |label| tasks << [label, line_number] }
          line.scan(/`([^`\n]+)`/) do |match|
            value = match.first.strip
            paths << value if path_like?(value)
            commands << value if command?(value)
          end
          line.to_enum(:scan, PLACEHOLDER).each do
            match = Regexp.last_match
            placeholders << {
              "kind" => placeholder_kind(match[0])[0, PLACEHOLDER_DISPLAY_LIMIT],
              "line" => line_number
            }
          end
        end

        markdown = render(headings, requirements, tasks, paths.uniq.sort,
                          commands.uniq.sort, placeholders)
        {
          "role" => @role,
          "path" => @path,
          "markdown" => markdown,
          "word_count" => @contents.scan(/\b[[:alnum:]_'-]+\b/).length,
          "line_count" => @contents.lines.length,
          "placeholder_count" => placeholders.length,
          "unresolved_placeholders" => placeholders,
          "referenced_paths" => paths.uniq.sort
        }
      end

      private

      def path_like?(value)
        value.match?(/\A(?:\.?\.?\/)?[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.\[\]-]+)+\z/) ||
          value.match?(/\A[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,12}\z/)
      end

      def command?(value)
        value.match?(COMMAND) || (value.include?(" --") && value.include?("/"))
      end

      def placeholder_kind(value)
        normalized = value.upcase
        return "todo" if normalized == "TODO"
        return "tbd" if normalized == "TBD"
        return "fixme" if normalized == "FIXME"
        return "question" if value == "???"

        "template"
      end

      def render(headings, requirements, tasks, paths, commands, placeholders)
        lines = ["### #{@role}: `#{@path}`"]
        append_entries(lines, "Headings", headings.map { |line, name| "L#{line} #{name}" })
        append_entries(lines, "Requirements", requirements.map { |label, line| "#{label} (L#{line})" })
        append_entries(lines, "Tasks", tasks.map { |label, line| "#{label} (L#{line})" })
        append_entries(lines, "Paths", paths.map { |path| "`#{path}`" })
        append_entries(lines, "Commands", commands.map { |command| "`#{command}`" })
        placeholder_entries = placeholders.map do |entry|
          "#{entry.fetch("kind")} (L#{entry.fetch("line")})"
        end
        append_entries(lines, "Unresolved placeholders", placeholder_entries)
        lines << "- Unresolved placeholder count: #{placeholders.length}"
        lines << "- Words: #{@contents.scan(/\b[[:alnum:]_'-]+\b/).length}"
        lines << "- Lines: #{@contents.lines.length}"
        lines.join("\n")
      end

      def append_entries(lines, heading, entries)
        return if entries.empty?

        lines << "#### #{heading}"
        entries.each { |entry| lines << "- #{entry}" }
      end
    end

    def self.build(repository:, spec: nil, plan: nil, tier:, mode:, output:,
                   executor:, model: nil, effort: nil, context_paths: [])
      new(
        repository: repository,
        spec: spec,
        plan: plan,
        tier: tier,
        mode: mode,
        output: output,
        executor: executor,
        model: model,
        effort: effort,
        context_paths: context_paths
      ).build
    end

    def initialize(repository:, spec:, plan:, tier:, mode:, output:, executor:,
                   model:, effort:, context_paths:)
      @repository = repository
      @spec = spec
      @plan = plan
      @tier = tier
      @mode = mode
      @output = output
      @executor = executor
      @model = model
      @effort = effort
      @context_paths = context_paths
    end

    def build
      if @spec.nil? && @plan.nil?
        raise Error.new("missing_target", "at least one of spec or plan is required")
      end
      validate_enum("tier", @tier, TIERS)
      validate_enum("mode", @mode, MODES)
      validate_enum("output", @output, OUTPUTS)
      validate_enum("executor", @executor, EXECUTORS)

      @root = repository_root
      built_targets = targets
      built_inventory = built_targets.map do |target|
        Inventory.build(
          target.fetch("role"), target.fetch("path"),
          File.join(@root, target.fetch("path"))
        )
      end
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "repository" => repository_metadata,
        "targets" => built_targets,
        "tier" => @tier,
        "mode" => @mode,
        "output" => @output,
        "requested_executor" => @executor,
        "requested_model" => @model,
        "requested_effort" => @effort,
        "enabled_tasks" => enabled_tasks,
        "inventory" => built_inventory,
        "context_paths" => resolved_context_paths(built_targets, built_inventory),
        "starting_metrics" => starting_metrics(built_inventory)
      }
    end

    private

    def validate_enum(name, value, allowed)
      return if allowed.include?(value)

      raise Error.new(
        "invalid_#{name}", "invalid #{name}: #{value.inspect}",
        {"value" => value, "allowed" => allowed}
      )
    end

    def run_id
      "ar-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}-#{SecureRandom.hex(4)}"
    end

    def repository_root
      repository = File.expand_path(@repository)
      output, status = Open3.capture2e(
        "git", "-C", repository, "rev-parse", "--show-toplevel"
      )
      unless status.success?
        raise Error.new(
          "repository_root_unresolved", "could not resolve Git repository root",
          {"repository" => repository}
        )
      end
      File.realpath(output.strip)
    end

    def repository_metadata
      head, head_status = git("rev-parse", "HEAD")
      status_output, status_status = git("status", "--porcelain=v1", "--untracked-files=all")
      status_lines = status_status.success? ? status_output.lines.map(&:chomp) : []
      {
        "root" => @root,
        "head" => head_status.success? ? head.strip : nil,
        "dirty" => !status_lines.empty?,
        "status" => status_lines
      }
    end

    def git(*arguments)
      Open3.capture2e("git", "-C", @root, *arguments)
    end

    def targets
      result = [["spec", @spec], ["plan", @plan]].each_with_object([]) do |(role, path), items|
        next unless path

        expanded_path = File.expand_path(path, @root)
        begin
          absolute_path = File.realpath(expanded_path)
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise Error.new(
            "missing_file", "#{role} file does not exist: #{path}",
            {"role" => role, "path" => path}
          )
        end
        unless contained?(absolute_path)
          raise Error.new(
            "outside_repository", "#{role} path is outside the repository: #{path}",
            {"role" => role, "path" => path}
          )
        end
        unless File.file?(absolute_path)
          raise Error.new(
            "missing_file", "#{role} path is not a file: #{path}",
            {"role" => role, "path" => path}
          )
        end
        relative_path = Pathname.new(absolute_path).relative_path_from(Pathname.new(@root)).to_s

        items << {
          "role" => role,
          "path" => relative_path,
          "sha256" => Digest::SHA256.file(absolute_path).hexdigest
        }
      end
      same_file = result.length == 2 && File.identical?(
        File.join(@root, result[0].fetch("path")),
        File.join(@root, result[1].fetch("path"))
      )
      if same_file
        raise Error.new(
          "ambiguous_role", "one file cannot serve as both spec and plan",
          {"path" => result[0].fetch("path"), "roles" => %w[spec plan]}
        )
      end
      result
    end

    def contained?(path)
      path == @root || path.start_with?(@root + File::SEPARATOR)
    end

    def enabled_tasks
      tasks = BASE_TASKS.dup
      tasks << "traceability" if @spec && @plan
      if @spec && %w[high ultra].include?(@tier)
        tasks.concat(%w[divergence-probe-1 divergence-probe-2 divergence-probe-3])
      end
      tasks
    end

    def resolved_context_paths(built_targets, built_inventory)
      paths = @context_paths.map { |path| explicit_context_path(path) }
      built_inventory.each do |inventory|
        inventory.fetch("referenced_paths").each do |path|
          absolute_path = File.expand_path(path, @root)
          begin
            real_path = File.realpath(absolute_path)
            if contained?(real_path)
              paths << Pathname.new(real_path).relative_path_from(Pathname.new(@root)).to_s
            end
          rescue Errno::ENOENT, Errno::ENOTDIR
            # References to paths that do not exist are not context pointers.
          end
        end
      end
      built_targets.each do |target|
        directory = File.dirname(target.fetch("path"))
        loop do
          guidance = directory == "." ? "AGENTS.md" : File.join(directory, "AGENTS.md")
          paths << guidance if safe_repository_file?(guidance)
          break if directory == "."

          directory = File.dirname(directory)
        end
      end
      paths.uniq.sort
    end

    def safe_repository_file?(relative_path)
      absolute_path = File.realpath(File.join(@root, relative_path))
      contained?(absolute_path) && File.file?(absolute_path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def explicit_context_path(path)
      begin
        absolute_path = File.realpath(File.expand_path(path, @root))
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.new(
          "missing_file", "context path does not exist: #{path}",
          {"role" => "context", "path" => path}
        )
      end
      unless contained?(absolute_path)
        raise Error.new(
          "outside_repository", "context path is outside the repository: #{path}",
          {"role" => "context", "path" => path}
        )
      end
      Pathname.new(absolute_path).relative_path_from(Pathname.new(@root)).to_s
    end

    def starting_metrics(built_inventory)
      {
        "target_count" => built_inventory.length,
        "word_count" => built_inventory.inject(0) { |sum, item| sum + item.fetch("word_count") },
        "line_count" => built_inventory.inject(0) { |sum, item| sum + item.fetch("line_count") },
        "unresolved_placeholder_count" => built_inventory.inject(0) do |sum, item|
          sum + item.fetch("placeholder_count")
        end
      }
    end
  end
end
