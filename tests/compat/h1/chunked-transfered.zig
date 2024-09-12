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

fn handleRequest(_: ?*anyopaque, t: *haiya.Transcation) !void {
    defer t.deinit();
    if (std.mem.eql(u8, t.request.method, "GET")) {
        const TEXT = "Hello World!";

        _ = t.resetResponse(.OK);
        var writer = try t.writeBodyStart(.Infinite, "text/plain");

        _ = try writer.write(TEXT);
        try writer.close();
    } else {
        _ = t.resetResponse(.@"Bad Request");
        try t.writeResponse();
    }
}

test "Transfer-Encoding is chunked when body size is infinite" {
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

    const header = try resp.getHeader("Transfer-Encoding") orelse return error.NoHeader;
    try te.expectEqualStrings("chunked", header.get());

    const body = if (resp.body) |b| b else return error.NoBody;
    var bufStream = std.io.fixedBufferStream(body.items);

    const TEXT = "Hello World!";
    var buf = [_]u8{0} ** TEXT.len;
    const n = try bufStream.reader().read(&buf);
    try te.expectEqualStrings(TEXT, buf[0..n]);
}
