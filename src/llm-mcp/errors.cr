# src/llm-mcp/errors.cr
module LLM::MCP
  def self.milliseconds(span : Time::Span) : String
    value = span.total_milliseconds
    value == value.round ? value.to_i64.to_s : value.to_s
  end

  class Error < Exception
  end

  class RpcError < Error
    getter code : Int64
    getter data : JSON::Any?

    def initialize(code : Int, message : String, @data : JSON::Any? = nil)
      @code = code.to_i64
      super(message)
    end
  end

  class ConnectionClosedError < Error
    def initialize(message : String = "MCP connection closed")
      super(message)
    end
  end

  class TimeoutError < Error
    getter timeout : Time::Span

    def initialize(@timeout : Time::Span)
      super("MCP request timed out after #{LLM::MCP.milliseconds(timeout)}ms")
    end
  end

  class AbortError < Error
    def initialize(message : String = "MCP request aborted")
      super(message)
    end
  end

  class HttpError < Error
    getter status : Int32
    getter body : String

    def initialize(@status : Int32, message : String, @body : String = "")
      super(message)
    end
  end

  class AuthRequiredError < HttpError
    getter www_authenticate : String?

    def initialize(@www_authenticate : String?, body : String = "")
      super(401, "MCP server requires authentication", body)
    end
  end

  class SessionExpiredError < HttpError
    def initialize(body : String = "")
      super(404, "MCP session expired", body)
    end
  end
end
