const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const root = b.addModule("parkinglot", .{
        .root_source_file = b.path("parkinglot.zig"),
        .optimize = optimize,
        .target = target,
    });
    root.addImport("typetool", b.dependency("typetool", .{
        .optimize = optimize,
        .target = target,
    }).module("typetool"));
}
