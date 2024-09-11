//! Buffer with atomic reference count.
const std = @import("std");
const log = std.log.scoped(.ArcBuffer);
const Atomic = std.atomic.Value;

refcount: Atomic(u32) = Atomic(u32).init(1),
vec: []u8,

const ArcBuffer = @This();

/// Reference of the buffer slot.
///
/// After used, use `.deinit` to update the reference count.
pub const Ref = struct {
    slot: *ArcBuffer,
    value: []u8,

    pub fn deinit(self: Ref) void {
        _ = self.slot.refcount.fetchSub(1, .seq_cst);
    }

    pub fn slice(self: Ref, offset: usize, end: usize) Ref {
        _ = self.slot.refcount.fetchAdd(1, .seq_cst);
        return .{
            .slot = self.slot,
            .value = self.value[offset..end],
        };
    }
};

pub fn ref(self: *ArcBuffer, offset: usize, len: usize) Ref {
    const ocnt = self.refcount.fetchAdd(1, .seq_cst);
    if (ocnt == 0) {
        log.warn("This is buffer is already dropped.", .{});
    }
    return .{
        .slot = self,
        .value = self.vec[offset .. offset + len],
    };
}

/// The reference count is initialised as 1. You must decrement it using .unref() after used.
pub fn create(alloc: std.mem.Allocator, size: usize) !*ArcBuffer {
    const n = try alloc.create(ArcBuffer);
    errdefer alloc.destroy(n);
    const buffer = try alloc.alloc(u8, size);
    errdefer alloc.free(buffer);

    n.* = .{ .vec = buffer };
    return n;
}

/// Decrement the reference count.
///
/// The reference count is initialised as 1. So it won't be picked up by another thread by chance.
///
/// You must unref it after used.
pub fn unref(self: *ArcBuffer) void {
    _ = self.refcount.fetchSub(1, .seq_cst);
}

pub fn destory(self: *ArcBuffer, alloc: std.mem.Allocator) void {
    if (self.refcount.load(.seq_cst) > 0) {
        log.warn("Someone is still referencing this buffer, destorying anyway.", .{});
    }
    alloc.free(self.vec);
    alloc.destroy(self);
}

pub fn resize(self: *ArcBuffer, alloc: std.mem.Allocator, nsz: usize) bool {
    _ = self.refcount.fetchAdd(1, .seq_cst);
    defer self.unref();
    return alloc.resize(self.vec, nsz);
}
