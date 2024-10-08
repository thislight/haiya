const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = @import("./Request.zig");
const Response = @import("./Response.zig");
const Stream = @import("../Stream.zig");
const StatusCode = @import("./statuses.zig").Code;
const ArcBuffer = @import("../ArcBuffer.zig");
const Headers = @import("./Headers.zig");
const FileSize = @import("../units.zig").FileSize;

stream: *Stream,
request: Request,
/// The response will be returned.
///
/// By default it's an empty "Internal Server Error" (HTTP 500) response.
/// Use `Transcation.resetResponse` to set status code.
response: Response = .{
    .statusCode = StatusCode.@"Internal Server Error".int(),
    .statusText = StatusCode.@"Internal Server Error".text(),
},
parentAllocator: std.heap.ArenaAllocator,

const Self = @This();

pub fn init(stream: *Stream, request: Request, arnea: std.heap.ArenaAllocator) Self {
    return Self{
        .stream = stream,
        .request = request,
        .parentAllocator = arnea,
    };
}

pub fn arena(self: *Self) Allocator {
    return self.parentAllocator.allocator();
}

/// Return the general purpose allocator.
///
/// Use `arena` if you need the arena allocator.
pub fn allocator(self: *const Self) Allocator {
    return self.parentAllocator.child_allocator;
}

pub fn deinit(self: *const Self) void {
    const stream = self.stream;
    _ = stream.flush() catch {};
    self.parentAllocator.deinit();
    stream.markResponseEnd();
}

/// Copy request content into arena and return a new instance.
/// The old instance should be dropped.
pub fn copyToArena(self: *Self) !Self {
    const request = try self.request.dupe(self.arena());
    errdefer request.deinit(self.arena);
    return Self.init(self.stream, request, self.parentAllocator);
}

fn selectContentEncoding(values: []const Headers.ContentEncoding) ?Headers.ContentEncoding {
    for (values) |item| {
        if (item == .gzip) {
            return item;
        }
    }
    return null;
}

/// Resets the response with the specified status code.
///
/// This is the first function when you want to return a response.
/// It resets the `.response` as the `statusCode`, and set up headers for use.
/// The arena allocator will be used.
///
/// Returns the response.
pub fn resetResponse(self: *Self, statusCode: StatusCode) *Response {
    const resp = &self.response;

    resp.* = Response{
        .statusCode = statusCode.int(),
        .statusText = statusCode.text(),
    };

    return &self.response;
}

fn beforeWriteResponse(self: *Self) !void {
    const defaultKeepAlive = self.request.headers.isConnectionKeepAlive() orelse switch (self.request.version) {
        .http1_0 => false,
        else => true,
    };
    const userKeepAlive = self.request.headers.isConnectionKeepAlive() orelse defaultKeepAlive;
    {
        self.stream.lock.lock();
        defer self.stream.lock.unlock();
        self.stream.cfg.keepAlive = userKeepAlive;
    }
    switch (self.request.version) {
        .http1_0, .http1_1 => {
            try self.response.headers.replaceOrPut(
                self.arena(),
                "Connection",
                if (userKeepAlive) "keep-alive" else "close",
            );
            if (userKeepAlive) {
                try self.response.headers.replaceOrPut(
                    self.arena(),
                    "Keep-Alive",
                    try std.fmt.allocPrint(
                        self.arena(),
                        "{}",
                        .{self.stream.cfg.keepAliveMaxIdle},
                    ),
                );
            }
        },
        else => {},
    }
}

/// Write response into the stream.
///
/// This function will hold the lock of the stream while processing.
pub fn writeResponse(self: *Self) !void {
    try self.beforeWriteResponse();
    return try self.stream.writeResponse(self.arena(), self.response, self.request.version);
}

fn ReturnErrorSetOf(T: type) type {
    return @typeInfo(@typeInfo(T).Fn.return_type.?).ErrorUnion.error_set;
}

pub const BodySize = union(enum) {
    Infinite: void,
    Sized: u64,
};

/// Set up the response for specified body size. You must call this function at least once
/// before writing response, if you have body.
///
/// For `.Sized`, the "Content-Length" is set to the specified number.
///
/// For `.Infinite`, the operation depends on the HTTP version:
/// - HTTP/1.x: the Transfer-Encoding header is set to "chunked". `bodyWriter` recongize this header and will automatically change to output.
/// - The others: do nothing.
///
/// Be advised that this function uses the memory from `arena`.
/// Normally this function should not be called repeatly, or it may use too much memory.
///
/// This function does not hold any lock.
pub fn setBodySize(self: *Self, size: BodySize) !void {
    switch (size) {
        .Infinite => {
            if (self.stream.session.transport == .http1) {
                try self.response.headers.setTransferEncoding(self.arena(), .chunked);
            }
        },
        .Sized => |v| {
            try self.response.headers.setContentLength(self.arena(), v);
        },
    }
}

