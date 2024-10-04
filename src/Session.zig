//! Represent a bridge to a connection, like TCP connection, h2 connection.
//!
//! ## Resource Management
//!
//!
const std = @import("std");
const Stream = @import("./Stream.zig");
const parkinglot = @import("parkinglot");
const xev = @import("xev");
const tls = @import("./tls.zig");
const log = std.log.scoped(.Session);
const ArcBuffer = @import("./ArcBuffer.zig");
const Transcation = @import("./http/Transcation.zig");
const Server = @import("./Server.zig");
const rio = @import("rio");
const Arc = @import("./rc.zig").Arc;
const ServerEvent = @import("./ServerEvent.zig");

parent: *Server,
lock: parkinglot.Lock = .{},
transport: Transport,
fd: rio.Fd,
/// Stream Trackings.
///
/// The session must not be destoryed before all streams are destoryed.
///
/// Streams referenced in Transcations, when the transcation is still being worked
/// in a thread, the stream should not be closed.
streams: std.ArrayListUnmanaged(*Stream) = .{},
nextStreamId: u32 = 1,
/// TLS Context.
///
/// Not implemented yet.
tls: ?tls.Context = null,
allocator: std.mem.Allocator,
/// Buffers used in the streams.
///
/// Zero or more streams may reference one buffer.
/// That's because h2 and h3 supports mux. We don't know the one piece of data belongs before parsing them.
///
/// Arcbuffer is to avoid copying frames around.
///
/// Buffer will be splited on frames, and push to the `.inputs` of the streams.
///
/// A buffer will be reused if no one referencing. They will not be free'd as the `Session` active.
buffers: std.ArrayListUnmanaged(*ArcBuffer) = .{},

/// Current status of the session.
///
///
status: Status = .Open,

activeEvent: ?ServerEvent = null,

const Self = @This();

pub const Status = enum {
    Open,
    Closing,
    Closed,
};

pub const Transport = union(enum) {
    http1: void,
    h2: void,
    h3: void,
};

fn h1GetStream(self: *Self) *Stream {
    return self.streams.items[0];
}

fn h1AfterRead(
    self: *Self,
    st: *Stream,
) void {
    if (st.inProgressTranscation == null) {
        if (st.iRState == .unspecified) {
            st.markRequestStart();
        }

        if (st.hasNewTranscation()) |nextTranscation| {
            self.parent.call(nextTranscation);
        } else |err| switch (err) {
            error.RetryLater => {
                log.debug("hasNewTranscation for stream#{} => RetryLater", .{st.streamId});
            },
            else => {
                log.err("hasNewTranscation for stream#{} => {}", .{ st.streamId, err });
            },
        }
    }
}

pub fn receiveReadBuffer(self: *Self, cqe: rio.Ring.Completion, buffer: *ArcBuffer) !void {
    log.debug("${x} receive read on ${x}", .{ @intFromPtr(self), @intFromPtr(buffer) });
    self.lock.lock();
    defer self.lock.unlock();
    defer self.activeEvent = null;
    defer buffer.unref();
    if (cqe.resAsRecv()) |readsize| {
        const ref = buffer.ref(0, readsize);
        errdefer ref.deinit();
        switch (self.transport) {
            .http1 => {
                const st = self.h1GetStream();
                st.lock.lock();
                defer st.lock.unlock();
                if (readsize > 0) {
                    try st.inputs.append(self.allocator, ref);
                    self.h1AfterRead(st);
                } else {
                    ref.deinit();
                }
                st.onUpdates.notifyAll();
            },
            else => unreachable,
        }
    } else |err| {
        log.err("read failed: {}", .{err});
        return err;
    }
}

/// Set up a read.
///
/// This function will initialise `self.activeRead`.
///
/// This function will not hold the lock.
pub fn setReadBuffer(self: *Self) !void {
    const buffer = try self.findOrCreateBuffer(self.parent.cfg.bufferSize);
    errdefer buffer.unref();
    log.debug("${x} set read on buffer ${x}", .{ @intFromPtr(self), @intFromPtr(buffer) });
    const activeRead = &self.activeEvent;
    activeRead.* = .{
        .operation = .{ .ReadBuffer = buffer },
        .session = self,
    };
    _ = try self.parent.io.recv(@intFromPtr(activeRead), self.fd, buffer.vec);
    _ = try self.parent.io.submit(0);
}

/// Cancel read buffer if any read is active.
///
/// This function does not hold any lock.
pub fn cancelReadBuffer(self: *Self) !void {
    if (self.activeEvent) |act| {
        if (act.operation != .ReadBuffer) return;
        self.activeEvent = .{
            .operation = .{ .CancelReadBuffer = act.operation.ReadBuffer },
            .session = self,
        };
        _ = try self.parent.io.cancel(@intFromPtr(&self.activeEvent), @intFromPtr(&self.activeEvent));
        _ = try self.parent.io.submit(0);
    }
}

