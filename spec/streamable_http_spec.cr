# spec/streamable_http_spec.cr
require "./spec_helper"

private alias MCP = LLM::MCP

private record RecordedRequest, method : String, headers : HTTP::Headers, message : JSON::Any? = nil

private class Recorder
  getter requests = [] of RecordedRequest
end

private class ProcAuth < MCP::AuthProvider
  def initialize(@token_source : Proc(String?), @handler : Proc(MCP::UnauthorizedContext, Nil)? = nil)
  end

  def token : String?
    @token_source.call
  end

  def on_unauthorized(context : MCP::UnauthorizedContext) : Bool
    handler = @handler
    return false unless handler
    handler.call(context)
    true
  end
end

private class ChunkIO < IO
  getter sent = 0

  def read(slice : Bytes) : Int32
    @sent += 1
    return 0 if @sent > 1000
    line = "data: xxxxxxxxxxxxxxxx\n".to_slice
    line.copy_to(slice)
    line.size
  end

  def write(slice : Bytes) : Nil
  end
end

private def protocol_handler(context : HTTP::Server::Context, recorder : Recorder, body : JSON::Any? = nil) : Nil
  request = context.request
  response = context.response
  case request.method
  when "GET"
    recorder.requests << RecordedRequest.new("GET", request.headers)
    response.status_code = 405
    return
  when "DELETE"
    recorder.requests << RecordedRequest.new("DELETE", request.headers)
    response.status_code = 200
    return
  end
  message = body || JSON.parse(TestHttp.read_body(context))
  recorder.requests << RecordedRequest.new(request.method, request.headers, message)
  unless message.as_h.has_key?("id")
    response.status_code = 202
    return
  end
  case message["method"]?.try(&.as_s)
  when "initialize"
    response.content_type = "application/json"
    response.headers["mcp-session-id"] = "session-1"
    response.print({jsonrpc: "2.0", id: message["id"], result: {
      protocolVersion: MCP::LATEST_PROTOCOL_VERSION, capabilities: {tools: {} of String => String},
      serverInfo: {name: "http-fixture", version: "1.0.0"},
    }}.to_json)
  when "tools/list"
    response.content_type = "application/json"
    response.print({jsonrpc: "2.0", id: message["id"], result: {tools: [{name: "echo", inputSchema: {type: "object"}}]}}.to_json)
  else
    response.content_type = "text/event-stream"
    response.print("id: tool-result\n")
    response.print("data: #{({jsonrpc: "2.0", id: message["id"], result: {content: [{type: "text", text: "hello"}]}}).to_json}\n\n")
  end
end

private def start_server(&handler : HTTP::Server::Context, Recorder -> Nil) : {String, Recorder}
  recorder = Recorder.new
  origin = TestHttp.listen { |context, _origin| handler.call(context, recorder) }
  {"#{origin}/mcp", recorder}
end

private def new_client : MCP::Client
  MCP::Client.new("http-test", "1.0.0")
end

private def hello : JSON::Any
  json(%({"content":[{"type":"text","text":"hello"}]}))
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

describe LLM::MCP::Sse do
  it "parses chunked CRLF events, comments, IDs, and multiline data" do
    events = [] of MCP::Sse::Event
    io = IO::Memory.new(%(: keepalive\r\nid: 7\r\ndata: {"one":\r\ndata: 1}\r\n\r\n))
    MCP::Sse.consume(io) { |event| events << event }
    events.should eq([MCP::Sse::Event.new(%({"one":\n1}), nil, "7")])
  end

  it "rejects events whose data lines exceed the limit without a blank line" do
    io = ChunkIO.new
    expect_raises(MCP::Error, "MCP SSE event exceeds 256 bytes") { MCP::Sse.consume(io, 256) { } }
    io.sent.should be < 100
  end
end

