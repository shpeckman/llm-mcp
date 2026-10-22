# spec/client_spec.cr
require "./spec_helper"

private alias MCP = LLM::MCP

private class TestServer
  getter transport : MCP::Testing::InMemoryTransport
  getter messages = [] of MCP::JsonRpc::Message
  @handlers = {} of String => Proc(MCP::JsonRpc::Request, JSON::Any)

  def initialize(@transport : MCP::Testing::InMemoryTransport)
    transport.on_message do |message|
      @messages << message
      if message.is_a?(MCP::JsonRpc::Request)
        request = message
        spawn respond(request)
      end
    end
    transport.start
    set_handler("initialize") do
      json(%({"protocolVersion":"#{MCP::LATEST_PROTOCOL_VERSION}","capabilities":{"tools":{"listChanged":true}},
              "serverInfo":{"name":"test-server","version":"1.0.0"},"instructions":"Use test tools."}))
    end
  end

  def set_handler(method : String, &handler : MCP::JsonRpc::Request -> JSON::Any) : Nil
    @handlers[method] = handler
  end

  def sent_json : Array(JSON::Any)
    @messages.map { |message| JSON.parse(message.to_json) }
  end

  private def respond(request : MCP::JsonRpc::Request) : Nil
    reply = begin
      handler = @handlers[request.method]? || raise MCP::RpcError.new(-32601, "Method not found: #{request.method}")
      MCP::JsonRpc::Success.new(request.id, handler.call(request)).as(MCP::JsonRpc::Message)
    rescue error : MCP::RpcError
      MCP::JsonRpc::Failure.new(request.id, MCP::JsonRpc::ErrorObject.new(error.code, error.message.to_s, error.data))
    rescue error
      MCP::JsonRpc::Failure.new(request.id, MCP::JsonRpc::ErrorObject.new(-32603, error.message.to_s))
    end
    @transport.send(reply)
  rescue MCP::ConnectionClosedError
  end
end

private def create_server : {MCP::Testing::InMemoryTransport, TestServer}
  pair = MCP::Testing.in_memory_transport_pair
  {pair[:client], TestServer.new(pair[:server])}
end

private def connect : {MCP::Client, TestServer}
  client_transport, server = create_server
  client = MCP::Client.new("test-client", "2.0.0")
  client.connect(client_transport)
  {client, server}
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

