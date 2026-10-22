# src/llm-mcp/types.cr
module LLM::MCP
  LATEST_PROTOCOL_VERSION     = "2025-11-25"
  SUPPORTED_PROTOCOL_VERSIONS = {LATEST_PROTOCOL_VERSION, "2025-06-18", "2025-03-26", "2024-11-05"}

  struct Implementation
    include JsonView
    JsonView.field name, "name", String, required: true
    JsonView.field version, "version", String, required: true
    JsonView.field title, "title", String
  end

  struct Root
    getter uri : String
    getter name : String?

    def initialize(@uri : String, @name : String? = nil)
    end

    def to_json(builder : JSON::Builder) : Nil
      builder.object do
        builder.field "uri", @uri
        @name.try { |value| builder.field "name", value }
      end
    end
  end

  struct ListChangedCapability
    include JsonView
    JsonView.field list_changed, "listChanged", Bool
  end

  struct ResourcesCapability
    include JsonView
    JsonView.field subscribe, "subscribe", Bool
    JsonView.field list_changed, "listChanged", Bool
  end

  struct ServerCapabilities
    include JsonView
    JsonView.field experimental, "experimental", JSON::Any
    JsonView.field logging, "logging", JSON::Any
    JsonView.field prompts, "prompts", ListChangedCapability
    JsonView.field resources, "resources", ResourcesCapability
    JsonView.field tools, "tools", ListChangedCapability
    JsonView.field completions, "completions", JSON::Any
  end

  struct InitializeResult
    include JsonView
    JsonView.field protocol_version, "protocolVersion", String, required: true
    JsonView.field capabilities, "capabilities", ServerCapabilities, required: true
    JsonView.field server_info, "serverInfo", Implementation, required: true
    JsonView.field instructions, "instructions", String
  end

  struct ProgressNotification
    include JsonView
    JsonView.field progress, "progress", Float64, required: true
    JsonView.field total, "total", Float64
    JsonView.field message, "message", String

    def progress_token : JsonRpc::Id
      JsonRpc.id?(self["progressToken"]?).not_nil!
    end
  end

  struct CancelledNotification
    include JsonView
    JsonView.field reason, "reason", String

    def request_id : JsonRpc::Id
      JsonRpc.id?(self["requestId"]?).not_nil!
    end
  end

  struct ContentAnnotations
    include JsonView
    JsonView.field audience, "audience", Array(String)
    JsonView.field priority, "priority", Float64
    JsonView.field last_modified, "lastModified", String
  end

  struct ToolAnnotations
    include JsonView
    JsonView.field title, "title", String
    JsonView.field read_only_hint, "readOnlyHint", Bool
    JsonView.field destructive_hint, "destructiveHint", Bool
    JsonView.field idempotent_hint, "idempotentHint", Bool
    JsonView.field open_world_hint, "openWorldHint", Bool
  end

  struct ToolExecution
    include JsonView
    JsonView.field task_support, "taskSupport", String
  end

  struct Tool
    include JsonView
    JsonView.field name, "name", String, required: true
    JsonView.field title, "title", String
    JsonView.field description, "description", String
    JsonView.field input_schema, "inputSchema", JSON::Any, required: true
    JsonView.field output_schema, "outputSchema", JSON::Any
    JsonView.field annotations, "annotations", ToolAnnotations
    JsonView.field execution, "execution", ToolExecution
    JsonView.field meta, "_meta", JSON::Any
  end

  struct Resource
    include JsonView
    JsonView.field uri, "uri", String, required: true
    JsonView.field name, "name", String, required: true
    JsonView.field title, "title", String
    JsonView.field description, "description", String
    JsonView.field mime_type, "mimeType", String
    JsonView.field size, "size", Int64
    JsonView.field annotations, "annotations", ContentAnnotations
    JsonView.field meta, "_meta", JSON::Any
  end

  struct ResourceTemplate
    include JsonView
    JsonView.field uri_template, "uriTemplate", String, required: true
    JsonView.field name, "name", String, required: true
    JsonView.field title, "title", String
    JsonView.field description, "description", String
    JsonView.field mime_type, "mimeType", String
    JsonView.field annotations, "annotations", ContentAnnotations
    JsonView.field meta, "_meta", JSON::Any
  end

  struct ResourceContents
    include JsonView
    JsonView.field uri, "uri", String, required: true
    JsonView.field mime_type, "mimeType", String
    JsonView.field text, "text", String
    JsonView.field blob, "blob", String
    JsonView.field meta, "_meta", JSON::Any
  end

  struct ReadResourceResult
    include JsonView
    JsonView.field meta, "_meta", JSON::Any

    def contents : Array(ResourceContents)
      self["contents"]?.try(&.as_a?).try(&.map { |item| ResourceContents.new(item) }) || [] of ResourceContents
    end
  end

  record ListResourcesResult, resources : Array(Resource), next_cursor : String? = nil
  record ListResourceTemplatesResult, resource_templates : Array(ResourceTemplate), next_cursor : String? = nil
end
