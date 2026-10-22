# src/llm-mcp/stdio.cr
lib LibMcpSpawn
  POSIX_SPAWN_SETPGROUP  = 0x02
  POSIX_SPAWN_SETSIGDEF  = 0x04
  POSIX_SPAWN_SETSIGMASK = 0x08
  F_DUPFD_CLOEXEC        = {% if flag?(:darwin) %} 67 {% else %} 1030 {% end %}

  fun posix_spawn_file_actions_init(actions : Void*) : LibC::Int
  fun posix_spawn_file_actions_destroy(actions : Void*) : LibC::Int
  fun posix_spawn_file_actions_adddup2(actions : Void*, fd : LibC::Int, newfd : LibC::Int) : LibC::Int
  fun posix_spawn_file_actions_addchdir_np(actions : Void*, path : LibC::Char*) : LibC::Int
  fun posix_spawnattr_init(attr : Void*) : LibC::Int
  fun posix_spawnattr_destroy(attr : Void*) : LibC::Int
  fun posix_spawnattr_setflags(attr : Void*, flags : LibC::Short) : LibC::Int
  fun posix_spawnattr_setpgroup(attr : Void*, pgroup : LibC::PidT) : LibC::Int
  fun posix_spawnattr_setsigmask(attr : Void*, mask : LibC::SigsetT*) : LibC::Int
  fun posix_spawnattr_setsigdefault(attr : Void*, mask : LibC::SigsetT*) : LibC::Int
  fun posix_spawnp(pid : LibC::PidT*, file : LibC::Char*, actions : Void*, attr : Void*, argv : LibC::Char**, envp : LibC::Char**) : LibC::Int
end

