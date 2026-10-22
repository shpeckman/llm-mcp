# src/llm-mcp/oauth/callback.cr
module LLM::MCP::OAuth
  record Callback, code : String, state : String, iss : String? = nil

  struct CallbackPage
    getter? ok : Bool
    getter message : String?
    getter details : String?

    def initialize(@ok : Bool, @message : String? = nil, @details : String? = nil)
    end

    def self.success : CallbackPage
      new(true)
    end

    def self.failure(message : String, details : String? = nil) : CallbackPage
      new(false, message, details)
    end

    def plain_text : String
      return "Authorization complete. You may close this window." if @ok
      details = @details
      details ? "#{@message}\n\n#{details}" : @message.to_s
    end
  end

  alias PageRenderer = Proc(CallbackPage, String)

  class PendingCallback
    getter state : String
    getter path : String?
    @result = Channel(Callback | Exception).new(1)
    getter? settled = false

    def initialize(@state : String, @path : String?)
    end

    def wait : Callback
      result = @result.receive
      raise result if result.is_a?(Exception)
      result
    end

    protected def settle(result : Callback | Exception) : Nil
      return if @settled
      @settled = true
      @result.send(result)
    end
  end

  class CallbackServer
    getter redirect_url : String
    @pending = {} of String => PendingCallback

    def self.listen(*, host : String = "127.0.0.1", redirect_host : String? = nil, port : Int32 = 0,
                    path : String = "/callback", extra_paths : Array(String) = [] of String,
                    timeout : Time::Span = 5.minutes, render_page : PageRenderer? = nil) : CallbackServer
      instance = nil.as(CallbackServer?)
      server = HTTP::Server.new { |context| instance.try &.handle(context) }
      address = server.bind_tcp(host, port)
      shown = redirect_host || host
      shown = "[#{shown}]" if shown.includes?(':')
      created = new(server, "http://#{shown}:#{address.port}#{path}", [path] + extra_paths, timeout, render_page)
      instance = created
      spawn { server.listen }
      created
    end

    protected def initialize(@server : HTTP::Server, @redirect_url : String, @paths : Array(String), @timeout : Time::Span,
                             @render_page : PageRenderer?)
    end

    def wait_for_callback(state : String, path : String? = nil) : PendingCallback
      raise Error.new("OAuth state is already pending") if @pending.has_key?(state)
      pending = PendingCallback.new(state, path)
      @pending[state] = pending
      spawn expire(pending)
      pending
    end

    def close : Nil
      pending = @pending.values
      @pending.clear
      pending.each(&.settle(Error.new("OAuth callback server closed")))
      @server.close
    end

    protected def handle(context : HTTP::Server::Context) : Nil
      request = context.request
      unless @paths.includes?(request.path)
        reply(context.response, 404, CallbackPage.failure("Not found"))
        return
      end
      params = request.query_params
      state = params["state"]?.presence
      pending = state.try { |key| @pending[key]? }
      unless state && pending
        reply(context.response, 400, CallbackPage.failure("Invalid or expired OAuth state"))
        return
      end
      @pending.delete(state)
      expected_path = pending.path
      if expected_path && request.path != expected_path
        pending.settle(Error.new("The authorization response arrived on another redirect URI"))
        reply(context.response, 400, CallbackPage.failure("Unexpected redirect URI"))
        return
      end
      if error = params["error"]?.presence
        description = params["error_description"]?.presence || error
        pending.settle(Error.new(description))
        reply(context.response, 200, CallbackPage.failure("Authorization failed. You may close this window.", description))
        return
      end
      code = params["code"]?.presence
      unless code
        pending.settle(Error.new("OAuth callback did not include an authorization code"))
        reply(context.response, 400, CallbackPage.failure("Missing authorization code"))
        return
      end
      pending.settle(Callback.new(code, state, params["iss"]?.presence))
      reply(context.response, 200, CallbackPage.success)
    end

    private def expire(pending : PendingCallback) : Nil
      sleep @timeout
      return if pending.settled?
      @pending.delete(pending.state) if @pending[pending.state]?.same?(pending)
      pending.settle(Error.new("OAuth callback timed out"))
    end

    private def reply(response : HTTP::Server::Response, status : Int32, page : CallbackPage) : Nil
      response.status_code = status
      if render = @render_page
        response.headers["content-type"] = "text/html; charset=utf-8"
        response.headers["cache-control"] = "no-store"
        response.print(render.call(page))
      else
        response.headers["content-type"] = "text/plain; charset=utf-8"
        response.print(page.plain_text)
      end
    end
  end
end
