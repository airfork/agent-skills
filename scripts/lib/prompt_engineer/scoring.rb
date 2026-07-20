require "digest"

module PromptEngineer
  module Scoring
    class Error < StandardError; end

    DIMENSIONS = PromptEngineer::Corpus::SCORING_MAXIMA.keys.freeze
    PRIMARY_DIMENSIONS = %w[task_success requirement_preservation].freeze
    ARMS = %w[unassisted legacy replacement].freeze
    RELEASE_DECISIONS = %w[QUALIFIED_EXPLICIT QUALIFIED_IMPLICIT NOT_QUALIFIED INCONCLUSIVE].freeze
    STABILITY_SESSION_CAP = 18
    TARGETED_SESSION_CAP = 6

    class MaskedPacket
      attr_reader :document, :rubric, :label_map, :packet_digest,
                  :private_rubric_digest, :masked_label_map_digest

      def initialize(document, rubric, label_map)
        @document = deep_freeze(deep_copy(document))
        @rubric = deep_freeze(deep_copy(rubric))
        @label_map = deep_freeze(deep_copy(label_map))
        @packet_digest = @document.fetch("packet_digest")
        @private_rubric_digest = @document.fetch("private_rubric_digest")
        @masked_label_map_digest = @document.fetch("masked_label_map_digest")
        freeze
      end

      def fetch(key, *arguments)
        @document.fetch(key, *arguments)
      end

      def [](key)
        @document[key]
      end

      def key?(key)
        @document.key?(key)
      end

      def to_h
        Scoring.send(:deep_copy, @document)
      end

      def to_json(*arguments)
        @document.to_json(*arguments)
      end

      private

      def deep_copy(value)
        Scoring.send(:deep_copy, value)
      end

      def deep_freeze(value)
        Scoring.send(:deep_freeze, value)
      end
    end

    module_function

    def build_judge_packet(run_id:, case_id:, host:, repeat_index:, seed:, public_case:, rubric:, executor_records:)
      raise Error, "run ID is required" unless string_value?(run_id)
      raise Error, "case ID is invalid" unless case_id == public_case.fetch("case_id")
      raise Error, "host is unsupported" unless Corpus::HOSTS.include?(host)
      raise Error, "repeat index is invalid" unless repeat_index.is_a?(Integer) && repeat_index >= 0
      raise Error, "mask seed is required" unless string_value?(seed)

      normalized_rubric = normalize_rubric(rubric)
      records = normalize_executor_records(executor_records, run_id, case_id, host, repeat_index)
      labels = deterministic_labels(records.map { |record| record.fetch("arm") }, seed, run_id, case_id, host, repeat_index)
      outputs = records.map do |record|
        {
          "label" => labels.fetch(record.fetch("arm")),
          "messages" => visible_messages(record),
          "tool_events" => normalized_tool_events(record),
          "final_status" => record.fetch("final_status"),
          "metrics" => metrics(record)
        }
      end.sort_by { |output| output.fetch("label").bytes }

      document = {
        "schema_version" => 1,
        "packet_id" => "packet-#{Canonical.digest({"run_id" => run_id, "case_id" => case_id, "host" => host, "repeat_index" => repeat_index})[0, 32]}",
        "run_id" => run_id,
        "case_id" => case_id,
        "host" => host,
        "repeat_index" => repeat_index,
        "task" => public_task(public_case),
        "rubric" => normalized_rubric,
        "private_rubric_digest" => Canonical.digest(rubric),
        "masked_label_map_digest" => Canonical.digest(labels),
        "output_labels" => outputs.map { |output| output.fetch("label") },
        "outputs" => outputs
      }
      document["packet_digest"] = Canonical.digest(document)
      MaskedPacket.new(document, normalized_rubric, labels)
    rescue KeyError, TypeError => error
      raise Error, "malformed judge packet input: #{error.message}"
    end
    alias mask_packet build_judge_packet

    def ingest_judge_result!(result, packet:)
      raise Error, "judge result must be an object" unless result.is_a?(Hash)
      raise Error, "arm identity must not be supplied by a masked judge" if result.key?("arm") || result.key?("arm_guess") || result.key?("arm_label_map")
      raise Error, "masked packet digest does not match" unless result.fetch("masked_packet_digest") == packet.packet_digest
      raise Error, "private rubric digest does not match" unless result.fetch("private_rubric_digest") == packet.private_rubric_digest
      raise Error, "packet ID does not match" unless result.fetch("packet_id") == packet.document.fetch("packet_id")
      raise Error, "run ID does not match" unless result.fetch("run_id") == packet.document.fetch("run_id")
      raise Error, "output labels do not match" unless result.fetch("output_labels") == packet.document.fetch("output_labels")
      result.fetch("rubric_dimensions").each do |dimension|
        ids = dimension.fetch("point_results").map { |point| point.fetch("point_id") }
        raise Error, "duplicate point results for #{dimension.fetch("dimension")}" unless ids.uniq.length == ids.length
      end
      Contracts.validate_judge_result!(result, {"rubric_points" => packet.rubric.fetch("rubric_points")})
      deep_freeze(deep_copy(result))
    rescue Contracts::Error, KeyError, TypeError => error
      raise Error, "invalid judge result: #{error.message}"
    end

    def reconcile_judges(results, packet:)
      raise Error, "one or two judges are required" unless results.is_a?(Array) && (1..2).include?(results.length)
      validated = results.map { |result| ingest_judge_result!(result, packet: packet) }
      scores = DIMENSIONS.each_with_object({}) do |dimension, output|
        output[dimension] = validated.map { |result| result.fetch("scores").fetch(dimension) }.min
      end
      material_uncertainty = validated.any? { |result| material_uncertainty?(result) }
      disagreement = validated.length == 2 && validated[0].fetch("scores") != validated[1].fetch("scores")
      selected = if validated.length == 1
        "first"
      elsif validated[0].fetch("scores") == validated[1].fetch("scores")
        "tie"
      elsif validated[1].fetch("scores").values.sum < validated[0].fetch("scores").values.sum
        "second"
      else
        "first"
      end
      {
        "packet_id" => packet.document.fetch("packet_id"),
        "scores" => scores,
        "status" => material_uncertainty ? "inconclusive" : "scored",
        "judge_count" => validated.length,
        "judge_disagreement" => disagreement,
        "selected_judge" => selected
      }
    end

    def near_boundary?(replacement, legacy)
      PRIMARY_DIMENSIONS.any? do |dimension|
        (replacement.fetch(dimension).to_i - legacy.fetch(dimension).to_i).abs <= 1
      end
    end

    def select_repeats(rows, corpus_digest:, stability_case_ids: [])
      raise Error, "corpus digest is invalid" unless corpus_digest =~ /\A[0-9a-f]{64}\z/
      raise Error, "repeat candidates must be an array" unless rows.is_a?(Array)
      ordered = rows.map { |row| deep_copy(row) }.sort_by do |row|
        priority = row.fetch("zero_tolerance_uncertain", false) ? 0 : (row.fetch("requirement_uncertain", false) ? 1 : 2)
        margin = primary_margin(row)
        [priority, margin, Canonical.digest({"corpus_digest" => corpus_digest, "host" => row.fetch("host"), "case_id" => row.fetch("case_id")})]
      end
      stable = stability_case_ids.map(&:to_s).uniq.sort_by do |case_id|
        Canonical.digest({"corpus_digest" => corpus_digest, "case_id" => case_id})
      end.first(3)
      {
        "stability_case_ids" => stable,
        "stability_session_cap" => STABILITY_SESSION_CAP,
        "targeted_session_cap" => TARGETED_SESSION_CAP,
        "targeted_candidates" => ordered,
        "selected" => ordered.first(2)
      }
    rescue KeyError, TypeError => error
      raise Error, "malformed repeat candidate: #{error.message}"
    end

    def release_decision(evidence)
      evidence = deep_copy(evidence)
      hosts = Corpus::HOSTS
      status = evidence.fetch("host_status", {})
      return decision_payload("INCONCLUSIVE", "unsupported host adapter", evidence) unless hosts.all? { |host| status[host] == "supported" }
      return decision_payload("NOT_QUALIFIED", "zero-tolerance failure", evidence) unless Array(evidence["zero_tolerance_failures"]).empty?
      return decision_payload("INCONCLUSIVE", "unresolved comparison", evidence) unless Array(evidence["inconclusives"]).empty?

      comparisons = comparable_comparisons(evidence.fetch("comparisons"), hosts)
      return decision_payload("INCONCLUSIVE", "fixed host/case denominator is incomplete", evidence) unless complete_comparison_set?(comparisons, hosts)

      aggregate = aggregate_scores(comparisons, hosts)
      outcomes = comparisons.map { |comparison| comparison_outcome(comparison) }
      losses = outcomes.count { |outcome| outcome == "loss" }
      large_loss = comparisons.any? { |comparison| primary_loss(comparison) > 1 }
      return decision_payload("NOT_QUALIFIED", "replacement loses the frozen release gate", evidence, aggregate: aggregate, outcomes: outcomes) if losses > 4 || large_loss
      return decision_payload("NOT_QUALIFIED", "aggregate score gate failed", evidence, aggregate: aggregate, outcomes: outcomes) unless aggregate_gate?(aggregate, hosts)
      return decision_payload("NOT_QUALIFIED", "efficiency gate failed", evidence, aggregate: aggregate, outcomes: outcomes) unless efficiency_gate?(evidence.fetch("efficiency"))
      return decision_payload("NOT_QUALIFIED", "explicit trigger gate failed", evidence, aggregate: aggregate, outcomes: outcomes) unless explicit_trigger_gate?(evidence)
      decision_payload("QUALIFIED_EXPLICIT", "all explicit release gates passed", evidence, aggregate: aggregate, outcomes: outcomes)
    rescue KeyError, TypeError => error
      raise Error, "malformed release evidence: #{error.message}"
    end

    def score(result, packet: nil)
      validated = packet ? ingest_judge_result!(result, packet: packet) : result
      validated.fetch("scores").dup
    end

    def normalize_rubric(rubric)
      source = rubric.fetch("rubric_points", rubric)
      raise Error, "rubric dimensions are not frozen" unless source.is_a?(Hash) && source.keys.sort == DIMENSIONS.sort
      normalized = {}
      source.each do |dimension, points|
        if points.is_a?(Integer)
          normalized[dimension] = {dimension => points}
        elsif points.is_a?(Hash) && points.keys.all? { |point_id| point_id.is_a?(String) } && points.values.all? { |weight| weight.is_a?(Integer) && weight >= 0 }
          normalized[dimension] = points.sort.to_h
        else
          raise Error, "rubric points are malformed for #{dimension}"
        end
      end
      {
        "rubric_points" => normalized,
        "prohibited_behaviors" => Array(rubric["prohibited_behaviors"]).map(&:to_s).sort,
        "zero_tolerance_gates" => Array(rubric["zero_tolerance_gates"]).map(&:to_s).sort,
        "judge_instructions" => rubric.fetch("judge_instructions", "Score only observable output evidence.").to_s
      }
    end

    def normalize_executor_records(records, run_id, case_id, host, repeat_index)
      raise Error, "exactly one record per arm is required" unless records.is_a?(Array) && records.length == ARMS.length
      arms = records.map { |record| record.fetch("arm") }
      raise Error, "executor arms are incomplete" unless arms.uniq.sort == ARMS.sort
      records.each do |record|
        raise Error, "executor run binding mismatch" unless record.fetch("run_id") == run_id && record.fetch("case_id") == case_id && record.fetch("host") == host && record.fetch("repeat_index") == repeat_index
        raise Error, "executor messages are missing" unless record.fetch("messages").is_a?(Array)
      end
      records.map { |record| deep_copy(record) }.sort_by { |record| record.fetch("arm") }
    rescue KeyError, TypeError => error
      raise Error, "malformed executor record: #{error.message}"
    end
    private_class_method :normalize_executor_records

    def deterministic_labels(arms, seed, run_id, case_id, host, repeat_index)
      arms.sort_by do |arm|
        Canonical.digest({"seed" => seed, "run_id" => run_id, "case_id" => case_id, "host" => host, "repeat_index" => repeat_index, "arm" => arm})
      end.each_with_index.each_with_object({}) do |(arm, index), labels|
        labels[arm] = "variant-#{(97 + index).chr}"
      end.sort.to_h
    end
    private_class_method :deterministic_labels

    def public_task(public_case)
      allowed = %w[case_id title task prompt_context public_requirements required_host_configuration allowed_tools time_budget profile primary_dimension host_coverage safety_classification]
      allowed.each_with_object({}) { |key, task| task[key] = deep_copy(public_case.fetch(key)) if public_case.key?(key) }.sort.to_h
    rescue KeyError => error
      raise Error, "public task is incomplete: #{error.message}"
    end
    private_class_method :public_task

    def visible_messages(record)
      record.fetch("messages").map do |message|
        {"ordinal" => message.fetch("ordinal"), "channel" => message.fetch("channel"), "text" => message.fetch("text").to_s}
      end
    end
    private_class_method :visible_messages

    def normalized_tool_events(record)
      record.fetch("tool_events", []).map do |event|
        {"ordinal" => event.fetch("ordinal"), "tool" => event.fetch("tool").to_s, "status" => event.fetch("status").to_s}
      end
    end
    private_class_method :normalized_tool_events

    def metrics(record)
      assistant = record.fetch("messages").select { |message| message.fetch("channel") == "assistant" }
      final_text = assistant.last ? assistant.last.fetch("text").to_s : ""
      {
        "visible_assistant_characters" => assistant.sum { |message| message.fetch("text").to_s.length },
        "final_answer_characters" => final_text.length,
        "elapsed_seconds" => elapsed_seconds(record),
        "tool_calls" => record.fetch("tool_events", []).length,
        "model_turns" => record.fetch("model_turns", assistant.length),
        "user_interruptions" => record.fetch("user_interruptions", 0),
        "unnecessary_mutation" => record.fetch("unnecessary_mutation", false)
      }
    end
    private_class_method :metrics

    def elapsed_seconds(record)
      started = Time.iso8601(record.fetch("timestamps").fetch("started_at"))
      ended = Time.iso8601(record.fetch("timestamps").fetch("ended_at"))
      value = ended - started
      raise Error, "executor timestamps are invalid" if value < 0

      value
    rescue ArgumentError, KeyError, TypeError => error
      raise Error, "executor timestamps are invalid: #{error.message}"
    end
    private_class_method :elapsed_seconds

    def material_uncertainty?(result)
      result.fetch("uncertainty").fetch("classification") == "material" || result.fetch("rubric_dimensions").any? do |dimension|
        dimension.fetch("point_results").any? { |point| point.fetch("status") == "uncertain" }
      end
    end
    private_class_method :material_uncertainty?

    def comparable_comparisons(comparisons, hosts)
      raise Error, "comparisons must be an array" unless comparisons.is_a?(Array)
      comparisons.select { |comparison| hosts.include?(comparison.fetch("host")) && comparison.fetch("status") == "comparable" }
    end
    private_class_method :comparable_comparisons

    def complete_comparison_set?(comparisons, hosts)
      expected = hosts.flat_map { |host| Corpus::CASE_IDS.map { |case_id| [host, case_id] } }
      actual = comparisons.map { |comparison| [comparison.fetch("host"), comparison.fetch("case_id")] }
      actual.uniq.sort == expected.sort
    end
    private_class_method :complete_comparison_set?

    def aggregate_scores(comparisons, hosts)
      hosts.each_with_object({}) do |host, result|
        rows = comparisons.select { |comparison| comparison.fetch("host") == host }
        result[host] = DIMENSIONS.each_with_object({}) do |dimension, scores|
          scores[dimension] = %w[legacy replacement].each_with_object({}) do |arm, arms|
            arms[arm] = rows.sum { |row| arm_score(row, arm).fetch(dimension) }
          end
        end
      end
    end
    private_class_method :aggregate_scores

    def comparison_outcome(comparison)
      replacement = arm_score(comparison, "replacement")
      legacy = arm_score(comparison, "legacy")
      return "win" if PRIMARY_DIMENSIONS.all? { |dimension| replacement.fetch(dimension) >= legacy.fetch(dimension) } && PRIMARY_DIMENSIONS.any? { |dimension| replacement.fetch(dimension) > legacy.fetch(dimension) }
      return "tie" if PRIMARY_DIMENSIONS.all? { |dimension| replacement.fetch(dimension) == legacy.fetch(dimension) }

      "loss"
    end
    private_class_method :comparison_outcome

    def primary_loss(comparison)
      replacement = arm_score(comparison, "replacement")
      legacy = arm_score(comparison, "legacy")
      PRIMARY_DIMENSIONS.map { |dimension| legacy.fetch(dimension) - replacement.fetch(dimension) }.max
    end
    private_class_method :primary_loss

    def arm_score(comparison, arm)
      direct = comparison.fetch(arm, {})
      runs = comparison.fetch("#{arm}_runs", comparison.fetch("runs", nil))
      return normalize_score(direct) unless runs.is_a?(Array) && !runs.empty?
      selected = runs.select { |run| run.fetch("arm") == arm }
      selected = [direct] if selected.empty?
      DIMENSIONS.each_with_object({}) do |dimension, score|
        score[dimension] = selected.map { |run| normalize_score(run).fetch(dimension) }.min
      end
    end
    private_class_method :arm_score

    def normalize_score(score)
      DIMENSIONS.each_with_object({}) do |dimension, result|
        value = score.fetch(dimension)
        raise Error, "score is invalid for #{dimension}" unless value.is_a?(Integer) && value >= 0 && value <= Corpus::SCORING_MAXIMA.fetch(dimension)
        result[dimension] = value
      end
    end
    private_class_method :normalize_score

    def aggregate_gate?(aggregate, hosts)
      hosts.all? do |host|
        PRIMARY_DIMENSIONS.all? do |dimension|
          aggregate.fetch(host).fetch(dimension).fetch("replacement") >= aggregate.fetch(host).fetch(dimension).fetch("legacy")
        end
      end
    end
    private_class_method :aggregate_gate?

    def efficiency_gate?(efficiency)
      Corpus::HOSTS.all? do |host|
        replacement = efficiency.fetch(host).fetch("replacement")
        legacy = efficiency.fetch(host).fetch("legacy")
        replacement.fetch("turns") <= legacy.fetch("turns") * 0.75 && replacement.fetch("characters") <= legacy.fetch("characters") * 0.75
      end
    end
    private_class_method :efficiency_gate?

    def explicit_trigger_gate?(evidence)
      explicit = evidence.fetch("explicit_triggers")
      explicit.fetch("passed") == explicit.fetch("total") && explicit.fetch("total") == Budget::EXPLICIT_TRIGGER_RUNS
    end
    private_class_method :explicit_trigger_gate?

    def decision_payload(decision, reason, evidence, aggregate: nil, outcomes: nil)
      payload = {"decision" => decision, "reason" => reason}
      payload["aggregate_scores"] = aggregate if aggregate
      payload["comparison_outcomes"] = outcomes if outcomes
      payload["zero_tolerance_failures"] = deep_copy(evidence.fetch("zero_tolerance_failures", []))
      payload["inconclusives"] = deep_copy(evidence.fetch("inconclusives", []))
      payload
    end
    private_class_method :decision_payload

    def primary_margin(row)
      replacement = row.fetch("replacement", {})
      legacy = row.fetch("legacy", {})
      PRIMARY_DIMENSIONS.map { |dimension| (replacement.fetch(dimension, 0) - legacy.fetch(dimension, 0)).abs }.min
    end
    private_class_method :primary_margin

    def string_value?(value)
      value.is_a?(String) && !value.empty?
    end
    private_class_method :string_value?

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
    private_class_method :deep_copy

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
    private_class_method :deep_freeze
  end
end
