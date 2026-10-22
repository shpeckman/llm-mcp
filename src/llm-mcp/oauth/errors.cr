# src/llm-mcp/oauth/errors.cr
module LLM::MCP::OAuth
  class ResponseError < Error
    getter code : String
    getter error_uri : String?

    def initialize(@code : String, message : String, @error_uri : String? = nil)
      super(message.empty? ? code : message)
    end
  end

  class IssuerMismatchError < Error
    getter expected : String?
    getter received : String?

    def initialize(@expected : String?, @received : String?)
      super("OAuth issuer mismatch: expected #{IssuerMismatchError.format(expected)}, received #{IssuerMismatchError.format(received)}")
    end

    protected def self.format(issuer : String?) : String
      issuer.nil? ? "none" : issuer.to_json
    end
  end

  class InsecureEndpointError < Error
    getter endpoint : String

    def initialize(@endpoint : String)
      super("Refusing to send OAuth credentials to non-HTTPS endpoint #{endpoint}")
    end
  end

  class RegistrationError < Error
    getter status : Int32
    getter body : String

    def initialize(@status : Int32, @body : String)
      super("OAuth dynamic client registration failed with status #{status}: #{body}")
    end
  end

  class AuthorizationRequiredError < Error
    def initialize
      super("MCP OAuth authorization requires user interaction")
    end
  end
end
