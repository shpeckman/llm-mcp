# src/llm-mcp/sse.cr
module LLM::MCP::Sse
  READ_CHUNK = 16 * 1024
  NEWLINE    = 0x0a_u8

  record Event, data : String, event : String? = nil, id : String? = nil

  class Parser
    @event_name : String? = nil
    @event_id : String? = nil
    @data = [] of String
    @data_bytes = 0

    def initialize(@max_event_bytes : Int32, @on_event : Proc(Event, Nil), @on_id : Proc(String, Nil)?,
                   @on_retry : Proc(Time::Span, Nil)?)
    end

    def line(raw : String) : Nil
      text = raw.ends_with?('\r') ? raw[0, raw.size - 1] : raw
      if text.empty?
        dispatch
        return
      end
      return if text.starts_with?(':')
      colon = text.index(':')
      field = colon ? text[0, colon] : text
      value = colon ? text[(colon + 1)..] : ""
      value = value[1..] if value.starts_with?(' ')
      case field
      when "data"
        @data_bytes += value.bytesize + (@data.empty? ? 0 : 1)
        raise Error.new("MCP SSE event exceeds #{@max_event_bytes} bytes") if @data_bytes > @max_event_bytes
        @data << value
      when "event"
        @event_name = value
      when "id"
        unless value.includes?('\0')
          @event_id = value
          @on_id.try &.call(value)
        end
      when "retry"
        if value.each_char.all?(&.ascii_number?) && !value.empty? && (milliseconds = value.to_i64?)
          @on_retry.try &.call(milliseconds.milliseconds)
        end
      end
    end

    def dispatch : Nil
      if @data.empty?
        @event_name = nil
        @event_id = nil
        return
      end
      event = Event.new(@data.join('\n'), @event_name.presence, @event_id.presence)
      @event_name = nil
      @event_id = nil
      @data.clear
      @data_bytes = 0
      @on_event.call(event)
    end
  end

  def self.consume(io : IO, max_event_bytes : Int32 = DEFAULT_MAX_MESSAGE_BYTES, on_id : Proc(String, Nil)? = nil,
                   on_retry : Proc(Time::Span, Nil)? = nil, &on_event : Event -> Nil) : Nil
    read(io, max_event_bytes, Parser.new(max_event_bytes, on_event, on_id, on_retry))
  end

  private def self.read(io : IO, max_event_bytes : Int32, parser : Parser) : Nil
    buffer = Bytes.new(READ_CHUNK)
    pending = IO::Memory.new
    while (count = io.read(buffer)) > 0
      chunk = buffer[0, count]
      start = 0
      while newline = chunk.index(NEWLINE, start)
        pending.write(chunk[start, newline - start])
        parser.line(String.new(pending.to_slice).scrub)
        pending.clear
        start = newline + 1
      end
      pending.write(chunk[start, count - start]) if start < count
      raise Error.new("MCP SSE event exceeds #{max_event_bytes} bytes") if pending.bytesize > max_event_bytes
    end
    parser.line(String.new(pending.to_slice).scrub) if pending.bytesize > 0
    parser.dispatch
  end
end
