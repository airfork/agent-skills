module PromptEngineer
  module Sandbox
    module Darwin
      module_function

      def capability
        Sandbox.capability.merge("platform" => "darwin")
      end
    end
  end
end
