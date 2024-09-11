//! Test if headers (request/response line and headers reading/setting) works
const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.h1_headers);
const curl = @import("curl").Easy;
const te = std.testing;

fn handleRequest(_: ?*anyopaque, t: *haiya.Transcation) !void {
    defer t.deinit();
    if (std.mem.eql(u8, t.request.method, "GET")) {
        const TEXT = "Hello World!";

        const resp = try t.resetResponse(.OK);
        try resp.headers.append(t.arena(), "X-Test", "1");
        var writer = try t.writeBodyStart(.{ .Sized = TEXT.len }, "text/plain");

        _ = try writer.write(TEXT);
        try writer.close();
    } else {
        _ = try t.resetResponse(.@"Bad Request");
        try t.writeBodyNoContent();
    }
}

test "can add Content-Type" {
    var served = try haiya.Server.Serve(?*anyopaque).create(
        te.allocator,
        handleRequest,
        null,
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
    const resp = try client.get(uriText);
    defer resp.deinit();

    const header = try resp.getHeader("Content-Type") orelse return error.NoHeader;
    try te.expectEqualStrings("text/plain", header.get());
}

test "can add custom header" {
    var served = try haiya.Server.Serve(?*anyopaque).create(
        te.allocator,
        handleRequest,
        null,
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
    const resp = try client.get(uriText);
    defer resp.deinit();

    const header = try resp.getHeader("X-Test") orelse return error.NoHeader;
    try te.expectEqualStrings("1", header.get());
}
