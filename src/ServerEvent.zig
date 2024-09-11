const std = @import("std");
const Session = @import("./Session.zig");
const rio = @import("rio");
const ArcBuffer = @import("./ArcBuffer.zig");
const Stream = @import("./Stream.zig");

session: *Session,
operation: Operation,

const ServerEvent = @This();

pub const Operation = union(enum) {
    ReadBuffer: *ArcBuffer,
    CloseStream: *Stream,
    CancelReadBuffer: *ArcBuffer,
    /// The special event to ask the dispatch thread to check the server status.
    ///
    /// The `.session` must be set to `undefined`.
    CheckServerStatus: void,
};

pub fn create(alloc: std.mem.Allocator, session: *Session, operation: Operation) !*ServerEvent {
    const self = try alloc.create(ServerEvent);
    self.* = .{
        .session = session,
        .operation = operation,
    };
    return self;
}