module LLM::MCP
  class StdioTransport < Transport
    enum Stderr
      Pipe
      Inherit
    end

    DEFAULT_MAX_STDERR_BYTES = 64 * 1024
    DEFAULT_CLOSE_TIMEOUT    = 2.seconds
    STDIN_CLOSE_GRACE        = 500.milliseconds
    READ_CHUNK               = 64 * 1024
    NEWLINE                  = 0x0a_u8

    @@live_groups = Set(Int64).new
    @@exit_hook = false

    getter command : String
    getter args : Array(String)
    getter cwd : String?
    getter env : Hash(String, String)?
    getter? inherit_env : Bool
    getter stderr_mode : Stderr
    getter max_message_bytes : Int32
    getter max_stderr_bytes : Int32
    getter close_timeout : Time::Span

    @on_stderr : Proc(String, Nil)?
    @started = false
    @closed = false
    @exited = false
    @finalized = false
    @child_pid : Int64? = nil
    @stdin : IO::FileDescriptor? = nil
    @stdout_pending = IO::Memory.new
    @stderr_buffer = IO::Memory.new
    @write_lock = Mutex.new
    @finished = Channel(Nil).new
    @open_parts = 0

    def initialize(@command : String, args : Enumerable(String) = [] of String, @cwd : String? = nil,
                   @env : Hash(String, String)? = nil, @inherit_env : Bool = true, stderr : Stderr = Stderr::Pipe,
                   @on_stderr : Proc(String, Nil)? = nil, @max_message_bytes : Int32 = DEFAULT_MAX_MESSAGE_BYTES,
                   @max_stderr_bytes : Int32 = DEFAULT_MAX_STDERR_BYTES, @close_timeout : Time::Span = DEFAULT_CLOSE_TIMEOUT)
      @args = args.to_a
      @stderr_mode = stderr
    end

    def pid : Int64?
      @finalized ? nil : @child_pid
    end

    def stderr : String
      String.new(@stderr_buffer.to_slice).scrub
    end

    def start : Nil
      raise Error.new("MCP stdio transport already started") if @started
      raise ConnectionClosedError.new if @closed
      @started = true
      stdin_reader, stdin_writer = IO.pipe
      stdout_reader, stdout_writer = IO.pipe
      stderr_pipe = @stderr_mode.pipe? ? IO.pipe : nil
      pid = begin
        StdioTransport.posix_spawn(@command, @args, environment, @cwd, stdin_reader, stdout_writer, stderr_pipe.try(&.[1]))
      rescue error
        stdin_writer.close
        stdout_reader.close
        stderr_pipe.try &.[0].close
        raise error
      ensure
        stdin_reader.close
        stdout_writer.close
        stderr_pipe.try &.[1].close
      end
      stdin_writer.sync = true
      @child_pid = pid
      @stdin = stdin_writer
      StdioTransport.track(pid)
      @open_parts = stderr_pipe ? 3 : 2
      spawn read_stdout(stdout_reader)
      stderr_pipe.try { |pipe| spawn read_stderr(pipe[0]) }
      spawn watch(pid)
    end

    def send(message : JsonRpc::Message, signal : AbortSignal? = nil) : Nil
      stdin = @stdin
      raise ConnectionClosedError.new if !@started || @closed || stdin.nil? || stdin.closed?
      payload = String.build do |io|
        message.to_json(io)
        io << '\n'
      end
      @write_lock.synchronize { stdin.write(payload.to_slice) }
    end

    def close : Nil
      return if @closed
      @closed = true
      if @child_pid.nil? || @finalized
        emit_close
        return
      end
      if @exited
        close_stdin
        return
      end
      grace = {STDIN_CLOSE_GRACE, @close_timeout}.min
      close_stdin
      unless wait_finished(grace)
        kill_group(Signal::TERM)
        unless wait_finished(@close_timeout)
          kill_group(Signal::KILL)
          wait_finished(nil)
        end
      end
      kill_group(Signal::TERM)
    end

    protected def self.track(pid : Int64) : Nil
      unless @@exit_hook
        @@exit_hook = true
        at_exit { @@live_groups.each { |group| LibC.kill(-group.to_i32, Signal::TERM.value) } }
      end
      @@live_groups << pid
    end

    protected def self.untrack(pid : Int64) : Nil
      @@live_groups.delete(pid)
    end

    private def environment : Hash(String, String)
      extra = @env || {} of String => String
      @inherit_env ? ENV.to_h.merge(extra) : extra.dup
    end

    private def close_stdin : Nil
      @stdin.try &.close
    rescue IO::Error
    end

    private def wait_finished(span : Time::Span?) : Bool
      return true if @finalized
      if span
        select
        when @finished.receive?
          true
        when timeout(span)
          @finalized
        end
      else
        @finished.receive?
        true
      end
    end

    private def kill_group(signal : Signal) : Nil
      pid = @child_pid
      return unless pid
      LibC.kill(pid.to_i32, signal.value) unless LibC.kill(-pid.to_i32, signal.value) == 0
    end

    private def read_stdout(io : IO::FileDescriptor) : Nil
      buffer = Bytes.new(READ_CHUNK)
      while (count = io.read(buffer)) > 0
        feed_stdout(buffer[0, count])
      end
    rescue IO::Error
    ensure
      io.close
      settle_part
    end

    private def read_stderr(io : IO::FileDescriptor) : Nil
      buffer = Bytes.new(READ_CHUNK)
      while (count = io.read(buffer)) > 0
        chunk = buffer[0, count]
        keep_stderr(chunk)
        @on_stderr.try &.call(String.new(chunk).scrub)
      end
    rescue IO::Error
    ensure
      io.close
      settle_part
    end

    private def watch(pid : Int64) : Nil
      Process.new(Crystal::System::Process.new(pid.to_i32)).wait
    rescue
    ensure
      StdioTransport.untrack(pid)
      @exited = true
      settle_part
    end

    private def settle_part : Nil
      @open_parts -= 1
      finalize_child if @open_parts == 0
    end

    private def finalize_child : Nil
      @finalized = true
      unless String.new(@stdout_pending.to_slice).blank?
        emit_error(Error.new("MCP stdio server closed with an incomplete JSON-RPC message"))
      end
      @stdout_pending.clear
      @finished.close
      emit_close
    end

    private def keep_stderr(chunk : Bytes) : Nil
      @stderr_buffer.write(chunk)
      excess = @stderr_buffer.bytesize - @max_stderr_bytes
      return unless excess > 0
      kept = @stderr_buffer.to_slice[excess, @max_stderr_bytes].dup
      @stderr_buffer.clear
      @stderr_buffer.write(kept)
    end

    private def feed_stdout(chunk : Bytes) : Nil
      start = 0
      while newline = chunk.index(NEWLINE, start)
        piece = chunk[start, newline - start]
        if @stdout_pending.bytesize == 0
          handle_line(piece)
        else
          @stdout_pending.write(piece)
          handle_line(@stdout_pending.to_slice)
          @stdout_pending.clear
        end
        start = newline + 1
      end
      return if start >= chunk.size
      @stdout_pending.write(chunk[start, chunk.size - start])
      return unless @stdout_pending.bytesize > @max_message_bytes
      @stdout_pending.clear
      emit_error(Error.new("MCP stdio message exceeds #{@max_message_bytes} bytes"))
    end

    private def handle_line(line : Bytes) : Nil
      if line.size > @max_message_bytes
        emit_error(Error.new("MCP stdio message exceeds #{@max_message_bytes} bytes"))
        return
      end
      text = String.new(line).scrub
      text = text[0, text.size - 1] if text.ends_with?('\r')
      return if text.blank?
      emit_message(JsonRpc.parse(JSON.parse(text)))
    rescue error
      emit_error(error)
    end

    protected def self.posix_spawn(command : String, args : Array(String), env : Hash(String, String), cwd : String?,
                                   stdin : IO::FileDescriptor, stdout : IO::FileDescriptor, stderr : IO::FileDescriptor?) : Int64
      actions = Pointer(UInt64).malloc(64).as(Void*)
      attr = Pointer(UInt64).malloc(64).as(Void*)
      check(LibMcpSpawn.posix_spawn_file_actions_init(actions), "posix_spawn_file_actions_init")
      check(LibMcpSpawn.posix_spawnattr_init(attr), "posix_spawnattr_init")
      sources = [stdin.fd, stdout.fd, stderr.try(&.fd)].map { |fd| fd.try { |value| high_fd(value) } }
      begin
        sources.each_with_index do |source, target|
          next unless source
          check(LibMcpSpawn.posix_spawn_file_actions_adddup2(actions, source, target), "posix_spawn_file_actions_adddup2")
        end
        cwd.try { |dir| check(LibMcpSpawn.posix_spawn_file_actions_addchdir_np(actions, dir), "posix_spawn_file_actions_addchdir_np") }
        mask = uninitialized LibC::SigsetT
        LibC.sigemptyset(pointerof(mask))
        defaults = uninitialized LibC::SigsetT
        LibC.sigfillset(pointerof(defaults))
        LibC.sigdelset(pointerof(defaults), Signal::KILL.value)
        LibC.sigdelset(pointerof(defaults), Signal::STOP.value)
        check(LibMcpSpawn.posix_spawnattr_setsigmask(attr, pointerof(mask)), "posix_spawnattr_setsigmask")
        check(LibMcpSpawn.posix_spawnattr_setsigdefault(attr, pointerof(defaults)), "posix_spawnattr_setsigdefault")
        check(LibMcpSpawn.posix_spawnattr_setpgroup(attr, 0), "posix_spawnattr_setpgroup")
        flags = LibMcpSpawn::POSIX_SPAWN_SETPGROUP | LibMcpSpawn::POSIX_SPAWN_SETSIGDEF | LibMcpSpawn::POSIX_SPAWN_SETSIGMASK
        check(LibMcpSpawn.posix_spawnattr_setflags(attr, flags.to_i16), "posix_spawnattr_setflags")
        argv = ([command] + args).map(&.to_unsafe) + [Pointer(UInt8).null]
        envp = env.map { |key, value| "#{key}=#{value}".to_unsafe } + [Pointer(UInt8).null]
        pid = uninitialized LibC::PidT
        error = LibMcpSpawn.posix_spawnp(pointerof(pid), command, actions, attr, argv.to_unsafe, envp.to_unsafe)
        raise RuntimeError.from_os_error("Error executing process: '#{command}'", Errno.new(error)) unless error == 0
        pid.to_i64
      ensure
        sources.zip([stdin.fd, stdout.fd, stderr.try(&.fd)]) { |source, original| LibC.close(source) if source && source != original }
        LibMcpSpawn.posix_spawn_file_actions_destroy(actions)
        LibMcpSpawn.posix_spawnattr_destroy(attr)
      end
    end

    private def self.high_fd(fd : Int32) : Int32
      fd > 2 ? fd : LibC.fcntl(fd, LibMcpSpawn::F_DUPFD_CLOEXEC, 3)
    end

    private def self.check(result : LibC::Int, what : String) : Nil
      raise RuntimeError.from_os_error(what, Errno.new(result)) unless result == 0
    end
  end
end
