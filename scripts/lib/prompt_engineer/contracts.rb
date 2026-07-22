require "psych"
require "time"

module PromptEngineer
  module Contracts
    class Error < StandardError; end
    class YamlError < Error; end
    class SchemaError < Error; end
    class ValidationError < Error; end

    TYPES = %w[object array string integer number boolean null].freeze
    KEYWORDS = %w[
      type properties required additionalProperties items enum const pattern
      minimum maximum minLength maxLength minItems maxItems allOf if then else
    ].freeze
    CORE_TAGS = [
      nil,
      "tag:yaml.org,2002:map",
      "tag:yaml.org,2002:seq",
      "tag:yaml.org,2002:str",
      "tag:yaml.org,2002:int",
      "tag:yaml.org,2002:float",
      "tag:yaml.org,2002:bool",
      "tag:yaml.org,2002:null"
    ].freeze

    module_function

    def parse_yaml(source)
      text = source.respond_to?(:read) ? source.read : source.to_s
      documents = []
      Psych.parse_stream(text) { |document| documents << document }
      raise YamlError, "exactly one YAML document is required" unless documents.length == 1

      document = documents.first
      walk_ast(document.root, [])
      value = safe_load(text)
      reject_non_string_keys(value, [])
      reject_nonfinite_values(value, [])
      value
    rescue YamlError
      raise
    rescue Psych::Exception, ArgumentError, TypeError => error
      raise YamlError, error.message
    end

    def load_yaml(path)
      parse_yaml(File.binread(path))
    rescue Errno::ENOENT, Errno::EACCES => error
      raise YamlError, error.message
    end

    def load_schema(path)
      schema = load_yaml(path)
      validate_schema!(schema)
      schema
    end

    def validate!(value, schema, path = [])
      validate_schema!(schema, [])
      validate_value(value, schema, path)
      true
    end

    def validate(value, schema)
      validate!(value, schema)
      []
    rescue ValidationError => error
      [error.message]
    end

    def validate_judge_result!(result, rubric)
      declared = normalize_declared_points(rubric)
      expected_dimensions = PromptEngineer::Corpus::SCORING_MAXIMA.keys
      dimensions = result.fetch("rubric_dimensions")
      actual_dimensions = dimensions.map { |dimension| dimension.fetch("dimension") }
      raise ValidationError, "dimensions must cover the frozen five dimensions" unless actual_dimensions.uniq.sort == expected_dimensions.sort

      dimensions.each do |dimension|
        name = dimension.fetch("dimension")
        points = declared.fetch(name)
        actual_points = dimension.fetch("point_results")
        actual_ids = actual_points.map { |point| point.fetch("point_id") }
        raise ValidationError, "point IDs are not declared for #{name}" unless actual_ids.uniq.sort == points.keys.sort
        expected_maximum = points.values.sum
        raise ValidationError, "maximum does not match weights for #{name}" unless dimension.fetch("maximum") == expected_maximum

        lost_weight = 0
        actual_points.each do |point|
          point_id = point.fetch("point_id")
          expected_weight = points.fetch(point_id)
          raise ValidationError, "weight does not match declared point #{point_id}" unless point.fetch("weight") == expected_weight
          status = point.fetch("status")
          raise ValidationError, "status is invalid for #{point_id}" unless %w[pass fail uncertain].include?(status)
          raise ValidationError, "citation_required must be boolean for #{point_id}" unless [true, false].include?(point.fetch("citation_required"))
          if %w[fail uncertain].include?(status)
            lost_weight += expected_weight
            citation = point.fetch("citation", nil)
            raise ValidationError, "citation evidence is required for #{point_id}" unless point.fetch("citation_required") == true && citation.is_a?(String) && !citation.empty?
          elsif point.fetch("citation_required") == true
            citation = point.fetch("citation", nil)
            raise ValidationError, "citation is required for #{point_id}" unless citation.is_a?(String) && !citation.empty?
          end
          if status == "uncertain"
            classification = point.fetch("uncertainty").fetch("classification")
            raise ValidationError, "uncertainty classification is required for #{point_id}" unless classification == "material"
          end
        end
        expected_score = [expected_maximum - lost_weight, 0].max
        raise ValidationError, "score does not match weights for #{name}" unless dimension.fetch("score") == expected_score
        if result.key?("scores")
          raise ValidationError, "scores do not match #{name}" unless result.fetch("scores").fetch(name) == expected_score
        end
      end
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise ValidationError, "malformed judge result: #{error.message}"
    end

    def validate_executor_binding!(result, facts)
      required = %w[run_id case_id host session_id arm nonce staged_package_digest machine_id staged_path public_task_packet_digest raw_export_digest launch_attestation_digest]
      missing = required.reject { |key| facts.key?(key) }
      raise ValidationError, "executor binding facts are incomplete" unless missing.empty?
      expected_binding = required.each_with_object({}) { |key, binding| binding[key] = facts.fetch(key) }
      raise ValidationError, "run binding mismatch" unless result.fetch("run_id") == facts.fetch("run_id")
      raise ValidationError, "case binding mismatch" unless result.fetch("case_id") == facts.fetch("case_id")
      raise ValidationError, "host binding mismatch" unless result.fetch("host") == facts.fetch("host")
      raise ValidationError, "arm binding mismatch" unless result.fetch("arm") == facts.fetch("arm")
      raise ValidationError, "nonce binding mismatch" unless result.fetch("nonce") == facts.fetch("nonce")
      raise ValidationError, "session binding mismatch" unless result.fetch("session").fetch("id") == facts.fetch("session_id")
      raise ValidationError, "launch packet binding mismatch" unless result.fetch("public_task_packet_digest") == facts.fetch("public_task_packet_digest")
      raise ValidationError, "raw export binding mismatch" unless result.fetch("raw_export_digest") == facts.fetch("raw_export_digest")
      raise ValidationError, "package binding mismatch" unless result.fetch("expected_package_digest") == facts.fetch("staged_package_digest")
      raise ValidationError, "launch attestation binding mismatch" unless result.fetch("sandbox_launch_attestation_digest") == facts.fetch("launch_attestation_digest")

      %w[activation_evidence invocation_evidence].each do |field|
        evidence = result.fetch(field)
        raise ValidationError, "#{field} binding mismatch" unless evidence.fetch("binding") == expected_binding
        expected_digest = Canonical.digest(expected_binding)
        raise ValidationError, "#{field} binding digest mismatch" unless evidence.fetch("binding_digest") == expected_digest && evidence.fetch("machine_binding_digest") == expected_digest
        raise ValidationError, "#{field} machine binding mismatch" unless evidence.fetch("machine_id") == facts.fetch("machine_id")
        raise ValidationError, "#{field} staged path mismatch" unless evidence.fetch("staged_path") == facts.fetch("staged_path")
        evidence_copy = Marshal.load(Marshal.dump(evidence))
        evidence_digest = evidence_copy.delete("evidence_digest")
        raise ValidationError, "#{field} evidence digest mismatch" unless evidence_digest == Canonical.digest(evidence_copy)
      end
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise ValidationError, "malformed executor binding: #{error.message}"
    end

    def validate_executor_result!(result, facts, token_cap: nil)
      validate_executor_binding!(result, facts)
      timestamps = result.fetch("timestamps")
      begin
        started_at = Time.iso8601(timestamps.fetch("started_at"))
        ended_at = Time.iso8601(timestamps.fetch("ended_at"))
      rescue ArgumentError, TypeError => error
        raise ValidationError, "timestamp is invalid: #{error.message}"
      end
      raise ValidationError, "timestamp ordering is invalid" unless ended_at > started_at

      events = result.fetch("messages") + result.fetch("tool_events")
      ordinals = events.map { |event| event.fetch("ordinal") }
      raise ValidationError, "event ordinals must be unique and monotonic" unless ordinals == ordinals.sort && ordinals.uniq.length == ordinals.length

      usage = result.fetch("usage")
      input_tokens = usage.fetch("input_tokens")
      output_tokens = usage.fetch("output_tokens")
      total_tokens = usage.fetch("total_tokens")
      raise ValidationError, "total_tokens is inconsistent" unless total_tokens == input_tokens + output_tokens
      cap = token_cap || facts["token_cap"]
      raise ValidationError, "token cap exceeded" if cap && total_tokens > cap
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise ValidationError, "malformed executor result: #{error.message}"
    end

    def validate_schema!(schema, path = [])
      raise SchemaError, "schema must be an object at #{render_path(path)}" unless schema.is_a?(Hash)

      unknown = schema.keys - KEYWORDS
      raise SchemaError, "unknown schema keyword #{unknown.first.inspect}" unless unknown.empty?
      if schema.key?("type")
        types = schema["type"].is_a?(Array) ? schema["type"] : [schema["type"]]
        unless types.all? { |type| TYPES.include?(type) }
          raise SchemaError, "unsupported schema type at #{render_path(path)}"
        end
      end
      if schema.key?("properties")
        properties = schema["properties"]
        raise SchemaError, "properties must be an object at #{render_path(path)}" unless properties.is_a?(Hash)
        properties.each do |name, child|
          raise SchemaError, "property names must be strings" unless name.is_a?(String)

          validate_schema!(child, path + ["properties", name])
        end
      end
      if schema.key?("required")
        required = schema["required"]
        unless required.is_a?(Array) && required.all? { |name| name.is_a?(String) }
          raise SchemaError, "required must contain strings at #{render_path(path)}"
        end
        if schema.key?("properties")
          missing_properties = required - schema["properties"].keys
          raise SchemaError, "required property is not declared at #{render_path(path)}" unless missing_properties.empty?
        end
      end
      if schema.key?("additionalProperties") && ![true, false].include?(schema["additionalProperties"])
        raise SchemaError, "additionalProperties must be boolean at #{render_path(path)}"
      end
      if schema.key?("items")
        validate_schema!(schema["items"], path + ["items"])
      end
      if schema.key?("allOf")
        all_of = schema["allOf"]
        raise SchemaError, "allOf must be an array at #{render_path(path)}" unless all_of.is_a?(Array) && !all_of.empty?

        all_of.each_with_index { |child, index| validate_schema!(child, path + ["allOf", index]) }
      end
      %w[if then else].each do |keyword|
        validate_schema!(schema[keyword], path + [keyword]) if schema.key?(keyword)
      end
      if schema.key?("enum") && !schema["enum"].is_a?(Array)
        raise SchemaError, "enum must be an array at #{render_path(path)}"
      end
      if schema.key?("pattern")
        begin
          Regexp.new(schema["pattern"])
        rescue StandardError
          raise SchemaError, "invalid pattern at #{render_path(path)}"
        end
      end
      numeric_keywords = %w[minimum maximum]
      numeric_keywords.each do |keyword|
        next unless schema.key?(keyword)
        unless finite_real?(schema[keyword])
          raise SchemaError, "#{keyword} must be numeric at #{render_path(path)}"
        end
      end
      length_keywords = %w[minLength maxLength minItems maxItems]
      length_keywords.each do |keyword|
        next unless schema.key?(keyword)
        unless schema[keyword].is_a?(Integer) && schema[keyword] >= 0
          raise SchemaError, "#{keyword} must be a nonnegative integer at #{render_path(path)}"
        end
      end
      true
    end

    def normalize_declared_points(rubric)
      points = rubric.fetch("rubric_points", rubric)
      expected_dimensions = PromptEngineer::Corpus::SCORING_MAXIMA.keys
      raise ValidationError, "rubric dimensions are not frozen" unless points.is_a?(Hash) && points.keys.sort == expected_dimensions.sort
      if points.values.all? { |value| value.is_a?(Integer) }
        points.each_with_object({}) { |(dimension, weight), normalized| normalized[dimension] = {dimension => weight} }
      elsif points.values.all? { |value| value.is_a?(Hash) }
        points.each_with_object({}) do |(dimension, point_map), normalized|
          raise ValidationError, "declared point map is not closed" unless point_map.keys.all? { |point_id| point_id.is_a?(String) } && point_map.values.all? { |weight| weight.is_a?(Integer) && weight >= 0 }
          normalized[dimension] = point_map
        end
      else
        raise ValidationError, "declared point weights are malformed"
      end
    end

    def walk_ast(node, path)
      return if node.nil?
      if node.is_a?(Psych::Nodes::Alias)
        raise YamlError, "aliases are not permitted at #{render_path(path)}"
      end
      unless CORE_TAGS.include?(node.tag)
        raise YamlError, "unsupported YAML tag #{node.tag.inspect} at #{render_path(path)}"
      end
      if node.is_a?(Psych::Nodes::Scalar) && node.plain && node.value =~ /\A[+-]?\.(?:nan|inf)\z/i
        raise YamlError, "nonfinite YAML scalar at #{render_path(path)}"
      end
      if node.is_a?(Psych::Nodes::Scalar) && node.tag && node.tag =~ /:(?:int|float)\z/
        raise YamlError, "explicit numeric scalar tags are not permitted at #{render_path(path)}"
      end
      if node.is_a?(Psych::Nodes::Scalar) && node.plain &&
          node.value =~ /\A[+-]?(?:(?:[0-9][0-9_]*\.[0-9_]*|\.[0-9_]+|[0-9][0-9_]*))[eE][+-]?[0-9_]+\z/
        converted = Float(node.value.delete("_"))
        raise YamlError, "nonfinite YAML scalar at #{render_path(path)}" unless converted.finite?
      end
      if node.is_a?(Psych::Nodes::Mapping)
        keys = {}
        children = node.children
        children.each_slice(2) do |key, value|
          unless key.is_a?(Psych::Nodes::Scalar)
            raise YamlError, "mapping keys must be scalar strings at #{render_path(path)}"
          end
          if key.tag
            raise YamlError, "AST mapping keys must not be explicitly tagged at #{render_path(path)}"
          end
          unless string_mapping_key?(key)
            raise YamlError, "AST mapping keys must be strings at #{render_path(path)}"
          end
          key_name = key.value
          if key_name == "<<"
            raise YamlError, "merge keys are not permitted at #{render_path(path)}"
          end
          if keys.key?(key_name)
            raise YamlError, "duplicate scalar key #{key_name.inspect} at #{render_path(path)}"
          end
          keys[key_name] = true
          walk_ast(key, path + [key_name])
          walk_ast(value, path + [key_name])
        end
      elsif node.respond_to?(:children)
        (node.children || []).each_with_index { |child, index| walk_ast(child, path + [index]) }
      end
    end
    private_class_method :walk_ast

    def string_mapping_key?(node)
      return true unless node.tag.nil? && node.plain && !node.quoted

      value = node.value.to_s
      return false if value.empty?
      return false if value =~ /\A(?:true|false|null|~)\z/i
      return false if value =~ /\A[-+]?0b[01_]+\z/i
      return false if value =~ /\A[-+]?(?:0|[1-9][0-9_]*|0o[0-7_]+|0x[0-9a-f_]+)\z/i
      return false if value =~ /\A[-+]?(?:[0-9][0-9_]*)?\.[0-9_]+(?:[eE][-+]?[0-9]+)?\z/
      return false if value =~ /\A[-+]?(?:[0-9][0-9_]*)[eE][-+]?[0-9]+\z/i
      return false if value =~ /\A(?:\.inf|\.nan)\z/i
      return false if value =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt]|\z)/

      true
    end
    private_class_method :string_mapping_key?

    def safe_load(text)
      begin
        Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue ArgumentError
        Psych.safe_load(text, [], [], false)
      end
    end
    private_class_method :safe_load

    def reject_non_string_keys(value, path)
      case value
      when Hash
        value.each do |key, child|
          raise YamlError, "mapping keys must be strings at #{render_path(path)}" unless key.is_a?(String)

          reject_non_string_keys(child, path + [key])
        end
      when Array
        value.each_with_index { |child, index| reject_non_string_keys(child, path + [index]) }
      end
    end
    private_class_method :reject_non_string_keys

    def reject_nonfinite_values(value, path)
      if value.is_a?(Numeric) && !finite_real?(value)
        raise YamlError, "nonfinite YAML value at #{render_path(path)}"
      end
      case value
      when Hash
        value.each { |key, child| reject_nonfinite_values(child, path + [key]) }
      when Array
        value.each_with_index { |child, index| reject_nonfinite_values(child, path + [index]) }
      end
    end
    private_class_method :reject_nonfinite_values

    def validate_value(value, schema, path)
      if value.is_a?(Numeric) && !finite_real?(value)
        raise ValidationError, "finite at #{render_path(path)}"
      end
      if schema.key?("type")
        types = schema["type"].is_a?(Array) ? schema["type"] : [schema["type"]]
        unless types.any? { |type| type_matches?(value, type) }
          raise ValidationError, "type at #{render_path(path)}"
        end
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        raise ValidationError, "enum at #{render_path(path)}"
      end
      if schema.key?("const") && value != schema["const"]
        raise ValidationError, "const at #{render_path(path)}"
      end
      schema.fetch("allOf", []).each { |child| validate_value(value, child, path) }
      if schema.key?("if")
        condition_matches = begin
          validate_value(value, schema.fetch("if"), path)
          true
        rescue ValidationError
          false
        end
        branch = condition_matches ? schema["then"] : schema["else"]
        validate_value(value, branch, path) if branch
      end
      case value
      when Hash
        required = schema.fetch("required", [])
        required.each do |name|
          raise ValidationError, "required #{name.inspect} at #{render_path(path)}" unless value.key?(name)
        end
        properties = schema.fetch("properties", {})
        if schema["additionalProperties"] == false
          extras = value.keys - properties.keys
          raise ValidationError, "additionalProperties #{extras.first.inspect} at #{render_path(path)}" unless extras.empty?
        end
        value.each do |name, child|
          validate_value(child, properties[name], path + [name]) if properties.key?(name)
        end
      when Array
        if schema.key?("items")
          value.each_with_index { |child, index| validate_value(child, schema["items"], path + [index]) }
        end
        check_length(value, schema, "minItems", "maxItems", path)
      when String
        if schema.key?("pattern") && Regexp.new(schema["pattern"]) !~ value
          raise ValidationError, "pattern at #{render_path(path)}"
        end
        check_length(value, schema, "minLength", "maxLength", path)
      when Numeric
        if schema.key?("minimum") && value < schema["minimum"]
          raise ValidationError, "minimum at #{render_path(path)}"
        end
        if schema.key?("maximum") && value > schema["maximum"]
          raise ValidationError, "maximum at #{render_path(path)}"
        end
      end
      true
    end
    private_class_method :validate_value

    def type_matches?(value, type)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric) && !value.is_a?(Complex)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else false
      end
    end
    private_class_method :type_matches?

    def finite_real?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) &&
        (!value.respond_to?(:finite?) || value.finite?)
    end
    private_class_method :finite_real?

    def check_length(value, schema, minimum, maximum, path)
      if schema.key?(minimum) && value.length < schema[minimum]
        raise ValidationError, "#{minimum} at #{render_path(path)}"
      end
      if schema.key?(maximum) && value.length > schema[maximum]
        raise ValidationError, "#{maximum} at #{render_path(path)}"
      end
    end
    private_class_method :check_length

    def render_path(path)
      return "$" if path.empty?

      "$" + path.map { |part| part.is_a?(Integer) ? "[#{part}]" : ".#{part}" }.join
    end
    private_class_method :render_path
  end
end
