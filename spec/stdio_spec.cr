# spec/stdio_spec.cr
require "./spec_helper"

private alias MCP = LLM::MCP

private FIXTURE = File.join(Dir.tempdir, "llm-mcp-stdio-fixture-#{Process.pid}")

private def fixture : String
  unless File.exists?(FIXTURE)
    source = File.expand_path("fixtures/server.cr", __DIR__)
    status = Process.run("crystal", ["build", source, "-o", FIXTURE], output: STDOUT, error: STDERR)
    raise "failed to build the stdio fixture" unless status.success?
  end
  FIXTURE
end

private def alive?(pid : Int64) : Bool
  return false unless LibC.kill(pid.to_i32, 0) == 0
  stat = File.read("/proc/#{pid}/stat") rescue nil
  return true unless stat
  stat.split(") ", 2)[1]?.try(&.starts_with?('Z')) != true
end

describe LLM::MCP::StdioTransport do
  it "connects to a newline-delimited MCP server and captures stderr" do
    stderr = [] of String
    transport = MCP::StdioTransport.new(fixture, on_stderr: ->(chunk : String) { stderr << chunk; nil })
    client = MCP::Client.new("stdio-test", "1.0.0")
    client.connect(transport)
    client.list_tools.map(&.raw).should eq([json(%({"name":"echo","inputSchema":{"type":"object"}}))])
    client.call_tool("echo", {text: "hello"}).raw.should eq(json(%({"content":[{"type":"text","text":"hello"}]})))
    transport.pid.should be_a(Int64)
    eventually { transport.stderr.includes?("stdio fixture ready") }
    stderr.join.should contain("stdio fixture ready")
    client.close
    client.connection_state.should eq(MCP::ConnectionState::Closed)
  end

  it "kills a server that ignores shutdown, including its children" do
    transport = MCP::StdioTransport.new(fixture, ["stubborn"], close_timeout: 100.milliseconds)
    client = MCP::Client.new("stdio-test", "1.0.0")
    client.connect(transport)
    grandchild = nil.as(Int64?)
    eventually { grandchild = transport.stderr.match(/grandchild (\d+)/).try(&.[1].to_i64) }
    started_at = Time.instant
    client.close
    (Time.instant - started_at).should be < 5.seconds
    pid = grandchild.not_nil!
    eventually(attempts: 100, delay: 20.milliseconds) { !alive?(pid) }
  end

  it "fails to start a command that does not exist" do
    transport = MCP::StdioTransport.new("llm-mcp-no-such-command")
    expect_raises(RuntimeError) { MCP::Client.new("stdio-test", "1.0.0").connect(transport) }
  end
end
