//! Stream.
//!
const std = @import("std");
const parkinglot = @import("parkinglot");
const Session = @import("./Session.zig");
const ArcBuffer = @import("./ArcBuffer.zig");
const Request = @import("./http/Request.zig");
const h1 = @import("./http/h1.zig");
const Transcation = @import("./http/Transcation.zig");
const FileSize = @import("./units.zig").FileSize;
const Response = @import("./http/Response.zig");
const log = std.log.scoped(.Stream);
const rio = @import("rio");
const ServerEvent = @import("./ServerEvent.zig");

session: *Session,
lock: parkinglot.Lock = .{},
/// Stream Id.
///
/// This id is allocated at the `Session` level.
///
/// **For h2**:
/// It must be unique in the whole Session lifecycle per the spec.
streamId: u32,
state: State = .Idle,
priority: i8 = 0,

/// The queue of input data.
///
/// The allocator from the session is used to manage this list.
///
/// **For h2**:
/// Every `ArcBuffer.Ref` will be a frame in h2.
inputs: std.ArrayListUnmanaged(ArcBuffer.Ref) = .{},

/// The notify when the situation changed.
///
/// Will be notified on those situtaion:
///
/// - An active read is completed
/// - the state is changed to `.Closed`, but before the actual destorying running
/// - An in-progress transcation is destoryed
onUpdates: parkinglot.Condition = .{},

io: rio.Ring,

/// The next transcation.
///
/// This field is used to store the pending transcation.
/// Please use `Transcation.copyToArena` before moving the
/// transcation to `Stream.inProgressTranscation`.
nextTranscation: Transcation = undefined,
iRState: union(enum) {
    unspecified: void,
    h1: h1.RequestState,
    h2: void,
    h3: void,
} = .unspecified,

inProgressTranscation: ?Transcation = null,

closingEvent: ?ServerEvent = undefined,

cfg: Cfg = .{},

pub const State = enum {
    Idle,

    ReservedLocal,
    ReservedRemote,
    Open,

    HalfClosedRemote,
    HalfClosedLocal,

    Closed,
};

pub const Cfg = struct {
    keepAlive: bool = false,
    keepAliveMaxIdle: u32 = 5,
};

const Stream = @This();

pub fn create(session: *Session, id: u32) !*Stream {
    const n = try session.allocator.create(Stream);
    errdefer session.allocator.destroy(n);

    n.* = .{
        .io = try session.parent.io.from(4, .{}),
        .session = session,
        .streamId = id,
    };

    return n;
}

fn waitForCurrentTranscation(self: *Stream, lock: *parkinglot.Lock) void {
    while (self.inProgressTranscation != null) {
        self.onUpdates.wait(lock);
    }
}

/// Deinitialise the structure.
///
/// The stream must be closed. This function holds the session lock
/// at the start and the stream lock in the process.
pub fn destory(self: *Stream) void {
    {
        self.session.lock.lock();
        defer self.session.lock.unlock();
        _ = self.session.findAndRemoveStream(self) catch {};
    }
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.waitForCurrentTranscation(&self.lock);
    }

    self.lock.lock();
    std.debug.assert(self.state == .Closed);
    const alloc = self.session.allocator;

    self.flush() catch {};
    self.io.deinit();
    while (self.inputs.popOrNull()) |node| {
        node.deinit();
    }
    self.inputs.deinit(alloc);

    alloc.destroy(self);
}

fn setCloseStream(self: *Stream) !void {
    const session = self.session;
    const event = &self.closingEvent;
    event.* = .{
        .operation = .{ .CloseStream = self },
        .session = session,
    };
    errdefer event.* = null;
    _ = try session.parent.io.nop(@intFromPtr(event));
    _ = session.parent.io.submit(0) catch {};
}

/// Ask the server to close this stream.
///
/// This function holds the lock of the stream, and
/// should not be called in the dispatch thread.
pub fn close(self: *Stream) void {
    while (true) {
        self.tryClose() catch |err| {
            log.err("could not set stream close: {}", .{err});
            switch (err) {
                error.SubmissionQueueFull => {
                    self.session.parent.onSqAvailable.wait(&self.lock);
                    continue;
                },
            }
        };
        break;
    }
}

pub fn tryClose(self: *Stream) !void {
    self.lock.lock();
    defer self.lock.unlock();
    self.state = .Closed;
    self.onUpdates.notifyAll();
    if (self.closingEvent == null) {
        try self.setCloseStream();
    }
}

