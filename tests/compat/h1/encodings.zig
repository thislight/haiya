const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.h1_headers);
const curl = @import("curl").Easy;
const libcurl = @import("curl").libcurl;
const te = std.testing;
const routers = haiya.routers;

fn handleCompressionOnTheFly(t: *haiya.Transcation) !void {
    defer t.deinit();
    if (std.mem.eql(u8, t.request.method, "GET")) {
        const TEXT = "Hello World!";

        _ = t.resetResponse(.OK);
        var writer = try t.writeBodyStartCompressed("text/plain");

        _ = try writer.write(TEXT);
        try writer.close();
    } else {
        _ = t.resetResponse(.@"Bad Request");
        try t.writeBodyNoContent();
    }
}

fn handleChunkedEncoding(t: *haiya.Transcation) !void {
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

const Router = routers.DefineRouter(std.meta.Tuple(&.{}), .{
    routers.Path("/on-the-fly", handleCompressionOnTheFly),
    routers.Path("/chunked", handleChunkedEncoding),
});

test "gzip compression on-the-fly" {
    var router = Router.init(.{});
    var served = try haiya.Server.Serve(?*anyopaque).create(
        te.allocator,
        Router.routeOrErr,
        &router,
        .{},
    );
    defer served.destory();

    var arena = std.heap.ArenaAllocator.init(te.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var uri = served.baseUrl();
    uri.path = .{ .raw = "/on-the-fly" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();

    {
        const code = libcurl.curl_easy_setopt(client.handle, libcurl.CURLOPT_ACCEPT_ENCODING, "gzip");
        try te.expectEqual(@as(c_uint, libcurl.CURLE_OK), code);
    }

    const resp = try client.get(uriText);
    defer resp.deinit();

    const encoding = try resp.getHeader("Content-Encoding");
    try te.expect(encoding != null);
    try te.expectEqualStrings("gzip", encoding.?.get());
}

test "Transfer-Encoding is chunked when body size is infinite" {
    var router = Router.init(.{});
    var served = try haiya.Server.Serve(?*anyopaque).create(
        te.allocator,
        Router.routeOrErr,
        &router,
        .{},
    );
    defer served.destory();

    var arena = std.heap.ArenaAllocator.init(te.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var uri = served.baseUrl();
    uri.path = .{ .raw = "/chunked" };
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
