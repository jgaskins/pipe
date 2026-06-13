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
    @size : Int32 = 0 # Bytes currently in the buffer
    # A reader parks when the buffer is empty; a writer parks when it is full.
    # Those conditions are mutually exclusive (the buffer can't be both at
    # once), so at most one side is ever waiting and they can share a single
    # rendezvous channel rather than allocating a fresh one on every park.
    @wakeup : Channel(Nil) = Channel(Nil).new
    @waiting_reader : Channel(Nil)? = nil
    @waiting_writer : Channel(Nil)? = nil
    @mutex : Mutex = Mutex.new(:unchecked)
    getter? closed : Bool = false

    def initialize(@capacity : Int32)
      @data = Pointer(UInt8).malloc(@capacity)
    end

    def write(slice : Bytes) : Nil
      remaining = slice

      while remaining.size > 0
        channel = nil
        wake = nil

        @mutex.synchronize do
          raise IO::Error.new("Closed stream") if @closed

          space = @capacity &- @size
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

            # Advance the write position, wrapping around the end of the ring
            # buffer. `head` stays in `0...@capacity` and we advance by at most
            # `capacity`, so a single conditional subtraction is equivalent to
            # (and cheaper than) a modulo by `capacity`.
            @head &+= to_write
            @head &-= @capacity if @head >= @capacity
            @size &+= to_write
            remaining = remaining[to_write..]

            if reader = @waiting_reader
              @waiting_reader = nil
              wake = reader
            end
          else
            # The buffer is full, so we wait for the reader
            channel = @wakeup
            @waiting_writer = channel
          end
        end

        # Wake the parked reader only after releasing the mutex so it doesn't
        # resume just to contend for a lock we still hold.
        wake.try &.send(nil)
        channel.try &.receive?
      end
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?

      loop do
        channel = nil
        wake = nil
        read_count = 0

        @mutex.synchronize do
          if @size > 0
            to_read = Math.min(@size, slice.size)

            # Just like in writing, the amount we're trying to read may be more
            # than is available at the end of the buffer, which requires
            # wrapping around to the beginning. This means we need to read in 2
            # separate chunks.
            first_chunk = Math.min(to_read, @capacity &- @tail)
            slice.to_unsafe.copy_from(@data + @tail, first_chunk)

            if to_read > first_chunk
              second_chunk = to_read &- first_chunk
              (slice.to_unsafe + first_chunk).copy_from(@data, second_chunk)
            end

            # See the matching note in #write: a conditional subtraction wraps
            # @tail around the ring buffer more cheaply than a modulo.
            @tail &+= to_read
            @tail &-= @capacity if @tail >= @capacity
            @size &-= to_read
            read_count = to_read

            if writer = @waiting_writer
              @waiting_writer = nil
              wake = writer
            end
          elsif @closed
            return 0
          else
            # The buffer is empty, so wait for the writer
            channel = @wakeup
            @waiting_reader = channel
          end
        end

        # See the matching note in #write: wake the parked writer only after
        # releasing the mutex.
        wake.try &.send(nil)
        return read_count if read_count > 0
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
  end

  class Reader < IO
    include IO::Buffered

    @buffer : Buffer
    getter? closed : Bool = false

    protected def initialize(@buffer)
      # Reading from the ring buffer is just a memcpy, so copying through the
      # read buffer first costs more than it saves. `#gets` and `#peek` still
      # use the buffer — `#peek` fills it regardless of this setting.
      @read_buffering = false
    end

    def unbuffered_read(slice : Bytes) : Int32
      @buffer.read(slice)
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("Cannot write to a Pipe::Reader")
    end

    def unbuffered_write(slice : Bytes) : NoReturn
      raise IO::Error.new("Cannot write to a Pipe::Reader")
    end

    def unbuffered_flush : Nil
    end

    def unbuffered_rewind : NoReturn
      raise IO::Error.new("Cannot rewind a pipe")
    end

    def unbuffered_close : Nil
      @closed = true
    end
  end

  class Writer < IO
    include IO::Buffered

    @buffer : Buffer
    getter? closed : Bool = false

    protected def initialize(@buffer)
      # Match `IO.pipe`: every write is immediately visible to the reader
      # unless the caller opts into write buffering with `sync = false`.
      self.sync = true
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("Cannot read from a Pipe::Writer")
    end

    def unbuffered_read(slice : Bytes) : NoReturn
      raise IO::Error.new("Cannot read from a Pipe::Writer")
    end

    def unbuffered_write(slice : Bytes) : Nil
      @buffer.write(slice)
    end

    def unbuffered_flush : Nil
    end

    def unbuffered_rewind : NoReturn
      raise IO::Error.new("Cannot rewind a pipe")
    end

    def unbuffered_close : Nil
      return if @closed
      @closed = true
      @buffer.close
    end
  end
end
