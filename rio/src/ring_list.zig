const std = @import("std");

pub fn RingList(T: type) type {
    return struct {
        buf: []T,
        startIdx: usize = 0,
        endIdx: usize = 0,

        const List = @This();

        pub const Error = error{
            Overflow,
        };

        pub fn init(buf: []T) List {
            return .{ .buf = buf };
        }

        pub fn initAlloc(alloc: std.mem.Allocator, capacity: usize) !List {
            const buf = try alloc.alloc(T, capacity);
            return List.init(buf);
        }

        pub fn deinitAlloc(self: List, alloc: std.mem.Allocator) void {
            alloc.free(self.buf);
        }

        pub fn len(self: *const List) usize {
            return if (self.endIdx > self.startIdx)
                self.endIdx - self.startIdx
            else
                self.startIdx - self.endIdx;
        }

        pub fn addOneAtEnd(self: *List) !*T {
            const nextIdx = (self.endIdx + 1) % self.buf.len;
            if (nextIdx == self.startIdx) {
                return Error.Overflow;
            }
            self.endIdx = nextIdx;
            return &self.buf[nextIdx - 1];
        }

        pub fn append(self: *List, value: T) !void {
            const ptr = try self.addOneAtEnd();
            ptr.* = value;
        }

        /// Remove the value at the first and return it.
        pub fn pull(self: *List) ?T {
            if (self.len() == 0) return null;
            const idx = self.startIdx;
            self.startIdx = (idx + 1) % self.buf.len;
            return self.buf[idx];
        }

        pub fn addOneAtStart(self: *List) !*T {
            const nextIdx = if (self.startIdx == 0) self.buf.len - 1 else self.startIdx - 1;
            if (nextIdx == self.endIdx) {
                return Error.Overflow;
            }
            self.startIdx = nextIdx;
            return &self.buf[nextIdx];
        }

        pub fn prepend(self: *List, value: T) !void {
            const ptr = try self.addOneAtStart();
            ptr.* = value;
        }

        /// Remove the value at the last and remove it.
        pub fn pop(self: *List) ?T {
            if (self.len() == 0) return null;
            const idx = self.endIdx;
            self.endIdx = if (idx == 0) self.buf.len - 1 else idx - 1;
            return self.buf[idx];
        }
    };
}

test "RingList can add and remove items" {
    const t = std.testing;
    var list = try RingList(usize).initAlloc(t.allocator, 4);
    defer list.deinitAlloc(t.allocator);
    for (0..4) |i| {
        try list.append(i);
    }
    for (0..4) |i| {
        try t.expectEqual(i, list.pull());
    }
    for (0..4) |i| {
        try list.prepend(i);
    }
    for (0..4) |i| {
        try t.expectEqual(i, list.pop());
    }
}
