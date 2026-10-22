# spec/support/http_server.cr
module TestHttp
  alias Handler = Proc(HTTP::Server::Context, String, Nil)

  class Server
    getter origin : String

    def initialize(@server : HTTP::Server, @origin : String)
    end

    def close : Nil
      @server.close
    end
  end

  @@servers = [] of Server
  @@release = Channel(Nil).new

  def self.listen(&handler : HTTP::Server::Context, String -> Nil) : String
    origin = ""
    server = HTTP::Server.new do |context|
      handler.call(context, origin)
    rescue error
      context.response.status_code = 500
      context.response.print(error.message)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    origin = "http://127.0.0.1:#{address.port}"
    @@servers << Server.new(server, origin)
    spawn { server.listen }
    origin
  end

  def self.read_body(context : HTTP::Server::Context) : String
    context.request.body.try(&.gets_to_end) || ""
  end

  def self.park : Nil
    @@release.receive?
  end

  def self.close_all : Nil
    servers = @@servers
    @@servers = [] of Server
    servers.each(&.close)
    @@release.close
    @@release = Channel(Nil).new
  end
end
