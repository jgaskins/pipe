# pipe

`Pipe` provides reader and writer `IO`s, similar to `IO.pipe`. The main difference is that `IO.pipe` uses kernel-level file descriptors, but `Pipe::Reader` and `Pipe::Writer` live entirely in user-space. This avoids consuming file descriptors on systems where they are limited and ends up being much lighter weight.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     pipe:
       github: jgaskins/pipe
   ```

2. Run `shards install`

## Usage

```crystal
require "pipe"

reader, writer = Pipe.create

spawn do
  # Avoid generating an entire JSON blob in RAM
  (1..1_000_000).to_json writer
ensure
  writer.close
end

HTTP::Client.post "http://localhost:3000/data", body: reader
```

## Contributing

1. Fork it (<https://github.com/jgaskins/pipe/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
