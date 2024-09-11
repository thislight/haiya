const std = @import("std");

pub fn MappedTuple(R: type, Tuple: type) type {
    const inf = @typeInfo(Tuple).Struct;
    comptime var fields: std.BoundedArray(std.builtin.Type.StructField, inf.fields.len) = .{};
    for (inf.fields) |f| {
        fields.appendAssumeCapacity(.{
            .alignment = 0,
            .default_value = f.default_value,
            .is_comptime = f.is_comptime,
            .name = f.name,
            .type = R,
        });
    }
    return @Type(.{ .Struct = .{
        .layout = .auto,
        .is_tuple = true,
        .fields = fields.constSlice(),
        .decls = &.{},
    } });
}

/// Mapping tuple.
///
/// Example:
/// ````zig
/// fn mapTypeOf(value: anytype) type {
///     return @TypeOf(value);
/// }
///
/// _ = MapTuple(type, .{ 1, @as(u64, 1), @(usize, 1) }, mapTypeOf); // Result is .{ comptime_int, u64, usize }
/// ````
pub fn MapTuple(R: type, tuple: anytype, mapper: anytype) MappedTuple(R, @TypeOf(tuple)) {
    var result: MappedTuple(R, @TypeOf(tuple)) = undefined;
    for (@typeInfo(@TypeOf(tuple)).Struct.fields) |f| {
        @field(result, f.name) = mapper(@field(tuple, f.name));
    }
    return result;
}

pub fn MergedTuple(Tuples: anytype) type {
    comptime var len = 0;
    for (@typeInfo(Tuples).Struct.fields) |f| {
        len += @typeInfo(f.type).Struct.fields.len;
    }
    comptime var fields: std.BoundedArray(std.builtin.Type.StructField, len) = .{};
    for (@typeInfo(Tuples).Struct.fields) |f| {
        for (@typeInfo(f.type).Struct.fields) |sf| {
            fields.appendAssumeCapacity(.{
                .alignment = 0,
                .default_value = sf.default_value,
                .is_comptime = sf.is_comptime,
                .type = sf.type,
                .name = std.fmt.comptimePrint("{}", .{fields.len}),
            });
        }
    }
    return @Type(.{ .Struct = .{
        .layout = .auto,
        .fields = fields.constSlice(),
        .decls = &.{},
        .is_tuple = true,
    } });
}

fn mapTypeOf(comptime value: anytype) type {
    return @TypeOf(value);
}

/// Merging tuples.
///
/// Examples:
/// ````zig
/// _ = MergeTuple(.{
///     .{ 1, 2, 3 },
///     .{ 4, 5 },
/// }); // Result is .{ 1, 2, 3, 4, 5 }
/// ````
pub fn MergeTuple(tuples: anytype) MergedTuple(@TypeOf(tuples)) {
    var result: MergedTuple(@TypeOf(tuples)) = undefined;
    comptime var i = 0;
    inline for (@typeInfo(@TypeOf(tuples)).Struct.fields) |f| {
        inline for (@typeInfo(f.type).Struct.fields) |sf| {
            @field(result, std.fmt.comptimePrint("{}", .{i})) = @field(@field(tuples, f.name), sf.name);
            i += 1;
        }
    }
    return result;
}

pub fn ClosureResult(Closure: type) type {
    const inf = @typeInfo(Closure);
    return switch (inf) {
        .Fn => |f| f.return_type.?,
        .Struct => ClosureResult(@TypeOf(Closure.call)),
        .Optional => |option| ClosureResult(option.child),
        else => @compileError("unexpected type for a closure: " ++ @typeName(Closure)),
    };
}

/// Invoke a closure.
///
/// A closure is a function or a struct has `call()`, or a pointer to one of them.
///
/// Note: If you want to receive `*Self`, which is mutable, the object must be
/// passed by mutable pointer, just like the example.
///
/// Example:
///
/// ````zig
/// const Closure = struct {
///   count: u32 = 0,
///
///   pub fn call(self: *@This(), offset: u32) u32 {
///     count += offset;
///     return count;
///   }
/// };
///
/// var callable = Closure {};
///
/// std.debug.print("count: {}", .{invokeClosure(&callable, .{ 1 })});
/// ````
pub fn invokeClosure(closure: anytype, args: anytype) ClosureResult(@TypeOf(closure)) {
    const T = @TypeOf(closure);
    const info = @typeInfo(T);
    if (info == .Fn) {
        return @call(.none, closure, args);
    } else if (info == .Struct) {
        return @call(.auto, @TypeOf(closure).call, MergeTuple(.{ .{closure}, args }));
    } else if (info == .Pointer and info.Pointer.size == .One and switch (@typeInfo(info.Pointer.child)) {
        .Fn, .Struct => true,
        else => false,
    }) {
        return switch (@typeInfo(info.Pointer.child)) {
            .Fn => @call(.none, closure, args),
            .Struct => @call(.none, closure.call, args),
            else => unreachable,
        };
    } else if (info == .Optional) {
        return invokeClosure(closure.?, args);
    } else {
        @compileError("closure expect a function or a structure with call method");
    }
}

pub fn UnwrappedOptional(T: type) type {
    return switch (@typeInfo(T)) {
        .Optional => |option| UnwrappedOptional(option.child),
        else => T,
    };
}

/// Unwrap optional value, even if the value is not option type.
///
/// Unlike .? operator, this function accepts both ?T and T, returns T.
/// The main usage is for `anytype` params that are possiblily null.
pub fn unwrapOptional(value: anytype) UnwrappedOptional(@TypeOf(value)) {
    return switch (@typeInfo(@TypeOf(value))) {
        .Optional => value.?,
        .Null => unreachable,
        else => value,
    };
}

pub fn isNotNull(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .Optional => value != null,
        .Null => false,
        else => true,
    };
}
