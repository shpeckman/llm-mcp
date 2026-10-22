# src/llm-mcp/oauth/discovery.cr
module LLM::MCP::OAuth
  enum DiscoveryKind
    OAuth
    Oidc
  end

  record DiscoveryUrl, url : URI, kind : DiscoveryKind

  CHALLENGE_FIELDS = {"resource_metadata", "scope", "error", "error_description"}.to_h do |name|
    {name, Regex.new("(?:^|[,\\s])#{Regex.escape(name)}=(?:\"([^\"]*)\"|([^\\s,]+))", Regex::Options::IGNORE_CASE)}
  end

  def self.parse_www_authenticate(header : String?) : Challenge
    return Challenge.new unless header && !header.empty?
    scheme = header.lstrip.split(/\s+/, 2).first?.try(&.downcase)
    return Challenge.new unless scheme == "bearer" || scheme == "dpop"
    resource_metadata = challenge_field(header, "resource_metadata")
    Challenge.new(
      resource_metadata_url: resource_metadata.try { |url| Url.parse?(url) },
      scope: challenge_field(header, "scope"),
      error: challenge_field(header, "error"),
      error_description: challenge_field(header, "error_description"),
    )
  end

  private def self.challenge_field(header : String, name : String) : String?
    match = CHALLENGE_FIELDS[name].match(header)
    return unless match
    (match[1]?.presence || match[2]?.presence)
  end

  def self.discover_protected_resource_metadata(server_url : String | URI, *, resource_metadata_url : String | URI | Nil = nil,
                                                protocol_version : String = LATEST_PROTOCOL_VERSION, fetch : Fetch? = nil,
                                                signal : AbortSignal? = nil) : ProtectedResourceMetadata
    server = Url.parse(server_url)
    fetcher = fetch || DEFAULT_FETCH
    configured = resource_metadata_url.try { |url| Url.parse(url) }
    target = configured || Url.resolve(server, "/.well-known/oauth-protected-resource#{path_suffix(server)}")
    response = fetch_metadata(target, fetcher, protocol_version, signal)
    if configured.nil? && server.path != "/" && discovery_miss?(response.status)
      response.close
      response = fetch_metadata(Url.resolve(server, "/.well-known/oauth-protected-resource"), fetcher, protocol_version, signal)
    end
    unless response.ok?
      response.close
      raise Error.new("HTTP #{response.status} loading OAuth protected resource metadata")
    end
    ProtectedResourceMetadata.parse(response.json)
  end

  def self.build_authorization_server_discovery_urls(authorization_server_url : String | URI) : Array(DiscoveryUrl)
    issuer = Url.parse(authorization_server_url)
    path = path_suffix(issuer)
    urls = [
      DiscoveryUrl.new(Url.resolve(issuer, "/.well-known/oauth-authorization-server#{path}"), DiscoveryKind::OAuth),
      DiscoveryUrl.new(Url.resolve(issuer, "/.well-known/openid-configuration#{path}"), DiscoveryKind::Oidc),
    ]
    urls << DiscoveryUrl.new(Url.resolve(issuer, "#{path}/.well-known/openid-configuration"), DiscoveryKind::Oidc) unless path.empty?
    urls
  end

  def self.discover_authorization_server_metadata(authorization_server_url : String | URI, *, fetch : Fetch? = nil,
                                                  protocol_version : String = LATEST_PROTOCOL_VERSION,
                                                  skip_issuer_validation : Bool = false,
                                                  signal : AbortSignal? = nil) : AuthorizationServerMetadata?
    fetcher = fetch || DEFAULT_FETCH
    build_authorization_server_discovery_urls(authorization_server_url).each do |candidate|
      response = fetch_metadata(candidate.url, fetcher, protocol_version, signal)
      unless response.ok?
        response.close
        next if discovery_miss?(response.status)
        raise Error.new("HTTP #{response.status} loading authorization server metadata from #{candidate.url}")
      end
      metadata = AuthorizationServerMetadata.parse(response.json)
      unless skip_issuer_validation
        expected = authorization_server_url.is_a?(URI) ? Url.href(authorization_server_url) : authorization_server_url
        raise IssuerMismatchError.new(expected, metadata.issuer) unless trim_slash(metadata.issuer) == trim_slash(expected)
      end
      return metadata
    end
    nil
  end

  def self.discover_oauth_server_info(server_url : String | URI, *, resource_metadata_url : URI? = nil,
                                      authorization_server_metadata_url : URI? = nil, fetch : Fetch? = nil,
                                      skip_issuer_validation : Bool = false, signal : AbortSignal? = nil) : ServerInfo
    resource_metadata = begin
      discover_protected_resource_metadata(server_url, resource_metadata_url: resource_metadata_url, fetch: fetch, signal: signal)
    rescue error
      raise error if network_failure?(error)
      nil
    end
    if url = authorization_server_metadata_url
      response = fetch_metadata(url, fetch || DEFAULT_FETCH, LATEST_PROTOCOL_VERSION, signal)
      unless response.ok?
        response.close
        raise Error.new("HTTP #{response.status} loading authorization server metadata from #{url}")
      end
      metadata = AuthorizationServerMetadata.parse(response.json)
      return ServerInfo.new(metadata.issuer, metadata, resource_metadata)
    end
    authorization_server_url = resource_metadata.try(&.authorization_servers).try(&.first?) ||
                               Url.resolve(Url.parse(server_url), "/").to_s
    metadata = discover_authorization_server_metadata(authorization_server_url, fetch: fetch,
      skip_issuer_validation: skip_issuer_validation, signal: signal)
    ServerInfo.new(authorization_server_url, metadata, resource_metadata)
  end

  def self.resource_url_from_server_url(value : String | URI) : URI
    url = Url.parse(value)
    url.fragment = nil
    url
  end

  def self.select_resource(server_url : String | URI, metadata : ProtectedResourceMetadata?) : String?
    return unless metadata
    requested = resource_url_from_server_url(server_url)
    configured = Url.parse(metadata.resource)
    mismatch = "Protected resource #{metadata.resource} does not match MCP server #{requested}"
    raise Error.new(mismatch) unless Url.origin(requested) == Url.origin(configured)
    requested_path = requested.path.ends_with?('/') ? requested.path : "#{requested.path}/"
    configured_path = configured.path.ends_with?('/') ? configured.path : "#{configured.path}/"
    raise Error.new(mismatch) unless requested_path.starts_with?(configured_path)
    metadata.resource
  end

  protected def self.network_failure?(error : Exception) : Bool
    error.is_a?(IO::Error) || error.is_a?(OpenSSL::SSL::Error) || error.is_a?(AbortError)
  end

  private def self.fetch_metadata(url : URI, fetch : Fetch, protocol_version : String, signal : AbortSignal?) : HttpResponse
    headers = HTTP::Headers{"Accept" => "application/json", "MCP-Protocol-Version" => protocol_version}
    fetch.call(HttpRequest.new("GET", url, headers, nil, signal))
  end

  private def self.discovery_miss?(status : Int32) : Bool
    (400 <= status < 500) || status == 502
  end

  private def self.path_suffix(url : URI) : String
    path = url.path
    path.ends_with?('/') ? path[0, path.size - 1] : path
  end

  private def self.trim_slash(value : String) : String
    value.ends_with?('/') ? value[0, value.size - 1] : value
  end
end
