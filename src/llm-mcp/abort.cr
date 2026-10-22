# src/llm-mcp/abort.cr
module LLM::MCP
  class AbortSignal
    NOOP_REMOVER = -> { nil }

    getter reason : Exception? = nil
    getter? aborted = false
    @listeners = Listeners(Proc(Exception, Nil)).new

    def self.any(signals : Enumerable(AbortSignal)) : AbortSignal
      controller = AbortController.new
      if aborted = signals.find(&.aborted?)
        controller.abort(aborted.reason.not_nil!)
        return controller.signal
      end
      removers = signals.map { |signal| forward(signal, controller) }
      controller.signal.on_abort { |_| removers.each(&.call) }
      controller.signal
    end

    def self.timeout(span : Time::Span) : AbortSignal
      controller = AbortController.new
      spawn do
        sleep span
        controller.abort(AbortError.new("The operation timed out"))
      end
      controller.signal
    end

    private def self.forward(signal : AbortSignal, controller : AbortController) : Proc(Nil)
      signal.on_abort { |reason| controller.abort(reason) }
    end

    def on_abort(&listener : Exception -> Nil) : Proc(Nil)
      return NOOP_REMOVER if @aborted
      @listeners.add(listener)
    end

    def throw_if_aborted : Nil
      if reason = @reason
        raise reason
      end
    end

    protected def abort(reason : Exception) : Nil
      return if @aborted
      @aborted = true
      @reason = reason
      listeners = @listeners.snapshot
      @listeners.clear
      failure = nil
      listeners.each do |listener|
        listener.call(reason)
      rescue error
        failure ||= error
      end
      failure.try { |error| raise error }
    end
  end

  class AbortController
    getter signal = AbortSignal.new

    def abort(reason : Exception = AbortError.new("The operation was aborted")) : Nil
      @signal.abort(reason)
    end

    def abort(message : String) : Nil
      abort(AbortError.new(message))
    end
  end
end
