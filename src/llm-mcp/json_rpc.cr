# src/llm-mcp/json_rpc.cr
module LLM::MCP::JsonRpc
  PARSE_ERROR      = -32700_i64
  INVALID_REQUEST  = -32600_i64
  METHOD_NOT_FOUND = -32601_i64
  INVALID_PARAMS   = -32602_i64
  INTERNAL_ERROR   = -32603_i64

  alias Id = String | Int64 | Float64

  struct ErrorObject
    getter code : Int64
    getter message : String
    getter data : JSON::Any?

    def initialize(code : Int, @message : String, @data : JSON::Any? = nil)
      @code = code.to_i64
    end

    def to_json(builder : JSON::Builder) : Nil
      builder.object do
        builder.field "code", @code
        builder.field "message", @message
        @data.try { |value| builder.field "data", value }
      end
    end
  end

  abstract struct Message
    def to_json(builder : JSON::Builder) : Nil
      builder.object do
        builder.field "jsonrpc", "2.0"
        write_fields(builder)
      end
    end

    protected abstract def write_fields(builder : JSON::Builder) : Nil
  end

  struct Request < Message
    getter id : Id
    getter method : String
    getter params : JSON::Any?

    def initialize(@id : Id, @method : String, @params : JSON::Any? = nil)
    end

    protected def write_fields(builder : JSON::Builder) : Nil
      builder.field "id", @id
      builder.field "method", @method
      @params.try { |value| builder.field "params", value }
    end
  end

  struct Notification < Message
    getter method : String
    getter params : JSON::Any?

    def initialize(@method : String, @params : JSON::Any? = nil)
    end

    protected def write_fields(builder : JSON::Builder) : Nil
      builder.field "method", @method
      @params.try { |value| builder.field "params", value }
    end
  end

  abstract struct Response < Message
    abstract def id : Id
  end

  struct Success < Response
    getter id : Id
    getter result : JSON::Any

    def initialize(@id : Id, @result : JSON::Any)
    end

    protected def write_fields(builder : JSON::Builder) : Nil
      builder.field "id", @id
      builder.field "result", @result
    end
  end

  struct Failure < Response
    getter id : Id
    getter error : ErrorObject

    def initialize(@id : Id, @error : ErrorObject)
    end

    protected def write_fields(builder : JSON::Builder) : Nil
      builder.field "id", @id
      builder.field "error", @error
    end
  end

  def self.id?(value : JSON::Any?) : Id?
    case raw = value.try(&.raw)
    when String, Int64
      raw
    when Float64
      return nil unless raw.finite?
      raw == raw.round && raw.abs < 9.007199254740992e15 ? raw.to_i64 : raw
    end
  end

  def self.parse?(value : JSON::Any) : Message?
    hash = value.as_h?
    return unless hash && hash["jsonrpc"]?.try(&.as_s?) == "2.0"
    method = hash["method"]?.try(&.as_s?)
    id = id?(hash["id"]?)
    if method
      return Request.new(id, method, hash["params"]?) if id
      return Notification.new(method, hash["params"]?) unless hash.has_key?("id")
    end
    return unless id
    if hash.has_key?("result")
      Success.new(id, hash["result"]) unless hash.has_key?("error")
    else
      error_object(hash["error"]?).try { |error| Failure.new(id, error) }
    end
  end

  def self.parse(value : JSON::Any) : Message
    parse?(value) || raise RpcError.new(INVALID_REQUEST, "Invalid JSON-RPC message")
  end

  def self.request?(value : JSON::Any) : Bool
    parse?(value).is_a?(Request)
  end

  def self.notification?(value : JSON::Any) : Bool
    parse?(value).is_a?(Notification)
  end

  def self.response?(value : JSON::Any) : Bool
    parse?(value).is_a?(Response)
  end

  private def self.error_object(value : JSON::Any?) : ErrorObject?
    error = value.try(&.as_h?)
    return unless error
    code = error["code"]?.try { |item| item.as_i64? || item.as_f?.try { |float| float == float.round ? float.to_i64 : nil } }
    message = error["message"]?.try(&.as_s?)
    ErrorObject.new(code, message, error["data"]?) if code && message
  end
end