pub const WRITER_BUFFER_SIZE = FileSize(usize).pack(64, .kibibyte).to(.byte).number();

/// Create a body writer.
///
/// Returns a writer that writes data as body. The response must be written before
/// writing body.
///
/// This function recongize these headers:
///
/// - `Transfer-Encoding: chunked`: chunked transfering will be enabled. This should only be enabled
/// for HTTP/1.
/// - `Transfer-Encoding: gzip`: compression will be initialised.
///
/// Note that this writer is buffered. It automatically submits SEQ(s) and consumes all
/// CQE(s) when the buffer is full. You must call the `close` function in the end of writing.
///
/// This function does not hold any lock.
pub fn bodyWriter(self: *Self) BodyWriterContext(WRITER_BUFFER_SIZE) {
    return self.bodyWriterContext(WRITER_BUFFER_SIZE);
}

/// Get the body writer context.
///
/// This function is almost same to the `bodyWriter` function,
/// the only difference is this function allows you to custom the
/// buffer size. Mostly you don't need it.
///
/// This function does not hold any lock.
pub fn bodyWriterContext(self: *Self, comptime bufferSize: usize) BodyWriterContext(bufferSize) {
    const Context = BodyWriterContext(bufferSize);
    return Context{ .owner = self };
}

pub fn CompressionContext(DirectWriter: type) type {
    return union(enum) {
        Identity: void,
        GZip: std.compress.gzip.Compressor(DirectWriter),
    };
}

/// Compressed body writer context. This only works under `Transfer-Encoding: chunked`.
///
/// There is no need to specify the buffer size,
/// since most of compression algorithms requires a window.
pub const CompressedBodyContext = struct {
    compress: CompressionContext(DirectWriter),
    owner: *Self,

    const CHUNKED_ADD_BYTES = std.fmt.comptimePrint("{x}", .{std.math.maxInt(u64)}).len;

    const Cx = @This();

    const DirectWriter = std.io.GenericWriter(*Stream, WriteError, Cx.directWriteAndFlush);

    pub const WriteError = ReturnErrorSetOf(@TypeOf(Stream.writeSlice)) || ReturnErrorSetOf(@TypeOf(Stream.flush)) ||
        error{
        /// From std.compress.gzip.Compressor(x).{write, flush}.
        /// Rubicon: I'd like to contain it, but I don't know how to handle that
        /// since it is undocumented.
        UnfinishedBits,
    };

    fn directWriteAndFlush(self: *Stream, value: []const u8) WriteError!usize {
        var lengthTextBuf = [_]u8{0} ** CHUNKED_ADD_BYTES;
        const lengthText = std.fmt.bufPrint(
            &lengthTextBuf,
            "{x}",
            .{value.len},
        ) catch unreachable;

        try self.writeSlice(0, lengthText);
        try self.writeSlice(0, "\r\n");
        try self.writeSlice(0, value);
        try self.writeSlice(0, "\r\n");
        try self.flush();
        return value.len;
    }

    pub fn write(self: *Cx, value: []const u8) WriteError!usize {
        return switch (self.compress) {
            .Identity => Cx.directWriteAndFlush(self.owner.stream, value),
            .GZip => |*compress| compress.write(value),
        };
    }

    pub fn close(self: *Cx) WriteError!void {
        switch (self.compress) {
            .Identity => {},
            .GZip => |*compress| try compress.finish(),
        }
        try self.owner.stream.writeSlice(0, "0" ++ "\r\n" ** 2);
        try self.owner.stream.flush();
    }

    pub const Writer = std.io.GenericWriter(
        *Cx,
        WriteError,
        Cx.write,
    );

    /// Get the writer structure which includes more wrappers of write().
    ///
    /// The returned structure does not need to be mutable to function.
    ///
    /// This function does not hold any lock.
    pub fn writer(self: *Cx) Writer {
        return Writer{ .context = self };
    }
};

