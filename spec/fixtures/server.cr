# spec/fixtures/server.cr
require "json"

def reply(id : JSON::Any, result) : Nil
  STDOUT.puts({jsonrpc: "2.0", id: id, result: result}.to_json)
  STDOUT.flush
end

def echo_server : Nil
  STDERR.puts "stdio fixture ready"
  STDERR.flush
  while line = STDIN.gets
    message = JSON.parse(line)
    id = message["id"]?
    next unless id
    case message["method"].as_s
    when "initialize"
      reply(id, {protocolVersion: "2025-06-18", capabilities: {tools: {} of String => String},
                 serverInfo: {name: "stdio-fixture", version: "1.0.0"}})
    when "tools/list"
      reply(id, {tools: [{name: "echo", inputSchema: {type: "object"}}]})
    when "tools/call"
      reply(id, {content: [{type: "text", text: message["params"]["arguments"]["text"].to_s}]})
    when "ping"
      reply(id, {} of String => String)
    else
      STDOUT.puts({jsonrpc: "2.0", id: id, error: {code: -32601, message: "not found"}}.to_json)
      STDOUT.flush
    end
  end
end

def stubborn_server : Nil
  Signal::TERM.ignore
  grandchild = Process.new(Process.executable_path.not_nil!, ["grandchild"],
    input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
  STDERR.puts "grandchild #{grandchild.pid}"
  STDERR.flush
  while line = STDIN.gets
    message = JSON.parse(line)
    next unless message["method"]? == "initialize"
    reply(message["id"], {protocolVersion: "2025-06-18", capabilities: {} of String => String,
                          serverInfo: {name: "stubborn-fixture", version: "1.0.0"}})
  end
  sleep
end

def grandchild : Nil
  Signal::TERM.ignore
  sleep
end

case ARGV.first?
when "stubborn"   then stubborn_server
when "grandchild" then grandchild
else                   echo_server
end
