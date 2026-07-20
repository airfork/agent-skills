require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module PromptEngineer
  class RunStore
    class Error < StandardError; end

    ARMS = %w[legacy replacement unassisted].freeze
    DIGEST = /\A[0-9a-f]{64}\z/.freeze
    MAX_RECORD_BYTES = 1_048_576
    MAX_EXPORT_BYTES = 16 * 1_024 * 1_024
    ROOT_MODE = 0o700
    FILE_MODE = 0o600

    attr_reader :root, :run_id

    def self.prepare(run_root: nil, root: nil, **options)
      target = run_root || root
      raise Error, "run root is required" unless target

      new(target).prepare(**options)
    end

    def self.open(root)
      new(root, load_existing: true)
    end

    def initialize(root, load_existing: false)
      @root = File.expand_path(root)
      @mutex = Mutex.new
      @task_index = {}
      @manifest = nil
      @manifest_digest = nil
      load_existing! if load_existing
    end

    def prepare(corpus:, package_root:, qualification_policy:, legacy_lock:, environment: {}, legacy_root: nil)
      refuse_existing_root!
      corpus = normalize_corpus(corpus)
      policy, policy_digest = normalize_policy(qualification_policy)
      lock, lock_digest = normalize_legacy_lock(legacy_lock)
      package_digest = directory_digest(package_root)
      captured_environment = normalize_environment(environment, policy)
      verify_legacy_lock!(lock, legacy_root)
      create_run_root!

      @run_id = "run-#{SecureRandom.uuid}"
      @manifest = build_manifest(
        corpus: corpus,
        policy: policy,
        policy_digest: policy_digest,
        lock_digest: lock_digest,
        package_digest: package_digest,
        environment: captured_environment
      )

      create_layout!
      write_json_exclusive(manifest_path, @manifest)
      @manifest_digest = Digest::SHA256.hexdigest(File.binread(manifest_path))
      create_ledger!
      build_base_dag(corpus).each do |task|
        @task_index.fetch(task.fetch("id"))
        append_event(task.merge("event" => "node_created"))
        write_task_packets(task, corpus)
      end
      self
    rescue Corpus::Error, Contracts::Error, Errno::EEXIST, Errno::ENOENT, Errno::EACCES => error
      raise Error, error.message
    end

    def manifest
      deep_freeze(deep_copy(@manifest))
    end

    def manifest_path
      path("manifest.json")
    end

    def manifest_digest
      @manifest_digest || Digest::SHA256.hexdigest(File.binread(manifest_path))
    end

    def ledger_path
      path("ledger.jsonl")
    end

    def path(*parts)
      relative = parts.flatten.join("/")
      raise Error, "path escape" if relative.start_with?("/") || relative.split("/").include?("..")

      File.join(@root, relative)
    end

    def public_packet(case_id, host, arm, repeat_index: 0, kind: "initial")
      task = task_for(case_id: case_id, host: host, arm: arm, repeat_index: repeat_index, kind: kind)
      read_json(path("packets", "public", "#{task.fetch("id")}.json"))
    end

    def private_packet(case_id, host, arm, repeat_index: 0, kind: "initial")
      task = task_for(case_id: case_id, host: host, arm: arm, repeat_index: repeat_index, kind: kind)
      read_json(path("packets", "private", "#{task.fetch("id")}.json"))
    end

    def pending_tasks
      status = task_statuses
      @task_index.values.select { |task| status.fetch(task.fetch("id"), "pending") == "pending" }.map { |task| deep_copy(task) }
    end

    def claim_next!(worker_id = "operator")
      raise Error, "worker ID is invalid" unless worker_id.is_a?(String) && !worker_id.empty?

      with_ledger_lock do |events|
        raise Error, "run is closed" if closed_events?(events)
        statuses = statuses_from(events)
        task = @task_index.values.find { |candidate| statuses.fetch(candidate.fetch("id"), "pending") == "pending" }
        raise Error, "no pending work" unless task

        lease = task.merge(
          "status" => "leased",
          "worker_id" => worker_id,
          "nonce" => SecureRandom.hex(32),
          "session_id" => "session-#{SecureRandom.uuid}",
          "arm_label" => @manifest.fetch("arm_labels").fetch(task.fetch("arm")),
          "staged_package_digest" => @manifest.fetch("package_digest"),
          "public_task_packet_digest" => task.fetch("public_task_packet_digest"),
          "launch_attestation_digest" => "pending"
        )
        append_event_unlocked(events, lease.merge("event" => "lease_created"))
        deep_freeze(deep_copy(lease))
      end
    end
    alias next! claim_next!
    alias next claim_next!

    def ingest_executor!(record, raw_export: nil)
      PromptEngineer::Provenance.ingest!(store: self, record: record, raw_export: raw_export)
    end

    def close!(reason)
      raise Error, "close reason is required" unless reason.is_a?(String) && !reason.empty?

      with_ledger_lock do |events|
        raise Error, "run is already closed" if closed_events?(events)

        append_event_unlocked(events, {"event" => "run_closed", "reason" => reason, "at" => Time.now.utc.iso8601(6)})
      end
      true
    end

    def closed?
      closed_events?(read_events)
    end

    def ingested_records
      read_events.select { |event| event["event"] == "executor_ingested" }.map do |event|
        read_json(path(event.fetch("record_path")))
      end
    end

    def events
      read_events.map { |event| deep_freeze(deep_copy(event)) }
    end

    # Called only after Provenance has validated the source record. The source
    # export is deliberately not read from a path named by the record.
    def persist_executor_record!(record, raw_export: nil)
      with_ledger_lock do |events|
        raise Error, "run is closed" if closed_events?(events)
        nonce = record.fetch("nonce")
        raise Error, "duplicate nonce" if events.any? { |event| event["event"] == "executor_ingested" && event["nonce"] == nonce }

        record_bytes = PromptEngineer::Canonical.json(record)
        raise Error, "executor record is too large" if record_bytes.bytesize > MAX_RECORD_BYTES
        if raw_export
          raise Error, "raw export is too large" if raw_export.bytesize > MAX_EXPORT_BYTES
        end
        digest = Digest::SHA256.hexdigest(record_bytes)
        relative = File.join("records", "executor", "#{digest}.json")
        write_bytes_exclusive(path(relative), record_bytes)
        append_event_unlocked(events, {
          "event" => "executor_ingested",
          "record_digest" => digest,
          "record_path" => relative,
          "nonce" => nonce,
          "node_id" => record.fetch("node_id", task_for_nonce(events, nonce).fetch("id")),
          "at" => Time.now.utc.iso8601(6)
        })
        digest
      end
    end

    private

    def load_existing!
      raise Error, "run manifest is missing" unless File.file?(manifest_path)

      @manifest = read_json(manifest_path)
      @run_id = @manifest.fetch("run_id")
      @manifest_digest = Digest::SHA256.hexdigest(File.binread(manifest_path))
      @task_index = read_events.each_with_object({}) do |event, tasks|
        tasks[event.fetch("id")] = event.reject { |key, _| key == "event" } if event["event"] == "node_created"
      end
    rescue JSON::ParserError, KeyError, Errno::ENOENT => error
      raise Error, "invalid run store: #{error.message}"
    end

    def refuse_existing_root!
      raise Error, "run root already exists" if File.exist?(@root) || File.symlink?(@root)

      FileUtils.mkdir_p(File.dirname(@root), mode: ROOT_MODE)
    end

    def create_run_root!
      Dir.mkdir(@root, ROOT_MODE)
    rescue Errno::EEXIST
      raise Error, "run root already exists"
    end

    def normalize_corpus(value)
      corpus = value.respond_to?(:tree_digest) ? value : Corpus.load(value)
      raise Error, "corpus is not loaded" unless corpus.respond_to?(:public_case) && corpus.respond_to?(:private_rubric)

      corpus
    end

    def normalize_policy(value)
      source = value.is_a?(Hash) ? deep_copy(value) : Contracts.load_yaml(value)
      if !value.is_a?(Hash)
        schema_path = File.join(File.dirname(File.expand_path(value)), "schemas", "qualification-policy-v1.yml")
        Contracts.validate!(source, Contracts.load_schema(schema_path)) if File.file?(schema_path)
      end
      [source, PromptEngineer::Canonical.digest(source)]
    end

    def normalize_legacy_lock(value)
      lock = value.is_a?(Hash) ? deep_copy(value) : Corpus.load_legacy_lock(value)
      Corpus.send(:validate_lock_shape, lock)
      [lock, PromptEngineer::Canonical.digest(lock)]
    rescue Contracts::Error, KeyError => error
      raise Error, error.message
    end

    def normalize_environment(environment, policy)
      raise Error, "environment must be an object" unless environment.is_a?(Hash)
      allowed = policy.fetch("allowlists").fetch("environment")
      unknown = environment.keys.map(&:to_s) - allowed
      raise Error, "environment contains undeclared keys: #{unknown.join(", ")}" unless unknown.empty?

      environment.each_with_object({}) do |(key, value), output|
        raise Error, "environment keys and values must be strings" unless key.is_a?(String) && value.is_a?(String)

        output[key] = value.dup
      end.sort.to_h
    rescue KeyError, TypeError => error
      raise Error, "environment allowlist is missing: #{error.message}"
    end

    def verify_legacy_lock!(lock, legacy_root)
      return true if lock.fetch("status") == "blocked" && legacy_root.nil?
      raise Error, "pinned legacy lock requires a legacy root" if legacy_root.nil?

      Corpus.verify_legacy_lock(lock, legacy_root)
    rescue Corpus::LegacyLockError => error
      raise Error, error.message
    end

    def build_manifest(corpus:, policy:, policy_digest:, lock_digest:, package_digest:, environment:)
      arm_labels = ARMS.each_with_object({}) do |arm, labels|
        labels[arm] = "arm-#{PromptEngineer::Canonical.digest({"run_id" => @run_id, "arm" => arm})[0, 24]}"
      end
      {
        "schema_version" => 1,
        "run_id" => @run_id,
        "created_at" => Time.now.utc.iso8601(6),
        "corpus_digest" => corpus.tree_digest,
        "corpus_manifest_digest" => corpus.manifest_digest,
        "package_digest" => package_digest,
        "qualification_policy_digest" => policy_digest,
        "legacy_lock_digest" => lock_digest,
        "arm_labels" => arm_labels,
        "environment_allowlist" => policy.fetch("allowlists").fetch("environment"),
        "environment" => environment,
        "paths" => {"homes" => "homes", "outputs" => "outputs", "scratch" => "scratch", "public_packets" => "packets/public", "private_packets" => "packets/private", "records" => "records"},
        "budgets" => {"behavioral" => Budget::BEHAVIORAL_RUNS, "trigger" => Budget::TRIGGER_RUNS, "judge" => Budget::MAX_JUDGE_RUNS, "operator_time_seconds" => Budget::OPERATOR_TIME_SECONDS},
        "dag" => {"initial_count" => 72, "stability_count" => 18, "trigger_count" => 40, "targeted_repeat_count" => 0, "second_judge_count" => 0},
        "expansion_rules" => [
          {"id" => "targeted-repeat-v1", "max_nodes" => Budget::TARGETED_BEHAVIORAL_RUNS, "content_addressed" => true},
          {"id" => "second-judge-v1", "max_nodes" => Budget::CONDITIONAL_JUDGE_RUNS, "content_addressed" => true}
        ],
        "policy_snapshot" => policy
      }
    end

    def create_layout!
      %w[homes outputs scratch packets packets/public packets/private records records/executor].each do |relative|
        FileUtils.mkdir_p(path(relative), mode: ROOT_MODE)
        File.chmod(ROOT_MODE, path(relative))
      end
      @manifest.fetch("arm_labels").each_value do |label|
        Corpus::HOSTS.each do |host|
          FileUtils.mkdir_p(path("homes", label, host), mode: ROOT_MODE)
          File.chmod(ROOT_MODE, path("homes", label, host))
        end
      end
    end

    def create_ledger!
      write_bytes_exclusive(ledger_path, PromptEngineer::Canonical.json({"event" => "prepared", "manifest_digest" => PromptEngineer::Canonical.digest(@manifest), "at" => Time.now.utc.iso8601(6)}))
    end

    def build_base_dag(corpus)
      tasks = []
      corpus.case_ids.each do |case_id|
        Corpus::HOSTS.each do |host|
          ARMS.each { |arm| tasks << task_for_node("initial", case_id, host, arm, 0, nil, corpus) }
        end
      end
      corpus.case_ids.first(3).each do |case_id|
        Corpus::HOSTS.each do |host|
          ARMS.each { |arm| tasks << task_for_node("stability", case_id, host, arm, 1, nil, corpus) }
        end
      end
      corpus.trigger_records.each do |trigger|
        if trigger.fetch("expected_activation")
          Corpus::HOSTS.each { |host| tasks << task_for_node("trigger", nil, host, "replacement", 0, trigger, corpus) }
          tasks << task_for_node("trigger", nil, "codex", "unassisted", 0, trigger, corpus)
        else
          tasks << task_for_node("trigger", nil, "codex", "unassisted", 0, trigger, corpus)
          tasks << task_for_node("trigger", nil, "claude", "unassisted", 0, trigger, corpus)
        end
      end
      raise Error, "base DAG count is not frozen" unless tasks.length == 130

      tasks
    end

    def task_for_node(kind, case_id, host, arm, repeat_index, trigger, corpus)
      binding = {"kind" => kind, "case_id" => case_id, "host" => host, "arm" => arm, "repeat_index" => repeat_index, "trigger_id" => trigger && trigger.fetch("id")}
      id = "node-#{PromptEngineer::Canonical.digest(binding)[0, 32]}"
      public_payload = if trigger
        {"kind" => "trigger", "trigger_id" => trigger.fetch("id"), "prompt" => trigger.fetch("prompt"), "expected_activation" => trigger.fetch("expected_activation"), "arm_label" => @manifest.fetch("arm_labels").fetch(arm), "host" => host}
      else
        {"kind" => kind, "case" => corpus.public_case(case_id), "arm_label" => @manifest.fetch("arm_labels").fetch(arm), "host" => host, "repeat_index" => repeat_index}
      end
      public_digest = PromptEngineer::Canonical.digest(public_payload)
      task = binding.merge("id" => id, "public_task_packet_digest" => public_digest)
      task["expected_activation"] = trigger.fetch("expected_activation") if trigger
      @task_index[id] = task
      task
    end

    def write_task_packets(task, corpus)
      node_id = task.fetch("id")
      public_payload = if task.fetch("case_id")
        {"kind" => task.fetch("kind"), "case" => corpus.public_case(task.fetch("case_id")), "arm_label" => @manifest.fetch("arm_labels").fetch(task.fetch("arm")), "host" => task.fetch("host"), "repeat_index" => task.fetch("repeat_index")}
      else
        trigger = corpus.trigger_records.find { |candidate| candidate.fetch("id") == task.fetch("trigger_id") }
        {"kind" => "trigger", "trigger_id" => trigger.fetch("id"), "prompt" => trigger.fetch("prompt"), "expected_activation" => trigger.fetch("expected_activation"), "arm_label" => @manifest.fetch("arm_labels").fetch(task.fetch("arm")), "host" => task.fetch("host")}
      end
      private_payload = task.fetch("case_id") ? {"case_id" => task.fetch("case_id"), "arm" => task.fetch("arm"), "rubric" => corpus.private_rubric(task.fetch("case_id"))} : {"trigger_id" => task.fetch("trigger_id"), "arm" => task.fetch("arm"), "expected_activation" => task.fetch("expected_activation", false)}
      write_json_exclusive(path("packets", "public", "#{node_id}.json"), public_payload)
      write_json_exclusive(path("packets", "private", "#{node_id}.json"), private_payload)
      task["public_packet_path"] = File.join("packets", "public", "#{node_id}.json")
      task["private_packet_path"] = File.join("packets", "private", "#{node_id}.json")
      task["output_path"] = File.join("outputs", node_id)
      task["scratch_path"] = File.join("scratch", node_id)
      task["public_task_packet_digest"] = PromptEngineer::Canonical.digest(public_payload)
      @task_index[node_id] = task
    end

    def task_for(case_id:, host:, arm:, repeat_index:, kind:)
      @task_index.values.find do |task|
        task["case_id"] == case_id && task["host"] == host && task["arm"] == arm && task["repeat_index"] == repeat_index && task["kind"] == kind
      end || (raise Error, "unknown task")
    end

    def task_for_nonce(events, nonce)
      event = events.reverse.find { |candidate| candidate["event"] == "lease_created" && candidate["nonce"] == nonce }
      raise Error, "unknown lease nonce" unless event

      event
    end

    def task_statuses
      statuses_from(read_events)
    end

    def statuses_from(events)
      statuses = {}
      events.each do |event|
        case event["event"]
        when "lease_created" then statuses[event.fetch("id")] = "leased"
        when "executor_ingested" then statuses[event.fetch("node_id")] = "ingested"
        end
      end
      statuses
    end

    def closed_events?(events)
      events.any? { |event| event["event"] == "run_closed" }
    end

    def read_events
      return [] unless File.file?(ledger_path)

      File.binread(ledger_path).lines.reject(&:empty?).map { |line| JSON.parse(line) }
    rescue JSON::ParserError, Errno::ENOENT => error
      raise Error, "invalid run ledger: #{error.message}"
    end

    def with_ledger_lock
      @mutex.synchronize do
        File.open(ledger_path, "r+b") do |file|
          file.flock(File::LOCK_EX)
          events = file.read.lines.reject(&:empty?).map { |line| JSON.parse(line) }
          result = yield(events)
          file.flock(File::LOCK_UN)
          result
        end
      end
    rescue JSON::ParserError, Errno::ENOENT => error
      raise Error, "invalid run ledger: #{error.message}"
    end

    def append_event(event)
      with_ledger_lock { |events| append_event_unlocked(events, event) }
    end

    def append_event_unlocked(_events, event)
      bytes = PromptEngineer::Canonical.json(event)
      File.open(ledger_path, "ab", FILE_MODE) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      fsync_directory(File.dirname(ledger_path))
      true
    end

    def write_json_exclusive(target, value)
      write_bytes_exclusive(target, PromptEngineer::Canonical.json(value))
    end

    def write_bytes_exclusive(target, bytes)
      raise Error, "bytes must be binary data" unless bytes.is_a?(String)

      FileUtils.mkdir_p(File.dirname(target), mode: ROOT_MODE)
      temporary = "#{target}.tmp-#{SecureRandom.hex(8)}"
      File.open(temporary, "wb", FILE_MODE) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      raise Error, "target already exists" if File.exist?(target)

      File.rename(temporary, target)
      fsync_directory(File.dirname(target))
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def read_json(target)
      JSON.parse(File.binread(target))
    rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => error
      raise Error, "invalid stored JSON: #{error.message}"
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def fsync_directory(directory)
      File.open(directory, "r") { |file| file.fsync }
    rescue SystemCallError
      raise Error, "directory fsync is unavailable"
    end

    def directory_digest(root)
      expanded = File.expand_path(root)
      reject_symlink_tree!(expanded)
      raise Error, "package root is not a directory" unless File.directory?(expanded)
      before = tree_identity(expanded)
      digest = Digest::SHA256.new
      files = Dir.glob(File.join(expanded, "**", "*")).select { |path| File.file?(path) }.map { |path| path.sub(%r{\A#{Regexp.escape(expanded)}/?}, "") }.sort_by(&:b)
      files.each do |relative|
        path = File.join(expanded, relative)
        first = File.lstat(path)
        bytes = File.binread(path)
        second = File.lstat(path)
        raise Error, "package changed during digest" unless identity(first) == identity(second)
        digest.update(relative.encode("UTF-8"))
        digest.update("\0")
        digest.update(bytes)
        digest.update("\0")
      end
      raise Error, "package tree changed during digest" unless before == tree_identity(expanded)
      digest.hexdigest
    rescue Errno::ENOENT, Errno::EACCES => error
      raise Error, error.message
    end

    def reject_symlink_tree!(root)
      raise Error, "package root is symlinked" if File.symlink?(root)
      raise Error, "package root has symlinked ancestor" unless File.realpath(root) == root
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next if [".", ".."].include?(File.basename(path))
        raise Error, "package contains symlink" if File.symlink?(path)
      end
    end

    def tree_identity(root)
      ([root] + Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)).reject { |path| [".", ".."].include?(File.basename(path)) }.sort_by(&:b).map do |path|
        stat = File.lstat(path)
        [path.sub(%r{\A#{Regexp.escape(root)}/?}, "."), identity(stat)]
      end
    end

    def identity(stat)
      [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime.to_f, stat.nlink]
    end
  end
end
