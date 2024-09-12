//! Test if Transfer-Encoding works
//!
//! Targets:
//!
//! - Trasfer-Encoding: chunked
const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.h1_headers);
const curl = @import("curl").Easy;
const te = std.testing;

fn handleRequest(ud: ?*anyopaque, t: *haiya.Transcation) !void {
    defer t.deinit();
    const streamptr: *usize = @alignCast(@ptrCast(ud));
    defer streamptr.* = @intFromPtr(t.stream);
    if (std.mem.eql(u8, t.request.method, "GET")) {
        const TEXT = "Hello World!";

        _ = t.resetResponse(.OK);
        var writer = try t.writeBodyStart(.Infinite, "text/plain");

        _ = try writer.write(TEXT);
        try writer.close();
    } else {
        _ = t.resetResponse(.@"Bad Request");
        try t.writeBodyNoContent();
    }
}

test "Connection: keep-alive can persistent the connection" {
    var streamptr: usize = 0;
    var served = try haiya.Server.Serve(?*anyopaque).create(
        te.allocator,
        handleRequest,
        &streamptr,
        .{},
    );
    defer served.destory();

    var arena = std.heap.ArenaAllocator.init(te.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var uri = served.baseUrl();
    uri.path = .{ .raw = "/" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();

    const call0 = call0: {
        const resp = try client.get(uriText);
        defer resp.deinit();
        break :call0 streamptr;
    };

    const call1 = call1: {
        const resp = try client.get(uriText);
        defer resp.deinit();
        break :call1 streamptr;
    };

    try te.expectEqual(call0, call1);
}
