//! Test if headers (request/response line and headers reading/setting) works
const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.h1_headers);
const curl = @import("curl").Easy;
const te = std.testing;

fn setCookieDep(t: *haiya.Transcation, testCookie: haiya.Cookie("test")) !void {
    defer t.deinit();
    _ = t.resetResponse(.@"No Content");
    try testCookie.set("test", .{});
    try t.writeBodyNoContent();
}

fn setMultipleCookies(t: *haiya.Transcation) !void {
    const resp = t.resetResponse(.@"No Content");
    try resp.headers.replaceOrPutCookie(t.arena(), .{
        .name = "test1",
        .value = "test",
        .cfg = .{},
    });
    try resp.headers.replaceOrPutCookie(t.arena(), .{
        .name = "test2",
        .value = "test",
        .cfg = .{},
    });
}

const Router = haiya.routers.DefineRouter(std.meta.Tuple(&.{}), .{
    haiya.routers.Path("/set-cookie", setCookieDep),
    haiya.routers.Path("/set-multiple-cookies", setMultipleCookies),
    haiya.routers.Always(haiya.handlers.AlwaysNotFound(.{}).handle),
});

test "can add Set-Cookie" {
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
    uri.path = .{ .raw = "/set-cookie" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.get(uriText);
    defer resp.deinit();

    const header = try resp.getHeader("Set-Cookie");
    try te.expect(header != null);
    try te.expectStringStartsWith(header.?.get(), "test=test;");
}

test "can add multiple Set-Cookie" {
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
    uri.path = .{ .raw = "/set-multiple-cookies" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.get(uriText);
    defer resp.deinit();

    var iter = try resp.iterateHeaders(.{ .name = "Set-Cookie" });
    var cnt: usize = 0;
    while (try iter.next()) |item| {
        try te.expectStringEndsWith(item.get(), "=test;");
        cnt += 1;
    }
    try te.expectEqual(2, cnt);
}
