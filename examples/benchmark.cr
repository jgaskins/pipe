require "benchmark"
require "../src/pipe"

BUFFERS = [] of IO::Memory

Benchmark.bm do |x|
  bytes = Random::Secure.random_bytes

  x.report "IO.pipe" do
    run_benchmark *IO.pipe, bytes
  end

  x.report "Pipe.create" do
    run_benchmark *Pipe.create, bytes
  end
end

# Show that the buffers are the same size
pp BUFFERS.map(&.to_slice.bytesize.humanize_bytes)
# Ensure they also have the exact same contents
if BUFFERS[0].to_slice != BUFFERS[1].to_slice
  raise "Buffers are not equal!"
end

def run_benchmark(reader : IO, writer : IO, bytes)
  spawn do
    # Write 1GB of data to the pipe, regardless of how many bytes we received
    ((1<<30) // bytes.bytesize).times do
      writer.write bytes
    end
  ensure
    writer.close
  end

  buffer = IO::Memory.new
  BUFFERS << buffer
  IO.copy reader, buffer
end
