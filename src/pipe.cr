module Pipe
  VERSION = "0.1.0"

  DEFAULT_CAPACITY = 64 * 1024 # 64KB

  def self.create(capacity : Int32 = DEFAULT_CAPACITY) : {Reader, Writer}
    buffer = Buffer.new(capacity)
    {Reader.new(buffer), Writer.new(buffer)}
  end

  private class Buffer
    @data : Pointer(UInt8)
    @capacity : Int32
    @head : Int32 = 0 # Write position
    @tail : Int32 = 0 # Read position
    @full : Bool = false
    @waiting_reader : Channel(Nil)? = nil
    @waiting_writer : Channel(Nil)? = nil
    @mutex : Mutex = Mutex.new
    getter? closed : Bool = false

    def initialize(@capacity : Int32)
      @data = Pointer(UInt8).malloc(@capacity)
    end

    def write(slice : Bytes) : Nil
      remaining = slice

      while remaining.size > 0
        channel = nil
        @mutex.synchronize do
          raise IO::Error.new("Closed stream") if @closed

          space = available_space
          if space > 0
            to_write = Math.min(space, remaining.size)

            # We write in 1-2 chunks. If the first write exceeds the available
            # space at the end of the buffer, we wrap around to the beginning
            # and write the rest there.
            first_chunk = Math.min(to_write, @capacity - @head)
            (@data + @head).copy_from(remaining.to_unsafe, first_chunk)

            if to_write > first_chunk
              second_chunk = to_write - first_chunk
              @data.copy_from(remaining.to_unsafe + first_chunk, second_chunk)
            end

            @head = (@head + to_write) % @capacity
            @full = (@head == @tail) && to_write > 0
            remaining = remaining[to_write..]

            if reader = @waiting_reader
              @waiting_reader = nil
              reader.send(nil)
            end
          else
            # The buffer is full, so we wait for the reader
            channel = Channel(Nil).new
            @waiting_writer = channel
          end
        end

        channel.try &.receive?
      end
    end

    def read(slice : Bytes) : Int32
      loop do
        channel = nil

        @mutex.synchronize do
          available = available_data
          if available > 0
            to_read = Math.min(available, slice.size)

            # Just like in writing, the amount we're trying to read may be more
            # than is available at the end of the buffer, which requires
            # wrapping around to the beginning. This means we need to read in 2
            # separate chunks.
            first_chunk = Math.min(to_read, @capacity - @tail)
            slice.to_unsafe.copy_from(@data + @tail, first_chunk)

            if to_read > first_chunk
              second_chunk = to_read - first_chunk
              (slice.to_unsafe + first_chunk).copy_from(@data, second_chunk)
            end

            @tail = (@tail + to_read) % @capacity
            @full = false

            if writer = @waiting_writer
              @waiting_writer = nil
              writer.send(nil)
            end

            return to_read
          elsif @closed
            return 0
          else
            # The buffer is empty, so wait for the writer
            channel = Channel(Nil).new
            @waiting_reader = channel
          end
        end

        channel.try &.receive?
      end
    end

    def close : Nil
      @mutex.synchronize do
        @closed = true
        if reader = @waiting_reader
          @waiting_reader = nil
          reader.send(nil)
        end
        if writer = @waiting_writer
          @waiting_writer = nil
          writer.send(nil)
        end
      end
    end

    private def available_space : Int32
      @capacity - available_data
    end

    private def available_data : Int32
      if @full
        @capacity
      elsif @head >= @tail
        @head - @tail
      else
        @capacity - @tail + @head
      end
    end
  end

  class Reader < IO
    @buffer : Buffer
    getter? closed : Bool = false

    protected def initialize(@buffer)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("Closed stream") if closed?
      @buffer.read(slice)
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("Cannot write to a Pipe::Reader")
    end

    def close : Nil
      @closed = true
    end
  end

  class Writer < IO
    @buffer : Buffer
    getter? closed : Bool = false

    protected def initialize(@buffer)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("Cannot read from a Pipe::Writer")
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("Closed stream") if @closed
      @buffer.write(slice)
    end

    def close : Nil
      return if @closed
      @closed = true
      @buffer.close
    end
  end
end
