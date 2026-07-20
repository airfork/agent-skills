module PromptEngineer
  module Cutover
    class Error < StandardError; end

    module_function

    def evaluate(qualification:, capabilities:, runtime:, sandbox:)
      reasons = []
      reasons << "qualification is not PASS" unless qualification == "PASS"
      reasons << "capability evidence is incomplete" unless capabilities.is_a?(Hash) && capabilities.values.all? { |value| value.is_a?(Hash) && value["status"] == "supported" }
      reasons << "Ruby 2.6 compatibility evidence is unavailable" unless runtime == "ruby-2.6"
      reasons << "sandbox support is unavailable" unless sandbox == "supported"
      {
        "decision" => reasons.empty? ? "READY" : "BLOCKED",
        "mutations_permitted" => reasons.empty?,
        "reasons" => reasons
      }
    end

    def apply!(_decision)
      raise Error, "cutover mutations are disabled until all qualification gates pass"
    end
  end
end
