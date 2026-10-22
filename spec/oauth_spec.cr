# spec/oauth_spec.cr
require "./spec_helper"

private alias MCP = LLM::MCP
private alias OAuth = LLM::MCP::OAuth

private class TestOAuthProvider < OAuth::ClientProvider
  getter redirect_url : String
  getter client_metadata : OAuth::ClientMetadata
  property client : OAuth::ClientInformation? = nil
  property token_set : OAuth::Tokens? = nil
  property verifier : String? = nil
  property discovery : OAuth::DiscoveryState? = nil
  property authorization_url : URI? = nil

  def initialize(@redirect_url : String)
    @client_metadata = OAuth::ClientMetadata.new(
      redirect_uris: [redirect_url], client_name: "llm-mcp-test",
      grant_types: ["authorization_code", "refresh_token"], response_types: ["code"],
      token_endpoint_auth_method: "none")
  end

  def state : String?
    "expected-state"
  end

  def client_information : OAuth::ClientInformation?
    @client
  end

  def save_client_information(information : OAuth::ClientInformation) : Nil
    @client = information
  end

  def tokens : OAuth::Tokens?
    @token_set
  end

  def save_tokens(tokens : OAuth::Tokens) : Nil
    @token_set = tokens
  end

  def redirect_to_authorization(url : URI) : Nil
    @authorization_url = url
  end

  def save_code_verifier(verifier : String) : Nil
    @verifier = verifier
  end

  def code_verifier : String
    @verifier || raise "Missing code verifier"
  end

  def invalidate_credentials(kind : OAuth::CredentialKind) : Nil
    @client = nil if kind.all? || kind.client?
    @token_set = nil if kind.all? || kind.tokens?
    @verifier = nil if kind.all? || kind.verifier?
    @discovery = nil if kind.all? || kind.discovery?
  end

  def save_discovery_state(state : OAuth::DiscoveryState) : Nil
    @discovery = state
  end

  def discovery_state : OAuth::DiscoveryState?
    @discovery
  end
end

private def send_json(context : HTTP::Server::Context, value, status : Int32 = 200) : Nil
  context.response.status_code = status
  context.response.content_type = "application/json"
  context.response.print(value.to_json)
end

private def form(context : HTTP::Server::Context) : URI::Params
  URI::Params.parse(TestHttp.read_body(context))
end

private def as_metadata(origin : String) : JSON::Any
  json({issuer: origin, authorization_endpoint: "#{origin}/authorize", token_endpoint: "#{origin}/token",
        response_types_supported: ["code"]}.to_json)
end

private def unauthorized(origin : String, header : String, token : String?, status : Int32 = 401) : MCP::UnauthorizedContext
  response = MCP::HttpResponse.new(status, HTTP::Headers{"www-authenticate" => header}, "")
  MCP::UnauthorizedContext.new(response, URI.parse("#{origin}/mcp"), MCP::DEFAULT_FETCH, token)
end

private def query(url : URI?, key : String) : String?
  url.try(&.query_params[key]?)
end

private def background(&block : -> T) : Channel(T | Exception) forall T
  channel = Channel(T | Exception).new(1)
  spawn do
    channel.send(block.call)
  rescue error
    channel.send(error)
  end
  channel
end

