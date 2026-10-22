# src/llm-mcp/http.cr
module LLM::MCP
  record HttpRequest, method : String, url : URI, headers : HTTP::Headers = HTTP::Headers.new, body : String? = nil,
    signal : AbortSignal? = nil

  class HttpResponse
    getter status : Int32
    getter headers : HTTP::Headers
    getter body : IO
    getter? closed = false

    def initialize(@status : Int32, @headers : HTTP::Headers = HTTP::Headers.new, @body : IO = IO::Memory.new,
                   @on_close : Proc(Nil)? = nil)
    end

    def self.new(status : Int32, headers : HTTP::Headers, body : String) : HttpResponse
      new(status, headers, IO::Memory.new(body))
    end

    def ok? : Bool
      200 <= @status <= 299
    end

    def content_type : String?
      @headers["content-type"]?.try(&.split(';', 2).first.strip.downcase).presence
    end

    def text(limit : Int32? = nil) : String
      if max = limit
        buffer = Bytes.new(max)
        String.new(buffer[0, read_some(buffer)]).scrub
      else
        @body.gets_to_end.scrub
      end
    ensure
      close
    end

    def json : JSON::Any
      JSON.parse(text)
    end

    def close : Nil
      return if @closed
      @closed = true
      @on_close.try &.call
    end

    private def read_some(buffer : Bytes) : Int32
      total = 0
      while total < buffer.size
        count = @body.read(buffer[total..])
        break if count == 0
        total += count
      end
      total
    end
  end

  alias Fetch = Proc(HttpRequest, HttpResponse)

  class HttpFetcher
    MAX_IDLE_PER_ORIGIN = 4

    private class BodyIO < IO
      getter? eof = false

      def initialize(@io : IO)
      end

      def read(slice : Bytes) : Int32
        count = @io.read(slice)
        @eof = true if count == 0 && !slice.empty?
        count
      end

      def peek : Bytes?
        bytes = @io.peek
        @eof = true if bytes && bytes.empty?
        bytes
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("HTTP response body is read-only")
      end
    end

    @idle = {} of String => Array(HTTP::Client)

    def call(request : HttpRequest) : HttpResponse
      signal = request.signal
      signal.try &.throw_if_aborted
      key = origin_key(request.url)
      client = checkout(key, request.url)
      ready = Channel(HttpResponse | Exception).new(1)
      remove_abort = signal ? close_on_abort(signal, client) : AbortSignal::NOOP_REMOVER
      spawn exchange(client, key, request, ready, remove_abort)
      result = ready.receive
      return result unless result.is_a?(Exception)
      if signal && signal.aborted?
        raise signal.reason.not_nil!
      end
      raise result
    end

    def to_fetch : Fetch
      ->(request : HttpRequest) { call(request) }
    end

    private def close_on_abort(signal : AbortSignal, client : HTTP::Client) : Proc(Nil)
      signal.on_abort { |_| client.close }
    end

    private def exchange(client : HTTP::Client, key : String, request : HttpRequest,
                         ready : Channel(HttpResponse | Exception), remove_abort : Proc(Nil)) : Nil
      handed = false
      reusable = false
      done = Channel(Bool).new(1)
      http_request = HTTP::Request.new(request.method, request.url.request_target, request.headers.dup, request.body)
      begin
        client.exec(http_request) do |response|
          body = BodyIO.new(response.body_io)
          handed = true
          ready.send(HttpResponse.new(response.status_code, response.headers, body, finisher(client, body, done)))
          reusable = done.receive
        end
      rescue error
        reusable = false
        ready.send(error) unless handed
      ensure
        remove_abort.call
        reusable ? checkin(key, client) : client.close
      end
    end

    private def finisher(client : HTTP::Client, body : BodyIO, done : Channel(Bool)) : Proc(Nil)
      -> do
        reusable = body.eof?
        client.close unless reusable
        done.send(reusable)
        nil
      end
    end

    private def origin_key(url : URI) : String
      "#{url.scheme}://#{url.host}:#{url.port}"
    end

    private def checkout(key : String, url : URI) : HTTP::Client
      @idle[key]?.try(&.pop?) || HTTP::Client.new(url)
    end

    private def checkin(key : String, client : HTTP::Client) : Nil
      idle = @idle[key] ||= [] of HTTP::Client
      if idle.size < MAX_IDLE_PER_ORIGIN
        idle << client
      else
        client.close
      end
    end
  end

  DEFAULT_HTTP_FETCHER = HttpFetcher.new
  DEFAULT_FETCH        = DEFAULT_HTTP_FETCHER.to_fetch
end