/// Writer context for body.
///
/// FIXME: we need to give option for compression to the user.
/// The content-length + content-encoding is not what i think originally.
/// Since the content-length looks like that be the compressed size,
/// There is impossible for us to know the size prior the close() call.
///
/// Plan:
/// - Recover the body writer context to the one without compression
/// - Provides compressedWriter() and writeCompressed(),
///     the former one serves the Transfer-Encoding: chunked + Content-Encoding use case,
///     the latter one serves the Content-Length + Content-Encoding one.
pub fn BodyWriterContext(comptime bufferSize: usize) type {
    return struct {
        buffer: std.BoundedArray(u8, bufferSize + BUFFER_ADD_BYTES) = .{},
        owner: *Self,

        const Cx = @This();

        const CHUNKED_ADD_BYTES = std.fmt.comptimePrint("{x}", .{std.math.maxInt(u64)}).len;
        const BUFFER_ADD_BYTES = CHUNKED_ADD_BYTES;

        pub const WriteError = ReturnErrorSetOf(@TypeOf(Stream.writeSlice)) || ReturnErrorSetOf(@TypeOf(Stream.flush));

        /// The unused size depends on the `bufferSize`.
        ///
        /// Be careful! Do not use this function if the additional buffer size is used.
        fn unusedSize(self: Cx) usize {
            return bufferSize - self.buffer.len;
        }

        /// Write data into buffer, flush if the buffer full.
        ///
        /// This function does not hold any lock.
        pub fn write(self: *Cx, src: []const u8) WriteError!usize {
            const unusedCapacitySize = self.unusedSize();
            if (unusedCapacitySize >= src.len) {
                self.buffer.appendSliceAssumeCapacity(src);
                return src.len;
            }

            var rest = src;
            while (rest.len > 0) {
                const sz = @min(self.unusedSize(), rest.len);
                const data = rest[0..sz];
                self.buffer.appendSliceAssumeCapacity(data);
                try self.flush();
                rest = rest[sz..];
            }
            return src.len;
        }

        fn isChunked(self: *Cx) bool {
            const owner = self.owner;
            return if (owner.response.headers.transferEncoding()) |encoding|
                encoding == .chunked
            else
                false;
        }

        /// Flush the buffer.
        ///
        /// This function does not hold any lock. This function uses the additional buffer,
        /// and resets the whole buffer before leaving.
        pub fn flush(self: *Cx) !void {
            const owner = self.owner;
            const stream = owner.stream;
            const value = self.buffer.constSlice();
            // Clean up all the buffer, including the additional space.
            switch (stream.session.transport) {
                .http1 => {
                    if (self.isChunked()) {
                        const lengthText = std.fmt.bufPrint(
                            self.buffer.unusedCapacitySlice(),
                            "{x}",
                            .{value.len},
                        ) catch unreachable;
                        // Use additional buffer size, always have enough space.
                        self.buffer.resize(value.len + lengthText.len) catch unreachable;
                        errdefer self.buffer.resize(value.len) catch unreachable;

                        try stream.writeSlice(0, lengthText);
                        try stream.writeSlice(0, "\r\n");
                        try stream.writeSlice(0, value);
                        try stream.writeSlice(0, "\r\n");
                        try stream.flush();
                    } else {
                        try stream.writeSlice(0, value);
                        try stream.flush();
                    }
                },
                else => unreachable,
            }
            self.buffer.resize(0) catch unreachable;
        }

        /// Write rest data.
        ///
        /// This function calls flush and writing additional data if required by protocol.
        /// It must be call when your writing is finished.
        ///
        /// This function does not hold any lock.
        pub fn close(self: *Cx) !void {
            defer self.* = undefined;
            try self.flush();
            if (self.isChunked()) {
                std.debug.assert(self.owner.stream.session.transport == .http1);
                try self.owner.stream.writeSlice(0, "0" ++ "\r\n" ** 2);
                try self.owner.stream.flush();
            }
        }

        pub const Writer = std.io.GenericWriter(
            *Cx,
            WriteError,
            Cx.write,
        );

        /// Get the writer structure which includes more wrappers of write().
        ///
        /// The returned structure does not need to be immutable to function.
        ///
        /// This function does not hold any lock.
        pub fn writer(self: *Cx) Writer {
            return Writer{ .context = self };
        }
    };
}

/// Set up the response for writing body, and send the headers to the peer.
///
/// This function does not hold any lock.
pub fn writeBodyStart(self: *Self, size: BodySize, contentType: []const u8) !BodyWriterContext(WRITER_BUFFER_SIZE) {
    try self.response.headers.setContentType(self.arena(), contentType);
    try self.setBodySize(size);
    try self.writeResponse();
    return self.bodyWriter();
}

/// Set up the response for without body, and send the headers to the peer.
///
/// This function does not hold any lock.
pub fn writeBodyNoContent(self: *Self) !void {
    try self.setBodySize(.{ .Sized = 0 });
    try self.writeResponse();
}

