//! Test if headers (request/response line and headers reading/setting) works
const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.h1_headers);
const curl = @import("curl").Easy;
const te = std.testing;

fn echoFixedLengthBody(t: *haiya.Transcation) !void {
    defer t.deinit();
    if (std.mem.eql(u8, t.request.method, "POST")) {
        var readerCx = t.bodyReader(.Bandwidth);
        const reader = readerCx.reader();
        const text = try reader.readAllAlloc(t.arena(), 4096);

        _ = t.resetResponse(.OK);
        var writer = try t.writeBodyStart(
            .{ .Sized = text.len },
            t.request.headers.getOne("Content-Type") orelse "text/plain",
        );

        _ = try writer.write(text);
        try writer.close();
    } else {
        _ = t.resetResponse(.@"Bad Request");
        try t.writeBodyNoContent();
    }
}

const Router = haiya.routers.DefineRouter(std.meta.Tuple(&.{}), .{
    haiya.routers.Path("/fixed-bandwidth", echoFixedLengthBody),
});

test "can read fixed-length body" {
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
    uri.path = .{ .raw = "/fixed-bandwidth" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.post(uriText, "text/plain", "Hello, World!");
    defer resp.deinit();

    try te.expect(resp.body != null);
    const body = resp.body.?;
    try te.expectEqualStrings("Hello, World!", body.items);
}
