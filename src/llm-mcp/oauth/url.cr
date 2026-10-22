# src/llm-mcp/oauth/url.cr
module LLM::MCP::OAuth::Url
  SCHEME        = /\A[a-zA-Z][a-zA-Z0-9+.\-]*\z/
  SPECIAL       = {"http" => 80, "https" => 443, "ws" => 80, "wss" => 443, "ftp" => 21}
  UNSAFE_SCHEME = {"javascript", "data", "vbscript"}

  def self.parse?(value : String | URI) : URI?
    uri = value.is_a?(URI) ? value.dup : URI.parse(value)
    scheme = uri.scheme
    return unless scheme && SCHEME.matches?(scheme)
    return if SPECIAL.has_key?(scheme.downcase) && uri.host.presence.nil?
    normalize(uri)
  rescue URI::Error
    nil
  end

  def self.parse(value : String | URI) : URI
    parse?(value) || raise Error.new("Invalid URL: #{value}")
  end

  def self.normalize(uri : URI) : URI
    normalized = uri.normalize
    normalized.path = "/" if normalized.path.empty? && SPECIAL.has_key?(normalized.scheme.to_s)
    normalized
  end

  def self.href(value : String | URI) : String
    parse(value).to_s
  end

  def self.origin(uri : URI) : String
    scheme = uri.scheme.to_s.downcase
    port = uri.port
    host = uri.host.to_s.downcase
    port && port != SPECIAL[scheme]? ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
  end

  def self.resolve(base : URI, path : String) : URI
    normalize(base.resolve(path))
  end

  def self.unsafe?(uri : URI) : Bool
    UNSAFE_SCHEME.includes?(uri.scheme.to_s.downcase)
  end

  def self.loopback?(uri : URI) : Bool
    host = uri.host.to_s.downcase
    {"localhost", "127.0.0.1", "[::1]", "::1"}.includes?(host)
  end

  def self.with_params(uri : URI, values : Hash(String, String)) : URI
    copy = uri.dup
    params = copy.query_params
    values.each { |key, value| params[key] = value }
    copy.query_params = params
    copy
  end
end