pub fn readBuffer(self: *Stream) !ArcBuffer.Ref {
    self.lock.lock();
    defer self.lock.unlock();
    if (self.inputs.popOrNull()) |ref| {
        return ref;
    }
    while (self.inputs.items.len == 0) {
        {
            self.session.lock.lock();
            defer self.session.lock.unlock();
            if (self.session.activeEvent == null) {
                try self.session.setReadBuffer();
            }
        }
        self.onUpdates.wait(&self.lock);
        if (self.state == .Closed) {
            return rio.RecvError.ConnRefused;
        }
    }
    return self.inputs.pop();
}

pub fn writeBuffer(self: *Stream, ud: u64, value: ArcBuffer.Ref) !void {
    const sqe = try self.io.sqe();
    sqe.send(self.session.fd, value.value);
    sqe.ud(ud);
}

/// Write response.
///
/// This function must be the first `write*` to call.
pub fn writeResponse(self: *Stream, alloc: std.mem.Allocator, value: Response, version: Request.Version) !void {
    switch (self.session.transport) {
        .http1 => {
            const bytes = h1.countResponse(value, version);
            if (bytes > std.math.maxInt(usize)) {
                return std.mem.Allocator.Error.OutOfMemory;
            }
            const buffer = try alloc.alloc(u8, @intCast(bytes));
            var wst = std.io.fixedBufferStream(buffer);
            h1.fmtResponse(wst.writer(), value, version) catch unreachable;
            try self.writeSlice(0, buffer);
            _ = try self.io.submit(1);
            _ = try self.io.cqe();
        },
        else => unreachable,
    }
}

pub fn writeSlice(self: *Stream, ud: u64, value: []const u8) !void {
    const sqe = try self.io.sqe();
    sqe.send(self.session.fd, value);
    sqe.ud(ud);
}

/// Submit all requests and consume the CQE(s).
pub fn flush(self: *Stream) !void {
    _ = try self.io.submit(0);
    const n = self.io.sqReady();
    for (0..n) |_| {
        _ = try self.io.cqe();
    }
}

pub fn markRequestStart(self: *Stream) void {
    self.nextTranscation = Transcation.init(
        self,
        Request.empty(),
        std.heap.ArenaAllocator.init(self.session.allocator),
    );
    switch (self.session.transport) {
        .http1 => self.iRState = .{ .h1 = .{} },
        .h2 => self.iRState = .h2,
        .h3 => self.iRState = .h3,
    }
}

/// Mark this request is ended.
/// If this request is ended, this stream can prepare for the next request.
///
/// Received data from this point will be treated as data for the next transcation.
fn markRequestEnd(self: *Stream) void {
    self.iRState = .unspecified;
}

/// Mark this response is ended.
///
/// This function does not hold any lock. It will notify on `onUpdates`.
pub fn markResponseEnd(self: *Stream) void {
    self.markRequestEnd();
    self.inProgressTranscation = null;
    self.onUpdates.notifyAll();
    if (!self.cfg.keepAlive) {
        self.close();
    } else {
        self.session.lock.lock();
        defer self.session.lock.unlock();
        if (self.session.activeEvent == null) {
            self.session.setReadBuffer() catch |err| {
                log.err("could not setup the next read: {}", .{err});
                self.close();
            };
        }
    }
}

const BAD_REQ_PAGE = @embedFile("./pages/400.html");

fn writeBadRequest(
    self: *Stream,
) !void {
    self.markRequestEnd();
    defer self.markResponseEnd();
    const buffer = try self.session.findOrCreateBuffer(512 + BAD_REQ_PAGE.len);
    defer buffer.unref();
    var allocback = std.heap.FixedBufferAllocator.init(buffer.vec);
    const alloc = allocback.allocator();
    var resp = Response{ .statusCode = 400, .statusText = "Bad Request" };
    defer resp.shallowDeinit(alloc);
    try resp.headers.append(alloc, "Content-Type", "text/html");
    try resp.headers.append(alloc, "Content-Length", std.fmt.comptimePrint(
        "{}",
        .{BAD_REQ_PAGE.len},
    ));
    try self.writeResponse(alloc, resp, switch (self.session.transport) {
        .http1 => Request.Version.http1_1,
        .h2 => Request.Version.h2,
        .h3 => unreachable,
    });
    try self.writeSlice(0, BAD_REQ_PAGE);
    try self.flush();
}

pub const TranscationCheckError = error{
    /// The caller should resize the same buffer, receive more data and retry again.
    RetryLater,
    /// The request is malformed.
    BadRequest,
    /// The request still needs additional data.
    Continue,
};

