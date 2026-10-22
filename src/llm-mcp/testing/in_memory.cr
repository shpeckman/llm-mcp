# src/llm-mcp/testing/in_memory.cr
module LLM::MCP::Testing
  class InMemoryTransport < Transport
    getter? started = false
    getter? closed = false
    @peer : InMemoryTransport? = nil
    @queue = Deque(JsonRpc::Message).new
    @wake = Channel(Bool).new(1)
    @pumping = false

    def connect_peer(peer : InMemoryTransport) : Nil
      raise Error.new("In-memory MCP transport already has a peer") if @peer
      @peer = peer
    end

    def start : Nil
      raise ConnectionClosedError.new if @closed
      @started = true
    end

    def send(message : JsonRpc::Message, signal : AbortSignal? = nil) : Nil
      raise ConnectionClosedError.new if !@started || @closed
      peer = @peer
      unless peer && peer.started? && !peer.closed?
        raise ConnectionClosedError.new("In-memory MCP peer is not connected")
      end
      peer.deliver(JsonRpc.parse(JSON.parse(message.to_json)))
    end

    def close : Nil
      return if @closed
      @closed = true
      @wake.close
      emit_close
      @peer.try &.close
    end

    def emit_error(error : Exception) : Nil
      super
    end

    protected def deliver(message : JsonRpc::Message) : Nil
      return if @closed
      @queue << message
      unless @pumping
        @pumping = true
        spawn pump
      end
      select
      when @wake.send(true)
      else
      end
    end

    private def pump : Nil
      while @wake.receive?
        while !@closed && (message = @queue.shift?)
          begin
            emit_message(message)
          rescue error
            emit_error(error)
          end
        end
      end
    end
  end

  def self.in_memory_transport_pair : {client: InMemoryTransport, server: InMemoryTransport}
    client = InMemoryTransport.new
    server = InMemoryTransport.new
    client.connect_peer(server)
    server.connect_peer(client)
    {client: client, server: server}
  end
end
