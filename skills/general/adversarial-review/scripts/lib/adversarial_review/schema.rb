require "json"

module AdversarialReview
  class Schema
    Error = Struct.new(:code, :path, :message) do
      def to_h
        {"code" => code, "path" => path, "message" => message}
      end
    end

    def self.validate(name, value)
      path = File.join(AdversarialReview.root, "assets", "schemas", "#{name}.json")
      schema = JSON.parse(File.read(path))
      new(schema, name).validate(value).map(&:to_h)
    end

    def initialize(schema, name)
      @schema = schema
      @name = name
      @errors = []
    end

    def validate(value)
      visit(@schema, value, "")
      validate_artifact_digest_paths(value)
      validate_dedupe(value) if @name == "dedupe"
      validate_author_action_paths(value) if @name == "author-actions"
      validate_intrinsic_records(value)
      @errors
    end

    private

    def visit(schema, value, path)
      if schema.key?("type") && !matches_type?(schema.fetch("type"), value)
        add_error("type", path, "value must be a #{schema.fetch("type")}")
        return
      end
      if schema.key?("const") && value != schema.fetch("const")
        add_error("const", path, "value must equal #{schema.fetch("const").inspect}")
      end
      if schema.key?("enum") && !schema.fetch("enum").include?(value)
        add_error("enum", path, "value is not in the allowed set")
      end
      if schema.key?("minimum") && value < schema.fetch("minimum")
        add_error("minimum", path, "value is below the minimum")
      end
      if schema.key?("maximum") && value > schema.fetch("maximum")
        add_error("maximum", path, "value is above the maximum")
      end
      if schema.key?("minLength") && value.length < schema.fetch("minLength")
        add_error("min_length", path, "string is shorter than the minimum length")
      end
      if schema.key?("maxLength") && value.length > schema.fetch("maxLength")
        add_error("max_length", path, "string is longer than the maximum length")
      end
      if schema.key?("maxItems") && value.length > schema.fetch("maxItems")
        add_error("max_items", path, "array contains too many items")
      end
      if schema.key?("pattern") && !schema_pattern(schema.fetch("pattern")).match?(value)
        add_error("pattern", path, "string does not match the required pattern")
      end

      if value.is_a?(Hash)
        properties = schema.fetch("properties", {})
        schema.fetch("required", []).each do |key|
          unless value.key?(key)
            add_error("required", child_path(path, key), "property is required")
          end
        end
        if schema["additionalProperties"] == false
          (value.keys - properties.keys).each do |key|
            add_error("additional_property", child_path(path, key), "property is not allowed")
          end
        elsif schema["additionalProperties"].is_a?(Hash)
          (value.keys - properties.keys).each do |key|
            visit(schema.fetch("additionalProperties"), value[key], child_path(path, key))
          end
        end
        properties.each do |key, child_schema|
          visit(child_schema, value[key], child_path(path, key)) if value.key?(key)
        end
      elsif value.is_a?(Array) && schema.key?("items")
        value.each_with_index do |item, index|
          visit(schema.fetch("items"), item, child_path(path, index))
        end
      end
    end

    def child_path(path, key)
      segment = key.to_s.gsub("~", "~0").gsub("/", "~1")
      "#{path}/#{segment}"
    end

    def pointer(*segments)
      segments.reduce("") { |path, segment| child_path(path, segment) }
    end

    def schema_pattern(pattern)
      source = explicitly_anchored_pattern?(pattern) ? "\\A(?:#{pattern})\\z" : pattern
      Regexp.new(source)
    end

    def explicitly_anchored_pattern?(pattern)
      return false unless pattern.start_with?("^") && pattern.end_with?("$")

      backslashes = 0
      index = pattern.length - 2
      while index >= 0 && pattern[index] == "\\"
        backslashes += 1
        index -= 1
      end
      backslashes.even?
    end

    def matches_type?(type, value)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      else false
      end
    end

    def validate_dedupe(value)
      return unless value.is_a?(Hash) && value["groups"].is_a?(Array)

      seen = {}
      group_ids = {}
      value.fetch("groups").each_with_index do |group, group_index|
        next unless group.is_a?(Hash) && group["candidate_ids"].is_a?(Array)

        group_id = group["group_id"]
        if group_ids.key?(group_id)
          add_error("group_duplicate", pointer("groups", group_index, "group_id"), "group ID is duplicated")
        else
          group_ids[group_id] = true
        end

        group.fetch("candidate_ids").each_with_index do |candidate_id, candidate_index|
          path = pointer("groups", group_index, "candidate_ids", candidate_index)
          if seen.key?(candidate_id)
            add_error("candidate_duplicate", path, "candidate ID already belongs to #{seen.fetch(candidate_id)}")
          else
            seen[candidate_id] = "group #{group_index}"
          end
        end
      end
    end

    def validate_intrinsic_records(value)
      return unless value.is_a?(Hash)

      case @name
      when "attack", "divergence"
        validate_finding_text(value["findings"], "findings")
      when "judge"
        validate_unique_record_field(value["verdicts"], "candidate_id", "subject_duplicate", "verdicts")
        validate_nonblank_fields(value["verdicts"], %w[evidence consequence], "verdicts")
      when "author-actions"
        validate_unique_record_field(value["actions"], "finding_id", "subject_duplicate", "actions")
        validate_nonblank_fields(value["actions"], ["rationale"], "actions")
      when "resolution"
        validate_unique_record_field(value["checks"], "finding_id", "subject_duplicate", "checks")
        validate_nonblank_fields(value["checks"], ["evidence"], "checks")
        validate_finding_text(value["new_findings"], "new_findings")
      when "arbiter"
        validate_unique_record_field(value["decisions"], "subject_id", "subject_duplicate", "decisions")
        validate_nonblank_fields(value["decisions"], ["evidence"], "decisions")
        validate_nested_unique_ids(value["decisions"], "mapped_candidate_ids", "decisions")
      end
    end

    def validate_unique_record_field(records, field, code, collection)
      return unless records.is_a?(Array)

      seen = {}
      records.each_with_index do |record, index|
        next unless record.is_a?(Hash) && record.key?(field)

        identifier = record[field]
        if seen.key?(identifier)
          add_error(code, pointer(collection, index, field), "subject ID is duplicated")
        else
          seen[identifier] = true
        end
      end
    end

    def validate_nonblank_fields(records, fields, collection)
      return unless records.is_a?(Array)

      records.each_with_index do |record, index|
        next unless record.is_a?(Hash)

        fields.each do |field|
          value = record[field]
          next unless value.is_a?(String) && value.strip.empty?

          add_error("blank_evidence", pointer(collection, index, field), "text must contain non-whitespace evidence")
        end
      end
    end

    def validate_nested_unique_ids(records, field, collection)
      return unless records.is_a?(Array)

      records.each_with_index do |record, index|
        next unless record.is_a?(Hash) && record[field].is_a?(Array)

        seen = {}
        record.fetch(field).each_with_index do |identifier, nested_index|
          if seen.key?(identifier)
            add_error(
              "candidate_duplicate", pointer(collection, index, field, nested_index),
              "candidate ID is duplicated"
            )
          else
            seen[identifier] = true
          end
        end
      end
    end

    def validate_finding_text(findings, collection)
      return unless findings.is_a?(Array)

      validate_nonblank_fields(findings, %w[summary evidence consequence], collection)
      findings.each_with_index do |finding, index|
        next unless finding.is_a?(Hash) && finding["location"].is_a?(Hash)

        location = finding.fetch("location")
        %w[path heading].each do |field|
          value = location[field]
          next unless value.is_a?(String) && value.strip.empty?

          add_error(
            "blank_evidence", pointer(collection, index, "location", field),
            "location text must not be whitespace"
          )
        end
        line_start = location["line_start"]
        line_end = location["line_end"]
        if line_start.is_a?(Integer) && line_end.is_a?(Integer) && line_end < line_start
          add_error(
            "line_order", pointer(collection, index, "location", "line_end"),
            "location line_end must be greater than or equal to line_start"
          )
        end
      end
    end

    def validate_artifact_digest_paths(value)
      return unless value.is_a?(Hash) && value["artifact_digests"].is_a?(Hash)

      if value.fetch("artifact_digests").keys.any? { |path| !path.is_a?(String) || path.empty? }
        add_error("min_length", pointer("artifact_digests"), "artifact paths must be non-empty strings")
      end
    end

    def validate_author_action_paths(value)
      return unless value.is_a?(Hash) && value["actions"].is_a?(Array)

      value.fetch("actions").each_with_index do |action, action_index|
        next unless action.is_a?(Hash) && action["changed_paths"].is_a?(Array)

        action.fetch("changed_paths").each_with_index do |path, path_index|
          next unless path.is_a?(String) && !path.empty?
          next unless invalid_repository_relative_path?(path)

          error_path = pointer("actions", action_index, "changed_paths", path_index)
          add_error("invalid_path", error_path, "path must be an unambiguous repository-relative path")
        end
      end
    end

    def invalid_repository_relative_path?(path)
      return true if path.match?(/[\x00-\x1f\x7f]/)
      return true if path.start_with?("/", "\\")
      return true if path.match?(/\A[A-Za-z]:/)

      path.split(/[\x2f\x5c]/, -1).any? do |segment|
        segment.empty? || segment == "." || segment == ".."
      end
    end

    def add_error(code, path, message)
      @errors << Error.new(code, path, message)
    end
  end
end
