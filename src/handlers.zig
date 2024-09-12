const std = @import("std");
const PathArgs = @import("./routers.zig").PathArgs;
const Transcation = @import("./http/Transcation.zig");

pub const AlwaysNotFoundOpts = struct {};

/// Make a handler always returns 404.
pub fn AlwaysNotFound(comptime _: AlwaysNotFoundOpts) type {
    return struct {
        pub fn handle(t: *Transcation) !void {
            defer t.deinit();
            _ = t.resetResponse(.@"Not Found");
            try t.writeBodyNoContent();
        }
    };
}
