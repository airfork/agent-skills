require "psych"

module PromptEngineer
  module Contracts
    class Error < StandardError; end
    class YamlError < Error; end
    class SchemaError < Error; end
    class ValidationError < Error; end

    TYPES = %w[object array string integer number boolean null].freeze
    KEYWORDS = %w[
      type properties required additionalProperties items enum const pattern
      minimum maximum minLength maxLength minItems maxItems
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
      document = Psych.parse(text)
      walk_ast(document.root, [])
      value = safe_load(text)
      reject_non_string_keys(value, [])
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
        unless schema[keyword].is_a?(Numeric)
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

    def walk_ast(node, path)
      return if node.nil?
      if node.is_a?(Psych::Nodes::Alias)
        raise YamlError, "aliases are not permitted at #{render_path(path)}"
      end
      unless CORE_TAGS.include?(node.tag)
        raise YamlError, "unsupported YAML tag #{node.tag.inspect} at #{render_path(path)}"
      end
      if node.is_a?(Psych::Nodes::Mapping)
        keys = {}
        children = node.children
        children.each_slice(2) do |key, value|
          unless key.is_a?(Psych::Nodes::Scalar)
            raise YamlError, "mapping keys must be scalar strings at #{render_path(path)}"
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

    def validate_value(value, schema, path)
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
