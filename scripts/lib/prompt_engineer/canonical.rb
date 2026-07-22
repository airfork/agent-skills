require "digest"
require "json"

module PromptEngineer
  module Canonical
    module_function

    def json(value)
      normalized = normalize(value)
      bytes = JSON.generate(normalized).encode("UTF-8")
      raise ArgumentError, "canonical JSON is not valid UTF-8" unless bytes.valid_encoding?

      bytes + "\n".encode("UTF-8")
    rescue JSON::GeneratorError => error
      raise ArgumentError, error.message
    end

    def digest(value)
      Digest::SHA256.hexdigest(json(value))
    end

    def self.canonical_json(value)
      json(value)
    end

    def self.canonicalize(value)
      json(value)
    end

    def self.sha256(value)
      digest(value)
    end

    def normalize(value)
      case value
      when Hash
        pairs = value.map do |key, item|
          raise ArgumentError, "canonical JSON object keys must be strings" unless key.is_a?(String)

          [key.encode("UTF-8"), normalize(item)]
        end
        Hash[pairs.sort_by { |pair| pair[0].bytes }]
      when Array
        value.map { |item| normalize(item) }
      when String
        value.encode("UTF-8")
      when Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ArgumentError, "non-finite number is not canonical JSON" unless value.finite?

        value
      else
        raise ArgumentError, "unsupported canonical JSON value: #{value.class}"
      end
    end
    private_class_method :normalize
  end
end