/// Set up the response for compressing and writing body in chunks, and send the
/// headers to the peer.
///
/// If your content is already compressed and you want to ask the user agent decompress
/// it, just set `Content-Encoding: <compression>` header and write the body normally.
///
/// You use this function only if you are required to compress the data on-the-fly.
///
/// Compressed messages leave you to the compression-related
/// attack, like [the BREACH attack](https://en.wikipedia.org/wiki/BREACH).
///
/// TODO: Can we migrate the attack without user action?
pub fn writeBodyStartCompressed(self: *Self, contentType: []const u8) !CompressedBodyContext {
    try self.response.headers.setContentType(self.arena(), contentType);
    try self.setBodySize(.Infinite);

    var clientEncodingBuf: [6]Headers.ContentEncoding = undefined;
    const supportedEncodings = self.request.headers.acceptEncodings(&clientEncodingBuf);

    const useEncoding = selectContentEncoding(supportedEncodings);

    if (useEncoding) |encoding| {
        try self.response.headers.setContentEncoding(self.arena(), encoding);
        // FIXME: Use transfer-encoding?
        try self.response.headers.replaceOrPut(self.arena(), "Vary", "Accept-Encoding");
        // TODO: merge, not replace
    }

    try self.writeResponse();

    return CompressedBodyContext{
        .owner = self,
        .compress = if (useEncoding) |encoding|
            switch (encoding) {
                .gzip => .{ .GZip = try std.compress.gzip.compressor(CompressedBodyContext.DirectWriter{ .context = self.stream }, .{}) },
                else => unreachable,
            }
        else
            .Identity,
    };
}

pub fn compressAndWriteBody() void {
    @compileError("TODO");
}

fn requestBodySize(self: Self) BodySize {
    if (self.request.headers.transferEncodingHas(.chunked)) {
        return .Infinite;
    } else if (self.request.headers.contentLength()) |length| {
        return .{ .Sized = length };
    } else {
        return .{ .Sized = 0 };
    }
}

pub fn ChunkedBodyReader(comptime optimize: Stream.ReadOptimize) type {
    return struct {
        stream: *Stream,
        chunk: ChunkReadState = ChunkReadState.init,
        finalChunk: bool = false,

        const ReaderContext = @This();

        const ChunkReadState = union(enum) {
            /// The length part
            Length: std.BoundedArray(u8, 10),
            Content: ContentState,
            Trailers: u8,

            const init = ChunkReadState{
                .Length = .{},
            };

            const ContentState = struct {
                len: usize = 0,
                read: usize = 0,
            };
        };

        pub const ReadError = error{
            BadLength,
        };

        pub fn read(self: *ReaderContext, dst: []u8) !usize {
            const chunkState = &self.chunk;

            switch (chunkState.*) {
                .Length => |*lengthTextBuf| {
                    if (self.finalChunk) {
                        return 0;
                    }
                    while (true) {
                        const buf = try self.stream.readBuffer();
                        defer buf.deinit();
                        self.stream.lock.lock();
                        defer self.stream.lock.unlock();

                        const eolIdx = std.mem.indexOfScalar(u8, buf.value, '\n') orelse {
                            try lengthTextBuf.appendSlice(buf.value);
                            continue; // Read additional buffer for size.
                        };
                        if (eolIdx == 0 or buf.value[eolIdx - 1] != '\r') {
                            return ReadError.BadLength;
                        }

                        try lengthTextBuf.appendSlice(buf.value[0..eolIdx]);

                        const size = std.fmt.parseInt(usize, lengthTextBuf.constSlice(), 16) catch {
                            return ReadError.BadLength;
                        };

                        chunkState.* = .{ .Content = .{
                            .len = size,
                        } };

                        if (size == 0) {
                            self.finalChunk = true;
                        }

                        if (buf.value.len - 1 != eolIdx) {
                            // Push back
                            try self.stream.inputs.insert(
                                self.stream.session.allocator,
                                0,
                                buf.slice(eolIdx + 1, buf.value.len),
                            );
                            self.stream.onUpdates.notifyAll();
                        }

                        return self.read(dst);
                    }
                },
                .Content => |*state| {
                    var dstOfs: usize = 0;
                    while (true) {
                        const readableSize = state.len - state.read;
                        if (readableSize == 0) {
                            chunkState.* = .{ .Trailers = 0 };
                            return dstOfs;
                        }
                        const buf = try self.stream.readBuffer();
                        defer buf.deinit();
                        self.stream.lock.lock();
                        defer self.stream.lock.unlock();

                        const src = buf.value[0..@min(readableSize, buf.value.len)];
                        const rest = dst[dstOfs..];
                        if (src.len > rest.len) {
                            std.mem.copyForwards(u8, rest, src[0..rest.len]);
                            state.read += rest.len;
                            try self.stream.inputs.insert(
                                self.stream.session.allocator,
                                0,
                                buf.slice(rest.len, buf.value.len),
                            );
                            self.stream.onUpdates.notifyAll();
                            return dst.len;
                        } else {
                            // src.len <= rest.len
                            std.mem.copyForwards(u8, rest[0..src.len], src);
                            state.read += src.len;
                            dstOfs += src.len;
                            switch (optimize) {
                                .Bandwidth => {},
                                .Latency => return dstOfs,
                            }
                        }
                    }
                },
                .Trailers => |*pc| {
                    while (true) {
                        const buf = try self.stream.readBuffer();
                        defer buf.deinit();
                        const eolIdx = std.mem.indexOfScalar(u8, buf.value, '\n') orelse {
                            pc.* = buf.value[buf.value.len - 1];
                            continue;
                        };
                        const lastChar = if (eolIdx == 0) pc.* else buf.value[eolIdx - 1];
                        if (lastChar == '\r') {
                            chunkState.* = ChunkReadState.init;
                            return self.read(dst);
                        }
                    }
                },
            }
        }
    };
}