/// Find or create a buffer. The returned buffer have 1 as the reference count.
///
/// This function is not thread-safe.
pub fn findOrCreateBuffer(self: *Self, sz: usize) !*ArcBuffer {
    for (self.buffers.items) |item| {
        if (item.vec.len >= sz and item.refcount.cmpxchgWeak(0, 1, .seq_cst, .seq_cst) == null) {
            return item;
        }
    }
    const slot = try ArcBuffer.create(self.allocator, sz);
    errdefer slot.destory(self.allocator);
    try self.buffers.append(self.allocator, slot);
    return slot;
}

/// Find next available stream id.
fn findNextStreamId(self: *Self) error{Overflow}!u32 {
    const maxStreamId = switch (self.transport) {
        .http1 => 1,
        .h2 => std.math.maxInt(u31),
        .h3 => std.math.maxInt(u32),
    };
    var streamId = self.nextStreamId;
    while (streamId <= maxStreamId) {
        for (self.streams.items) |s| {
            if (s.streamId == streamId) {
                continue;
            }
        }
        if ((self.transport == .h2 and
            streamId % 2 == 0) or self.transport != .h2)
        {
            break;
        }
        streamId += 1;
    } else {
        return error.Overflow;
    }
    self.nextStreamId = streamId + 1;
    return streamId;
}

pub const CreateStreamError = std.mem.Allocator.Error || rio.InitError;

fn createStream(self: *Self, streamId: u32) CreateStreamError!*Stream {
    const n = try Stream.create(self, streamId);
    errdefer n.destory();
    try self.streams.append(self.allocator, n);
    return n;
}

pub fn create(
    parent: *Server,
    fd: rio.Fd,
    transport: Transport,
    alloc: std.mem.Allocator,
) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .allocator = alloc,
        .fd = fd,
        .parent = parent,
        .transport = transport,
    };
    switch (transport) {
        .http1 => {
            const stream = try self.createStream(0);
            stream.state = .Open;
            self.nextStreamId = 1;
        },
        else => unreachable,
    }
    log.debug("${x} created", .{@intFromPtr(self)});
    return self;
}

/// Deinitialise the resource.
///
/// This function is thread-safe.
///
/// Note: this function does not remove itself from the parent (server),
/// you should remove it before calling this.
pub fn destory(self: *Self) void {
    self.lock.lock();
    const fd = self.fd;
    std.debug.assert(self.streams.items.len == 0);
    self.streams.deinit(self.allocator);
    rio.os.close(fd);
    if (self.activeEvent) |act| {
        switch (act.operation) {
            .CancelReadBuffer, .ReadBuffer => |buf| {
                buf.unref();
            },
            else => unreachable,
        }
    }
    while (self.buffers.popOrNull()) |item| {
        item.destory(self.allocator);
    }
    self.buffers.deinit(self.allocator);
    const alloc = self.allocator;
    alloc.destroy(self);
    log.debug("session ${x} is destoryed", .{@intFromPtr(self)});
}

/// Start the closing for this session.
///
/// This function holds the session's lock.
pub fn close(self: *Self) void {
    self.lock.lock();
    defer self.lock.unlock();
    if (self.status != .Open) {
        return;
    }
    self.status = .Closing;
    while (self.activeEvent != null and self.activeEvent.?.operation == .ReadBuffer) {
        self.cancelReadBuffer() catch |err| {
            switch (err) {
                error.SubmissionQueueFull => {
                    self.parent.onSqAvailable.wait(&self.lock);
                    continue;
                },
                else => {},
            }
        };
        break;
    }
}

/// Continue the closing process.
///
/// If this session can be removed from the server and be destroyed, returns `true`.
///
/// This function will hold the lock of this session and of every stream in this session.
pub fn checkClosing(self: *Self) !bool {
    self.lock.lock();
    defer self.lock.unlock();

    switch (self.status) {
        .Closed => return true,
        .Open => return false,
        else => {},
    }

    if (self.activeEvent) |event| {
        if (event.operation == .ReadBuffer) {
            try self.cancelReadBuffer();
        }
        return false;
    }

    const streams = self.streams.items;
    var unclosed: usize = 0;
    for (streams) |st| {
        st.lock.lock();
        defer st.lock.unlock();

        if (st.state != .Closed) {
            st.lock.unlock();
            defer st.lock.lock();
            st.close();
            unclosed += 1;
        }
    }

    return unclosed == 0;
}

pub const OpenStreamError = error{
    NotAvailable,
} || std.mem.Allocator.Error;

pub fn openStream(self: *const Self) OpenStreamError!*Stream {
    // h1 only accepts 1 stream for each session
    std.debug.assert(self.transport != .http1 or (self.transport == .http1 and self.streams.items.len == 0));

    if (self.status != .Open) {
        return OpenStreamError.NotAvailable;
    }
    const streamId = self.findNextStreamId() catch return OpenStreamError.NotAvailable;
    const stream = try self.createStream(streamId);
    // sends required message to inform the stream
    stream.state = .Open;
    return stream;
}

pub fn findAndRemoveStream(self: *Self, stream: *Stream) error{NotFound}!*Stream {
    const idx = std.mem.indexOfScalar(*Stream, self.streams.items, stream) orelse {
        return error.NotFound;
    };
    return self.streams.swapRemove(idx);
}
