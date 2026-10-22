# src/llm-mcp/streamable_http.cr
module LLM::MCP
  record ReconnectOptions, initial_delay : Time::Span = 1.second, max_delay : Time::Span = 30.seconds,
    max_retries : Int32 = 5

  class StreamableHttpTransport < Transport
    MAX_ERROR_BODY_BYTES     = 8 * 1024
    ERROR_MESSAGE_BODY_CHARS = 500
    CLOSE_TIMEOUT            = 1.second
    INSUFFICIENT_SCOPE       = /(?:^|[\s,])error="?insufficient_scope"?/i

    private class StreamCursor
      property last_event_id : String? = nil
      property retry : Time::Span? = nil
      property? received = false
    end

    getter url : URI
    getter headers : HTTP::Headers
    getter session_id : String? = nil
    getter? open_get_stream : Bool
    getter max_message_bytes : Int32
    getter auth_provider : AuthProvider?
    getter reconnect : ReconnectOptions

    @fetch : Fetch
    @controller = AbortController.new
    @closed_channel = Channel(Nil).new
    @started = false
    @closed = false
    @protocol_version : String? = nil
    @get_stream_started = false
    @last_token : String? = nil

    def initialize(url : String | URI, headers : HTTP::Headers | Hash(String, String) | Nil = nil, fetch : Fetch? = nil,
                   @open_get_stream : Bool = true, @max_message_bytes : Int32 = DEFAULT_MAX_MESSAGE_BYTES,
                   @auth_provider : AuthProvider? = nil, @reconnect : ReconnectOptions = ReconnectOptions.new)
      @url = url.is_a?(URI) ? url.dup : URI.parse(url)
      raise ArgumentError.new("Invalid MCP server URL: #{url}") unless @url.scheme && @url.host
      @headers = HTTP::Headers.new
      headers.try &.each { |name, value| @headers[name] = value }
      @fetch = fetch || DEFAULT_FETCH
    end

    def start : Nil
      raise Error.new("MCP Streamable HTTP transport already started") if @started
      raise ConnectionClosedError.new if @closed
      @started = true
    end

    def protocol_version=(version : String) : Nil
      @protocol_version = version
    end

    def send(message : JsonRpc::Message, signal : AbortSignal? = nil) : Nil
      raise ConnectionClosedError.new if !@started || @closed
      extra = HTTP::Headers{"accept" => "application/json, text/event-stream", "content-type" => "application/json"}
      response = authorized_fetch("POST", extra, message.to_json, signal)
      check_response(response)
      capture_session(response)
      unless message.is_a?(JsonRpc::Request)
        response.close
        start_get_stream if message.is_a?(JsonRpc::Notification) && message.method == "notifications/initialized"
        return
      end
      if response.status == 202 || response.status == 204
        response.close
        raise HttpError.new(response.status, "MCP server accepted request #{message.method} without a response")
      end
      case type = response.content_type
      when "application/json"
        body = response.json
        (body.as_a? || [body]).each { |item| emit_message(JsonRpc.parse(item)) }
      when "text/event-stream"
        request_id = message.id
        spawn { consume_response_stream(response, request_id) }
      else
        response.close
        raise HttpError.new(response.status, "Unsupported MCP response content type: #{type || "missing"}")
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      @controller.abort
      @closed_channel.close
      if @started && @session_id
        begin
          request = HttpRequest.new("DELETE", @url, build_headers(HTTP::Headers.new, @last_token), nil,
            AbortSignal.timeout(CLOSE_TIMEOUT))
          @fetch.call(request).close
        rescue
        end
      end
      emit_close
    end

    private def authorized_fetch(method : String, extra : HTTP::Headers, body : String?, signal : AbortSignal? = nil) : HttpResponse
      attempt = 0
      loop do
        token = current_token
        raise AbortError.new if signal.try(&.aborted?)
        response = @fetch.call(HttpRequest.new(method, @url, build_headers(extra, token), body, @controller.signal))
        provider = @auth_provider
        return response if attempt > 0 || provider.nil? || !needs_authorization?(response)
        recovered = begin
          provider.on_unauthorized(UnauthorizedContext.new(response, @url, @fetch, token))
        rescue error
          response.close
          raise error
        end
        return response unless recovered
        response.close
        attempt += 1
      end
    end

    private def current_token : String?
      @last_token = @auth_provider.try(&.token)
    end

    private def build_headers(extra : HTTP::Headers, token : String?) : HTTP::Headers
      headers = @headers.dup
      extra.each { |name, values| headers[name] = values }
      @session_id.try { |session| headers["Mcp-Session-Id"] = session }
      @protocol_version.try { |version| headers["MCP-Protocol-Version"] = version }
      headers["Authorization"] = "Bearer #{token}" if token && !token.empty?
      headers
    end

    private def needs_authorization?(response : HttpResponse) : Bool
      return true if response.status == 401
      return false unless response.status == 403
      INSUFFICIENT_SCOPE.matches?(response.headers["www-authenticate"]? || "")
    end

    private def capture_session(response : HttpResponse) : Nil
      response.headers["mcp-session-id"]?.presence.try { |session| @session_id = session }
    end

    private def check_response(response : HttpResponse) : Nil
      return if response.ok?
      body = begin
        response.text(MAX_ERROR_BODY_BYTES)
      rescue
        ""
      end
      raise AuthRequiredError.new(response.headers["www-authenticate"]?, body) if response.status == 401
      raise SessionExpiredError.new(body) if response.status == 404 && @session_id
      raise HttpError.new(response.status, describe_failure(response.status, body), body)
    end

    private def describe_failure(status : Int32, body : String) : String
      text = body.strip
      snippet = text.size > ERROR_MESSAGE_BODY_CHARS ? "#{text[0, ERROR_MESSAGE_BODY_CHARS - 3]}..." : text
      "MCP HTTP request failed with status #{status}#{snippet.empty? ? "" : ": #{snippet}"}"
    end

    private def consume_sse(response : HttpResponse, cursor : StreamCursor, on_message : Proc(JsonRpc::Message, Nil)?) : Nil
      on_id = ->(id : String) { cursor.last_event_id = id; nil }
      on_retry = ->(delay : Time::Span) { cursor.retry = delay; nil }
      Sse.consume(response.body, @max_message_bytes, on_id, on_retry) do |event|
        cursor.received = true
        next if event.data.blank? || (event.event && event.event != "message")
        message = begin
          JsonRpc.parse(JSON.parse(event.data))
        rescue error
          emit_error(error)
          next
        end
        on_message.try &.call(message)
        emit_message(message)
      end
    end

    private def consume_response_stream(first : HttpResponse, request_id : JsonRpc::Id) : Nil
      cursor = StreamCursor.new
      answered = false
      on_message = ->(message : JsonRpc::Message) do
        answered = true if message.is_a?(JsonRpc::Response) && message.id == request_id
        nil
      end
      stream : HttpResponse? = first
      failure : Exception? = nil
      attempt = 0
      loop do
        if current = stream
          begin
            consume_sse(current, cursor, on_message)
            failure = nil
          rescue error
            failure = error
          ensure
            current.close
          end
        end
        return if answered || @closed
        if (error = failure) && !retryable?(error)
          break
        end
        break if cursor.last_event_id.nil? || attempt >= @reconnect.max_retries
        attempt = 0 if cursor.received?
        cursor.received = false
        return unless sleep_unless_closed(reconnect_delay(attempt, cursor.retry))
        attempt += 1
        begin
          stream = open_sse_stream(cursor.last_event_id)
        rescue error
          failure = error
          break unless retryable?(error)
          stream = nil
        end
      end
      return if @closed
      reason = failure.try(&.message) || "stream ended without a response"
      error = JsonRpc::ErrorObject.new(JsonRpc::INTERNAL_ERROR, "MCP response stream failed: #{reason}")
      emit_message(JsonRpc::Failure.new(request_id, error))
    end

    private def start_get_stream : Nil
      return if !@open_get_stream || @get_stream_started || @closed
      @get_stream_started = true
      spawn run_get_stream
    end

    private def run_get_stream : Nil
      cursor = StreamCursor.new
      attempt = 0
      until @closed
        begin
          stream = open_sse_stream(cursor.last_event_id)
          return unless stream
          opened_at = Time.instant
          begin
            consume_sse(stream, cursor, nil)
          ensure
            stream.close
          end
          attempt = 0 if cursor.received? || Time.instant - opened_at > @reconnect.max_delay
        rescue error
          return if @closed
          unless retryable?(error)
            emit_error(error)
            return
          end
        end
        cursor.received = false
        if attempt >= @reconnect.max_retries
          emit_error(Error.new("MCP server-to-client stream dropped and could not be reopened"))
          return
        end
        return unless sleep_unless_closed(reconnect_delay(attempt, cursor.retry))
        attempt += 1
      end
    end

    private def open_sse_stream(last_event_id : String?) : HttpResponse?
      extra = HTTP::Headers{"accept" => "text/event-stream"}
      last_event_id.try { |id| extra["last-event-id"] = id }
      response = authorized_fetch("GET", extra, nil)
      if response.status == 405
        response.close
        return
      end
      check_response(response)
      capture_session(response)
      type = response.content_type
      unless type == "text/event-stream"
        response.close
        raise HttpError.new(response.status, "Unsupported MCP GET response content type: #{type || "missing"}")
      end
      response
    end

    private def retryable?(error : Exception) : Bool
      case error
      when HttpError
        error.status == 408 || error.status == 429 || error.status >= 500
      when IO::Error, OpenSSL::SSL::Error
        true
      else
        false
      end
    end

    private def reconnect_delay(attempt : Int32, server_delay : Time::Span?) : Time::Span
      return server_delay if server_delay
      initial = @reconnect.initial_delay.total_milliseconds * (2.0 ** attempt)
      {initial, @reconnect.max_delay.total_milliseconds}.min.milliseconds
    end

    private def sleep_unless_closed(span : Time::Span) : Bool
      return false if @closed
      select
      when @closed_channel.receive?
        false
      when timeout(span)
        !@closed
      end
    end
  end
end
