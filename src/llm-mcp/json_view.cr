# src/llm-mcp/json_view.cr
module LLM::MCP
  def self.json(value) : JSON::Any
    case value
    when JSON::Any
      value
    else
      JSON.parse(value.to_json)
    end
  end

  def self.json_object(value, what : String) : JSON::Any
    any = json(value)
    raise ArgumentError.new("#{what} must be a JSON object") unless any.as_h?
    any
  end

  module JsonView
    getter raw : JSON::Any

    def initialize(@raw : JSON::Any)
    end

    macro included
      def self.new(pull : JSON::PullParser) : self
        new(JSON::Any.new(pull))
      end
    end

    def []?(key : String) : JSON::Any?
      @raw.as_h?.try(&.[key]?)
    end

    def ==(other : self) : Bool
      @raw == other.raw
    end

    def hash(hasher)
      @raw.hash(hasher)
    end

    def to_json(builder : JSON::Builder) : Nil
      @raw.to_json(builder)
    end

    def to_s(io : IO) : Nil
      @raw.to_json(io)
    end

    def inspect(io : IO) : Nil
      io << self.class.name << '('
      @raw.to_json(io)
      io << ')'
    end

    macro field(name, key, type, required = false)
      def {{name.id}} : {{type}}{{(required ? "" : "?").id}}
        %value = self[{{key}}]?
        {% resolved = type.resolve %}
        {% if resolved < ::LLM::MCP::JsonView %}
          %result = %value.try { |item| item.as_h? ? {{type}}.new(item) : nil }
        {% elsif resolved == ::String %}
          %result = %value.try(&.as_s?)
        {% elsif resolved == ::Bool %}
          %result = %value.try(&.as_bool?)
        {% elsif resolved == ::Int64 %}
          %result = %value.try { |item| item.as_i64? || item.as_f?.try { |float| float == float.round ? float.to_i64 : nil } }
        {% elsif resolved == ::Float64 %}
          %result = %value.try { |item| item.as_f? || item.as_i64?.try(&.to_f) }
        {% elsif type.stringify == "Array(String)" %}
          %result = %value.try(&.as_a?).try { |items| items.all?(&.as_s?) ? items.map(&.as_s) : nil }
        {% else %}
          %result = %value
        {% end %}
        {% if required %}
          %result.not_nil!
        {% else %}
          %result
        {% end %}
      end
    end
  end
end
