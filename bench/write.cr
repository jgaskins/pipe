require "../src/pipe"

reader, writer = Pipe.create

spawn do
  1_000_000.times do |i|
    writer.puts i
  end
ensure
  writer.close
end

count = 0
while line = reader.gets
  if (count += 1) % 100_000 == 0
    sleep 1.second
  end
  puts line
end

puts "Done reading. Press Enter to exit."
gets
