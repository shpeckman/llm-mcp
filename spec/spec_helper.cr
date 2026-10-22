# spec/spec_helper.cr
require "spec"
require "../src/llm-mcp"
require "../src/llm-mcp/oauth"
require "../src/llm-mcp/testing"
require "./support/http_server"

def json(text : String) : JSON::Any
  JSON.parse(text)
end

def eventually(attempts : Int32 = 200, delay : Time::Span = 10.milliseconds, &) : Nil
  attempts.times do
    return if yield
    sleep delay
  end
  raise "condition not met in time"
end

Spec.after_each { TestHttp.close_all }
