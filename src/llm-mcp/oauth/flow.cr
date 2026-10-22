# src/llm-mcp/oauth/flow.cr
module LLM::MCP::OAuth
  alias AddClientAuthentication = Proc(HTTP::Headers, URI::Params, URI, AuthorizationServerMetadata?, Nil)

  enum CredentialKind
    All
    Client
    Tokens
    Verifier
    Discovery
  end

  enum FlowResult
    Authorized
    Redirect
  end

  abstract class ClientProvider
    abstract def redirect_url : String
    abstract def client_metadata : ClientMetadata
    abstract def client_information : ClientInformation?
    abstract def save_client_information(information : ClientInformation) : Nil
    abstract def tokens : Tokens?
    abstract def save_tokens(tokens : Tokens) : Nil
    abstract def redirect_to_authorization(url : URI) : Nil
    abstract def save_code_verifier(verifier : String) : Nil
    abstract def code_verifier : String

    def client_metadata_document(metadata : AuthorizationServerMetadata?) : ClientMetadataDocument?
      nil
    end

    def state : String?
      nil
    end

    def add_client_authentication : AddClientAuthentication?
      nil
    end

    def invalidate_credentials(kind : CredentialKind) : Nil
    end

    def save_discovery_state(state : DiscoveryState) : Nil
    end

    def discovery_state : DiscoveryState?
      nil
    end
  end

  record FlowOptions, server_url : URI, authorization_code : String? = nil, iss : String? = nil, scope : String? = nil,
    resource_metadata_url : URI? = nil, authorization_server_metadata_url : URI? = nil, fetch : Fetch? = nil,
    signal : AbortSignal? = nil, skip_issuer_validation : Bool = false, skip_refresh : Bool = false

  record TokenRequestOptions, client_information : ClientInformation, metadata : AuthorizationServerMetadata? = nil,
    resource : String? = nil, add_client_authentication : AddClientAuthentication? = nil, fetch : Fetch? = nil,
    signal : AbortSignal? = nil

  record Authorization, url : URI, code_verifier : String

  CLIENT_AUTH_METHODS = {"client_secret_basic", "client_secret_post", "none"}

  def self.application_type(redirect_uris : Enumerable(String)) : String
    native = redirect_uris.any? do |uri|
      parsed = Url.parse?(uri)
      next false unless parsed
      scheme = parsed.scheme.to_s.downcase
      (scheme != "http" && scheme != "https") || Url.loopback?(parsed)
    end
    native ? "native" : "web"
  end

  def self.secure_endpoint(value : String | URI) : URI
    url = Url.parse(value)
    raise InsecureEndpointError.new(url.to_s) unless url.scheme == "https" || Url.loopback?(url)
    url
  end

  def self.start_authorization(authorization_server_url : String | URI, *, client_information : ClientInformation,
                               redirect_url : String | URI, metadata : AuthorizationServerMetadata? = nil,
                               scope : String? = nil, state : String? = nil, resource : String? = nil) : Authorization
    if metadata && !metadata.response_types_supported.includes?("code")
      raise Error.new("Authorization server does not support authorization codes")
    end
    if (methods = metadata.try(&.code_challenge_methods_supported)) && !methods.includes?("S256")
      raise Error.new("Authorization server does not support PKCE S256")
    end
    endpoint = metadata ? Url.parse(metadata.authorization_endpoint) : Url.resolve(Url.parse(authorization_server_url), "/authorize")
    verifier, challenge = pkce
    params = {
      "response_type"         => "code",
      "client_id"             => client_information.client_id,
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
      "redirect_uri"          => redirect_url.to_s,
    }
    params["state"] = state if state && !state.empty?
    if scope && !scope.empty?
      params["scope"] = scope
      params["prompt"] = "consent" if scope.split(/\s+/).includes?("offline_access")
    end
    params["resource"] = resource if resource && !resource.empty?
    Authorization.new(Url.with_params(endpoint, params), verifier)
  end

  def self.register_client(authorization_server_url : String | URI, *, client_metadata : ClientMetadata,
                           metadata : AuthorizationServerMetadata? = nil, scope : String? = nil, fetch : Fetch? = nil,
                           signal : AbortSignal? = nil) : ClientInformation
    endpoint = metadata.try(&.registration_endpoint)
    if metadata && endpoint.nil?
      raise Error.new("Authorization server does not support dynamic client registration")
    end
    url = endpoint ? Url.parse(endpoint) : Url.resolve(Url.parse(authorization_server_url), "/register")
    body = JSON.parse(client_metadata.to_json).as_h
    body["application_type"] = JSON::Any.new(client_metadata.application_type || application_type(client_metadata.redirect_uris || [] of String))
    body["scope"] = JSON::Any.new(scope) if scope && !scope.empty?
    headers = HTTP::Headers{"Accept" => "application/json", "content-type" => "application/json"}
    response = (fetch || DEFAULT_FETCH).call(HttpRequest.new("POST", url, headers, body.to_json, signal))
    raise RegistrationError.new(response.status, response.text) unless response.ok?
    ClientInformation.parse(response.json)
  end

  def self.exchange_authorization_code(authorization_server_url : String | URI, options : TokenRequestOptions, *,
                                       code : String, code_verifier : String, redirect_url : String | URI) : Tokens
    params = URI::Params{
      "grant_type"    => "authorization_code",
      "code"          => code,
      "code_verifier" => code_verifier,
      "redirect_uri"  => redirect_url.to_s,
    }
    token_request(authorization_server_url, options, params)
  end

  def self.refresh_authorization(authorization_server_url : String | URI, options : TokenRequestOptions, *,
                                 refresh_token : String) : Tokens
    params = URI::Params{"grant_type" => "refresh_token", "refresh_token" => refresh_token}
    tokens = token_request(authorization_server_url, options, params)
    tokens.refresh_token ? tokens : tokens.copy_with(refresh_token: refresh_token)
  end

  def self.step_up_scope(granted : String?, challenged : String?) : String?
    return if challenged.nil? || challenged.empty?
    scopes = [granted, challenged].flat_map { |scope| scope.try(&.split(/\s+/).reject(&.empty?)) || [] of String }
    scopes.uniq.join(' ')
  end

  def self.authorize_mcp(provider : ClientProvider, *, server_url : String | URI, authorization_code : String? = nil,
                         iss : String? = nil, scope : String? = nil, resource_metadata_url : URI? = nil,
                         authorization_server_metadata_url : URI? = nil, fetch : Fetch? = nil,
                         signal : AbortSignal? = nil, skip_issuer_validation : Bool = false,
                         skip_refresh : Bool = false) : FlowResult
    authorize_mcp(provider, FlowOptions.new(Url.parse(server_url), authorization_code, iss, scope, resource_metadata_url,
      authorization_server_metadata_url, fetch, signal, skip_issuer_validation, skip_refresh))
  end

  def self.authorize_mcp(provider : ClientProvider, options : FlowOptions) : FlowResult
    run_flow(provider, options)
  rescue error : ResponseError
    case error.code
    when "invalid_client", "unauthorized_client"
      provider.invalidate_credentials(CredentialKind::All)
      run_flow(provider, options)
    when "invalid_grant"
      provider.invalidate_credentials(CredentialKind::Tokens)
      run_flow(provider, options)
    else
      raise error
    end
  end

  private def self.pkce : {String, String}
    verifier = Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
    challenge = Base64.urlsafe_encode(Digest::SHA256.digest(verifier), padding: false)
    {verifier, challenge}
  end

  private def self.select_client_auth_method(information : ClientInformation, supported : Array(String)) : String
    hinted = information.token_endpoint_auth_method
    if hinted && CLIENT_AUTH_METHODS.includes?(hinted) && (supported.empty? || supported.includes?(hinted))
      return hinted
    end
    secret = information.client_secret
    return secret ? "client_secret_basic" : "none" if supported.empty?
    return "client_secret_basic" if secret && supported.includes?("client_secret_basic")
    return "client_secret_post" if secret && supported.includes?("client_secret_post")
    return "none" if supported.includes?("none")
    secret ? "client_secret_post" : "none"
  end

  private def self.apply_client_authentication(method : String, information : ClientInformation, headers : HTTP::Headers,
                                               params : URI::Params) : Nil
    if method == "client_secret_basic"
      secret = information.client_secret
      raise Error.new("client_secret_basic requires a client secret") unless secret
      headers["Authorization"] = "Basic #{Base64.strict_encode("#{information.client_id}:#{secret}")}"
    else
      params["client_id"] = information.client_id
      secret = information.client_secret
      params["client_secret"] = secret if method == "client_secret_post" && secret
    end
  end

  private def self.token_request(authorization_server_url : String | URI, options : TokenRequestOptions,
                                 params : URI::Params) : Tokens
    metadata = options.metadata
    url = secure_endpoint(metadata ? metadata.token_endpoint : Url.resolve(Url.parse(authorization_server_url), "/token"))
    headers = HTTP::Headers{"Accept" => "application/json", "content-type" => "application/x-www-form-urlencoded"}
    options.resource.try { |resource| params["resource"] = resource unless resource.empty? }
    if add = options.add_client_authentication
      add.call(headers, params, url, metadata)
    else
      method = select_client_auth_method(options.client_information, metadata.try(&.token_endpoint_auth_methods_supported) || [] of String)
      apply_client_authentication(method, options.client_information, headers, params)
    end
    response = (options.fetch || DEFAULT_FETCH).call(HttpRequest.new("POST", url, headers, params.to_s, options.signal))
    text = response.text
    value = begin
      JSON.parse(text)
    rescue JSON::ParseException
      nil
    end
    if (object = value.try(&.as_h?)) && (code = object["error"]?.try(&.as_s?))
      description = object["error_description"]?.try(&.as_s?) || code
      raise ResponseError.new(code, description, object["error_uri"]?.try(&.as_s?))
    end
    raise ResponseError.new("server_error", "HTTP #{response.status}: #{text}") unless response.ok?
    Tokens.parse(value)
  end

  private def self.with_scope(tokens : Tokens, scope : String?) : Tokens
    tokens.scope.nil? && scope && !scope.empty? ? tokens.copy_with(scope: scope) : tokens
  end

  private def self.discover(provider : ClientProvider, options : FlowOptions, metadata_url : URI?) : ServerInfo
    cached = metadata_url ? nil : provider.discovery_state
    if cached && !cached.authorization_server_url.empty?
      metadata = cached.authorization_server_metadata ||
                 discover_authorization_server_metadata(cached.authorization_server_url, fetch: options.fetch,
                   skip_issuer_validation: options.skip_issuer_validation, signal: options.signal)
      return ServerInfo.new(cached.authorization_server_url, metadata, cached.resource_metadata)
    end
    discover_oauth_server_info(options.server_url, resource_metadata_url: options.resource_metadata_url,
      authorization_server_metadata_url: metadata_url, fetch: options.fetch,
      skip_issuer_validation: options.skip_issuer_validation, signal: options.signal)
  end

  private def self.run_flow(provider : ClientProvider, options : FlowOptions) : FlowResult
    metadata_url = options.authorization_server_metadata_url.try { |url| secure_endpoint(url) }
    discovered = discover(provider, options, metadata_url)
    unless metadata_url
      provider.save_discovery_state(DiscoveryState.new(discovered.authorization_server_url,
        discovered.authorization_server_metadata, discovered.resource_metadata, options.resource_metadata_url.try(&.to_s)))
    end
    metadata = discovered.authorization_server_metadata
    resource = select_resource(options.server_url, discovered.resource_metadata)
    scope = options.scope.presence ||
            discovered.resource_metadata.try(&.scopes_supported).try(&.join(' ')).presence ||
            provider.client_metadata.scope.presence
    stored = provider.client_information
    document = stored ? nil : provider.client_metadata_document(metadata)
    if document
      document_url = Url.parse?(document.url)
      unless document_url && document_url.scheme == "https" && document_url.path != "/"
        raise Error.new("Invalid OAuth client metadata URL")
      end
    end
    client = stored || document.try { |found| ClientInformation.new(found.url) }
    unless client
      raise Error.new("OAuth client information is missing during code exchange") if options.authorization_code
      client = register_client(discovered.authorization_server_url, metadata: metadata,
        client_metadata: provider.client_metadata, scope: scope, fetch: options.fetch, signal: options.signal)
      provider.save_client_information(client)
    end
    redirect_url = document.try(&.redirect_url) || provider.redirect_url
    token_options = TokenRequestOptions.new(client, metadata, resource, provider.add_client_authentication,
      options.fetch, options.signal)
    if code = options.authorization_code
      iss = options.iss
      if !iss.nil? || metadata.try(&.authorization_response_iss_parameter_supported)
        expected = metadata.try(&.issuer)
        raise IssuerMismatchError.new(expected, iss) unless iss == expected
      end
      tokens = exchange_authorization_code(discovered.authorization_server_url, token_options,
        code: code, code_verifier: provider.code_verifier, redirect_url: redirect_url)
      provider.save_tokens(with_scope(tokens, scope))
      return FlowResult::Authorized
    end
    existing = options.skip_refresh ? nil : provider.tokens
    if existing && (refresh_token = existing.refresh_token)
      begin
        tokens = refresh_authorization(discovered.authorization_server_url, token_options, refresh_token: refresh_token)
        provider.save_tokens(with_scope(tokens, existing.scope))
        return FlowResult::Authorized
      rescue error
        raise error if options.signal.try(&.aborted?) || error.is_a?(InsecureEndpointError)
        raise error if error.is_a?(ResponseError) && error.code != "server_error"
      end
    end
    authorization = start_authorization(discovered.authorization_server_url, metadata: metadata,
      client_information: client, redirect_url: redirect_url, scope: scope, state: provider.state, resource: resource)
    provider.save_code_verifier(authorization.code_verifier)
    provider.redirect_to_authorization(authorization.url)
    FlowResult::Redirect
  end

  class OAuthAuthProvider < AuthProvider
    private class Recovery
      @done = Channel(Nil).new
      @error : Exception? = nil

      def finish(error : Exception?) : Nil
        @error = error
        @done.close
      end

      def wait : Nil
        @done.receive?
        @error.try { |error| raise error }
      end
    end

    getter provider : ClientProvider
    @in_flight : Recovery? = nil

    def initialize(@provider : ClientProvider)
    end

    def token : String?
      @provider.tokens.try(&.access_token)
    end

    def on_unauthorized(context : UnauthorizedContext) : Bool
      challenge = OAuth.parse_www_authenticate(context.response.headers["www-authenticate"]?)
      insufficient_scope = challenge.error == "insufficient_scope"
      if !insufficient_scope && @in_flight.nil? && (rejected = context.token)
        current = @provider.tokens.try(&.access_token)
        return true if current && current != rejected
      end
      if recovery = @in_flight
        recovery.wait
        return true
      end
      recovery = Recovery.new
      @in_flight = recovery
      begin
        recover(context, challenge, insufficient_scope)
        recovery.finish(nil)
      rescue error
        recovery.finish(error)
      ensure
        @in_flight = nil
      end
      recovery.wait
      true
    end

    private def recover(context : UnauthorizedContext, challenge : Challenge, insufficient_scope : Bool) : Nil
      granted = insufficient_scope ? @provider.tokens : nil
      scope = insufficient_scope ? OAuth.step_up_scope(granted.try(&.scope), challenge.scope) : challenge.scope
      result = OAuth.authorize_mcp(@provider, server_url: context.server_url,
        resource_metadata_url: challenge.resource_metadata_url, scope: scope, fetch: context.fetch,
        skip_refresh: insufficient_scope)
      raise AuthorizationRequiredError.new if result.redirect?
    end
  end

  def self.adapt_oauth_provider(provider : ClientProvider) : AuthProvider
    OAuthAuthProvider.new(provider)
  end
end
