require "../src/pipe"
require "http/client"
require "json"
require "log"
require "benchmark"

# Run with `LOG_LEVEL=debug` to see the values written by the server
Log.setup_from_env

{
  Pipe.create,
  IO.pipe,
}.each do |reader, writer|
  measurement = Benchmark.measure do
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
  end
  puts "#{reader.class}: #{measurement.total.humanize}s (#{measurement.utime.humanize}s user, #{measurement.stime.humanize}s system)"
end

puts "Done. Check memory usage or press Enter to exit."
gets
