const std = @import("std");

const Tool = struct {
    fn addModules(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
        mod.addImport("typetool", b.dependency("typetool", .{
            .target = target,
            .optimize = optimize,
        }).module("typetool"));
        mod.addImport("parkinglot", b.dependency("parkinglot", .{
            .target = target,
            .optimize = optimize,
        }).module("parkinglot"));
        mod.addImport("xev", b.dependency("xev", .{
            .target = target,
            .optimize = optimize,
        }).module("xev"));
    }
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const testFilters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const examples = b.step("examples", "Build examples");
    const checkStep = b.step("check", "Compile but won't install files");
    const test_step = b.step("test", "Run unit tests");
    const behaviourTests = b.step("test-behaviour", "Run behaviour tests");

    const rio = rio: {
        const mod = b.addModule("rio", .{
            .root_source_file = b.path("src/rio.zig"),
            .optimize = optimize,
            .target = target,
        });
        mod.addImport("parkinglot", b.dependency("parkinglot", .{
            .target = target,
            .optimize = optimize,
        }).module("parkinglot"));
        break :rio mod;
    };

    {
        const mod = b.addModule("haiya", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        Tool.addModules(b, mod, target, optimize);
        mod.addImport("rio", rio);

        const checkBuild = b.addStaticLibrary(.{
            .optimize = optimize,
            .target = target,
            .name = "haiya",
            .root_source_file = b.path("src/root.zig"),
        });
        Tool.addModules(b, &checkBuild.root_module, target, optimize);
        checkBuild.root_module.addImport("rio", rio);
        checkStep.dependOn(&checkBuild.step);

        const docBuild = b.addStaticLibrary(.{
            .optimize = optimize,
            .target = target,
            .name = "haiya",
            .root_source_file = b.path("src/root.zig"),
        });
        Tool.addModules(b, &docBuild.root_module, target, optimize);
        docBuild.root_module.addImport("rio", rio);

        const docsPath = docBuild.getEmittedDocs();
        const instDocs = b.addInstallDirectory(
            .{
                .install_subdir = "docs",
                .install_dir = .prefix,
                .source_dir = docsPath,
            },
        );

        b.default_step.dependOn(&instDocs.step);
    }

    {
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const lib_unit_tests = b.addTest(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
            .filters = testFilters,
        });
        Tool.addModules(b, &lib_unit_tests.root_module, target, optimize);

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        test_step.dependOn(&run_lib_unit_tests.step);
    }

    {
        const helloWorld = b.addExecutable(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/examples/hello.zig"),
            .name = "hello",
        });

        helloWorld.root_module.addImport(
            "haiya",
            b.modules.get("haiya") orelse @panic("NO MOD"),
        );
        helloWorld.root_module.addImport(
            "rio",
            b.modules.get("rio") orelse @panic("NO MOD"),
        );

        const installHelloWorld = b.addInstallArtifact(
            helloWorld,
            .{},
        );

        examples.dependOn(&installHelloWorld.step);
        checkStep.dependOn(&helloWorld.step);
    }

    {
        const modHaiya = b.modules.get("haiya") orelse @panic("Module not found");
        const modRio = b.modules.get("rio") orelse @panic("Module not found");

        inline for (BEHAVIOUR_TEST_FILES) |dfilename| {
            const filename = b.path("tests/" ++ dfilename);

            const exe = b.addTest(.{
                .root_source_file = filename,
                .optimize = optimize,
                .target = target,
                .strip = false,
                .filters = testFilters,
            });
            exe.root_module.addImport("haiya", modHaiya);
            exe.root_module.addImport("rio", modRio);

            if (b.lazyDependency("curl", .{})) |curlPkg| {
                exe.root_module.addImport("curl", curlPkg.module("curl"));
            }

            checkStep.dependOn(&exe.step);
            const run = b.addRunArtifact(exe);
            behaviourTests.dependOn(&run.step);
        }
    }
}

const BEHAVIOUR_TEST_FILES: []const []const u8 = &.{
    "compat/headers.zig",
    "compat/h1/chunked-transfered.zig",
    "compat/h1/keep-alive.zig",
    "compat/h1/compression.zig",
};
