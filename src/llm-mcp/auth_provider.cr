# src/llm-mcp/auth_provider.cr
module LLM::MCP
  record UnauthorizedContext, response : HttpResponse, server_url : URI, fetch : Fetch, token : String?

  abstract class AuthProvider
    abstract def token : String?

    def on_unauthorized(context : UnauthorizedContext) : Bool
      false
    end
  end
end
