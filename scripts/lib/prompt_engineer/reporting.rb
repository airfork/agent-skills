require "json"

module PromptEngineer
  module Reporting
    module_function

    def render(evidence)
      source = deep_copy(evidence)
      decision = PromptEngineer::Scoring.release_decision(source)
      lines = []
      lines << "# Prompt Engineer Qualification Report"
      lines << ""
      lines << "- Final decision: `#{decision.fetch("decision")}`"
      lines << "- Decision reason: #{decision.fetch("reason")}"
      lines << "- This report is deterministic evidence rendering; it does not launch hosts or authorize cutover."
      lines << ""
      section(lines, "Environment") { |body| append_json(body, source.fetch("environment", {})) }
      section(lines, "Digests") { |body| append_json(body, source.fetch("digests", {})) }
      section(lines, "Run locations and arm provenance") { |body| append_json(body, source.fetch("run_locations", source.fetch("arm_provenance", {}))) }
      section(lines, "Sandbox attestations") { |body| append_json(body, source.fetch("sandbox_attestations", {})) }
      section(lines, "Budgets") { |body| append_json(body, source.fetch("budgets", {})) }
      section(lines, "Exclusions") { |body| append_json(body, source.fetch("exclusions", [])) }
      section(lines, "Point scores") { |body| append_json(body, source.fetch("point_scores", source.fetch("comparisons", []))) }
      section(lines, "Judge disagreement") { |body| append_json(body, source.fetch("judge_disagreement", source.fetch("judge_results", []))) }
      section(lines, "Repeats") { |body| append_json(body, source.fetch("repeats", {})) }
      section(lines, "Trigger results") { |body| append_json(body, source.fetch("trigger_results", {"explicit" => source.fetch("explicit_triggers", {}), "implicit" => source.fetch("implicit_triggers", {}), "negative" => source.fetch("negative_triggers", {})})) }
      section(lines, "zero-tolerance results") { |body| append_json(body, source.fetch("zero_tolerance_failures", [])) }
      section(lines, "Release arithmetic") do |body|
        append_json(body, decision)
        append_json(body, {"comparison_count" => Array(source["comparisons"]).length, "inconclusive_count" => Array(source["inconclusives"]).length})
      end
      lines.join("\n") + "\n"
    rescue PromptEngineer::Scoring::Error, KeyError, TypeError => error
      raise ArgumentError, "cannot render qualification report: #{error.message}"
    end

    def report(evidence)
      render(evidence)
    end

    def section(lines, title)
      lines << "## #{title}"
      lines << ""
      body = []
      yield body
      lines.concat(body.empty? ? ["_none_"] : body)
      lines << ""
    end
    private_class_method :section

    def append_json(lines, value)
      lines << "```json"
      lines << PromptEngineer::Canonical.json(sort_for_report(value)).strip
      lines << "```"
    end
    private_class_method :append_json

    def sort_for_report(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) { |key, result| result[key] = sort_for_report(value.fetch(key)) }
      when Array
        value.map { |item| sort_for_report(item) }
      else
        value
      end
    end
    private_class_method :sort_for_report

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
    private_class_method :deep_copy
  end
end
