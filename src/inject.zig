//! Dependency Injection
//!
//!
const std = @import("std");
const typetool = @import("typetool");

fn CallTuple(F: type) type {
    const inf = @typeInfo(F).Fn;
    comptime var fields: std.BoundedArray(std.builtin.Type.StructField, inf.params.len) = .{};
    for (inf.params) |p| {
        fields.appendAssumeCapacity(.{
            .alignment = 0,
            .default_value = null,
            .is_comptime = false,
            .name = std.fmt.comptimePrint("{}", .{fields.len}),
            .type = p.type.?,
        });
    }
    return @Type(.{
        .Struct = .{ .layout = .auto, .is_tuple = true, .fields = fields.constSlice(), .decls = &.{} },
    });
}

pub fn DependencyReturnType(Closure: type) type {
    return switch (@typeInfo(Closure)) {
        .Struct => DependencyReturnType(@TypeOf(Closure.inject)),
        .Fn => |f| f.return_type.?,
        .Pointer => |ptr| if (ptr.size == .One) DependencyReturnType(ptr.child) else @compileError("unsupported closure"),
        else => @compileError("unsupported closure"),
    };
}

/// This is an minimal example of the dynamic dependency protocol.
///
/// You must define `ref` and `Requires` to declare the type for a dynamic dependency.
///
/// - The `Requires` can be an closure, see typetool's `invokeClosure`.
/// - The `ref` must be the result of the closure.
pub fn Depends(closure: anytype) type {
    return struct {
        ref: DependencyReturnType(@TypeOf(closure)),

        const Requires = closure;
    };
}

fn isStaticInjectable(Slot: type, Inject: type) bool {
    return Slot == Inject or Slot == ?Inject;
}

fn isDynamicInjectable(Slot: type, Inject: type) bool {
    return isInjectable(Slot, DependencyReturnType(Inject.Requires));
}

fn isDynamicInject(T: type) bool {
    return @typeInfo(T) == .Struct and @hasDecl(T, "Requires");
}

fn isInjectable(Slot: type, Inject: type) bool {
    return if (isDynamicInject(Inject)) isDynamicInjectable(Slot, Inject) else isStaticInjectable(Slot, Inject);
}

pub fn run(f: anytype, injects: anytype) @typeInfo(@TypeOf(f)).Fn.return_type.? {
    const inf = switch (@typeInfo(@TypeOf(f))) {
        .Fn => |c| c,
        .Pointer => |ptr| @typeInfo(@TypeOf(ptr.child)).Fn,
        else => @compileError("expect function or pointer to function, got " ++ @typeName(@TypeOf(f))),
    };
    var args: CallTuple(@TypeOf(f)) = undefined;

    inline for (inf.params, 0..inf.params.len) |p, i| {
        const argIndex = std.fmt.comptimePrint("{}", .{i});
        @field(args, argIndex) = if (comptime isDynamicInject(p.type.?))
            .{ .ref = runDependency(p.type.?, injects) }
        else staticInjected: {
            inline for (@typeInfo(@TypeOf(injects)).Struct.fields) |field| {
                if (comptime isStaticInjectable(p.type.?, field.type)) {
                    break :staticInjected @field(injects, field.name);
                }
            }
            @compileError(std.fmt.comptimePrint(
                "injectable \"{s}\" is not found at slot #{} for {s}, all injectables: {}",
                .{ @typeName(p.type.?), i, @typeName(@TypeOf(f)), @TypeOf(injects) },
            ));
        };
    }

    return @call(.auto, f, args);
}

test "run() injects scalars" {
    const t = std.testing;
    const S = struct {
        fn scalar(
            value: u32,
        ) !void {
            try t.expectEqual(@as(u32, 1), value);
        }
    };
    try run(S.scalar, .{@as(u32, 1)});
}

test "run() injects const dynamic dependency" {
    const t = std.testing;

    const SmartOffset = struct {
        offset: u32,

        pub fn inject(self: @This(), root: u32) u32 {
            return root + self.offset;
        }
    };

    const S = struct {
        fn dynamic(value: Depends(SmartOffset{ .offset = 2 })) !void {
            try t.expectEqual(@as(u32, 3), value.ref);
        }
    };

    try run(S.dynamic, .{@as(u32, 1)});
}

fn runDependency(D: type, injects: anytype) DependencyReturnType(@TypeOf(D.Requires)) {
    switch (@typeInfo(D)) {
        .Struct => {
            return run(@TypeOf(D.Requires).inject, typetool.MergeTuple(.{ .{ D.Requires, &D.Requires }, injects }));
        },
        else => @compileError("unsupported dependency " ++ @typeName(D)),
    }
}
