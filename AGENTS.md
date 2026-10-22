# AGENTS.md

## Overview

`llm-mcp` is the Crystal port of
[`@earendil-works/pi-mcp`](https://github.com/earendil-works/pi/tree/main/packages/mcp)
1.3.0 (upstream commit `bd3c9b8`): a standalone Model Context Protocol client
with stdio and Streamable HTTP transports, the MCP OAuth client subset, and an
in-memory testing transport. It has no shard dependencies and does not depend
on `llm-chord` or `llm-telemetry`. Values are `JSON::Any`.

Upstream is the specification. When behavior is in doubt, read the upstream
source and tests (`packages/mcp/src`, `packages/mcp/test`) and match them. The
README's "Differences from upstream" section lists every intentional
departure; keep it current.

## Repository layout

All code lives under `src/llm-mcp/`, next to the entry point `src/llm-mcp.cr`. Crystal resolves `require "llm-mcp/x"` to `src/llm-mcp/x.cr`, so the entry points `src/llm-mcp/oauth.cr` and `src/llm-mcp/testing.cr` share the folder with the implementation of `LLM::MCP`. Paths follow the shard name, not the module path.

```
src/llm-mcp.cr                      Entry point: client, transports, protocol types
src/llm-mcp/oauth.cr                Entry point for `require "llm-mcp/oauth"`
src/llm-mcp/testing.cr              Entry point for `require "llm-mcp/testing"`
src/llm-mcp/listeners.cr            Listeners(T): ordered listener sets with removers
src/llm-mcp/errors.cr               Error hierarchy (RpcError, ConnectionClosed, Timeout, Abort, Http, AuthRequired, SessionExpired)
src/llm-mcp/abort.cr                AbortSignal, AbortController
src/llm-mcp/json_view.cr            JsonView (typed read-only views over JSON::Any, `JsonView.field`), MCP.json
src/llm-mcp/json_rpc.cr             JsonRpc: messages, ids, error codes, parse (protocol/jsonrpc.ts)
src/llm-mcp/types.cr                Protocol versions and result types (protocol/types.ts)
src/llm-mcp/content.cr              ContentBlock kinds, CallToolResult, LlmContent, to_llm_content (protocol/content.ts)
src/llm-mcp/transport.cr            Transport base class (transports/transport.ts)
src/llm-mcp/client.cr               Client (client.ts)
src/llm-mcp/http.cr                 HttpRequest, HttpResponse, Fetch, HttpFetcher, DEFAULT_FETCH
src/llm-mcp/auth_provider.cr        AuthProvider, UnauthorizedContext (auth-provider.ts)
src/llm-mcp/sse.cr                  Sse.consume: the event-stream parser (consumeSseStream)
src/llm-mcp/streamable_http.cr      StreamableHttpTransport, ReconnectOptions (transports/streamable-http.ts)
src/llm-mcp/stdio.cr                StdioTransport: posix_spawn with process groups (transports/stdio.ts)
src/llm-mcp/testing/in_memory.cr    Testing::InMemoryTransport, in_memory_transport_pair (transports/in-memory.ts)
src/llm-mcp/oauth/url.cr            OAuth::Url: WHATWG-like URL parsing, origin, resolution
src/llm-mcp/oauth/errors.cr         OAuth errors (oauth/errors.ts)
src/llm-mcp/oauth/types.cr          Metadata, tokens, client information, parsing (oauth/types.ts)
src/llm-mcp/oauth/discovery.cr      Discovery and WWW-Authenticate parsing (oauth/discovery.ts)
src/llm-mcp/oauth/flow.cr           ClientProvider, authorize_mcp, token requests, OAuthAuthProvider (oauth/flow.ts)
src/llm-mcp/oauth/provider.cr       State, StateStore, MemoryStateStore, Provider (oauth/provider.ts)
src/llm-mcp/oauth/callback.cr       CallbackServer, PendingCallback, CallbackPage (oauth/callback.ts)
spec/spec_helper.cr                 Requires, `json`, `eventually`, server cleanup after each example
spec/support/http_server.cr         TestHttp: loopback HTTP::Server per example, `park` for held responses
spec/fixtures/server.cr             stdio fixture (echo, stubborn, grandchild modes), built by stdio_spec
spec/*_spec.cr                      Specs translated from upstream's test files
LICENSES/                           The MCP TypeScript SDK license (OAuth is adapted from it)
```

## Build / test / spec

```console
crystal spec
crystal tool format src spec
ameba
```

`ameba` reads `.ameba.yml`; `Naming/QueryBoolMethods`, `Lint/NotNil`, and
`Metrics/CyclomaticComplexity` are disabled. The specs never leave the
machine: HTTP and OAuth specs listen on 127.0.0.1, and `spec/stdio_spec.cr`
builds `spec/fixtures/server.cr` into the temporary directory (so `crystal`
must be on `PATH`).

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm-mcp/client.cr`. No other comments in code.
- Compiler-friendly, performance-focused, idiomatic Crystal; data-driven design.
- The usage-facing API must be ergonomic.
- Prevent shotgun surgery: a behavior change should touch one cohesive spot.
- Never use `out` as an identifier — it is a reserved keyword.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.

## Conventions specific to this codebase

- Upstream promises map to blocking calls on fibers. A request is dispatched on
  its own fiber and its caller waits on a channel with a deadline, so aborts,
  timeouts, and progress renewals work while a transport blocks.
- Received results are `JsonView` structs: `raw` keeps the whole object, and
  `JsonView.field name, "key", Type, required: true` declares accessors. Add a
  field with one line; validation that upstream performs stays in the client's
  `validate_*` methods (or `parse` for OAuth types), not in the views.
- Lists are data: `Client::TOOLS`, `RESOURCES`, `RESOURCE_TEMPLATES` are
  `ListSpec`s (method, key, item validator) shared by `list_all` and `list_page`.
- Errors derive from `LLM::MCP::Error`. Where upstream throws a plain `Error`,
  raise `Error`; network failures stay `IO::Error`/`OpenSSL::SSL::Error`, which
  the HTTP transport retries and OAuth discovery rethrows.
- Compiler quirks: a method that captures a block (`&block : ...`) and also
  contains a proc literal can fail with "read before assignment"; keep proc
  literals in a separate private method (`handler_remover`,
  `Listeners#remover`). `spawn call(arg)` on a variable narrowed by
  `is_a?`/`case` crashes the 1.21 compiler; copy it into a local first or use
  the block form `spawn { ... }`.
- `StdioTransport` spawns through `LibMcpSpawn.posix_spawnp` with
  `POSIX_SPAWN_SETPGROUP` and waits with Crystal's child handler
  (`Process.new(Crystal::System::Process.new(pid)).wait`), the same approach as
  `llm-chord`'s fork driver.
- `DEFAULT_FETCH` pools idle `HTTP::Client`s per origin. A response is reusable
  only when its body was read to the end; closing it early closes the socket.
