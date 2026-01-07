require "benchmark"
require "../src/pipe"

[
  8,
  100,
  1024,
  8192,
  32768,
  65536,
].each do |byte_size|
  puts
  puts byte_size.humanize_bytes
  Benchmark.ips do |x|
    io_reader, io_writer = IO.pipe
    pipe_reader, pipe_writer = Pipe.create
    bytes = Bytes.new(byte_size)

    x.report "IO.pipe" do
      io_writer.write bytes
      io_reader.read bytes
    end

    x.report "Pipe.create" do
      pipe_writer.write bytes
      pipe_reader.read bytes
    end
  end
end