describe LLM::MCP::Client do
  it "initializes the connection before exposing server information" do
    client, server = connect
    client.connection_state.should eq(MCP::ConnectionState::Connected)
    client.protocol_version.should eq(MCP::LATEST_PROTOCOL_VERSION)
    client.server_info.not_nil!.raw.should eq(json(%({"name":"test-server","version":"1.0.0"})))
    client.server_capabilities.not_nil!.raw.should eq(json(%({"tools":{"listChanged":true}})))
    client.server_capabilities.not_nil!.tools.not_nil!.list_changed.should be_true
    client.instructions.should eq("Use test tools.")
    eventually { server.messages.size == 2 }
    server.sent_json.should eq([
      json(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"#{MCP::LATEST_PROTOCOL_VERSION}",
             "capabilities":{},"clientInfo":{"name":"test-client","version":"2.0.0"}}})),
      json(%({"jsonrpc":"2.0","method":"notifications/initialized"})),
    ])
    client.close
  end

  it "paginates tools and preserves protocol tool definitions" do
    client, server = connect
    server.set_handler("tools/list") do |request|
      if request.params.try(&.["cursor"]?).nil?
        json(%({"tools":[{"name":"search","description":"Search","inputSchema":{"type":"object"}}],"nextCursor":"page-2"}))
      else
        json(%({"tools":[{"name":"read","inputSchema":{"type":"object"},"outputSchema":{"type":"object"},
                "annotations":{"readOnlyHint":true}}],"nextCursor":""}))
      end
    end
    tools = client.list_tools
    tools.map(&.raw).should eq([
      json(%({"name":"search","description":"Search","inputSchema":{"type":"object"}})),
      json(%({"name":"read","inputSchema":{"type":"object"},"outputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}})),
    ])
    tools[1].annotations.not_nil!.read_only_hint.should be_true
    client.close
  end

  it "lists and reads resources" do
    client, server = connect
    server.set_handler("resources/list") do |request|
      if request.params.try(&.["cursor"]?).nil?
        json(%({"resources":[{"uri":"file:///a","name":"a","mimeType":"text/plain"}],"nextCursor":"2"}))
      else
        json(%({"resources":[{"uri":"file:///b"}]}))
      end
    end
    server.set_handler("resources/templates/list") { json(%({"resourceTemplates":[{"uriTemplate":"repo://{owner}/{repo}","name":"repo"}]})) }
    server.set_handler("resources/read") do |request|
      json(%({"contents":[{"uri":#{request.params.not_nil!["uri"].to_json},"text":"hello"}]}))
    end
    client.list_resources.map(&.raw).should eq([
      json(%({"uri":"file:///a","name":"a","mimeType":"text/plain"})),
      json(%({"uri":"file:///b","name":"file:///b"})),
    ])
    client.list_resource_templates.map(&.raw).should eq([json(%({"uriTemplate":"repo://{owner}/{repo}","name":"repo"}))])
    first = client.list_resources_page
    first.resources.map(&.raw).should eq([json(%({"uri":"file:///a","name":"a","mimeType":"text/plain"}))])
    first.next_cursor.should eq("2")
    second = client.list_resources_page("2")
    second.resources.map(&.raw).should eq([json(%({"uri":"file:///b","name":"file:///b"}))])
    second.next_cursor.should be_nil
    read = client.read_resource("file:///a")
    read.raw.should eq(json(%({"contents":[{"uri":"file:///a","text":"hello"}]})))
    read.contents.first.text.should eq("hello")

    server.set_handler("resources/read") { json(%({"contents":[{"uri":"file:///a"}]})) }
    expect_raises(MCP::RpcError, "Invalid contents in MCP resources/read result") { client.read_resource("file:///a") }
    server.set_handler("resources/list") { json(%({"resources":[{"name":"no uri"}]})) }
    expect_raises(MCP::RpcError, "Invalid entry in MCP resources/list result") { client.list_resources }
    client.close
  end

  it "returns structured tool content and surfaces JSON-RPC errors" do
    client, server = connect
    server.set_handler("tools/call") do |request|
      params = request.params.not_nil!
      raise MCP::RpcError.new(1234, "tool failed", json(%({"retryable":false}))) if params["name"] == "fail"
      json(%({"content":[{"type":"text","text":"ok"}],"structuredContent":{"count":#{params["arguments"]["count"].to_json}}}))
    end
    client.call_tool("count", {count: 3}).raw.should eq(json(%({"content":[{"type":"text","text":"ok"}],"structuredContent":{"count":3}})))
    error = expect_raises(MCP::RpcError, "tool failed") { client.call_tool("fail") }
    error.code.should eq(1234)
    error.data.should eq(json(%({"retryable":false})))
    client.close
  end

  it "renews the timeout on progress" do
    client, server = connect
    server.set_handler("tools/call") do |request|
      token = request.params.not_nil!["_meta"]["progressToken"]
      spawn do
        sleep 100.milliseconds
        server.transport.send(MCP::JsonRpc::Notification.new("notifications/progress",
          json(%({"progressToken":#{token.to_json},"progress":1,"total":2}))))
      end
      sleep 200.milliseconds
      json(%({"content":[{"type":"text","text":"done"}]}))
    end
    progress = [] of JSON::Any
    on_progress = ->(notification : MCP::ProgressNotification) { progress << notification.raw; nil }
    result = client.call_tool("slow", {} of String => String, timeout: 150.milliseconds, on_progress: on_progress)
    result.raw.should eq(json(%({"content":[{"type":"text","text":"done"}]})))
    progress.should eq([json(%({"progressToken":2,"progress":1,"total":2}))])
    client.close
  end

  it "cancels aborted and timed-out requests" do
    client, server = connect
    server.set_handler("tools/call") { TestHttp.park; json("{}") }
    controller = MCP::AbortController.new
    spawn do
      sleep 20.milliseconds
      controller.abort("stop")
    end
    expect_raises(MCP::AbortError) { client.call_tool("wait", {} of String => String, signal: controller.signal) }
    eventually do
      server.sent_json.includes?(json(%({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"stop"}})))
    end
    expect_raises(MCP::TimeoutError) { client.call_tool("wait", {} of String => String, timeout: 5.milliseconds) }
    client.close
  end

  it "reports transport errors without failing pending requests" do
    client_transport, server = create_server
    client = MCP::Client.new("test-client", "1.0.0")
    client.connect(client_transport)
    errors = [] of String
    client.on_error { |error| errors << error.message.to_s }
    release = Channel(Nil).new
    server.set_handler("tools/call") { release.receive; json(%({"content":[]})) }
    call = background { client.call_tool("wait") }
    sleep 10.milliseconds
    client_transport.emit_error(Exception.new("stray log line"))
    release.send(nil)
    result = call.receive
    result.as(MCP::CallToolResult).raw.should eq(json(%({"content":[]})))
    errors.should eq(["stray log line"])
    client.close
  end

  it "accepts servers that answer with an older protocol version" do
    client_transport, server = create_server
    server.set_handler("initialize") do
      json(%({"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"old-server","version":"0.1.0"}}))
    end
    client = MCP::Client.new("test-client", "1.0.0")
    client.connect(client_transport)
    client.protocol_version.should eq("2024-11-05")
    client.close

    unsupported_transport, unsupported = create_server
    unsupported.set_handler("initialize") do
      json(%({"protocolVersion":"1999-01-01","capabilities":{},"serverInfo":{"name":"ancient-server","version":"0.1.0"}}))
    end
    rejected = MCP::Client.new("test-client", "1.0.0")
    expect_raises(MCP::Error, "unsupported protocol version") { rejected.connect(unsupported_transport) }
    rejected.connection_state.should eq(MCP::ConnectionState::Closed)
  end

  it "defaults missing tool result content to an empty list" do
    client, server = connect
    server.set_handler("tools/call") { json(%({"structuredContent":{"ok":true}})) }
    client.call_tool("structured").raw.should eq(json(%({"content":[],"structuredContent":{"ok":true}})))
    server.set_handler("tools/call") { json(%({"content":"not a list"})) }
    expect_raises(MCP::RpcError, "Invalid MCP tools/call result") { client.call_tool("broken") }
    client.close
  end

  it "accepts structured content that is not an object" do
    client, server = connect
    [%([{"id":1},{"id":2}]), "null", %("text"), "3", "false"].each do |structured|
      server.set_handler("tools/call") { json(%({"content":[],"structuredContent":#{structured}})) }
      client.call_tool("structured").structured_content.should eq(json(structured))
    end
    client.close
  end

  it "does not send notifications/cancelled for a timed-out initialize" do
    client_transport, server = create_server
    server.set_handler("initialize") { TestHttp.park; json("{}") }
    client = MCP::Client.new("test-client", "1.0.0", request_timeout: 5.milliseconds)
    expect_raises(MCP::TimeoutError) { client.connect(client_transport) }
    sleep 10.milliseconds
    server.messages.any? { |message| message.is_a?(MCP::JsonRpc::Notification) && message.method == "notifications/cancelled" }.should be_false
  end

  it "notifies close listeners once when the transport drops" do
    client, server = connect
    closed = 0
    client.on_close { closed += 1 }
    server.set_handler("tools/call") { TestHttp.park; json("{}") }
    pending = background { client.call_tool("wait") }
    sleep 10.milliseconds
    server.transport.close
    error = pending.receive
    error.should be_a(MCP::ConnectionClosedError)
    error.as(Exception).message.should eq("MCP connection closed")
    client.connection_state.should eq(MCP::ConnectionState::Closed)
    client.close
    closed.should eq(1)
  end

  it "answers roots/list and dispatches notifications" do
    client_transport, server = create_server
    client = MCP::Client.new("test-client", "1.0.0", roots: [MCP::Root.new("file:///workspace", "workspace")])
    client.connect(client_transport)
    changed = [] of JSON::Any?
    client.on_notification("notifications/tools/list_changed") { |params| changed << params }
    server.transport.send(MCP::JsonRpc::Request.new("roots", "roots/list"))
    server.transport.send(MCP::JsonRpc::Notification.new("notifications/tools/list_changed"))
    expected = json(%({"jsonrpc":"2.0","id":"roots","result":{"roots":[{"uri":"file:///workspace","name":"workspace"}]}}))
    eventually { server.sent_json.includes?(expected) }
    changed.should eq([nil])
    initialize = server.sent_json.first
    initialize["params"]["capabilities"].should eq(json(%({"roots":{}})))
    client.close
  end
end
