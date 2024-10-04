const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const root = b.addModule("rio", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    root.addImport("parkinglot", b.dependency("parkinglot", .{
        .optimize = optimize,
        .target = target,
    }).module("parkinglot"));
}
