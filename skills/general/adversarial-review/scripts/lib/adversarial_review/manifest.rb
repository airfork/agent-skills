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
    ULTRA_INCOMPATIBLE_EXECUTORS = %w[codex cursor gemini].freeze

    COMMON_TASKS = %w[tester assumptions-checker pre-mortem consistency-smells].freeze
    USER_SCOPE_BYTES = 65_536
    USER_ACTOR = /(?:end[- ]?users?|users?|operators?|customers?|administrators?|admins?)/i.freeze
    USER_BEHAVIOR = /(?:
      can|may|must|shall|should|will|
      receives?|sees?|runs?|uses?|opens?|views?|reviews?|gets?|experiences?|recovers?|
      configures?|submits?|creates?|updates?|deletes?|downloads?|uploads?|
      navigates?|completes?|starts?|stops?|retries?|chooses?|selects?|enters?|
      (?:is|are)\s+(?:shown|given|prompted|redirected|notified|warned|blocked|allowed)
    )/ix.freeze
    USER_BEHAVIOR_QUALIFIER = /(?:facing|visible|workflow|journey|experience|actions?|errors?|recovery|setup)/i.freeze

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
      MAX_HEADING_ENTRIES = 32
      MAX_REQUIREMENT_ENTRIES = 32
      MAX_TASK_ENTRIES = 32
      MAX_PATH_ENTRIES = 32
      MAX_COMMAND_ENTRIES = 32
      MAX_PLACEHOLDER_ENTRIES = 32
      MAX_ENTRY_CHARS = 160
      MAX_RENDERED_CHARS = 16_384

      def self.build(role, path, contents)
        new(role, path, contents).build
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
            closing_fence = /\A {0,3}#{Regexp.escape(fence_character)}{#{fence_length},}[ \t]*\r?\n?\z/
            if line.match?(closing_fence)
              fence_character = nil
              fence_length = nil
              next
            end
            candidate = line.strip
            commands << bounded_text(candidate) if command?(candidate)
            next
          end

          opening_fence = line.match(/\A {0,3}(`{3,}|~{3,})/)
          if opening_fence
            fence_character = opening_fence[1][0]
            fence_length = opening_fence[1].length
            next
          end

          heading = line.match(/\A\s*(\#{1,6})\s+(.+?)\s*\#*\s*\z/)
          if heading
            level = heading[1].length
            ancestry = ancestry.first(level - 1)
            ancestry[level - 1] = bounded_text(heading[2])
            headings << [line_number, bounded_text(ancestry.compact.join(" > "))]
          end

          line.scan(REQUIREMENT) { |label| requirements << [bounded_text(label), line_number] }
          line.scan(TASK) { |label| tasks << [bounded_text(label), line_number] }
          line.scan(/`([^`\n]+)`/) do |match|
            value = match.first.strip
            paths << bounded_text(value) if path_like?(value)
            commands << bounded_text(value) if command?(value)
          end
          line.to_enum(:scan, PLACEHOLDER).each do
            match = Regexp.last_match
            placeholders << {
              "kind" => placeholder_kind(match[0])[0, PLACEHOLDER_DISPLAY_LIMIT],
              "line" => line_number
            }
          end
        end

        retained_headings, heading_counts = retain(headings, MAX_HEADING_ENTRIES)
        retained_requirements, requirement_counts = retain(
          requirements, MAX_REQUIREMENT_ENTRIES
        )
        retained_tasks, task_counts = retain(tasks, MAX_TASK_ENTRIES)
        retained_paths, path_counts = retain(paths.uniq.sort, MAX_PATH_ENTRIES)
        retained_commands, command_counts = retain(commands.uniq.sort, MAX_COMMAND_ENTRIES)
        retained_placeholders, placeholder_counts = retain(
          placeholders, MAX_PLACEHOLDER_ENTRIES
        )
        entry_counts = {
          "headings" => heading_counts,
          "requirements" => requirement_counts,
          "tasks" => task_counts,
          "paths" => path_counts,
          "commands" => command_counts,
          "placeholders" => placeholder_counts
        }
        markdown = render(
          retained_headings, retained_requirements, retained_tasks,
          retained_paths, retained_commands, retained_placeholders, entry_counts
        )
        {
          "role" => @role,
          "path" => @path,
          "markdown" => markdown,
          "word_count" => @contents.scan(/\b[[:alnum:]_'-]+\b/).length,
          "line_count" => @contents.lines.length,
          "placeholder_count" => placeholders.length,
          "unresolved_placeholders" => retained_placeholders,
          "referenced_paths" => retained_paths,
          "entry_counts" => entry_counts
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

      def bounded_text(value)
        redacted = value.gsub(PLACEHOLDER) { |match| "<#{placeholder_kind(match)}>" }
        return redacted if redacted.length <= MAX_ENTRY_CHARS

        marker = "...[truncated]"
        redacted[0, MAX_ENTRY_CHARS - marker.length] + marker
      end

      def retain(entries, limit)
        retained = entries.first(limit)
        [
          retained,
          {
            "total_count" => entries.length,
            "retained_count" => retained.length,
            "truncated" => entries.length > retained.length
          }
        ]
      end

      def render(headings, requirements, tasks, paths, commands, placeholders, entry_counts)
        lines = ["### #{@role}: `#{@path}`"]
        lines << "#### Inventory entry counts"
        entry_counts.each do |name, counts|
          suffix = counts.fetch("truncated") ? " (truncated)" : ""
          lines << "- #{name}: #{counts.fetch("retained_count")}/#{counts.fetch("total_count")}#{suffix}"
        end
        append_entries(lines, "Headings", headings.map { |line, name| "L#{line} #{name}" })
        append_entries(lines, "Requirements", requirements.map { |label, line| "#{label} (L#{line})" })
        append_entries(lines, "Tasks", tasks.map { |label, line| "#{label} (L#{line})" })
        append_entries(lines, "Paths", paths.map { |path| "`#{path}`" })
        append_entries(lines, "Commands", commands.map { |command| "`#{command}`" })
        placeholder_entries = placeholders.map do |entry|
          "#{entry.fetch("kind")} (L#{entry.fetch("line")})"
        end
        append_entries(lines, "Unresolved placeholders", placeholder_entries)
        total_placeholders = entry_counts.fetch("placeholders").fetch("total_count")
        lines << "- Unresolved placeholder count: #{total_placeholders}"
        lines << "- Words: #{@contents.scan(/\b[[:alnum:]_'-]+\b/).length}"
        lines << "- Lines: #{@contents.lines.length}"
        bound_rendered(lines.join("\n"))
      end

      def bound_rendered(markdown)
        return markdown if markdown.length <= MAX_RENDERED_CHARS

        marker = "\n...[inventory truncated]"
        markdown[0, MAX_RENDERED_CHARS - marker.length] + marker
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
      validate_compatible_options

      @root = repository_root
      snapshots = target_snapshots
      built_targets = snapshots.map { |snapshot| snapshot.fetch("target") }
      built_inventory = snapshots.map { |snapshot| snapshot.fetch("inventory") }
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
        "enabled_tasks" => enabled_tasks(snapshots),
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

    def validate_compatible_options
      return unless @tier == "ultra" && ULTRA_INCOMPATIBLE_EXECUTORS.include?(@executor)

      raise Error.new(
        "incompatible_options", "ultra requires Claude or a portable execution route",
        {"tier" => @tier, "executor" => @executor}
      )
    end

    def run_id
      "ar-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}-#{SecureRandom.hex(4)}"
    end

    def repository_root
      repository = File.expand_path(@repository)
      output, status = run_git(repository, "rev-parse", "--show-toplevel")
      unless status.success? && !output.strip.empty?
        raise Error.new(
          "repository_root_unresolved", "could not resolve Git repository root",
          {
            "repository" => repository,
            "context" => "repository_root",
            "command" => ["git", "-C", repository, "rev-parse", "--show-toplevel"]
          }
        )
      end
      File.realpath(output.strip)
    end

    def repository_metadata
      head = required_git("repository_head", true, "rev-parse", "HEAD")
      status_output = required_git(
        "repository_status", false, "status", "--porcelain=v1", "--untracked-files=all"
      )
      status_lines = status_output.lines.map(&:chomp)
      {
        "root" => @root,
        "head" => head.strip,
        "dirty" => !status_lines.empty?,
        "status" => status_lines
      }
    end

    def required_git(context, require_output, *arguments)
      output, status = run_git(@root, *arguments)
      return output if status.success? && (!require_output || !output.strip.empty?)

      raise Error.new(
        "git_command_failed", "Git metadata command failed: #{context}",
        {
          "context" => context,
          "arguments" => arguments,
          "command" => ["git", "-C", @root] + arguments
        }
      )
    end

    def run_git(directory, *arguments)
      command = ["git", "-C", directory] + arguments
      begin
        Open3.capture2e(*command)
      rescue SystemCallError => error
        raise Error.new(
          "git_error", "could not start Git command",
          {
            "context" => "git_spawn",
            "command" => command,
            "errno" => error.errno
          }
        )
      end
    end

    def target_snapshots
      result = [["spec", @spec], ["plan", @plan]].each_with_object([]) do |(role, path), items|
        next unless path

        items << read_target_snapshot(role, path)
      end
      same_file = result.length == 2 &&
                  result[0].fetch("identity") == result[1].fetch("identity")
      if same_file
        raise Error.new(
          "ambiguous_role", "one file cannot serve as both spec and plan",
          {"path" => result[0].fetch("target").fetch("path"), "roles" => %w[spec plan]}
        )
      end
      result
    end

    def read_target_snapshot(role, path)
      absolute_path, relative_path, expected_stat = canonical_target(role, path)
      before_target_open(role, path, absolute_path)
      # BINARY: this content is digested, so it must be the file's real bytes.
      # Text mode would strip \r on some hosts and record a digest that
      # matches no actual file.
      flags = File::RDONLY | Atomic::BINARY_FLAG
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      begin
        File.open(absolute_path, flags) do |file|
          opened_stat = file.stat
          unless opened_stat.file? && same_identity?(expected_stat, opened_stat)
            raise target_changed_error(role, path)
          end
          contents = file.read
          {
            "target" => {
              "role" => role,
              "path" => relative_path,
              "sha256" => Digest::SHA256.hexdigest(contents)
            },
            "inventory" => Inventory.build(role, relative_path, contents),
            "user_or_operator_scope" => user_or_operator_scope_text?(contents),
            "identity" => [opened_stat.dev, opened_stat.ino]
          }
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise target_changed_error(role, path)
      rescue Errno::EACCES, Errno::EPERM, Errno::EIO
        raise Error.new(
          "target_unreadable", "#{role} target could not be read: #{path}",
          {"role" => role, "path" => path}
        )
      end
    end

    def canonical_target(role, path)
      expanded_path = File.expand_path(path, @root)
      begin
        absolute_path = File.realpath(expanded_path)
        expected_stat = File.stat(absolute_path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.new(
          "missing_file", "#{role} file does not exist: #{path}",
          {"role" => role, "path" => path}
        )
      rescue Errno::ELOOP, Errno::EACCES, Errno::EPERM, Errno::ENAMETOOLONG
        raise Error.new(
          "invalid_path", "#{role} path could not be resolved: #{path}",
          {"role" => role, "path" => path}
        )
      end
      unless contained?(absolute_path)
        raise Error.new(
          "outside_repository", "#{role} path is outside the repository: #{path}",
          {"role" => role, "path" => path}
        )
      end
      unless expected_stat.file?
        raise Error.new(
          "target_unreadable", "#{role} target is not a regular file: #{path}",
          {"role" => role, "path" => path}
        )
      end
      relative_path = Pathname.new(absolute_path).relative_path_from(Pathname.new(@root)).to_s
      [absolute_path, relative_path, expected_stat]
    end

    def before_target_open(_role, _path, _absolute_path)
      nil
    end

    # Hosts that cannot supply comparable inode identity across a path stat and a
    # handle stat get the size/mtime comparison instead; Atomic.guarantees
    # reports `inode_identity` false so the weaker check is declared.
    def same_identity?(left, right)
      return left.size == right.size && left.mtime == right.mtime unless Atomic::INODE_IDENTITY

      left.dev == right.dev && left.ino == right.ino
    end

    def target_changed_error(role, path)
      Error.new(
        "target_changed", "#{role} target changed while the manifest was built: #{path}",
        {"role" => role, "path" => path}
      )
    end

    def contained?(path)
      path == @root || path.start_with?(@root + File::SEPARATOR)
    end

    def enabled_tasks(snapshots)
      tasks = []
      tasks << "implementer" if @spec
      tasks << "tester"
      tasks << "user" if snapshots.any? { |snapshot| snapshot.fetch("user_or_operator_scope") }
      tasks.concat(%w[assumptions-checker pre-mortem consistency-smells])
      tasks << "feasibility" if @plan
      tasks << "traceability" if @spec && @plan
      if @spec && %w[high ultra].include?(@tier)
        tasks.concat(%w[divergence-probe-1 divergence-probe-2 divergence-probe-3])
      end
      tasks
    end

    def user_or_operator_scope_text?(contents)
      bounded = contents.byteslice(0, USER_SCOPE_BYTES).to_s.scrub
      visible = []
      fence_character = nil
      fence_length = nil
      bounded.lines.each do |line|
        if fence_character
          if line.match?(/\A {0,3}#{Regexp.escape(fence_character)}{#{fence_length},}[ \t]*\r?\n?\z/)
            fence_character = nil
            fence_length = nil
          end
          next
        end
        next if line.start_with?("\t") || line.match?(/\A {4}/)

        opening = line.match(/\A {0,3}(`{3,}|~{3,})/)
        if opening
          fence_character = opening[1][0]
          fence_length = opening[1].length
          next
        end
        visible << line.gsub(/(`+)[^`\n]*\1/, " ")
      end
      prose = visible.join
      actor_behavior = /\b(?:the|a|an|each|every)?\s*#{USER_ACTOR.source}\b\s+#{USER_BEHAVIOR.source}\b/ix
      qualified_behavior = /\b#{USER_ACTOR.source}[- ]#{USER_BEHAVIOR_QUALIFIER.source}\b/i
      explicit_behavior = /\b(?:genuine|actual|real|concrete|expected|documented)\s+#{USER_ACTOR.source}[- ]?#{USER_BEHAVIOR_QUALIFIER.source}\b/i
      prose.match?(actor_behavior) || prose.match?(qualified_behavior) || prose.match?(explicit_behavior)
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
          rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP,
                 Errno::EACCES, Errno::EPERM, Errno::ENAMETOOLONG
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
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP,
           Errno::EACCES, Errno::EPERM, Errno::ENAMETOOLONG
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
      rescue Errno::ELOOP, Errno::EACCES, Errno::EPERM, Errno::ENAMETOOLONG
        raise Error.new(
          "invalid_path", "context path could not be resolved: #{path}",
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
