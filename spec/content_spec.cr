# spec/content_spec.cr
require "./spec_helper"

private def llm(*items : LLM::MCP::LlmContent) : Array(LLM::MCP::LlmContent)
  items.to_a.map(&.as(LLM::MCP::LlmContent))
end

private def text(value : String) : LLM::MCP::LlmContent
  LLM::MCP::LlmContent::Text.new(value)
end

private def result(content : String) : LLM::MCP::CallToolResult
  LLM::MCP::CallToolResult.new(json(content))
end

describe "LLM::MCP.to_llm_content" do
  it "passes text and images through and replaces other blocks with text" do
    blocks = result(%({"content":[
      {"type":"text","text":"hello","annotations":{"priority":1}},
      {"type":"image","data":"aW1n","mimeType":"image/png","_meta":{"x":1}},
      {"type":"audio","data":"YXVk","mimeType":"audio/wav"},
      {"type":"resource_link","uri":"file:///a.txt","name":"a.txt"},
      {"type":"resource","resource":{"uri":"file:///b.txt","text":"inline"}},
      {"type":"resource","resource":{"uri":"file:///c.png","mimeType":"image/png","blob":"Yw=="}},
      {"type":"resource","resource":{"uri":"file:///d.bin","blob":"ZA=="}}
    ]}))
    LLM::MCP.to_llm_content(blocks).should eq(llm(
      text("hello"),
      LLM::MCP::LlmContent::Image.new("aW1n", "image/png"),
      text("[audio audio/wav omitted]"),
      text("a.txt: file:///a.txt"),
      text("inline"),
      LLM::MCP::LlmContent::Image.new("Yw==", "image/png"),
      text("[binary resource file:///d.bin (unknown type) omitted]"),
    ))
  end

  it "falls back to the structured content as JSON when there are no blocks" do
    result(%({"content":[],"structuredContent":[1,2]})).to_llm_content.should eq(llm(text("[\n  1,\n  2\n]")))
    result(%({"content":[],"structuredContent":null})).to_llm_content.should eq(llm(text("null")))
    result(%({"content":[],"structuredContent":{"n":1}})).to_llm_content.should eq(llm(text(%({\n  "n": 1\n}))))
    result(%({"content":[{"type":"text","text":"n=1"}],"structuredContent":{"n":1}})).to_llm_content.should eq(llm(text("n=1")))
  end

  it "serializes LLM content in pi-ai's shape" do
    LLM::MCP::LlmContent::Image.new("aW1n", "image/png").to_json.should eq(%({"type":"image","data":"aW1n","mimeType":"image/png"}))
  end
end
