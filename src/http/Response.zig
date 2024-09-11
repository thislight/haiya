const std = @import("std");
const Headers = @import("./Headers.zig");

statusCode: u16,
statusText: []const u8 = "",
headers: Headers = .{},

const Response = @This();

pub fn shallowDeinit(self: *Response, alloc: std.mem.Allocator) void {
    self.headers.deinit(alloc);
}
