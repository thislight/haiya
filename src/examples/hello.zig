const std = @import("std");
const haiya = @import("haiya");
const rio = @import("rio");
const log = std.log.scoped(.main);
const routers = haiya.routers;

var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn countedHelloWorld(t: *haiya.Transcation) !void {
    defer t.deinit();
    log.info("{s} {s} {}", .{
        t.request.method,
        t.request.path,
        t.request.version,
    });
    const value = counter.fetchAdd(1, .seq_cst) + 1;

    _ = try t.resetResponse(.OK);
    const TEXT = "Hello, World!";

    const addsize = std.fmt.count("Visited {} time.", .{value}) +
        if (value > 1) @as(u64, 1) else 0;

    var writerCx = try t.writeBodyStart(
        .{ .Sized = TEXT.len + addsize },
        "text/plain",
    );
    const writer = writerCx.writer();

    _ = try writer.write(TEXT);
    try writer.print("Visited {} time", .{value});
    if (value > 1) {
        _ = try writer.write("s");
    }
    _ = try writer.write(".");
    try writerCx.close();
}

pub fn namedHelloWorld(t: *haiya.Transcation, args: routers.PathArgs) !void {
    defer t.deinit();

    _ = try t.resetResponse(.OK);
    const name = args.ref[0];
    const content = try std.fmt.allocPrint(
        t.arena(),
        "Hello {s}!",
        .{name},
    );

    var writerCx = try t.writeBodyStart(
        .{ .Sized = content.len },
        "text/plain",
    );

    _ = try writerCx.write(content);
    try writerCx.close();
}

const Path = routers.Path;

const Router = routers.DefineRouter(std.meta.Tuple(&.{}), .{
    Path("/", countedHelloWorld),
    Path("/favicon.ico", haiya.handlers.AlwaysNotFound(.{}).handle),
    Path("/{}", namedHelloWorld),
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try haiya.GlobalContext.init(allocator);
    defer haiya.GlobalContext.deinit();

    const ring = try rio.Ring.init(256, .{});

    var router = Router.init(.{});

    var server = try haiya.Server.init(
        ring,
        Router.route,
        &router,
        allocator,
        .{},
    );
    defer server.deinit();
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9075);
    _ = try server.tcpListen(addr);
    log.info("listening on {}", .{addr});

    try server.dispatch();
}
