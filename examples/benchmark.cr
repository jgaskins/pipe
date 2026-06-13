require "benchmark"
require "../src/pipe"

Benchmark.bm do |x|
  bytes = Random::Secure.random_bytes

  x.report "IO.pipe" do
    reader, writer = IO.pipe
    writer.sync = false
    run_benchmark reader, writer, bytes
  end

  x.report "Pipe.create" do
    reader, writer = Pipe.create
    writer.sync = false
    run_benchmark reader, writer, bytes
  end
end

def run_benchmark(reader : IO, writer : IO, bytes)
  spawn do
    # Write 1GB of data to the pipe, regardless of how many bytes we received
    ((1i64 << 30) // bytes.bytesize).times do
      writer.write bytes
    end
  ensure
    writer.close
  end

  reader.skip_to_end
end
