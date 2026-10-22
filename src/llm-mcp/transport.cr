# src/llm-mcp/transport.cr
module LLM::MCP
  DEFAULT_MAX_MESSAGE_BYTES = 16 * 1024 * 1024

  abstract class Transport
    @message_listeners = Listeners(Proc(JsonRpc::Message, Nil)).new
    @error_listeners = Listeners(Proc(Exception, Nil)).new
    @close_listeners = Listeners(Proc(Nil)).new
    @close_emitted = false

    abstract def start : Nil
    abstract def send(message : JsonRpc::Message, signal : AbortSignal? = nil) : Nil
    abstract def close : Nil

    def protocol_version=(version : String) : Nil
    end

    def on_message(&listener : JsonRpc::Message -> Nil) : Proc(Nil)
      @message_listeners.add(listener)
    end

    def on_error(&listener : Exception -> Nil) : Proc(Nil)
      @error_listeners.add(listener)
    end

    def on_close(&listener : -> Nil) : Proc(Nil)
      @close_listeners.add(listener)
    end

    protected def emit_message(message : JsonRpc::Message) : Nil
      @message_listeners.snapshot.each(&.call(message))
    end

    protected def emit_error(error : Exception) : Nil
      @error_listeners.snapshot.each(&.call(error))
    end

    protected def emit_close : Nil
      return if @close_emitted
      @close_emitted = true
      @close_listeners.snapshot.each(&.call)
    end
  end
end
