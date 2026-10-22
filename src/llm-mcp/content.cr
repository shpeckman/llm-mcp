# src/llm-mcp/content.cr
module LLM::MCP
  abstract struct LlmContent
    abstract def type : String

    struct Text < LlmContent
      getter text : String

      def initialize(@text : String)
      end

      def type : String
        "text"
      end

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field "type", "text"
          builder.field "text", @text
        end
      end
    end

    struct Image < LlmContent
      getter data : String
      getter mime_type : String

      def initialize(@data : String, @mime_type : String)
      end

      def type : String
        "image"
      end

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field "type", "image"
          builder.field "data", @data
          builder.field "mimeType", @mime_type
        end
      end
    end
  end

  abstract struct ContentBlock
    include JsonView
    JsonView.field annotations, "annotations", ContentAnnotations
    JsonView.field meta, "_meta", JSON::Any

    def self.new(pull : JSON::PullParser) : ContentBlock
      from(JSON::Any.new(pull))
    end

    def self.from(value : JSON::Any) : ContentBlock
      hash = value.as_h?
      kind = hash.try(&.["type"]?).try(&.as_s?)
      return UnknownContent.new(value) unless hash && kind
      case kind
      when "text"
        return TextContent.new(value) if strings?(hash, "text")
      when "image"
        return ImageContent.new(value) if strings?(hash, "data", "mimeType")
      when "audio"
        return AudioContent.new(value) if strings?(hash, "data", "mimeType")
      when "resource_link"
        return ResourceLinkContent.new(value) if strings?(hash, "uri", "name")
      when "resource"
        resource = hash["resource"]?.try(&.as_h?)
        if resource && strings?(resource, "uri") && (strings?(resource, "text") || strings?(resource, "blob"))
          return EmbeddedResourceContent.new(value)
        end
      end
      UnknownContent.new(value)
    end

    private def self.strings?(hash : Hash(String, JSON::Any), *keys : String) : Bool
      keys.all? { |key| hash[key]?.try(&.as_s?) }
    end

    def type : String
      self["type"]?.try(&.as_s?) || "undefined"
    end

    abstract def to_llm : LlmContent
  end

  struct TextContent < ContentBlock
    JsonView.field text, "text", String, required: true

    def to_llm : LlmContent
      LlmContent::Text.new(text)
    end
  end

  struct ImageContent < ContentBlock
    JsonView.field data, "data", String, required: true
    JsonView.field mime_type, "mimeType", String, required: true

    def to_llm : LlmContent
      LlmContent::Image.new(data, mime_type)
    end
  end

  struct AudioContent < ContentBlock
    JsonView.field data, "data", String, required: true
    JsonView.field mime_type, "mimeType", String, required: true

    def to_llm : LlmContent
      LlmContent::Text.new("[audio #{mime_type} omitted]")
    end
  end

  struct ResourceLinkContent < ContentBlock
    JsonView.field uri, "uri", String, required: true
    JsonView.field name, "name", String, required: true
    JsonView.field title, "title", String
    JsonView.field description, "description", String
    JsonView.field mime_type, "mimeType", String
    JsonView.field size, "size", Int64

    def to_llm : LlmContent
      LlmContent::Text.new("#{name}: #{uri}")
    end
  end

  struct EmbeddedResourceContent < ContentBlock
    JsonView.field resource, "resource", ResourceContents, required: true

    def to_llm : LlmContent
      contents = resource
      if text = contents.text
        return LlmContent::Text.new(text)
      end
      blob = contents.blob.not_nil!
      mime_type = contents.mime_type
      if mime_type && mime_type.starts_with?("image/")
        return LlmContent::Image.new(blob, mime_type)
      end
      LlmContent::Text.new("[binary resource #{contents.uri} (#{mime_type || "unknown type"}) omitted]")
    end
  end

  struct UnknownContent < ContentBlock
    def to_llm : LlmContent
      LlmContent::Text.new("[unsupported MCP content #{type}]")
    end
  end

  struct CallToolResult
    include JsonView

    def content : Array(ContentBlock)
      (self["content"]?.try(&.as_a?) || [] of JSON::Any).map { |block| ContentBlock.from(block) }
    end

    def structured_content : JSON::Any?
      self["structuredContent"]?
    end

    def error? : Bool
      self["isError"]?.try(&.as_bool?) == true
    end

    def meta : JSON::Any?
      self["_meta"]?
    end

    def to_llm_content : Array(LlmContent)
      LLM::MCP.to_llm_content(content, structured_content)
    end
  end

  def self.to_llm_content(result : CallToolResult) : Array(LlmContent)
    result.to_llm_content
  end

  def self.to_llm_content(content : Array(ContentBlock), structured_content : JSON::Any? = nil) : Array(LlmContent)
    blocks = content.map(&.to_llm)
    if blocks.empty? && structured_content
      blocks << LlmContent::Text.new(structured_content.to_pretty_json)
    end
    blocks
  end
end
