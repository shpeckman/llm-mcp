# src/llm-mcp/client.cr
module LLM::MCP
  enum ConnectionState
    Idle
    Connecting
    Connected
    Closed

    def label : String
      to_s.downcase
    end
  end

  record RequestContext, signal : AbortSignal

  alias RequestHandler = Proc(JSON::Any?, RequestContext, JSON::Any?)
  alias ProgressListener = Proc(ProgressNotification, Nil)
  alias RootsSource = Array(Root) | Proc(Array(Root))

  record RequestOptions, signal : AbortSignal? = nil, timeout : Time::Span? = nil, on_progress : ProgressListener? = nil

  class Client
    DEFAULT_REQUEST_TIMEOUT = 30.seconds
    MAX_LIST_PAGES          = 1_000
    EMPTY_OBJECT            = JSON::Any.new({} of String => JSON::Any)
    PING_HANDLER            = ->(_params : JSON::Any?, _context : RequestContext) : JSON::Any? { EMPTY_OBJECT }

    private record ListSpec, method : String, key : String, valid : Proc(Hash(String, JSON::Any), Bool)
    private record ListPage, items : Array(JSON::Any), next_cursor : String?

    TOOLS = ListSpec.new("tools/list", "tools", ->(item : Hash(String, JSON::Any)) {
      !item["name"]?.try(&.as_s?).nil? && !item["inputSchema"]?.try(&.as_h?).nil?
    })
    RESOURCES = ListSpec.new("resources/list", "resources", ->(item : Hash(String, JSON::Any)) {
      !item["uri"]?.try(&.as_s?).nil? && Client.optional_string?(item["name"]?)
    })
    RESOURCE_TEMPLATES = ListSpec.new("resources/templates/list", "resourceTemplates", ->(item : Hash(String, JSON::Any)) {
      !item["uriTemplate"]?.try(&.as_s?).nil? && Client.optional_string?(item["name"]?)
    })

    private class Pending
      getter id : JsonRpc::Id
      getter channel = Channel(JSON::Any | Exception).new(1)
      getter send_controller = AbortController.new
      getter timeout : Time::Span?
      getter? cancellable : Bool
      getter on_progress : ProgressListener?
      getter progress_token : JsonRpc::Id?
      property deadline : Time::Instant? = nil
      property remove_abort : Proc(Nil)? = nil

      def initialize(@id : JsonRpc::Id, @timeout : Time::Span?, @cancellable : Bool, @on_progress : ProgressListener?,
                     @progress_token : JsonRpc::Id?)
      end
    end

    getter name : String
    getter version : String
    getter title : String?
    getter capabilities : JSON::Any?
    getter requested_protocol_version : String
    getter request_timeout : Time::Span?
    getter connection_state = ConnectionState::Idle
    getter server_info : Implementation? = nil
    getter server_capabilities : ServerCapabilities? = nil
    getter instructions : String? = nil
    getter protocol_version : String? = nil

    @transport : Transport? = nil
    @next_request_id = 1_i64
    @pending = {} of JsonRpc::Id => Pending
    @progress_requests = {} of JsonRpc::Id => JsonRpc::Id
    @incoming = {} of JsonRpc::Id => AbortController
    @request_handlers = {} of String => RequestHandler
    @notification_listeners = {} of String => Listeners(Proc(JSON::Any?, Nil))
    @error_listeners = Listeners(Proc(Exception, Nil)).new
    @close_listeners = Listeners(Proc(Nil)).new
    @disposers = [] of Proc(Nil)
    @roots = false

    def initialize(@name : String, @version : String, @title : String? = nil, capabilities = nil,
                   @requested_protocol_version : String = LATEST_PROTOCOL_VERSION,
                   @request_timeout : Time::Span? = DEFAULT_REQUEST_TIMEOUT, roots : RootsSource? = nil)
      unless SUPPORTED_PROTOCOL_VERSIONS.includes?(@requested_protocol_version)
        raise ArgumentError.new("Unsupported MCP protocol version #{@requested_protocol_version}")
      end
      @capabilities = capabilities.nil? ? nil : LLM::MCP.json_object(capabilities, "MCP client capabilities")
      @request_handlers["ping"] = PING_HANDLER
      if source = roots
        @roots = true
        @request_handlers["roots/list"] = roots_handler(source)
      end
    end

    def self.optional_string?(value : JSON::Any?) : Bool
      value.nil? || !value.as_s?.nil?
    end

    def connect(transport : Transport) : InitializeResult
      raise Error.new("Cannot connect MCP client in #{@connection_state.label} state") unless @connection_state.idle?
      @connection_state = ConnectionState::Connecting
      @transport = transport
      @disposers = [
        transport.on_message { |message| handle_message(message) },
        transport.on_error { |error| emit_error(error) },
        transport.on_close { handle_transport_close },
      ]
      begin
        transport.start
        result = validate_initialize_result(request_internal("initialize", initialize_params, RequestOptions.new, true))
        unless SUPPORTED_PROTOCOL_VERSIONS.includes?(result.protocol_version)
          raise Error.new("MCP server selected unsupported protocol version #{result.protocol_version}")
        end
        @protocol_version = result.protocol_version
        @server_info = result.server_info
        @server_capabilities = result.capabilities
        @instructions = result.instructions
        transport.protocol_version = result.protocol_version
        notify_internal("notifications/initialized", nil, true)
        @connection_state = ConnectionState::Connected
        result
      rescue error
        begin
          close
        rescue
        end
        raise error
      end
    end

    def request(method : String, params = nil, *, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                on_progress : ProgressListener? = nil) : JSON::Any
      request_internal(method, params.nil? ? nil : LLM::MCP.json_object(params, "MCP request params"),
        RequestOptions.new(signal, timeout, on_progress), false)
    end

    def notify(method : String, params = nil) : Nil
      notify_internal(method, params.nil? ? nil : LLM::MCP.json_object(params, "MCP notification params"), false)
    end

    def set_request_handler(method : String, &handler : JSON::Any?, RequestContext -> JSON::Any?) : Proc(Nil)
      @request_handlers[method] = handler
      handler_remover(method, handler)
    end

    def on_notification(method : String, &listener : JSON::Any? -> Nil) : Proc(Nil)
      listeners = @notification_listeners[method] ||= Listeners(Proc(JSON::Any?, Nil)).new
      notification_remover(method, listeners, listeners.add(listener))
    end

    def on_error(&listener : Exception -> Nil) : Proc(Nil)
      @error_listeners.add(listener)
    end

    def on_close(&listener : -> Nil) : Proc(Nil)
      @close_listeners.add(listener)
    end

    def ping(*, signal : AbortSignal? = nil, timeout : Time::Span? = nil) : Nil
      request("ping", signal: signal, timeout: timeout)
      nil
    end

    def list_tools(*, signal : AbortSignal? = nil, timeout : Time::Span? = nil, on_progress : ProgressListener? = nil) : Array(Tool)
      list_all(TOOLS, RequestOptions.new(signal, timeout, on_progress)).map { |item| Tool.new(item) }
    end

    def list_resources(*, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                       on_progress : ProgressListener? = nil) : Array(Resource)
      list_all(RESOURCES, RequestOptions.new(signal, timeout, on_progress)).map { |item| to_resource(item) }
    end

    def list_resources_page(cursor : String? = nil, *, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                            on_progress : ProgressListener? = nil) : ListResourcesResult
      page = list_page(RESOURCES, cursor, RequestOptions.new(signal, timeout, on_progress))
      ListResourcesResult.new(page.items.map { |item| to_resource(item) }, page.next_cursor)
    end

    def list_resource_templates(*, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                                on_progress : ProgressListener? = nil) : Array(ResourceTemplate)
      list_all(RESOURCE_TEMPLATES, RequestOptions.new(signal, timeout, on_progress)).map { |item| to_resource_template(item) }
    end

    def list_resource_templates_page(cursor : String? = nil, *, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                                     on_progress : ProgressListener? = nil) : ListResourceTemplatesResult
      page = list_page(RESOURCE_TEMPLATES, cursor, RequestOptions.new(signal, timeout, on_progress))
      ListResourceTemplatesResult.new(page.items.map { |item| to_resource_template(item) }, page.next_cursor)
    end

    def read_resource(uri : String, *, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                      on_progress : ProgressListener? = nil) : ReadResourceResult
      validate_read_resource_result(request("resources/read", {uri: uri}, signal: signal, timeout: timeout, on_progress: on_progress))
    end

    def call_tool(name : String, arguments = nil, *, signal : AbortSignal? = nil, timeout : Time::Span? = nil,
                  on_progress : ProgressListener? = nil) : CallToolResult
      params = {"name" => JSON::Any.new(name)}
      params["arguments"] = LLM::MCP.json_object(arguments, "MCP tool arguments") unless arguments.nil?
      result = request_internal("tools/call", JSON::Any.new(params), RequestOptions.new(signal, timeout, on_progress), false)
      validate_call_tool_result(result)
    end

    def close : Nil
      transport = @transport
      @transport = nil
      dispose_transport_listeners
      mark_closed(ConnectionClosedError.new)
      transport.try &.close
    end

    private def initialize_params : JSON::Any
      capabilities = @capabilities.try(&.as_h.dup) || {} of String => JSON::Any
      capabilities["roots"] = EMPTY_OBJECT if @roots && !capabilities.has_key?("roots")
      client_info = {"name" => JSON::Any.new(@name), "version" => JSON::Any.new(@version)}
      @title.try { |title| client_info["title"] = JSON::Any.new(title) }
      JSON::Any.new({
        "protocolVersion" => JSON::Any.new(@requested_protocol_version),
        "capabilities"    => JSON::Any.new(capabilities),
        "clientInfo"      => JSON::Any.new(client_info),
      })
    end

    private def roots_handler(source : RootsSource) : RequestHandler
      ->(_params : JSON::Any?, _context : RequestContext) : JSON::Any? {
        roots = source.is_a?(Array) ? source : source.call
        LLM::MCP.json({roots: roots})
      }
    end

    private def handler_remover(method : String, handler : RequestHandler) : Proc(Nil)
      -> do
        @request_handlers.delete(method) if @request_handlers[method]? == handler
        nil
      end
    end

    private def notification_remover(method : String, listeners : Listeners(Proc(JSON::Any?, Nil)), remove : Proc(Nil)) : Proc(Nil)
      -> do
        remove.call
        @notification_listeners.delete(method) if listeners.empty? && @notification_listeners[method]?.same?(listeners)
        nil
      end
    end

    private def list_page(spec : ListSpec, cursor : String?, options : RequestOptions) : ListPage
      params = cursor.nil? ? nil : JSON::Any.new({"cursor" => JSON::Any.new(cursor)})
      validate_list_page(spec, request_internal(spec.method, params, options, false))
    end

    private def list_all(spec : ListSpec, options : RequestOptions) : Array(JSON::Any)
      items = [] of JSON::Any
      cursors = Set(String).new
      cursor = nil
      MAX_LIST_PAGES.times do
        page = list_page(spec, cursor, options)
        items.concat(page.items)
        next_cursor = page.next_cursor
        return items if next_cursor.nil?
        raise Error.new("MCP #{spec.method} returned duplicate cursor: #{next_cursor}") unless cursors.add?(next_cursor)
        cursor = next_cursor
      end
      raise Error.new("MCP #{spec.method} exceeded #{MAX_LIST_PAGES} pages")
    end

    private def invalid(message : String) : RpcError
      RpcError.new(JsonRpc::INVALID_REQUEST, message)
    end

    private def validate_list_page(spec : ListSpec, value : JSON::Any) : ListPage
      object = value.as_h?
      items = object.try(&.[spec.key]?).try(&.as_a?)
      raise invalid("Invalid MCP #{spec.method} result") unless object && items
      items.each do |item|
        entry = item.as_h?
        raise invalid("Invalid entry in MCP #{spec.method} result") unless entry && spec.valid.call(entry)
      end
      raw_cursor = object["nextCursor"]?
      next_cursor = nil
      if raw_cursor && !raw_cursor.raw.nil? && raw_cursor.as_s? != ""
        next_cursor = raw_cursor.as_s? || raise invalid("Invalid MCP #{spec.method} cursor")
      end
      ListPage.new(items, next_cursor)
    end

    private def to_resource(item : JSON::Any) : Resource
      Resource.new(with_name(item, "uri"))
    end

    private def to_resource_template(item : JSON::Any) : ResourceTemplate
      ResourceTemplate.new(with_name(item, "uriTemplate"))
    end

    private def with_name(item : JSON::Any, fallback : String) : JSON::Any
      hash = item.as_h
      return item if hash["name"]?.try(&.as_s?)
      copy = hash.dup
      copy["name"] = hash[fallback]
      JSON::Any.new(copy)
    end

    private def validate_initialize_result(value : JSON::Any) : InitializeResult
      object = value.as_h?
      server_info = object.try(&.["serverInfo"]?).try(&.as_h?)
      valid = object && server_info &&
              object["protocolVersion"]?.try(&.as_s?) &&
              object["capabilities"]?.try(&.as_h?) &&
              server_info["name"]?.try(&.as_s?) &&
              server_info["version"]?.try(&.as_s?) &&
              Client.optional_string?(object["instructions"]?)
      raise invalid("Invalid MCP initialize result") unless valid
      InitializeResult.new(value)
    end

    private def validate_read_resource_result(value : JSON::Any) : ReadResourceResult
      contents = value.as_h?.try(&.["contents"]?).try(&.as_a?)
      raise invalid("Invalid MCP resources/read result") unless contents
      contents.each do |item|
        entry = item.as_h?
        valid = entry && entry["uri"]?.try(&.as_s?) && (entry["text"]?.try(&.as_s?) || entry["blob"]?.try(&.as_s?))
        raise invalid("Invalid contents in MCP resources/read result") unless valid
      end
      ReadResourceResult.new(value)
    end

    private def validate_call_tool_result(value : JSON::Any) : CallToolResult
      object = value.as_h?
      content = object.try(&.["content"]?)
      raise invalid("Invalid MCP tools/call result") unless object && (content.nil? || content.as_a?)
      return CallToolResult.new(value) if content
      copy = object.dup
      copy["content"] = JSON::Any.new([] of JSON::Any)
      CallToolResult.new(JSON::Any.new(copy))
    end

    private def request_internal(method : String, params : JSON::Any?, options : RequestOptions, allow_connecting : Bool) : JSON::Any
      transport = require_transport(allow_connecting)
      raise AbortError.new if options.signal.try(&.aborted?)
      id = @next_request_id
      @next_request_id += 1
      progress_token = options.on_progress ? id : nil
      request_params = progress_token ? with_progress_token(params, progress_token) : params
      cancellable = method != "initialize"
      entry = Pending.new(id, options.timeout || @request_timeout, cancellable, options.on_progress, progress_token)
      @pending[id] = entry
      @progress_requests[progress_token] = id if progress_token
      options.signal.try { |signal| entry.remove_abort = watch_abort(signal, entry) }
      arm_timeout(entry)
      dispatch(transport, JsonRpc::Request.new(id, method, request_params), entry)
      await(entry)
    end

    private def with_progress_token(params : JSON::Any?, token : JsonRpc::Id) : JSON::Any
      object = params.try(&.as_h?.try(&.dup)) || {} of String => JSON::Any
      meta = object["_meta"]?.try(&.as_h?.try(&.dup)) || {} of String => JSON::Any
      meta["progressToken"] = id_json(token)
      object["_meta"] = JSON::Any.new(meta)
      JSON::Any.new(object)
    end

    private def id_json(id : JsonRpc::Id) : JSON::Any
      JSON::Any.new(id)
    end

    private def watch_abort(signal : AbortSignal, entry : Pending) : Proc(Nil)
      signal.on_abort do |reason|
        cancel_pending(entry.id, AbortError.new, entry.cancellable?, reason.message || "Aborted")
      end
    end

    private def dispatch(transport : Transport, message : JsonRpc::Request, entry : Pending) : Nil
      spawn do
        transport.send(message, entry.send_controller.signal)
      rescue error
        cancel_pending(entry.id, error, false)
      end
    end

    private def await(entry : Pending) : JSON::Any
      loop do
        deadline = entry.deadline
        result = if deadline
                   remaining = deadline - Time.instant
                   if remaining <= Time::Span.zero
                     expire(entry)
                     next
                   end
                   select
                   when value = entry.channel.receive
                     value
                   when timeout(remaining)
                     next
                   end
                 else
                   entry.channel.receive
                 end
        raise result if result.is_a?(Exception)
        return result
      end
    end

    private def expire(entry : Pending) : Nil
      timeout = entry.timeout || Time::Span.zero
      cancel_pending(entry.id, TimeoutError.new(timeout), entry.cancellable?, "Request timed out")
    end

    private def notify_internal(method : String, params : JSON::Any?, allow_connecting : Bool) : Nil
      require_transport(allow_connecting).send(JsonRpc::Notification.new(method, params))
    end

    private def require_transport(allow_connecting : Bool) : Transport
      transport = @transport
      if transport && (@connection_state.connected? || (allow_connecting && @connection_state.connecting?))
        return transport
      end
      raise ConnectionClosedError.new("MCP client is #{@connection_state.label}")
    end

    private def handle_message(message : JsonRpc::Message) : Nil
      case message
      when JsonRpc::Response
        handle_response(message)
      when JsonRpc::Request
        request = message
        spawn handle_request(request)
      when JsonRpc::Notification
        handle_notification(message.method, message.params)
      end
    end

    private def handle_response(message : JsonRpc::Response) : Nil
      entry = @pending[message.id]?
      unless entry
        emit_error(Error.new("Received response for unknown MCP request #{message.id}"))
        return
      end
      remove_pending(entry)
      case message
      when JsonRpc::Failure
        entry.channel.send(RpcError.new(message.error.code, message.error.message, message.error.data))
      when JsonRpc::Success
        entry.channel.send(message.result)
      end
    end

    private def handle_request(message : JsonRpc::Request) : Nil
      transport = @transport
      return unless transport
      handler = @request_handlers[message.method]?
      unless handler
        error = JsonRpc::ErrorObject.new(JsonRpc::METHOD_NOT_FOUND, "Method not found: #{message.method}")
        respond(transport, JsonRpc::Failure.new(message.id, error))
        return
      end
      controller = AbortController.new
      @incoming[message.id] = controller
      begin
        result = handler.call(message.params, RequestContext.new(controller.signal))
        result = EMPTY_OBJECT if result.nil? || result.raw.nil?
        transport.send(JsonRpc::Success.new(message.id, result))
      rescue error
        response_error = if error.is_a?(RpcError)
                           JsonRpc::ErrorObject.new(error.code, error.message || "", error.data)
                         else
                           JsonRpc::ErrorObject.new(JsonRpc::INTERNAL_ERROR, error.message || error.class.name)
                         end
        respond(transport, JsonRpc::Failure.new(message.id, response_error))
      ensure
        @incoming.delete(message.id)
      end
    end

    private def respond(transport : Transport, message : JsonRpc::Message) : Nil
      transport.send(message)
    rescue error
      emit_error(error)
    end

    private def handle_notification(method : String, params : JSON::Any?) : Nil
      case method
      when "notifications/progress"
        handle_progress(params)
      when "notifications/cancelled"
        handle_cancelled(params)
      end
      listeners = @notification_listeners[method]?
      return unless listeners
      listeners.snapshot.each do |listener|
        listener.call(params)
      rescue error
        emit_error(error)
      end
    end

    private def handle_progress(params : JSON::Any?) : Nil
      object = params.try(&.as_h?)
      return unless object
      token = JsonRpc.id?(object["progressToken"]?)
      progress = object["progress"]?
      return unless token && progress && (progress.as_f? || progress.as_i64?)
      request_id = @progress_requests[token]?
      entry = request_id.try { |id| @pending[id]? }
      return unless entry
      arm_timeout(entry)
      begin
        entry.on_progress.try &.call(ProgressNotification.new(params.not_nil!))
      rescue error
        emit_error(error)
      end
    end

    private def handle_cancelled(params : JSON::Any?) : Nil
      object = params.try(&.as_h?)
      return unless object
      request_id = JsonRpc.id?(object["requestId"]?)
      controller = request_id.try { |id| @incoming[id]? }
      return unless controller
      reason = object["reason"]?.try(&.as_s?)
      reason ? controller.abort(reason) : controller.abort
    end

    private def arm_timeout(entry : Pending) : Nil
      timeout = entry.timeout
      entry.deadline = timeout && timeout > Time::Span.zero ? Time.instant + timeout : nil
    end

    private def cancel_pending(id : JsonRpc::Id, error : Exception, notify_server : Bool, reason : String? = nil) : Nil
      entry = @pending[id]?
      return unless entry
      remove_pending(entry)
      entry.channel.send(error)
      transport = @transport
      return unless notify_server && transport
      params = {"requestId" => id_json(id)}
      params["reason"] = JSON::Any.new(reason) if reason && !reason.empty?
      cancelled = JsonRpc::Notification.new("notifications/cancelled", JSON::Any.new(params))
      spawn respond(transport, cancelled)
    end

    private def remove_pending(entry : Pending) : Nil
      @pending.delete(entry.id)
      entry.deadline = nil
      entry.progress_token.try { |token| @progress_requests.delete(token) }
      entry.remove_abort.try &.call
      entry.send_controller.abort
    end

    private def reject_pending(error : Exception) : Nil
      @pending.values.each do |entry|
        remove_pending(entry)
        entry.channel.send(error)
      end
    end

    private def handle_transport_close : Nil
      mark_closed(ConnectionClosedError.new)
    end

    private def mark_closed(error : Exception) : Nil
      was_closed = @connection_state.closed?
      @connection_state = ConnectionState::Closed
      reject_pending(error)
      incoming = @incoming.values
      @incoming.clear
      incoming.each(&.abort(error))
      return if was_closed
      @close_listeners.snapshot.each do |listener|
        listener.call
      rescue listener_error
        emit_error(listener_error)
      end
    end

    private def emit_error(error : Exception) : Nil
      @error_listeners.snapshot.each(&.call(error))
    end

    private def dispose_transport_listeners : Nil
      disposers = @disposers
      @disposers = [] of Proc(Nil)
      disposers.each(&.call)
    end
  end
end
