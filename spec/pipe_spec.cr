require "./spec_helper"

describe Pipe do
  describe ".create" do
    it "returns a Reader and a Writer" do
      reader, writer = Pipe.create
      reader.should be_a Pipe::Reader
      writer.should be_a Pipe::Writer
    end
  end

  describe "basic read/write" do
    it "writes and reads data" do
      reader, writer = Pipe.create

      writer << "hello"
      writer.close

      reader.gets_to_end.should eq "hello"
    end

    it "reads data in chunks" do
      reader, writer = Pipe.create

      writer << "hello world"
      writer.close

      buffer = Bytes.new(5)
      reader.read(buffer).should eq 5
      String.new(buffer).should eq "hello"

      reader.read(buffer).should eq 5
      String.new(buffer).should eq " worl"

      reader.read(buffer).should eq 1
      String.new(buffer[0, 1]).should eq "d"
    end

    it "returns 0 when reading from closed empty pipe" do
      reader, writer = Pipe.create
      writer.close

      buffer = Bytes.new(10)
      reader.read(buffer).should eq 0
    end
  end

  describe "concurrent access" do
    it "blocks reader until data is available" do
      reader, writer = Pipe.create
      result = Channel(String).new

      spawn do
        result.send reader.gets_to_end
      end

      Fiber.yield
      writer << "async data"
      writer.close

      result.receive.should eq "async data"
    end

    it "handles multiple writes before read" do
      reader, writer = Pipe.create

      writer << "one"
      writer << "two"
      writer << "three"
      writer.close

      reader.gets_to_end.should eq "onetwothree"
    end

    it "handles interleaved reads and writes" do
      reader, writer = Pipe.create

      spawn do
        writer.puts "one"
        Fiber.yield
        writer.puts "two"
        Fiber.yield
        writer.puts "three"
        Fiber.yield
      ensure
        writer.close
      end

      reader.gets.should eq "one"
      reader.gets.should eq "two"
      reader.gets.should eq "three"
      reader.gets.should eq nil
    end
  end

  describe Pipe::Reader do
    it "raises on write" do
      reader, _ = Pipe.create
      expect_raises IO::Error, "Cannot write to a Pipe::Reader" do
        reader << "test"
      end
    end

    it "raises when reading after close" do
      reader, writer = Pipe.create
      reader.close

      expect_raises IO::Error, "Closed stream" do
        reader.gets_to_end
      end
    end

    it "reports closed status" do
      reader, _ = Pipe.create
      reader.closed?.should be_false
      reader.close
      reader.closed?.should be_true
    end
  end

  describe Pipe::Writer do
    it "raises on read" do
      _, writer = Pipe.create
      expect_raises IO::Error, "Cannot read from a Pipe::Writer" do
        writer.read Bytes.new(10)
      end
    end

    it "raises when writing after close" do
      _, writer = Pipe.create
      writer.close

      expect_raises IO::Error, "Closed stream" do
        writer << "test"
      end
    end

    it "reports closed status" do
      _, writer = Pipe.create
      writer.closed?.should be_false
      writer.close
      writer.closed?.should be_true
    end
  end

  describe "buffer capacity" do
    it "blocks writer when buffer is full" do
      reader, writer = Pipe.create(capacity: 10)
      write_completed = Channel(Nil).new

      spawn do
        writer << "12345678901234567890" # 20 bytes, but capacity is 10
        write_completed.send nil
      end

      # Give writer time to start and block
      sleep 10.milliseconds

      # Writer should be blocked, so the channel should be empty
      select
      when write_completed.receive
        raise "Writer should have blocked"
      else
        # Expected - writer is blocked
      end

      buffer = Bytes.new(10)
      reader.read(buffer).should eq 10
      buffer.should eq "1234567890".to_slice

      Fiber.yield
      select
      when write_completed.receive
        # Expected - writer is unblocked by the read above
      else
        raise "Writer should be unblocked"
      end

      # Read remaining data
      reader.read(buffer).should eq 10
      buffer.should eq "1234567890".to_slice
    end

    it "uses 64KB default capacity" do
      Pipe::DEFAULT_CAPACITY.should eq 64 * 1024
    end

    it "wraps around correctly in ring buffer" do
      reader, writer = Pipe.create(capacity: 10)

      # Write and read multiple times to force wrap-around
      5.times do |i|
        writer << "abcdefgh" # 8 bytes

        buffer = Bytes.new(8)
        reader.read(buffer).should eq 8
        buffer.should eq "abcdefgh".to_slice
      end

      # One more to ensure wrap-around works
      writer << "12345"
      writer.close

      reader.gets_to_end.should eq "12345"
    end

    it "allows custom capacity" do
      reader, writer = Pipe.create(capacity: 5)
      done = Channel(Nil).new

      spawn do
        writer << "abc"
        writer << "de"
        writer << "f" # This should block until reader consumes
        done.send(nil)
      end

      sleep 10.milliseconds

      # Read to unblock
      buffer = Bytes.new(2)
      reader.read(buffer)

      done.receive
      writer.close
    end
  end

  it "works with IO.copy" do
    reader, writer = Pipe.create

    spawn do
      source = IO::Memory.new("source data")
      IO.copy source, writer
    ensure
      writer.close
    end

    reader.gets_to_end.should eq "source data"
  end
end
