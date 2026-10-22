# src/llm-mcp/oauth/types.cr
module LLM::MCP::OAuth
  module Parse
    def self.object(value : JSON::Any?, name : String) : Hash(String, JSON::Any)
      value.try(&.as_h?) || raise Error.new("Invalid #{name}")
    end

    def self.absent?(value : JSON::Any?) : Bool
      value.nil? || value.raw.nil? || value.raw == ""
    end

    def self.required_string(value : JSON::Any?, name : String) : String
      text = value.try(&.as_s?)
      raise Error.new("Invalid #{name}") if text.nil? || text.empty?
      text
    end

    def self.optional_string(value : JSON::Any?, name : String) : String?
      absent?(value) ? nil : required_string(value, name)
    end

    def self.optional_strings(value : JSON::Any?, name : String) : Array(String)?
      return if value.nil? || value.raw.nil?
      items = value.as_a?
      raise Error.new("Invalid #{name}") unless items && items.all?(&.as_s?)
      items.map(&.as_s)
    end

    def self.safe_url(value : JSON::Any?, name : String) : String
      text = required_string(value, name)
      uri = Url.parse?(text)
      raise Error.new("Invalid #{name}") if uri.nil? || Url.unsafe?(uri)
      text
    end

    def self.optional_url(value : JSON::Any?, name : String) : String?
      absent?(value) ? nil : safe_url(value, name)
    end

    def self.compact(input : Hash(String, JSON::Any), values : Hash(String, JSON::Any?)) : JSON::Any
      hash = input.dup
      values.each do |key, value|
        if value.nil?
          hash.delete(key)
        else
          hash[key] = value
        end
      end
      JSON::Any.new(hash)
    end

    def self.any(value : String?) : JSON::Any?
      value.try { |text| JSON::Any.new(text) }
    end

    def self.any(values : Array(String)?) : JSON::Any?
      values.try { |items| JSON::Any.new(items.map { |item| JSON::Any.new(item) }) }
    end

    def self.any(value : Bool?) : JSON::Any?
      value.nil? ? nil : JSON::Any.new(value)
    end
  end

  struct ProtectedResourceMetadata
    include JsonView
    JsonView.field resource, "resource", String, required: true
    JsonView.field authorization_servers, "authorization_servers", Array(String)
    JsonView.field scopes_supported, "scopes_supported", Array(String)

    def self.parse(value : JSON::Any?) : self
      input = Parse.object(value, "OAuth protected resource metadata")
      servers = Parse.optional_strings(input["authorization_servers"]?, "authorization_servers")
      new(Parse.compact(input, {
        "resource"              => Parse.any(Parse.safe_url(input["resource"]?, "OAuth protected resource metadata resource")),
        "authorization_servers" => Parse.any(servers.try(&.map { |url| Parse.safe_url(JSON::Any.new(url), "authorization server URL") })),
        "scopes_supported"      => Parse.any(Parse.optional_strings(input["scopes_supported"]?, "scopes_supported")),
      }))
    end
  end

  struct AuthorizationServerMetadata
    include JsonView
    JsonView.field issuer, "issuer", String, required: true
    JsonView.field authorization_endpoint, "authorization_endpoint", String, required: true
    JsonView.field token_endpoint, "token_endpoint", String, required: true
    JsonView.field registration_endpoint, "registration_endpoint", String
    JsonView.field scopes_supported, "scopes_supported", Array(String)
    JsonView.field response_types_supported, "response_types_supported", Array(String), required: true
    JsonView.field grant_types_supported, "grant_types_supported", Array(String)
    JsonView.field token_endpoint_auth_methods_supported, "token_endpoint_auth_methods_supported", Array(String)
    JsonView.field code_challenge_methods_supported, "code_challenge_methods_supported", Array(String)
    JsonView.field client_id_metadata_document_supported, "client_id_metadata_document_supported", Bool
    JsonView.field authorization_response_iss_parameter_supported, "authorization_response_iss_parameter_supported", Bool

    def self.parse(value : JSON::Any?) : self
      input = Parse.object(value, "authorization server metadata")
      response_types = Parse.optional_strings(input["response_types_supported"]?, "response_types_supported")
      raise Error.new("Invalid response_types_supported") unless response_types
      new(Parse.compact(input, {
        "issuer"                                         => Parse.any(Parse.safe_url(input["issuer"]?, "authorization server issuer")),
        "authorization_endpoint"                         => Parse.any(Parse.safe_url(input["authorization_endpoint"]?, "authorization endpoint")),
        "token_endpoint"                                 => Parse.any(Parse.safe_url(input["token_endpoint"]?, "token endpoint")),
        "registration_endpoint"                          => Parse.any(Parse.optional_url(input["registration_endpoint"]?, "registration endpoint")),
        "scopes_supported"                               => Parse.any(Parse.optional_strings(input["scopes_supported"]?, "scopes_supported")),
        "response_types_supported"                       => Parse.any(response_types),
        "grant_types_supported"                          => Parse.any(Parse.optional_strings(input["grant_types_supported"]?, "grant_types_supported")),
        "token_endpoint_auth_methods_supported"          => Parse.any(Parse.optional_strings(input["token_endpoint_auth_methods_supported"]?, "token_endpoint_auth_methods_supported")),
        "code_challenge_methods_supported"               => Parse.any(Parse.optional_strings(input["code_challenge_methods_supported"]?, "code_challenge_methods_supported")),
        "client_id_metadata_document_supported"          => Parse.any(input["client_id_metadata_document_supported"]?.try(&.as_bool?)),
        "authorization_response_iss_parameter_supported" => Parse.any(input["authorization_response_iss_parameter_supported"]?.try(&.as_bool?)),
      }))
    end
  end

  module JsNumber
    def self.from_json(pull : JSON::PullParser) : Float64
      pull.read_float
    end

    def self.to_json(value : Float64, builder : JSON::Builder) : Nil
      if value == value.round && value.abs < 9.007199254740992e15
        builder.number(value.to_i64)
      else
        builder.number(value)
      end
    end
  end

  record Tokens, access_token : String, token_type : String, expires_in : Float64? = nil, scope : String? = nil,
    refresh_token : String? = nil, id_token : String? = nil do
    include JSON::Serializable

    @[JSON::Field(converter: LLM::MCP::OAuth::JsNumber)]
    @expires_in : Float64?

    def self.parse(value : JSON::Any?) : Tokens
      input = Parse.object(value, "OAuth token response")
      Tokens.new(
        access_token: Parse.required_string(input["access_token"]?, "access_token"),
        token_type: Parse.required_string(input["token_type"]?, "token_type"),
        expires_in: Tokens.expiry(input["expires_in"]?),
        scope: Parse.optional_string(input["scope"]?, "scope"),
        refresh_token: Parse.optional_string(input["refresh_token"]?, "refresh_token"),
        id_token: Parse.optional_string(input["id_token"]?, "id_token"),
      )
    end

    protected def self.expiry(value : JSON::Any?) : Float64?
      return if Parse.absent?(value)
      raw = value.not_nil!.raw
      number = case raw
               when Int64   then raw.to_f
               when Float64 then raw
               when String  then raw.strip.empty? ? 0.0 : raw.strip.to_f?
               when Bool    then raw ? 1.0 : 0.0
               end
      raise Error.new("Invalid expires_in") unless number && number.finite?
      number
    end
  end

  record ClientMetadata, redirect_uris : Array(String)? = nil, token_endpoint_auth_method : String? = nil,
    grant_types : Array(String)? = nil, response_types : Array(String)? = nil, application_type : String? = nil,
    client_name : String? = nil, client_uri : String? = nil, logo_uri : String? = nil, scope : String? = nil,
    contacts : Array(String)? = nil, tos_uri : String? = nil, policy_uri : String? = nil, jwks_uri : String? = nil,
    jwks : JSON::Any? = nil, software_id : String? = nil, software_version : String? = nil,
    software_statement : String? = nil do
    include JSON::Serializable
  end

  struct ClientInformation
    include JsonView
    JsonView.field client_id, "client_id", String, required: true
    JsonView.field client_secret, "client_secret", String
    JsonView.field client_id_issued_at, "client_id_issued_at", Float64
    JsonView.field client_secret_expires_at, "client_secret_expires_at", Float64
    JsonView.field token_endpoint_auth_method, "token_endpoint_auth_method", String
    JsonView.field redirect_uris, "redirect_uris", Array(String)

    def self.new(client_id : String, client_secret : String? = nil) : self
      hash = {"client_id" => JSON::Any.new(client_id)}
      client_secret.try { |secret| hash["client_secret"] = JSON::Any.new(secret) }
      new(JSON::Any.new(hash))
    end

    def self.parse(value : JSON::Any?) : self
      input = Parse.object(value, "OAuth client registration response")
      number = ->(item : JSON::Any?) { item.try { |found| found.as_i64? || found.as_f? } ? item : nil }
      new(Parse.compact(input, {
        "client_id"                => Parse.any(Parse.required_string(input["client_id"]?, "client_id")),
        "client_secret"            => Parse.any(Parse.optional_string(input["client_secret"]?, "client_secret")),
        "client_id_issued_at"      => number.call(input["client_id_issued_at"]?),
        "client_secret_expires_at" => number.call(input["client_secret_expires_at"]?),
        "redirect_uris"            => Parse.any(Parse.optional_strings(input["redirect_uris"]?, "redirect_uris") || [] of String),
      }))
    end
  end

  record ClientMetadataDocument, url : String, redirect_url : String

  struct DiscoveryState
    include JSON::Serializable

    @[JSON::Field(key: "authorizationServerUrl")]
    getter authorization_server_url : String
    @[JSON::Field(key: "authorizationServerMetadata")]
    getter authorization_server_metadata : AuthorizationServerMetadata?
    @[JSON::Field(key: "resourceMetadata")]
    getter resource_metadata : ProtectedResourceMetadata?
    @[JSON::Field(key: "resourceMetadataUrl")]
    getter resource_metadata_url : String?

    def initialize(@authorization_server_url : String, @authorization_server_metadata : AuthorizationServerMetadata? = nil,
                   @resource_metadata : ProtectedResourceMetadata? = nil, @resource_metadata_url : String? = nil)
    end
  end

  record ServerInfo, authorization_server_url : String, authorization_server_metadata : AuthorizationServerMetadata? = nil,
    resource_metadata : ProtectedResourceMetadata? = nil

  record Challenge, resource_metadata_url : URI? = nil, scope : String? = nil, error : String? = nil,
    error_description : String? = nil
end
