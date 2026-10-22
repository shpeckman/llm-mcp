# llm-mcp

A Crystal port of [`@earendil-works/pi-mcp`](https://github.com/earendil-works/pi/tree/main/packages/mcp)
1.3.0: a small, standalone Model Context Protocol client. It has no
dependencies beyond Crystal's standard library and does not depend on
`llm-chord` or `llm-telemetry`.

It provides a transport-neutral client core, stdio and Streamable HTTP
transports, the MCP OAuth client subset, and an in-memory transport for tests.

## Requirements

- Crystal `>= 1.21.0`
- A POSIX system (Linux, macOS) for `StdioTransport`

## Installation

```yaml
dependencies:
  llm-mcp:
    github: shpeckman/llm-mcp
```

Then `shards install`, and in your code:

```crystal
require "llm-mcp"           # LLM::MCP: client, transports, protocol types
require "llm-mcp/oauth"     # LLM::MCP::OAuth
require "llm-mcp/testing"   # LLM::MCP::Testing: the in-memory transport
```

## Usage

```crystal
require "llm-mcp"

alias MCP = LLM::MCP

transport = MCP::StdioTransport.new("npx", ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"])
client = MCP::Client.new("my-client", "1.0.0",
  roots: [MCP::Root.new("file:///workspace", "workspace")])

client.connect(transport)
tools = client.list_tools
result = client.call_tool("search", {query: "MCP"})
client.close
```

For a remote server, use `MCP::StreamableHttpTransport.new(url, headers: {...})`.
A `fetch:` proc can be injected for proxying or custom networking.

Every call blocks the calling fiber until it settles. Run independent calls on
their own fibers to overlap them.

### Tools for an LLM

`result.to_llm_content` (or `LLM::MCP.to_llm_content(result)`) converts a
`CallToolResult` to `LlmContent::Text` and `LlmContent::Image` values, which
serialize to pi-ai's `TextContent` and `ImageContent` shape
(`{"type":"text","text":...}`, `{"type":"image","data":...,"mimeType":...}`):

- text and images pass through;
- embedded text resources become text, embedded image resources become images;
- audio, resource links, and binary resources become short text placeholders;
- a result without content blocks but with `structured_content` becomes its
  pretty-printed JSON.

MCP reports tool failures in the result (`result.error?`), not as a protocol
error.

```crystal
tools = client.list_tools.map do |tool|
  {
    name:        "mcp_#{tool.name}".gsub(/[^A-Za-z0-9_-]/, "_")[0, 64],
    description: tool.description || tool.name,
    parameters:  tool.input_schema,
  }
end

result = client.call_tool("issues", {state: "open"})
content = result.to_llm_content
failed = result.error?
```

## Client

`MCP::Client.new(name, version, title = nil, capabilities = nil, requested_protocol_version = LATEST_PROTOCOL_VERSION, request_timeout = 30.seconds, roots = nil)`

| Option | Meaning |
| --- | --- |
| `name`, `version`, `title` | The client's `clientInfo`. |
| `capabilities` | Anything that serializes to a JSON object; sent as the client capabilities. `roots: {}` is added when `roots` is given and `capabilities` has no `roots`. |
| `requested_protocol_version` | One of `SUPPORTED_PROTOCOL_VERSIONS`; raises `ArgumentError` otherwise. |
| `request_timeout` | Default timeout per request. `nil`, zero, or a negative span disables it. |
| `roots` | `Array(Root)` or `Proc(Array(Root))`; answers the server's `roots/list`. |

| Member | Meaning |
| --- | --- |
| `connect(transport) : InitializeResult` | Starts the transport, sends `initialize`, checks the negotiated version, sends `notifications/initialized`. On failure the client closes and the error is raised. A client connects once. |
| `connection_state` | `ConnectionState` (`Idle`, `Connecting`, `Connected`, `Closed`). |
| `server_info`, `server_capabilities`, `instructions`, `protocol_version` | From the initialize result. |
| `list_tools` | Every tool, following `nextCursor` through all pages. |
| `list_resources`, `list_resource_templates` | Every resource or template; a missing `name` falls back to the URI (or URI template). |
| `list_resources_page(cursor = nil)`, `list_resource_templates_page(cursor = nil)` | One page: `ListResourcesResult` / `ListResourceTemplatesResult` (`resources` or `resource_templates`, `next_cursor`). |
| `read_resource(uri) : ReadResourceResult` | `contents` (`ResourceContents`: `uri`, `mime_type`, `text`, `blob`). |
| `call_tool(name, arguments = nil) : CallToolResult` | `arguments` is anything that serializes to a JSON object. A result without `content` gets `content: []`. |
| `ping` | Sends `ping`. |
| `request(method, params = nil) : JSON::Any` | Any request; `params` serializes to a JSON object. |
| `notify(method, params = nil)` | Any notification. |
| `set_request_handler(method) { \|params, context\| result }` | Answers server requests. `context.signal` aborts when the server cancels the request or the connection closes. A `nil` result answers `{}`; an `RpcError` answers with its code, message and data; any other exception with `-32603`. Returns a remover. `ping` is answered by default. |
| `on_notification(method) { \|params\| }` | Listens to a server notification (`params` is `JSON::Any?`). Returns a remover. |
| `on_error { \|error\| }` | Transport errors and listener failures. They are reported only; pending requests fail when the transport closes. |
| `on_close { }` | Called once when the connection closes, whether the transport dropped or `close` was called. |
| `close` | Rejects pending requests with `ConnectionClosedError`, aborts handlers of server requests, closes the transport. Idempotent. |

Every request method also takes `signal:` (an `AbortSignal`), `timeout:`
(overrides `request_timeout`), and `on_progress:` (a
`Proc(ProgressNotification, Nil)`; it adds a progress token, and each progress
notification restarts the timeout). `ping` takes `signal:` and `timeout:`.

- An aborted request raises `AbortError` and sends `notifications/cancelled`
  with the abort reason's message. A timed-out request raises `TimeoutError`
  and sends `notifications/cancelled` with `Request timed out`. `initialize` is
  never cancelled on the wire.
- A request whose sender gave up (answered, cancelled, timed out, closed) is
  never dispatched afterwards: the transport receives a signal that aborts at
  that point.
- Pagination raises on a repeated cursor and after 1,000 pages. `nextCursor`
  of `null` or `""` ends pagination.

### Cancellation

```crystal
controller = LLM::MCP::AbortController.new
spawn { sleep 5.seconds; controller.abort("user cancelled") }
client.call_tool("slow", signal: controller.signal)
```

`AbortController#abort(reason = AbortError.new(...))` or `abort(message)`.
`AbortSignal` has `aborted?`, `reason`, `on_abort { |reason| }` (returns a
remover), `throw_if_aborted`, `AbortSignal.any(signals)` and
`AbortSignal.timeout(span)`.

### Protocol types

Results are typed read-only views over the received JSON. Each keeps the whole
object in `raw` (unknown fields included), compares and serializes by it, and
exposes snake_case accessors; `view["key"]?` reads any field.

| Type | Accessors |
| --- | --- |
| `Implementation` | `name`, `version`, `title` |
| `InitializeResult` | `protocol_version`, `capabilities` (`ServerCapabilities`), `server_info`, `instructions` |
| `ServerCapabilities` | `experimental`, `logging`, `prompts`, `resources`, `tools`, `completions` |
| `Tool` | `name`, `title`, `description`, `input_schema`, `output_schema`, `annotations` (`ToolAnnotations`), `execution` (`ToolExecution`), `meta` |
| `Resource` | `uri`, `name`, `title`, `description`, `mime_type`, `size`, `annotations`, `meta` |
| `ResourceTemplate` | `uri_template`, `name`, `title`, `description`, `mime_type`, `annotations`, `meta` |
| `CallToolResult` | `content` (`Array(ContentBlock)`), `structured_content` (any JSON value, `nil` when absent), `error?`, `meta`, `to_llm_content` |
| `ContentBlock` | `TextContent`, `ImageContent`, `AudioContent`, `ResourceLinkContent`, `EmbeddedResourceContent`, or `UnknownContent`; `type`, `annotations`, `meta`, `to_llm` |
| `ProgressNotification` | `progress_token`, `progress`, `total`, `message` |
| `CancelledNotification` | `request_id`, `reason` |

Constants: `LATEST_PROTOCOL_VERSION` (`2025-11-25`) and
`SUPPORTED_PROTOCOL_VERSIONS` (also `2025-06-18`, `2025-03-26`, `2024-11-05`).

### JSON-RPC

`LLM::MCP::JsonRpc` has the messages (`Request`, `Notification`, and the
`Response`s `Success` and `Failure` with an `ErrorObject`), `Id`
(`String | Int64 | Float64`), `parse(json)` (raises `RpcError` `-32600`),
`parse?`, `request?`, `notification?`, `response?`, and the codes
`PARSE_ERROR`, `INVALID_REQUEST`, `METHOD_NOT_FOUND`, `INVALID_PARAMS`,
`INTERNAL_ERROR`.

### Errors

All errors derive from `LLM::MCP::Error`.

| Error | Raised when |
| --- | --- |
| `RpcError` (`code`, `data`) | The server answered with a JSON-RPC error, or a result failed validation (`-32600`). |
| `ConnectionClosedError` | The connection closed, or the client or transport is not open. |
| `TimeoutError` (`timeout`) | A request timed out. |
| `AbortError` | A request's signal aborted. |
| `HttpError` (`status`, `body`) | An HTTP request failed. |
| `AuthRequiredError` (`www_authenticate`) | HTTP 401 that no auth provider recovered from. |
| `SessionExpiredError` | HTTP 404 on an established session. |

## Transports

A transport owns framing and I/O and delivers individual JSON-RPC messages; the
client owns correlation, initialization, timeouts, cancellation, and server
requests. A custom transport subclasses `LLM::MCP::Transport`:

```crystal
abstract def start : Nil
abstract def send(message : JsonRpc::Message, signal : AbortSignal? = nil) : Nil
abstract def close : Nil
def protocol_version=(version : String) : Nil   # optional
```

and reports through the protected `emit_message`, `emit_error`, and
`emit_close` (which fires once). Listeners attach with `on_message`,
`on_error`, and `on_close`, each returning a remover. `send`'s signal aborts
once the sender no longer waits; the transport must not dispatch the message
after that.

### stdio

`StdioTransport.new(command, args = [], cwd: nil, env: nil, inherit_env: true, stderr: :pipe, on_stderr: nil, max_message_bytes: 16 MiB, max_stderr_bytes: 64 KiB, close_timeout: 2.seconds)`

- Spawns the server with `posix_spawn` as the leader of its own process
  group, so closing also terminates its children (wrappers such as `npx` or
  `uvx`). The process environment is inherited unless `inherit_env: false`;
  `env` is merged over it.
- Messages are newline-delimited JSON. Lines longer than `max_message_bytes`
  and unparsable lines are reported through `on_error`.
- `stderr: :pipe` keeps the last `max_stderr_bytes` in `stderr` and passes each
  chunk to `on_stderr`; `:inherit` leaves the server on the host's stderr.
- `pid` is the server's process id while it runs.
- `close` follows the spec: close stdin, wait up to 500 ms, send SIGTERM to the
  group, wait `close_timeout`, send SIGKILL. Once the server is gone, the group
  receives SIGTERM again for children that outlived it. Groups still running
  when the program exits receive SIGTERM.

### Streamable HTTP

`StreamableHttpTransport.new(url, headers: nil, fetch: nil, open_get_stream: true, max_message_bytes: 16 MiB, auth_provider: nil, reconnect: ReconnectOptions.new)`

- POSTs each message; JSON responses and event-stream (SSE) responses are
  both supported. `session_id` is the `Mcp-Session-Id` the server assigned;
  it and `MCP-Protocol-Version` are sent on later requests. `close` sends a
  best-effort `DELETE` for the session (one second, with the last request's
  token).
- After `notifications/initialized`, the server-to-client GET stream opens
  (unless `open_get_stream: false`; a 405 means the server has none). It
  reconnects with exponential backoff, resuming with `Last-Event-ID`.
- A response stream that drops before its answer is resumed with GET and
  `Last-Event-ID` when the server assigned event ids; otherwise only that
  request fails with `MCP response stream failed: ...`.
- `ReconnectOptions.new(initial_delay = 1.second, max_delay = 30.seconds, max_retries = 5)`.
  A server `retry` field overrides the delay. Network failures and statuses
  408, 429 and 5xx are retried; authentication, session and protocol errors
  are not.

#### Fetch

`Fetch` is `Proc(HttpRequest, HttpResponse)`.
`HttpRequest` has `method`, `url` (`URI`), `headers`, `body`, `signal`;
`HttpResponse` has `status`, `headers`, `body` (a streaming `IO`), `ok?`,
`content_type`, `text`, `json`, and `close`. The default, `DEFAULT_FETCH`,
runs on `HTTP::Client` with a small keep-alive pool per origin; aborting a
request's signal closes its connection and raises the signal's reason.

#### Authorization

```crystal
class StaticToken < LLM::MCP::AuthProvider
  def token : String?
    ENV["MCP_TOKEN"]?
  end
end
```

`AuthProvider#token` supplies the bearer token before every request whose
answer the transport waits for. On a 401, or a 403 whose challenge reports
`insufficient_scope`, the transport calls `on_unauthorized(context)` once.
Return `true` to retry the request with the provider's current token, `false`
(the default) to fail. `UnauthorizedContext` has `response`, `server_url`,
`fetch`, and `token` (the token the rejected request carried; a different
current token means another request already refreshed it).

### In-memory (testing)

```crystal
require "llm-mcp/testing"

pair = LLM::MCP::Testing.in_memory_transport_pair
client_transport, server_transport = pair[:client], pair[:server]
```

Messages are copied and delivered in order on their own fiber.
`InMemoryTransport#emit_error` is public so tests can simulate transport
failures.

## OAuth

`require "llm-mcp/oauth"` adds `LLM::MCP::OAuth`, the MCP OAuth client subset,
adapted from the MIT-licensed Model Context Protocol TypeScript SDK v1.29.0
(license under `LICENSES/`).

```crystal
require "llm-mcp"
require "llm-mcp/oauth"

alias MCP = LLM::MCP
alias OAuth = LLM::MCP::OAuth

server_url = "https://mcp.example.com/mcp"
callback = OAuth::CallbackServer.listen
authorization_url = nil.as(URI?)
oauth = OAuth::Provider.new(server_url, callback.redirect_url,
  OAuth::ClientMetadata.new(client_name: "My MCP client")) { |url| authorization_url = url }

connect = -> do
  client = MCP::Client.new("my-client", "1.0.0")
  client.connect(MCP::StreamableHttpTransport.new(server_url, auth_provider: OAuth.adapt_oauth_provider(oauth)))
  client
end

client = begin
  connect.call
rescue OAuth::AuthorizationRequiredError
  pending = callback.wait_for_callback(oauth.state.not_nil!)
  # Open authorization_url in the user's browser here.
  callback_result = pending.wait
  OAuth.authorize_mcp(oauth, server_url: server_url, authorization_code: callback_result.code, iss: callback_result.iss)
  connect.call
end
```

The shard does not open a browser or choose where credentials are stored;
pass a `StateStore` for durable credentials.

### Provider

`OAuth::Provider.new(server_url, redirect_url, client_metadata = ClientMetadata.new, client_id: nil, client_secret: nil, store: MemoryStateStore.new, client_metadata_document: nil) { |authorization_url| }`
is the default stateful `ClientProvider` for one exact server URL. Stored
state for another server URL is ignored, so credentials never leak across
servers. Unset metadata defaults to `redirect_uris: [redirect_url]`, the
`authorization_code` and `refresh_token` grants, `code` responses, and
`client_secret_post` (with a secret) or `none`. With `client_id`, registration
is skipped and the configured client is never overwritten. `state` returns the
stored OAuth `state` parameter, creating it on first use.

`StateStore` (`load : State?`, `save(state)`) persists an `OAuth::State`
(`server_url`, `client_information`, `tokens`, `tokens_expire_at` in Unix
milliseconds, `code_verifier`, `oauth_state`, `discovery`). It is
`JSON::Serializable` with upstream's camelCase keys, so a store file can be
shared with a Node client.

A custom provider subclasses `OAuth::ClientProvider`: `redirect_url`,
`client_metadata`, `client_information`, `save_client_information`, `tokens`,
`save_tokens`, `redirect_to_authorization(url)`, `save_code_verifier`, and
`code_verifier` are required; `client_metadata_document(metadata)`, `state`,
`add_client_authentication`, `invalidate_credentials(kind)`,
`save_discovery_state`, and `discovery_state` have defaults.

### Flow

| Function | Meaning |
| --- | --- |
| `authorize_mcp(provider, server_url:, authorization_code:, iss:, scope:, resource_metadata_url:, authorization_server_metadata_url:, fetch:, signal:, skip_issuer_validation:, skip_refresh:) : FlowResult` | Discovers (or reuses cached discovery), registers when no client is known, then exchanges `authorization_code`, refreshes stored tokens, or starts authorization (`Redirect`). `invalid_client`/`unauthorized_client` drop all credentials and retry once; `invalid_grant` drops the tokens and retries once. |
| `adapt_oauth_provider(provider) : AuthProvider` | The Streamable HTTP auth provider: after a 401 it refreshes, or raises `AuthorizationRequiredError` when the user must authorize. Concurrent 401s share one refresh, and a request whose token was already replaced is just retried. An `insufficient_scope` 403 skips the refresh and asks for the granted plus the challenged scopes. |
| `start_authorization`, `exchange_authorization_code`, `refresh_authorization`, `register_client` | The individual steps. `register_client` sends `application_type`, derived from `redirect_uris` when unset (`native` for loopback hosts and custom schemes). |
| `step_up_scope(granted, challenged)` | Granted plus challenged scopes, deduplicated. |
| `discover_oauth_server_info`, `discover_protected_resource_metadata`, `discover_authorization_server_metadata`, `build_authorization_server_discovery_urls` | Discovery (RFC 9728, RFC 8414, OIDC). Issuers are validated unless `skip_issuer_validation`. |
| `parse_www_authenticate(header) : Challenge` | `resource_metadata_url`, `scope`, `error`, `error_description` of a `Bearer` or `DPoP` challenge. |
| `resource_url_from_server_url`, `select_resource` | The RFC 8707 `resource` parameter. |

- Authorization uses PKCE `S256`. A code is exchanged only when its `iss`
  names the authorization server, or is absent and the server does not
  promise one (RFC 9207); otherwise `IssuerMismatchError`.
- Token and metadata endpoints must use https, except on loopback hosts
  (`InsecureEndpointError`).
- `signal:` aborts every request of the flow; an aborted refresh never falls
  back to a new authorization.
- Token responses without `scope` record the requested (or previously granted)
  scope. Empty and `null` optional fields count as absent.

Types: `Tokens`, `ClientMetadata` (records), `ClientInformation`,
`AuthorizationServerMetadata`, `ProtectedResourceMetadata` (JSON views with
`parse`), `DiscoveryState`, `ServerInfo`, `Challenge`,
`ClientMetadataDocument`, `CredentialKind`, `FlowResult`.

Errors (all `LLM::MCP::Error`): `ResponseError` (`code`, `error_uri`; an OAuth
error response), `IssuerMismatchError` (`expected`, `received`),
`InsecureEndpointError` (`endpoint`), `RegistrationError` (`status`, `body`),
`AuthorizationRequiredError`.

### Callback server

`OAuth::CallbackServer.listen(host: "127.0.0.1", redirect_host: nil, port: 0, path: "/callback", extra_paths: [], timeout: 5.minutes, render_page: nil)`
serves the redirect on loopback. `redirect_url` is the URL to register.
`wait_for_callback(state, path = nil)` returns a `PendingCallback` at once;
its `wait` returns the `Callback` (`code`, `state`, `iss`) or raises on an
error response, a missing code, another redirect path than `path`, the
timeout, or `close`. `render_page` (`Proc(CallbackPage, String)`) renders the
browser page as HTML; the default is plain text.

## Supported protocol surface

- MCP `2025-11-25`, accepting servers that negotiate `2025-06-18`,
  `2025-03-26`, or `2024-11-05`
- initialization and `notifications/initialized`; ping
- paginated `tools/list`, `resources/list`, `resources/templates/list`;
  `resources/read`; `tools/call` with structured content
- progress notifications with timeout renewal; request cancellation
- Streamable HTTP sessions, the GET stream with reconnection, and resumption
  of dropped response streams with `Last-Event-ID`
- stdio shutdown per the spec, applied to the server's process group
- server `ping` and `roots/list` requests; logging and list-change
  notifications through `on_notification`
- OAuth discovery, PKCE, dynamic client registration, Client ID Metadata
  Documents, token refresh shared by concurrent 401s, step-up authorization

Batch JSON-RPC messages, legacy HTTP+SSE, servers, sampling, and tasks are
outside the core, as upstream.

## Differences from upstream

- Promises become blocking calls on fibers. `OAuthCallbackServer.waitForCallback`
  becomes `wait_for_callback(...).wait`, so the wait is registered before the
  browser opens.
- Names follow Crystal: the `Mcp` prefix is dropped inside `LLM::MCP`
  (`McpClient` → `Client`, `McpError` → `RpcError`, `McpOAuthProvider` →
  `OAuth::Provider`, `McpOAuthAuthorizationRequiredError` →
  `OAuth::AuthorizationRequiredError`, `OAuthError` → `OAuth::ResponseError`,
  `OAuthCallbackServer` → `OAuth::CallbackServer`), options are keyword
  arguments, and durations are `Time::Span`s (`timeoutMs` → `timeout`,
  `closeTimeoutMs` → `close_timeout`, `retentionMs`-style fields likewise).
- All errors share the base `LLM::MCP::Error`; upstream's plain `Error`s
  raise it directly. Abort reasons are exceptions: `abort("stop")` wraps the
  text in an `AbortError`, and `notifications/cancelled` carries the reason's
  message.
- `AbortSignal`/`AbortController` are the shard's own, since Crystal has no
  platform signal.
- Results are JSON views rather than plain objects; they keep every field.
  A content block missing a field its type requires is an `UnknownContent`.
- `AuthProvider` is an abstract class whose `on_unauthorized` returns whether
  to retry, standing in for upstream's optional method. `ClientProvider#save_client_information`
  is required, where upstream refuses to register without it.
- `fetch` is a `Proc(HttpRequest, HttpResponse)` instead of the WHATWG fetch.
  Upstream's Cloudflare receiver fix has no counterpart.
- `StdioTransport` is POSIX only (upstream's Windows `taskkill` path is not
  ported) and spawns with `posix_spawnp`, which searches the host's `PATH`.
- Structured content printed by `to_llm_content` uses Crystal's JSON writer:
  a float such as `1.0` prints as `1.0`, where `JSON.stringify` writes `1`.
- An HTTP error body is read up to 8 KiB in bytes, where upstream slices
  characters of the whole body.
- JSON-RPC error codes must be integers.

## Development

```console
crystal spec
crystal tool format src spec
ameba
```

The specs never leave the machine: HTTP and OAuth specs run against
`HTTP::Server` on 127.0.0.1, and the stdio specs build `spec/fixtures/server.cr`
into the temporary directory.

## License

MIT. See [LICENSE](LICENSE). The OAuth module is adapted from the Model
Context Protocol TypeScript SDK; see
[LICENSES/modelcontextprotocol-typescript-sdk.txt](LICENSES/modelcontextprotocol-typescript-sdk.txt).
