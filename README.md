# Haiya - Extendable HTTP Server

Haiya is a extendable HTTP server inspired by Web frameworks - with full-speed running and development.

- Improve you application as you needed. No need to be "correct" at the first try.
- Simple execution model and guided APIs. Use the default as you pleased, and drive at you own when you needed.
- Designed as a library.

## What we have done?

- A usable HTTP/1.x server.
- Router with comptime-resolved dependency injection.

## Usage

See [this "Hello World" example](./src/examples/hello.zig) and [the build script](./build.zig).

You can build the API reference with `zig build`. Note that the reference must be served
at a HTTP server. You could do that with tools like `python -mhttp.server -d zig-out/docs`.

## License

The Apache License, version 2.
