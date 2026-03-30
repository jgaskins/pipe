require "http"
require "json"

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
