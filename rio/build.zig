const std = @import("std");
pub const Backend = @import("./src/root.zig").Backend;

/// - Linux
///   - `>= 5.15.0`: IoUring
///   - `>= 2.5.44`: EPoll (not implemented)
/// - else: Poll
/// - unknown platform: null
fn selectBackend(target: std.Target) Backend {
    return switch (target.os.tag) {
        .linux => linux: {
            if (target.os.isAtLeast(.linux, .{
                .major = 5,
                .minor = 15,
                .patch = 0,
            }) orelse false) {
                break :linux .IoUring;
            } else {
                break :linux .Poll;
            }
        },
        .windows => .Poll,
        .macos, .ios, .tvos, .watchos => .Poll,
        .wasi => .Poll,
        else => @panic("unknown platform, use -Dbackend=<backend> to specify a supported backend"),
    };
}

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const backend = b.option(Backend, "backend",
        \\ IO backend (default: auto detect based on the target)
    ) orelse selectBackend(target.result);

    const root = b.addModule("rio", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    const opts = b.addOptions();
    opts.addOption(Backend, "backend", backend);
    root.addOptions("build_opts", opts);
    root.addImport("parkinglot", b.dependency("parkinglot", .{
        .optimize = optimize,
        .target = target,
    }).module("parkinglot"));
}
