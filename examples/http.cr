require "../src/pipe"
require "http/client"
require "json"
require "log"

# Run with `LOG_LEVEL=debug` to see the values written by the server
Log.setup_from_env

reader, writer = Pipe.create

spawn do
  log = Log.for("json")
  http = HTTP::Server.new do |context|
    if body = context.request.body
      json = JSON::PullParser.new(body)
      json.read_array do
        value = json.read_int
        log.debug { value }
      end
    end
  end
  http.listen 45678
end

spawn do
  # Avoid generating an entire JSON blob in RAM
  JSON.build writer do |json|
    json.array do
      10_000_000.times do |i|
        json.scalar i
      end
    end
  end
ensure
  writer.close
end

HTTP::Client.post "http://localhost:45678/data", body: reader

puts "Done. Check memory usage or press Enter to exit."
gets