describe "LLM::MCP OAuth" do
  it "discovers, registers, authorizes with PKCE, and refreshes on 401" do
    expected_challenge = nil.as(String?)
    refreshes = 0
    origin = TestHttp.listen do |context, server_origin|
      request = context.request
      case request.path
      when "/.well-known/oauth-protected-resource/mcp"
        send_json(context, {resource: "#{server_origin}/mcp", authorization_servers: [server_origin], scopes_supported: ["org:read"]})
      when "/.well-known/oauth-authorization-server"
        send_json(context, {
          issuer: server_origin, authorization_endpoint: "#{server_origin}/authorize", token_endpoint: "#{server_origin}/token",
          registration_endpoint: "#{server_origin}/register", response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"], token_endpoint_auth_methods_supported: ["none"],
          code_challenge_methods_supported: ["S256"],
        })
      when "/register"
        metadata = JSON.parse(TestHttp.read_body(context)).as_h
        metadata["client_id"] = JSON::Any.new("test-client")
        metadata["client_secret"] = JSON::Any.new("")
        send_json(context, metadata, 201)
      when "/authorize"
        params = request.query_params
        expected_challenge = params["code_challenge"]?
        redirect = URI.parse(params["redirect_uri"])
        redirect.query_params = URI::Params{"code" => "test-code", "state" => params["state"]? || ""}
        context.response.status_code = 302
        context.response.headers["location"] = redirect.to_s
      when "/token"
        params = form(context)
        if params["grant_type"]? == "refresh_token"
          refreshes += 1
          send_json(context, json(%({"access_token":"refreshed-token","token_type":"Bearer","refresh_token":"","expires_in":null})))
          next
        end
        challenge = Base64.urlsafe_encode(Digest::SHA256.digest(params["code_verifier"]? || ""), padding: false)
        if params["code"]? != "test-code" || challenge != expected_challenge
          send_json(context, {error: "invalid_grant"}, 400)
          next
        end
        send_json(context, {access_token: "first-token", refresh_token: "refresh-token", token_type: "Bearer", scope: ""})
      when "/mcp"
        case request.method
        when "GET"
          context.response.status_code = 405
          next
        when "DELETE"
          next
        end
        token = request.headers["authorization"]?
        unless token == "Bearer first-token" || token == "Bearer refreshed-token"
          TestHttp.read_body(context)
          context.response.status_code = 401
          context.response.headers["www-authenticate"] =
            %(Bearer resource_metadata="#{server_origin}/.well-known/oauth-protected-resource/mcp", scope="")
          context.response.print("Unauthorized")
          next
        end
        message = JSON.parse(TestHttp.read_body(context))
        unless message.as_h.has_key?("id")
          context.response.status_code = 202
          next
        end
        result = if message["method"] == "initialize"
                   json(%({"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"oauth-test","version":"1.0.0"}}))
                 else
                   json(%({"tools":[{"name":"issues","inputSchema":{"type":"object"}}]}))
                 end
        send_json(context, {jsonrpc: "2.0", id: message["id"], result: result})
      else
        context.response.status_code = 404
      end
    end

    callback = OAuth::CallbackServer.listen
    provider = TestOAuthProvider.new(callback.redirect_url)
    transport = -> do
      MCP::StreamableHttpTransport.new("#{origin}/mcp", headers: {"Authorization" => "Bearer caller-supplied-stale-token"},
        auth_provider: OAuth.adapt_oauth_provider(provider), open_get_stream: false)
    end
    expect_raises(OAuth::AuthorizationRequiredError) { MCP::Client.new("oauth-test", "1.0.0").connect(transport.call) }
    query(provider.authorization_url, "scope").should eq("org:read")
    query(provider.authorization_url, "resource").should eq("#{origin}/mcp")

    pending = callback.wait_for_callback("expected-state")
    authorization = HTTP::Client.get(provider.authorization_url.not_nil!)
    HTTP::Client.get(authorization.headers["location"])
    code = pending.wait.code
    OAuth.authorize_mcp(provider, server_url: "#{origin}/mcp", authorization_code: code).should eq(OAuth::FlowResult::Authorized)

    client = MCP::Client.new("oauth-test", "1.0.0")
    client.connect(transport.call)
    client.list_tools.map(&.raw).should eq([json(%({"name":"issues","inputSchema":{"type":"object"}}))])
    client.close

    provider.token_set = provider.token_set.not_nil!.copy_with(access_token: "stale-token")
    refreshed = MCP::Client.new("oauth-test", "1.0.0")
    refreshed.connect(transport.call)
    provider.token_set.should eq(OAuth::Tokens.new(access_token: "refreshed-token", refresh_token: "refresh-token",
      token_type: "Bearer", scope: "org:read"))
    refreshes.should eq(1)
    refreshed.close
    callback.close
  end

  it "shares one refresh between concurrent 401s when refresh tokens rotate" do
    grants = [] of String
    origin = TestHttp.listen do |context, server_origin|
      case context.request.path
      when "/.well-known/oauth-protected-resource/mcp"
        send_json(context, {resource: "#{server_origin}/mcp", authorization_servers: ["not a url"]})
      when "/.well-known/oauth-authorization-server"
        send_json(context, as_metadata(server_origin))
      when "/token"
        refresh_token = form(context)["refresh_token"]? || ""
        grants << refresh_token
        if refresh_token != "r1"
          send_json(context, {error: "invalid_grant"}, 400)
          next
        end
        sleep 20.milliseconds
        send_json(context, {access_token: "a2", refresh_token: "r2", token_type: "Bearer", expires_in: 3600})
      else
        context.response.status_code = 404
      end
    end
    store = OAuth::MemoryStateStore.new
    provider = OAuth::Provider.new("#{origin}/mcp", "http://127.0.0.1/callback", OAuth::ClientMetadata.new(client_name: "test"),
      client_id: "client", store: store) { }
    provider.save_tokens(OAuth::Tokens.new(access_token: "a1", refresh_token: "r1", token_type: "Bearer"))
    auth = OAuth.adapt_oauth_provider(provider)
    first = background { auth.on_unauthorized(unauthorized(origin, "Bearer", "a1")) }
    second = background { auth.on_unauthorized(unauthorized(origin, "Bearer", "a1")) }
    first.receive.should be_true
    second.receive.should be_true
    auth.on_unauthorized(unauthorized(origin, "Bearer", "a1"))
    grants.should eq(["r1"])
    auth.token.should eq("a2")
    state = store.load.not_nil!
    state.tokens.not_nil!.refresh_token.should eq("r2")
    state.tokens_expire_at.not_nil!.should be > Time.utc.to_unix_ms + 3_500_000
  end

  it "asks for authorization instead of refreshing when the server needs more scope" do
    provider = TestOAuthProvider.new("http://127.0.0.1/callback")
    provider.client = OAuth::ClientInformation.new("client")
    provider.token_set = OAuth::Tokens.new(access_token: "a1", refresh_token: "r1", token_type: "Bearer", scope: "repo read:org")
    origin = TestHttp.listen do |context, server_origin|
      if context.request.path == "/.well-known/oauth-authorization-server"
        send_json(context, as_metadata(server_origin))
      else
        context.response.status_code = context.request.path == "/token" ? 500 : 404
      end
    end
    auth = OAuth.adapt_oauth_provider(provider)
    expect_raises(OAuth::AuthorizationRequiredError) do
      auth.on_unauthorized(unauthorized(origin, %(Bearer error="insufficient_scope", scope="repo admin"), "a1", 403))
    end
    query(provider.authorization_url, "scope").should eq("repo read:org admin")
    provider.token_set.not_nil!.access_token.should eq("a1")
  end

  it "binds persisted credentials to the exact MCP server URL" do
    store = OAuth::MemoryStateStore.new
    first = OAuth::Provider.new("https://one.example/mcp", "http://127.0.0.1/callback",
      OAuth::ClientMetadata.new(client_name: "test"), store: store) { }
    first.save_tokens(OAuth::Tokens.new(access_token: "secret", token_type: "Bearer"))
    first.tokens.not_nil!.access_token.should eq("secret")
    second = OAuth::Provider.new("https://two.example/mcp", "http://127.0.0.1/callback",
      OAuth::ClientMetadata.new(client_name: "test"), store: store) { }
    second.tokens.should be_nil
  end

  it "registers with an application_type derived from the redirect URIs unless one is set" do
    bodies = [] of JSON::Any
    origin = TestHttp.listen do |context, _origin|
      metadata = JSON.parse(TestHttp.read_body(context))
      bodies << metadata
      hash = metadata.as_h.dup
      hash["client_id"] = JSON::Any.new("client")
      send_json(context, hash, 201)
    end
    register = ->(redirect_uris : Array(String), application_type : String?) do
      OAuth.register_client(origin, client_metadata: OAuth::ClientMetadata.new(redirect_uris: redirect_uris, application_type: application_type))
    end
    register.call(["http://127.0.0.1:1234/callback"], nil)
    register.call(["http://[::1]/callback"], nil)
    register.call(["com.example.app:/callback"], nil)
    register.call(["https://app.example/callback"], nil)
    register.call(["http://localhost/callback"], "web")
    bodies.map(&.["application_type"].as_s).should eq(["native", "native", "native", "web", "web"])
  end

  it "rejects authorization metadata whose issuer does not match discovery" do
    origin = TestHttp.listen do |context, server_origin|
      if context.request.path == "/.well-known/oauth-authorization-server"
        send_json(context, {issuer: "https://attacker.example", authorization_endpoint: "#{server_origin}/authorize",
                            token_endpoint: "#{server_origin}/token", response_types_supported: ["code"]})
      else
        context.response.status_code = 404
      end
    end
    expect_raises(OAuth::IssuerMismatchError) { OAuth.discover_authorization_server_metadata(origin) }
  end

  it "uses a configured authorization server metadata document as is" do
    origin = TestHttp.listen do |context, server_origin|
      case context.request.path
      when "/.well-known/oauth-protected-resource/mcp"
        send_json(context, {resource: "#{server_origin}/mcp", authorization_servers: [server_origin]})
      when "/idp/metadata.json"
        send_json(context, {issuer: "https://idp.example", authorization_endpoint: "#{server_origin}/idp/authorize",
                            token_endpoint: "#{server_origin}/idp/token", response_types_supported: ["code"]})
      else
        context.response.status_code = 404
      end
    end
    provider = TestOAuthProvider.new("http://127.0.0.1/callback")
    provider.client = OAuth::ClientInformation.new("client")
    OAuth.authorize_mcp(provider, server_url: "#{origin}/mcp",
      authorization_server_metadata_url: URI.parse("#{origin}/idp/metadata.json")).should eq(OAuth::FlowResult::Redirect)
    authorization_url = provider.authorization_url.not_nil!
    "#{OAuth::Url.origin(authorization_url)}#{authorization_url.path}".should eq("#{origin}/idp/authorize")
    query(authorization_url, "resource").should eq("#{origin}/mcp")
    expect_raises(OAuth::InsecureEndpointError) do
      OAuth.authorize_mcp(provider, server_url: "#{origin}/mcp",
        authorization_server_metadata_url: URI.parse("http://idp.example/metadata.json"))
    end
  end

  it "exchanges a code only when its iss parameter names the authorization server" do
    codes = [] of String
    origin = TestHttp.listen do |context, _origin|
      unless context.request.method == "POST"
        context.response.status_code = 404
        next
      end
      codes << (form(context)["code"]? || "")
      send_json(context, {access_token: "token", token_type: "Bearer"})
    end
    exchange = ->(code : String, iss : String?, supported : Bool, with_metadata : Bool) do
      provider = TestOAuthProvider.new("http://127.0.0.1/callback")
      provider.client = OAuth::ClientInformation.new("client")
      provider.verifier = "verifier"
      metadata = with_metadata ? OAuth::AuthorizationServerMetadata.parse(json({
        issuer: origin, authorization_endpoint: "#{origin}/authorize", token_endpoint: "#{origin}/token",
        response_types_supported: ["code"], authorization_response_iss_parameter_supported: supported,
      }.to_json)) : nil
      provider.discovery = OAuth::DiscoveryState.new(origin, metadata)
      OAuth.authorize_mcp(provider, server_url: "#{origin}/mcp", authorization_code: code, iss: iss)
    end
    expect_raises(OAuth::IssuerMismatchError) { exchange.call("other", "https://attacker.example", false, true) }
    expect_raises(OAuth::IssuerMismatchError) { exchange.call("missing", nil, true, true) }
    exchange.call("matching", origin, true, true).should eq(OAuth::FlowResult::Authorized)
    exchange.call("omitted", nil, false, true).should eq(OAuth::FlowResult::Authorized)
    expect_raises(OAuth::IssuerMismatchError) { exchange.call("unverifiable", "https://attacker.example", false, false) }
    exchange.call("no-metadata", nil, false, false).should eq(OAuth::FlowResult::Authorized)
    codes.should eq(["matching", "omitted", "no-metadata"])
  end

  it "stops when its signal aborts, without falling back to a redirect" do
    stalled = [] of String
    origin = TestHttp.listen do |context, _origin|
      stalled << context.request.path
      TestHttp.park
    end
    run = ->(provider : TestOAuthProvider) do
      controller = MCP::AbortController.new
      count = stalled.size
      flow = background { OAuth.authorize_mcp(provider, server_url: "#{origin}/mcp", signal: controller.signal) }
      eventually { stalled.size == count + 1 }
      controller.abort
      flow.receive.should be_a(MCP::AbortError)
      provider.authorization_url.should be_nil
      stalled.last
    end
    run.call(TestOAuthProvider.new("http://127.0.0.1/callback")).should eq("/.well-known/oauth-protected-resource/mcp")

    refreshing = TestOAuthProvider.new("http://127.0.0.1/callback")
    refreshing.client = OAuth::ClientInformation.new("client")
    refreshing.token_set = OAuth::Tokens.new(access_token: "a1", refresh_token: "r1", token_type: "Bearer")
    refreshing.discovery = OAuth::DiscoveryState.new(origin, OAuth::AuthorizationServerMetadata.parse(as_metadata(origin)))
    run.call(refreshing).should eq("/token")
  end
end

describe LLM::MCP::OAuth::CallbackServer do
  it "renders plain text by default" do
    callback = OAuth::CallbackServer.listen
    begin
      pending = callback.wait_for_callback("s1")
      response = HTTP::Client.get("#{callback.redirect_url}?code=abc&state=s1")
      response.headers["content-type"].should eq("text/plain; charset=utf-8")
      response.body.should eq("Authorization complete. You may close this window.")
      pending.wait.code.should eq("abc")
    ensure
      callback.close
    end
  end

  it "rejects a response on another path than the expected one" do
    callback = OAuth::CallbackServer.listen(extra_paths: ["/callback/server-id"])
    begin
      origin = OAuth::Url.origin(URI.parse(callback.redirect_url))
      mixed_up = callback.wait_for_callback("s1", "/callback/server-id")
      HTTP::Client.get("#{origin}/callback?code=abc&state=s1").status_code.should eq(400)
      expect_raises(MCP::Error, "arrived on another redirect URI") { mixed_up.wait }

      pending = callback.wait_for_callback("s2", "/callback/server-id")
      HTTP::Client.get("#{origin}/callback/server-id?code=abc&state=s2").status_code.should eq(200)
      pending.wait.code.should eq("abc")
    ensure
      callback.close
    end
  end

  it "renders pages through render_page" do
    pages = [] of OAuth::CallbackPage
    renderer = ->(page : OAuth::CallbackPage) do
      pages << page
      page.ok? ? "<p>ok</p>" : "<p>#{page.message}</p>"
    end
    callback = OAuth::CallbackServer.listen(render_page: renderer)
    begin
      denied = callback.wait_for_callback("s1")
      failure = HTTP::Client.get("#{callback.redirect_url}?error=access_denied&error_description=Denied&state=s1")
      failure.headers["content-type"].should eq("text/html; charset=utf-8")
      expect_raises(MCP::Error, "Denied") { denied.wait }
      pages.last.should eq(OAuth::CallbackPage.failure("Authorization failed. You may close this window.", "Denied"))

      pending = callback.wait_for_callback("s2")
      HTTP::Client.get("#{callback.redirect_url}?code=abc&state=s2").body.should eq("<p>ok</p>")
      pending.wait.code.should eq("abc")
    ensure
      callback.close
    end
  end
end
