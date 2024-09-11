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

        _ = try t.resetResponse(.OK);
        var writer = try t.writeBodyStartCompressed("text/plain");

        _ = try writer.write(TEXT);
        try writer.close();
    } else {
        _ = try t.resetResponse(.@"Bad Request");
        try t.writeBodyNoContent();
    }
}

const Router = routers.DefineRouter(std.meta.Tuple(&.{}), .{
    routers.Path("/on-the-fly", handleCompressionOnTheFly),
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
