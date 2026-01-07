require "benchmark"
require "../src/pipe"

Benchmark.ips do |x|
  io_reader, io_writer = IO.pipe
  pipe_reader, pipe_writer = Pipe.create
  bytes = Bytes.new(1024)

  x.report "IO.pipe" do
    io_writer.write bytes
    io_reader.read bytes
  end

  x.report "Pipe.create" do
    pipe_writer.write bytes
    pipe_reader.read bytes
  end
end
