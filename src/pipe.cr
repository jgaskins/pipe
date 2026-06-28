module Pipe
  VERSION = "0.1.0"

  DEFAULT_CAPACITY = 64 * 1024 # 64KB

  def self.create(capacity : Int32 = DEFAULT_CAPACITY) : {Reader, Writer}
    buffer = Buffer.new(capacity)
    {Reader.new(buffer), Writer.new(buffer)}
  end

  # A single-producer/single-consumer ring buffer. Exactly one fiber writes and
  # one reads (matching `IO.pipe` semantics), which lets us move data without a
  # lock: the writer owns the head, the reader owns the tail, and each side only
  # *publishes* its own position and *reads* the other's.
  private class Buffer
    @data : Pointer(UInt8)
    @capacity : Int32

    # Free-running byte counters (total bytes ever written / read). The producer
    # owns @head_count and the consumer owns @tail_count; each is published with
    # a release-store and read by the other side with an acquire-load. That
    # acquire/release pairing is what guarantees the data copy is visible before
    # the position update — the job the mutex used to do. The number of bytes in
    # the buffer is just `head - tail` (unsigned subtraction, so the wrap at 2^32
    # cancels out), so there is no shared `size` field to contend on.
    @head_count = Atomic(UInt32).new(0)
    @tail_count = Atomic(UInt32).new(0)

    # The actual ring indices, wrapped into `0...@capacity`. Each is touched by a
    # single fiber only (@head_index by the writer, @tail_index by the reader),
    # so they need no synchronization. Keeping them separate from the counters
    # lets the capacity be any size — we wrap with a conditional subtraction
    # rather than masking, which would require a power-of-two capacity.
    @head_index = 0
    @tail_index = 0

    # A reader parks when the buffer is empty; a writer parks when it is full.
    # Those conditions are mutually exclusive, so at most one side is ever
    # waiting and they can share a single rendezvous channel rather than
    # allocating a fresh one on every park. The waiter slots are atomic so the
    # park/wake handshake needs no lock either.
    @wakeup : Channel(Nil) = Channel(Nil).new
    @waiting_reader = Atomic(Channel(Nil)?).new(nil)
    @waiting_writer = Atomic(Channel(Nil)?).new(nil)
    @closed = Atomic(UInt8).new(0)

    def initialize(@capacity : Int32)
      @data = Pointer(UInt8).malloc(@capacity)
    end

    def closed? : Bool
      @closed.get(:acquire) != 0
    end

    def write(slice : Bytes) : Nil
      remaining = slice

      while remaining.size > 0
        raise IO::Error.new("Closed stream") if @closed.get(:acquire) != 0

        head = @head_count.get(:relaxed) # the writer owns the head
        tail = @tail_count.get(:acquire)
        space = @capacity &- (head &- tail).to_i32

        if space > 0
          to_write = Math.min(space, remaining.size)

          # We write in 1-2 chunks. If the first write exceeds the available
          # space at the end of the buffer, we wrap around to the beginning
          # and write the rest there.
          index = @head_index
          first_chunk = Math.min(to_write, @capacity &- index)
          (@data + index).copy_from(remaining.to_unsafe, first_chunk)

          if to_write > first_chunk
            second_chunk = to_write &- first_chunk
            @data.copy_from(remaining.to_unsafe + first_chunk, second_chunk)
          end

          # Advance the write position, wrapping around the end of the ring
          # buffer. `index` stays in `0...@capacity` and we advance by at most
          # `capacity`, so a single conditional subtraction is equivalent to
          # (and cheaper than) a modulo by `capacity`.
          index &+= to_write
          index &-= @capacity if index >= @capacity
          @head_index = index

          # Publish the new head. Must come after the copy and before the wake
          # check below — see #wake_reader.
          @head_count.set(head &+ to_write, :release)
          remaining = remaining[to_write..]

          wake_reader
        else
          # The buffer is full, so we wait for the reader. Register first, then
          # re-check that the buffer is still full before parking, so we can't
          # miss a reader that frees space in between (a lost wakeup).
          @waiting_writer.set(@wakeup, :sequentially_consistent)
          tail = @tail_count.get(:sequentially_consistent)
          if @capacity &- (head &- tail).to_i32 > 0
            @waiting_writer.set(nil, :relaxed)
          else
            @wakeup.receive?
          end
        end
      end
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?

      loop do
        tail = @tail_count.get(:relaxed) # the reader owns the tail
        head = @head_count.get(:acquire)
        size = (head &- tail).to_i32

        if size > 0
          to_read = Math.min(size, slice.size)

          # Just like in writing, the amount we're trying to read may be more
          # than is available at the end of the buffer, which requires
          # wrapping around to the beginning. This means we need to read in 2
          # separate chunks.
          index = @tail_index
          first_chunk = Math.min(to_read, @capacity &- index)
          slice.to_unsafe.copy_from(@data + index, first_chunk)

          if to_read > first_chunk
            second_chunk = to_read &- first_chunk
            (slice.to_unsafe + first_chunk).copy_from(@data, second_chunk)
          end

          # See the matching note in #write: a conditional subtraction wraps
          # the read position around the ring buffer more cheaply than a modulo.
          index &+= to_read
          index &-= @capacity if index >= @capacity
          @tail_index = index

          @tail_count.set(tail &+ to_read, :release)

          wake_writer
          return to_read
        elsif @closed.get(:acquire) != 0
          return 0
        else
          # The buffer is empty, so wait for the writer. Register first, then
          # re-check for data (or close) before parking — see the matching note
          # in #write about lost wakeups.
          @waiting_reader.set(@wakeup, :sequentially_consistent)
          head = @head_count.get(:sequentially_consistent)
          if (head &- tail).to_i32 > 0 || @closed.get(:acquire) != 0
            @waiting_reader.set(nil, :relaxed)
          else
            @wakeup.receive?
          end
        end
      end
    end

    def close : Nil
      @closed.set(1, :sequentially_consistent)
      if reader = @waiting_reader.swap(nil, :acquire_release)
        reader.send(nil)
      end
      if writer = @waiting_writer.swap(nil, :acquire_release)
        writer.send(nil)
      end
    end

    # Wake a parked reader after publishing data. The fence orders the head
    # publish (above) before we observe the waiter slot, mirroring the parking
    # side which registers the slot and *then* re-reads the head. Without that
    # ordering both could miss each other and the reader would park forever.
    # The fence pairs with a relaxed load so the common case — nobody parked —
    # avoids writing the (reader-owned) waiter cache line on every call.
    private def wake_reader : Nil
      Atomic.fence(:sequentially_consistent)
      return if @waiting_reader.get(:relaxed).nil?
      if reader = @waiting_reader.swap(nil, :acquire_release)
        reader.send(nil)
      end
    end

    # The mirror image of #wake_reader, run by the reader after freeing space.
    private def wake_writer : Nil
      Atomic.fence(:sequentially_consistent)
      return if @waiting_writer.get(:relaxed).nil?
      if writer = @waiting_writer.swap(nil, :acquire_release)
        writer.send(nil)
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