describe LLM::MCP::StreamableHttpTransport do
  it "handles JSON and SSE responses with session and protocol headers" do
    url, recorder = start_server { |context, requests| protocol_handler(context, requests) }
    transport = MCP::StreamableHttpTransport.new(url)
    client = new_client
    client.connect(transport)
    transport.session_id.should eq("session-1")
    client.list_tools.map(&.raw).should eq([json(%({"name":"echo","inputSchema":{"type":"object"}}))])
    client.call_tool("echo", {text: "hello"}).raw.should eq(hello)
    eventually { recorder.requests.any? { |entry| entry.method == "GET" } }
    client.close
    list_request = recorder.requests.find { |entry| entry.message.try(&.["method"]?) == "tools/list" }.not_nil!
    list_request.headers["mcp-session-id"].should eq("session-1")
    list_request.headers["mcp-protocol-version"].should eq(MCP::LATEST_PROTOCOL_VERSION)
    recorder.requests.any? { |entry| entry.method == "DELETE" }.should be_true
  end

  it "classifies authentication failures" do
    url, _ = start_server do |context, _requests|
      TestHttp.read_body(context)
      context.response.status_code = 401
      context.response.headers["www-authenticate"] = %(Bearer resource_metadata="https://example.com/meta")
      context.response.print("login required")
    end
    error = expect_raises(MCP::AuthRequiredError) { new_client.connect(MCP::StreamableHttpTransport.new(url)) }
    error.status.should eq(401)
    error.body.should eq("login required")
    error.www_authenticate.should eq(%(Bearer resource_metadata="https://example.com/meta"))
  end

  it "fails only the request whose SSE stream breaks" do
    release_slow = Channel(Nil).new
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      name = message["params"]?.try(&.["name"]?).try(&.as_s?)
      if name == "broken"
        context.response.content_type = "text/event-stream"
        context.response.print("data: not json\n\n")
        next
      end
      release_slow.receive if name == "slow"
      protocol_handler(context, requests, message)
    end
    client = new_client
    errors = [] of Exception
    client.on_error { |error| errors << error }
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false))
    slow = background { client.call_tool("slow") }
    expect_raises(MCP::RpcError, "MCP response stream failed") { client.call_tool("broken") }
    release_slow.send(nil)
    slow.receive.as(MCP::CallToolResult).raw.should eq(hello)
    errors.size.should eq(1)
    client.close
  end

  it "opens the GET stream after initialization and sends Last-Event-ID only when resuming" do
    order = [] of String
    url, recorder = start_server do |context, requests|
      if context.request.method == "POST"
        message = JSON.parse(TestHttp.read_body(context))
        order << message["method"].as_s
        next protocol_handler(context, requests, message)
      end
      order << context.request.method
      protocol_handler(context, requests)
    end
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url))
    client.call_tool("echo")
    client.list_tools
    eventually { order.includes?("GET") }
    client.close
    order.index("GET").not_nil!.should be > order.index("notifications/initialized").not_nil!
    recorder.requests.all? { |entry| entry.headers["last-event-id"]?.nil? }.should be_true
  end

  it "resumes a response stream the server closed before answering" do
    resume_headers = [] of String
    url, _ = start_server do |context, requests|
      request = context.request
      if request.method == "GET" && (last = request.headers["last-event-id"]?)
        resume_headers << last
        context.response.content_type = "text/event-stream"
        context.response.print("id: 2\ndata: #{({jsonrpc: "2.0", id: 2, result: {content: [{type: "text", text: "resumed"}]}}).to_json}\n\n")
        next
      end
      next protocol_handler(context, requests) unless request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      next protocol_handler(context, requests, message) unless message["method"] == "tools/call"
      context.response.content_type = "text/event-stream"
      context.response.print("id: 1\nretry: 5\ndata:\n\n")
    end
    client = new_client
    errors = [] of Exception
    client.on_error { |error| errors << error }
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false))
    client.call_tool("echo").raw.should eq(json(%({"content":[{"type":"text","text":"resumed"}]})))
    resume_headers.should eq(["1"])
    errors.should be_empty
    client.close
  end

  it "fails a request whose response stream ends without an answer" do
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      next protocol_handler(context, requests, message) unless message["method"] == "tools/call"
      context.response.content_type = "text/event-stream"
      context.response.print(": nothing here\n\n")
    end
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false))
    expect_raises(MCP::RpcError, "MCP response stream failed: stream ended without a response") do
      client.call_tool("echo", timeout: 5.seconds)
    end
    client.close
  end

  it "reconnects the GET stream after it drops" do
    gets = 0
    last_event_ids = [] of String?
    notification = %({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "GET"
      gets += 1
      last_event_ids << context.request.headers["last-event-id"]?
      context.response.content_type = "text/event-stream"
      if gets == 1
        context.response.print("id: g1\ndata: #{notification}\n\n")
        next
      end
      context.response.print("id: g2\ndata: #{notification}\n\n")
      context.response.flush
      TestHttp.park
    end
    client = new_client
    changes = 0
    client.on_notification("notifications/tools/list_changed") { |_| changes += 1 }
    client.connect(MCP::StreamableHttpTransport.new(url, reconnect: MCP::ReconnectOptions.new(initial_delay: 1.millisecond)))
    eventually { changes == 2 }
    last_event_ids.should eq([nil, "g1"])
    client.close
  end

  it "rejects a request the server accepts without a response" do
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      next protocol_handler(context, requests, message) unless message["method"] == "tools/call"
      context.response.status_code = 202
    end
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false))
    expect_raises(MCP::HttpError, "without a response") { client.call_tool("echo") }
    client.close
  end

  it "includes the response body in HTTP errors" do
    url, _ = start_server do |context, _requests|
      TestHttp.read_body(context)
      context.response.status_code = 400
      context.response.print("Invalid Accept header")
    end
    expect_raises(MCP::HttpError, "MCP HTTP request failed with status 400: Invalid Accept header") do
      new_client.connect(MCP::StreamableHttpTransport.new(url))
    end
  end

  it "hands 401 and insufficient-scope 403 responses to the auth provider with the rejected token" do
    seen = [] of {Int32, String?}
    token = "old"
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      authorization = context.request.headers["authorization"]?
      if authorization == "Bearer old"
        context.response.status_code = 401
        context.response.headers["www-authenticate"] = "Bearer"
        next
      end
      if message["method"] == "tools/call" && authorization == "Bearer new"
        context.response.status_code = 403
        context.response.headers["www-authenticate"] = %(Bearer error="insufficient_scope", scope="admin")
        next
      end
      protocol_handler(context, requests, message)
    end
    auth = ProcAuth.new(-> { token.as(String?) }, ->(context : MCP::UnauthorizedContext) {
      seen << {context.response.status, context.token}
      token = context.response.status == 401 ? "new" : "admin"
      nil
    })
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false, auth_provider: auth))
    client.call_tool("echo").raw.should eq(hello)
    seen.should eq([{401, "old"}, {403, "new"}])
    client.close
  end

  it "does not retry requests that were cancelled while authorization was recovering" do
    token = "old"
    executed = [] of String
    url, _ = start_server do |context, requests|
      next protocol_handler(context, requests) unless context.request.method == "POST"
      message = JSON.parse(TestHttp.read_body(context))
      if message["method"] == "tools/call" && context.request.headers["authorization"]? == "Bearer old"
        context.response.status_code = 401
        context.response.headers["www-authenticate"] = "Bearer"
        next
      end
      executed << message["params"]["name"].as_s if message["method"] == "tools/call"
      protocol_handler(context, requests, message)
    end
    refresh_gate = Channel(Nil).new
    refreshing = false
    refreshed = Channel(Nil).new
    refreshes = 0
    waiting = 0
    auth = ProcAuth.new(-> { token.as(String?) }, ->(_context : MCP::UnauthorizedContext) {
      waiting += 1
      if refreshing
        refreshed.receive?
      else
        refreshing = true
        refreshes += 1
        refresh_gate.receive
        token = "new"
        refreshed.close
      end
      nil
    })
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false, auth_provider: auth))
    controller = MCP::AbortController.new
    aborted = background { client.call_tool("aborted", signal: controller.signal) }
    timed_out = background { client.call_tool("timed-out", timeout: 200.milliseconds) }
    kept = background { client.call_tool("kept") }
    eventually { waiting == 3 }
    controller.abort
    aborted.receive.should be_a(MCP::AbortError)
    timed_out.receive.should be_a(MCP::TimeoutError)
    refresh_gate.send(nil)
    kept.receive.as(MCP::CallToolResult).raw.should eq(hello)
    executed.should eq(["kept"])
    refreshes.should eq(1)
    client.close
  end

  it "closes the session with the last request's token, without asking the auth provider" do
    url, recorder = start_server { |context, requests| protocol_handler(context, requests) }
    calls = 0
    auth = ProcAuth.new(-> { calls += 1; "token-#{calls}".as(String?) })
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false, auth_provider: auth))
    before = calls
    client.close
    calls.should eq(before)
    deletes = recorder.requests.select { |entry| entry.method == "DELETE" }
    deletes.map(&.headers["authorization"]?).should eq(["Bearer token-#{before}"])
    deletes.first.headers["mcp-session-id"].should eq("session-1")
  end

  it "uses the injected fetch, also for the auth provider" do
    url, _ = start_server do |context, requests|
      if context.request.method == "POST" && context.request.headers["authorization"]?.nil?
        TestHttp.read_body(context)
        context.response.status_code = 401
        context.response.headers["www-authenticate"] = "Bearer"
        next
      end
      protocol_handler(context, requests)
    end
    fetched = [] of String
    fetch = ->(request : MCP::HttpRequest) {
      fetched << request.method
      MCP::DEFAULT_FETCH.call(request)
    }
    token = nil.as(String?)
    auth = ProcAuth.new(-> { token }, ->(context : MCP::UnauthorizedContext) {
      context.fetch.call(MCP::HttpRequest.new("GET", URI.parse(url))).close
      token = "token"
      nil
    })
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, fetch: fetch, open_get_stream: false, auth_provider: auth))
    client.list_tools.map(&.raw).should eq([json(%({"name":"echo","inputSchema":{"type":"object"}}))])
    client.close
    fetched.first(3).should eq(["POST", "GET", "POST"])
  end

  it "classifies an expired established session" do
    posts = 0
    url, _ = start_server do |context, requests|
      if context.request.method == "POST"
        posts += 1
        if posts > 2
          TestHttp.read_body(context)
          context.response.status_code = 404
          context.response.print("gone")
          next
        end
      end
      protocol_handler(context, requests)
    end
    client = new_client
    client.connect(MCP::StreamableHttpTransport.new(url, open_get_stream: false))
    expect_raises(MCP::SessionExpiredError) { client.list_tools }
    client.close
  end
end
