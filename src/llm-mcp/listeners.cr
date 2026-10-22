# src/llm-mcp/listeners.cr
module LLM::MCP
  class Listeners(T)
    @entries = {} of Int32 => T
    @next_id = 0

    def add(listener : T) : Proc(Nil)
      id = @next_id
      @next_id += 1
      @entries[id] = listener
      remover(id)
    end

    def snapshot : Array(T)
      @entries.values
    end

    def empty? : Bool
      @entries.empty?
    end

    def clear : Nil
      @entries.clear
    end

    private def remover(id : Int32) : Proc(Nil)
      -> { @entries.delete(id); nil }
    end
  end
end
