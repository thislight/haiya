const std = @import("std");

pub const FileSizeUnit = enum {
    byte,

    kilobyte,
    megabyte,
    gigabyte,

    kibibyte,
    mebibyte,
    gibibyte,
};

pub fn FileSize(T: type) type {
    return union(FileSizeUnit) {
        byte: T,

        // 1000 units
        kilobyte: T,
        megabyte: T,
        gigabyte: T,

        // 1024 units
        kibibyte: T,
        mebibyte: T,
        gibibyte: T,

        const Self = @This();

        const DecimalUnitStart = @intFromEnum(std.meta.Tag(Self).kilobyte);
        const BinaryUnitStart = @intFromEnum(std.meta.Tag(Self).kibibyte);

        pub fn pack(n: T, unit: FileSizeUnit) Self {
            inline for (std.meta.fields(Self)) |field| {
                if (std.mem.eql(u8, field.name, @tagName(unit))) {
                    return @unionInit(Self, field.name, n);
                }
            }
            unreachable;
        }

        pub fn number(self: Self) T {
            inline for (std.meta.fields(Self)) |field| {
                if (std.mem.eql(u8, field.name, @tagName(self))) {
                    return @field(self, field.name);
                }
            }
            unreachable;
        }

        /// Convert to specific unit. Error may be return if calculation is impossible, like overflow.
        ///
        /// See `to` if you believe the function won't error.
        pub fn convert(self: Self, targetUnit: FileSizeUnit) !Self {
            const activeUnit = std.meta.activeTag(self);
            if (activeUnit == targetUnit) {
                return self;
            }

            return switch (activeUnit) {
                .byte => switch (targetUnit) {
                    .byte => self,
                    .kilobyte, .megabyte, .gigabyte => pack(try std.math.divTrunc(T, self.number(), std.math.pow(
                        T,
                        1000,
                        @intFromEnum(targetUnit) - DecimalUnitStart + 1,
                    )), targetUnit),
                    .kibibyte, .mebibyte, .gibibyte => pack(try std.math.divTrunc(T, self.number(), std.math.pow(
                        T,
                        1024,
                        @intFromEnum(targetUnit) - BinaryUnitStart + 1,
                    )), targetUnit),
                },
                .kilobyte, .megabyte, .gigabyte => switch (targetUnit) {
                    .byte => pack(try std.math.mul(T, self.number(), std.math.pow(
                        T,
                        1000,
                        @intFromEnum(activeUnit) - DecimalUnitStart + 1,
                    )), .byte),
                    .kilobyte, .megabyte, .gigabyte => dec: {
                        if (@intFromEnum(targetUnit) > @intFromEnum(activeUnit)) {
                            break :dec pack(try std.math.divTrunc(
                                T,
                                self.number(),
                                std.math.pow(
                                    T,
                                    1000,
                                    @intFromEnum(targetUnit) - @intFromEnum(activeUnit),
                                ),
                            ), targetUnit);
                        } else if (@intFromEnum(targetUnit) < @intFromEnum(activeUnit)) {
                            break :dec pack(try std.math.mul(
                                T,
                                self.number(),
                                std.math.pow(
                                    T,
                                    1000,
                                    @intFromEnum(activeUnit) - @intFromEnum(targetUnit),
                                ),
                            ), targetUnit);
                        } else {
                            break :dec self;
                        }
                    },
                    else => try (try self.convert(.byte)).convert(targetUnit),
                },
                .kibibyte, .mebibyte, .gibibyte => switch (targetUnit) {
                    .byte => pack(
                        try std.math.mul(
                            T,
                            self.number(),
                            std.math.pow(T, 1024, @intFromEnum(activeUnit) - BinaryUnitStart + 1),
                        ),
                        .byte,
                    ),
                    .kibibyte, .mebibyte, .gibibyte => bin: {
                        if (@intFromEnum(targetUnit) > @intFromEnum(activeUnit)) {
                            break :bin pack(try std.math.divTrunc(
                                T,
                                self.number(),
                                std.math.pow(
                                    T,
                                    1024,
                                    @intFromEnum(targetUnit) - @intFromEnum(activeUnit),
                                ),
                            ), targetUnit);
                        } else if (@intFromEnum(targetUnit) < @intFromEnum(activeUnit)) {
                            break :bin pack(try std.math.mul(
                                T,
                                self.number(),
                                std.math.pow(
                                    T,
                                    1024,
                                    @intFromEnum(activeUnit) - @intFromEnum(targetUnit),
                                ),
                            ), targetUnit);
                        } else {
                            break :bin self;
                        }
                    },
                    else => try (try self.convert(.byte)).convert(targetUnit),
                },
            };
        }

        pub fn to(self: Self, targetUnit: FileSizeUnit) Self {
            return self.convert(targetUnit) catch unreachable;
        }

        pub fn numberCast(self: Self, NewType: type) FileSize(NewType) {
            const ovalue = self.number();
            const value: NewType = switch (@typeInfo(T)) {
                .Float => switch (@typeInfo(NewType)) {
                    .Int => @intFromFloat(ovalue),
                    .Float => @floatCast(ovalue),
                    else => unreachable,
                },
                .Int => switch (@typeInfo(NewType)) {
                    .Int => @intCast(ovalue),
                    .Float => @floatFromInt(ovalue),
                    else => unreachable,
                },
                else => unreachable,
            };
            return FileSize(NewType).pack(value, @enumFromInt(@intFromEnum(std.meta.activeTag(self))));
        }
    };
}

test "FileSize converts decimal-based units" {
    const t = std.testing;
    {
        const obytes = FileSize(u64){ .byte = 1000000 };

        try t.expectEqual(@as(u64, 1000), obytes.to(.kilobyte).number());
        try t.expectEqual(@as(u64, 1), obytes.to(.megabyte).number());
    }
    {
        const obytes = FileSize(u64){ .megabyte = 4 };
        try t.expectEqual(@as(u64, 4000), obytes.to(.kilobyte).number());
    }
    {
        const obytes = FileSize(u64){ .kilobyte = 4 };
        try t.expectEqual(@as(u64, 4000), obytes.to(.byte).number());
    }
}

test "FileSize converts binary-based units" {
    const t = std.testing;
    {
        const obytes = FileSize(u64){ .byte = 4096 };
        try t.expectEqual(@as(u64, 4), obytes.to(.kibibyte).number());
    }
    {
        const obytes = FileSize(u64){ .kibibyte = 4 };
        try t.expectEqual(@as(u64, 4096), obytes.to(.byte).number());
    }
    {
        const obytes = FileSize(u64){ .gibibyte = 4 };
        try t.expectEqual(@as(u64, 4096), obytes.to(.mebibyte).number());
    }
}

test "FileSize numberCast()" {
    const t = std.testing;
    const obytes = FileSize(u64){ .kilobyte = 4000 };
    try t.expectEqual(@as(u32, 4000), obytes.numberCast(u32).number());
}
