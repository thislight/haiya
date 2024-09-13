//! Test if the handler can read request body, under optimized for both .Bandwidth and .Latency.
const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const curl = @import("curl").Easy;
const te = std.testing;

fn Handlers(comptime readOpt: haiya.Stream.ReadOptimize) type {
    return struct {
        fn fixedLength(t: *haiya.Transcation) !void {
            defer t.deinit();
            if (std.mem.eql(u8, t.request.method, "POST")) {
                var readerCx = t.bodyReader(readOpt);
                const reader = readerCx.reader();
                const text = try reader.readBoundedBytes(4096);

                _ = t.resetResponse(.OK);
                var writer = try t.writeBodyStart(
                    .{ .Sized = text.len },
                    t.request.headers.getOne("Content-Type") orelse "text/plain",
                );

                _ = try writer.write(text.constSlice());
                try writer.close();
            } else {
                _ = t.resetResponse(.@"Bad Request");
                try t.writeBodyNoContent();
            }
        }

        fn unknownLength(t: *haiya.Transcation) !void {
            defer t.deinit();
            if (std.mem.eql(u8, t.request.method, "POST")) {
                var readerCx = t.bodyReader(readOpt);
                const reader = readerCx.reader();
                var input = try reader.readBoundedBytes(4096);

                _ = t.resetResponse(.OK);
                var writer = try t.writeBodyStart(
                    .Infinite,
                    t.request.headers.getOne("Content-Type") orelse "text/plain",
                );

                _ = try writer.write(input.constSlice());
                try writer.close();
            } else {
                _ = t.resetResponse(.@"Bad Request");
                try t.writeBodyNoContent();
            }
        }
    };
}

const Router = haiya.routers.DefineRouter(std.meta.Tuple(&.{}), .{
    haiya.routers.Path("/fixed-bandwidth", Handlers(.Bandwidth).fixedLength),
    haiya.routers.Path("/unknown-bandwidth", Handlers(.Bandwidth).unknownLength),
    haiya.routers.Path("/fixed-latency", Handlers(.Latency).fixedLength),
    haiya.routers.Path("/unknown-latency", Handlers(.Latency).unknownLength),
    haiya.routers.Always(haiya.handlers.AlwaysNotFound(.{}).handle),
});

test "can read fixed-length body (.Bandwidth)" {
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

test "can read fixed-length body (.Latency)" {
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
    uri.path = .{ .raw = "/fixed-latency" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.post(uriText, "text/plain", "Hello, World!");
    defer resp.deinit();

    try te.expect(resp.body != null);
    const body = resp.body.?;
    try te.expectEqualStrings("Hello, World!", body.items);
}

test "can read unknown-length body (.Bandwidth)" {
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
    uri.path = .{ .raw = "/unknown-bandwidth" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.post(uriText, "text/plain", "Hello, World!");
    defer resp.deinit();

    try te.expect(resp.body != null);
    const body = resp.body.?;
    try te.expectEqualStrings("Hello, World!", body.items);
}

test "can read unknown-length body (.Latency)" {
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
    uri.path = .{ .raw = "/unknown-latency" };
    const uriText = try std.fmt.allocPrintZ(alloc, "{}", .{uri});

    var client = try curl.init(alloc, .{});
    defer client.deinit();
    const resp = try client.post(uriText, "text/plain", "Hello, World!");
    defer resp.deinit();

    try te.expect(resp.body != null);
    const body = resp.body.?;
    try te.expectEqualStrings("Hello, World!", body.items);
}
