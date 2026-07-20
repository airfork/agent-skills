module PromptEngineer
  module Normalizers
    class UnsupportedError < StandardError; end

    class UnsupportedAdapter
      attr_reader :host

      def initialize(host)
        @host = host
      end

      def normalize(*)
        raise UnsupportedError,
              "native normalizer for #{host} is unsupported: " \
              "real native export evidence is unavailable"
      end
    end

    module_function

    def for(host)
      Capabilities.for(host)
      UnsupportedAdapter.new(host)
    end
  end
end
