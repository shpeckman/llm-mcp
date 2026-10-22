# src/llm-mcp/oauth/provider.cr
module LLM::MCP::OAuth
  struct State
    include JSON::Serializable

    @[JSON::Field(key: "serverUrl")]
    property server_url : String
    @[JSON::Field(key: "clientInformation")]
    property client_information : ClientInformation?
    property tokens : Tokens?
    @[JSON::Field(key: "tokensExpireAt")]
    property tokens_expire_at : Int64?
    @[JSON::Field(key: "codeVerifier")]
    property code_verifier : String?
    @[JSON::Field(key: "oauthState")]
    property oauth_state : String?
    property discovery : DiscoveryState?

    def initialize(@server_url : String, @client_information : ClientInformation? = nil, @tokens : Tokens? = nil,
                   @tokens_expire_at : Int64? = nil, @code_verifier : String? = nil, @oauth_state : String? = nil,
                   @discovery : DiscoveryState? = nil)
    end
  end

  abstract class StateStore
    abstract def load : State?
    abstract def save(state : State) : Nil
  end

  class MemoryStateStore < StateStore
    @value : State? = nil

    def load : State?
      @value
    end

    def save(state : State) : Nil
      @value = state
    end
  end

  alias ClientMetadataDocumentSource = Proc(AuthorizationServerMetadata?, ClientMetadataDocument?)

  class Provider < ClientProvider
    getter redirect_url : String
    getter client_metadata : ClientMetadata
    getter server_url : String

    @configured_client : ClientInformation?
    @store : StateStore
    @document : ClientMetadataDocumentSource?
    @on_redirect : Proc(URI, Nil)
    @lock = Mutex.new

    def initialize(server_url : String | URI, redirect_url : String | URI, client_metadata : ClientMetadata = ClientMetadata.new,
                   *, client_id : String? = nil, client_secret : String? = nil, store : StateStore = MemoryStateStore.new,
                   client_metadata_document : ClientMetadataDocumentSource? = nil, &on_redirect : URI -> Nil)
      @server_url = Url.href(server_url)
      @redirect_url = redirect_url.is_a?(URI) ? Url.href(redirect_url) : redirect_url
      secret = client_secret.presence
      @client_metadata = client_metadata.copy_with(
        redirect_uris: client_metadata.redirect_uris || [@redirect_url],
        grant_types: client_metadata.grant_types || ["authorization_code", "refresh_token"],
        response_types: client_metadata.response_types || ["code"],
        token_endpoint_auth_method: client_metadata.token_endpoint_auth_method || (secret ? "client_secret_post" : "none"),
      )
      @document = client_metadata_document
      @configured_client = client_id.presence.try { |id| ClientInformation.new(id, secret) }
      @store = store
      @on_redirect = on_redirect
    end

    def state : String?
      @lock.synchronize do
        current = own(@store.load)
        if existing = current.oauth_state
          next existing
        end
        generated = Random::Secure.hex(32)
        current.oauth_state = generated
        @store.save(current)
        generated
      end
    end

    def client_metadata_document(metadata : AuthorizationServerMetadata?) : ClientMetadataDocument?
      @document.try &.call(metadata)
    end

    def client_information : ClientInformation?
      @configured_client || load.client_information
    end

    def save_client_information(information : ClientInformation) : Nil
      return if @configured_client
      update { |value| value.client_information = information; value }
    end

    def tokens : Tokens?
      load.tokens
    end

    def save_tokens(tokens : Tokens) : Nil
      expires_at = tokens.expires_in.try { |seconds| Time.utc.to_unix_ms + (seconds * 1000).round.to_i64 }
      update do |value|
        value.tokens = tokens
        value.tokens_expire_at = expires_at
        value
      end
    end

    def redirect_to_authorization(url : URI) : Nil
      @on_redirect.call(url)
    end

    def save_code_verifier(verifier : String) : Nil
      update { |value| value.code_verifier = verifier; value }
    end

    def code_verifier : String
      load.code_verifier.presence || raise Error.new("No OAuth PKCE code verifier is stored")
    end

    def invalidate_credentials(kind : CredentialKind) : Nil
      update do |value|
        value.client_information = nil if kind.all? || kind.client?
        if kind.all? || kind.tokens?
          value.tokens = nil
          value.tokens_expire_at = nil
        end
        value.code_verifier = nil if kind.all? || kind.verifier?
        value.discovery = nil if kind.all? || kind.discovery?
        value.oauth_state = nil if kind.all?
        value
      end
    end

    def save_discovery_state(state : DiscoveryState) : Nil
      update { |value| value.discovery = state; value }
    end

    def discovery_state : DiscoveryState?
      load.discovery
    end

    private def load : State
      @lock.synchronize { own(@store.load) }
    end

    private def update(& : State -> State) : Nil
      @lock.synchronize { @store.save(yield own(@store.load)) }
    end

    private def own(state : State?) : State
      state && state.server_url == @server_url ? state : State.new(@server_url)
    end
  end
end