/// Check if the buffer has enough data for the next transcation.
///
/// When `.BadRequest` is returned, this function already handled the error and returnd a response.
///
/// This function does not hold any lock.
pub fn hasNewTranscation(self: *Stream) !*Transcation {
    if (self.inputs.items.len == 0) {
        return TranscationCheckError.RetryLater;
    }
    const block = self.inputs.orderedRemove(0);
    defer block.deinit();
    errdefer {
        const nref = block.slice(0, block.value.len);
        self.inputs.insert(self.session.allocator, 0, nref) catch |err| {
            nref.deinit();
            log.warn("unable to push back buffer in error, the buffer will be dropped: {}", .{err});
        };
    }
    switch (self.iRState) {
        .h1 => |state| {
            // For now, h1 requires the request line and headers fits in one chunk of buffer.
            // Maybe we can set the default page size as the max size and provide an option later.
            //
            // The key problem of HTTP/1.x parsing, is the content is stateful.
            // We need state to separate headers (request line/status line and headers)
            // and payload. That's not the case in h2 or h3 since the payload is explict
            // "marked" by the protocol, like, wraps in the special frame.
            // That's makes h2/h3 more like a RPC protocol and easier to implement in fact.
            const nstate = h1.requestFromStr(
                state,
                &self.nextTranscation.request,
                self.session.allocator,
                block.value,
            ) catch {
                try self.writeBadRequest();
                return TranscationCheckError.BadRequest;
            };
            if (nstate.final) {
                // Push the rest of buffer back
                if (block.value[nstate.walkedOffset..].len > 0) {
                    const nref = block.slice(nstate.walkedOffset, block.value.len);
                    errdefer nref.deinit();
                    try self.inputs.insert(self.session.allocator, 0, nref);
                    errdefer _ = self.inputs.orderedRemove(0);
                }
                self.inProgressTranscation = try self.nextTranscation.copyToArena();
                // No content copied, shallowDeinit() is enough.
                self.nextTranscation.request.shallowDeinit(self.session.allocator);
                return &self.inProgressTranscation.?;
            } else {
                // Increment the ref count
                const nref = block.slice(0, block.value.len);
                errdefer nref.deinit();
                try self.inputs.insert(
                    self.session.allocator,
                    0,
                    nref,
                );
                self.iRState = .{ .h1 = nstate };
                return TranscationCheckError.RetryLater;
            }
        },
        .unspecified => unreachable,
        else => unreachable,
    }
}

/// The reader optimizing target.
///
/// If you don't know how to choose, choose `.Bandwidth`. Most of time your app doesn't
/// need to optimize for low latency. You can always change it later.
pub const ReadOptimize = enum {
    /// This reader is optimized for low latency.
    ///
    /// The reader may return the result as soon as they are available.
    /// This option can avoid common latency causes like:
    ///
    /// - waiting to fulfill the provided buffer,
    ///
    /// but it may add additional reads to complete the task.
    ///
    /// This option can not avoid natrual latency causes, like:
    ///
    /// - The latency for TLS encrypting/decrypting,
    /// - Parsing requests, formating responses.
    ///
    /// They are must-have latency for operating.
    Latency,
    /// This reader is optimized for large bandwidth.
    ///
    /// The reader should fulfill the provided buffer as possible,
    /// so the batch operation works better and the number of reads can be reduced.
    Bandwidth,
};

pub fn InputReaderContext(comptime optimize: ReadOptimize) type {
    return struct {
        owner: *Stream,
        buffer: ?ArcBuffer.Ref = null,
        bufferOfs: usize = 0,

        fn nextBuffer(self: *@This()) !ArcBuffer.Ref {
            const buf = try self.owner.readBuffer();
            self.buffer = buf;
            self.bufferOfs = 0;
            return buf;
        }

        pub fn read(self: *@This(), dst: []u8) !usize {
            var dstOfs: usize = 0;
            while (true) {
                const buffer = self.buffer orelse try self.nextBuffer();
                const src = buffer.value[self.bufferOfs..];
                const rest = dst[dstOfs..];
                if (src.len > rest.len) {
                    std.mem.copyForwards(u8, rest, src[0..rest.len]);
                    self.bufferOfs += rest.len;
                    return dst.len;
                } else { // src.len <= rest.len
                    std.mem.copyForwards(u8, rest[0..src.len], src);
                    dstOfs += src.len;
                    buffer.deinit();
                    self.buffer = null;
                    switch (optimize) {
                        .Latency => return dstOfs,
                        .Bandwidth => {},
                    }
                }
            }
        }

        pub const ReadError = @typeInfo(@typeInfo(@TypeOf(@This().read)).Fn.return_type.?).ErrorUnion.error_set;

        pub const Reader = std.io.GenericReader(*@This(), ReadError, @This().read);

        pub fn reader(self: *@This()) Reader {
            return Reader{ .context = self };
        }
    };
}

/// The reader of the raw input.
///
/// Note: this reader doesn't support push back, use at your own risk.
pub fn inputReader(self: *Stream, comptime optimize: ReadOptimize) InputReaderContext(optimize) {
    return InputReaderContext(optimize){ .owner = self };
}