pub fn RegularBodyReader(comptime optimize: Stream.ReadOptimize) type {
    return struct {
        size: BodySize,
        readSize: usize = 0,
        stream: *Stream,

        const ReaderContext = @This();

        fn readableSize(self: ReaderContext) usize {
            return switch (self.size) {
                .Infinite => std.math.maxInt(usize),
                .Sized => |sz| if (sz > 0) sz - self.readSize else 0,
            };
        }

        pub fn read(self: *ReaderContext, dst: []u8) !usize {
            var dstOfs: usize = 0;
            while (true) {
                const restSz = self.readableSize();
                if (restSz == 0) {
                    return dstOfs;
                }

                const buf = self.stream.readBuffer() catch |err| switch (err) {
                    error.ConnectionRefused => return dstOfs,
                    else => return err,
                };
                defer buf.deinit();
                self.stream.lock.lock();
                defer self.stream.lock.unlock();

                const src = buf.value[0..@min(restSz, buf.value.len)];
                const rest = dst[dstOfs..];
                if (src.len > rest.len) {
                    std.mem.copyForwards(u8, rest, src[0..rest.len]);
                    try self.stream.inputs.insert(
                        self.stream.session.allocator,
                        0,
                        buf.slice(rest.len, buf.value.len),
                    );
                    self.readSize += rest.len;
                    self.stream.onUpdates.notifyAll();
                    return dst.len;
                } else { // src.len <= dst.len
                    std.mem.copyForwards(u8, rest, src);
                    dstOfs += src.len;
                    self.readSize += src.len;
                    switch (optimize) {
                        .Latency => return dstOfs,
                        else => {},
                    }
                }
            }
        }
    };
}

pub fn AutoBodyReader(comptime optimize: Stream.ReadOptimize) type {
    return union(enum) {
        Chunked: ChunkedBodyReader(optimize),
        Regular: RegularBodyReader(optimize),

        pub fn read(self: *@This(), dst: []u8) !usize {
            return switch (self.*) {
                .Chunked => |*r| try r.read(dst),
                .Regular => |*r| try r.read(dst),
            };
        }

        pub const Reader = std.io.GenericReader(
            *@This(),
            @typeInfo(@typeInfo(@TypeOf(@This().read)).Fn.return_type.?).ErrorUnion.error_set,
            @This().read,
        );

        pub fn reader(self: *@This()) Reader {
            return Reader{ .context = self };
        }
    };
}

/// Create a reader to read the request body.
///
/// The reader holds the lock of the stream while reading data.
/// This function does not hold any lock.
///
/// TODO: support compression?
pub fn bodyReader(self: Self, comptime optimize: Stream.ReadOptimize) AutoBodyReader(optimize) {
    const R = AutoBodyReader(optimize);
    if (self.stream.session.transport == .http1) {
        const size = self.requestBodySize();
        return switch (size) {
            .Infinite => R{ .Chunked = ChunkedBodyReader(optimize){ .stream = self.stream } },
            .Sized => R{ .Regular = RegularBodyReader(optimize){ .stream = self.stream, .size = size } },
        };
    }
    return R{ .Regular = RegularBodyReader(optimize){ .stream = self.stream, .size = self.requestBodySize() } };
}
