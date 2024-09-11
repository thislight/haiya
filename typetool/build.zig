const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const root = b.addModule("typetool", .{
        .root_source_file = b.path("typetool.zig"),
        .optimize = optimize,
        .target = target,
    });

    _ = root;
}
