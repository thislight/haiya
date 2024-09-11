const std = @import("std");

key: []const u8,
value: []const u8,

const Entry = @This();

pub const CachedKey = struct {
    key: []const u8,

    pub const ALL: []const CachedKey = &.{
        .{ .key = "Content-Type" },
        .{ .key = "Host" },
    };

    pub fn isFromCache(other: []const u8) bool {
        inline for (ALL) |item| {
            if (item.key.ptr == other.ptr) {
                return true;
            }
        }
        return false;
    }

    pub fn findCache(key: []const u8) ?CachedKey {
        inline for (CachedKey.ALL) |o| {
            if (std.mem.eql(u8, key, o.key)) {
                return o;
            }
        }
        return null;
    }
};

pub fn dupe(self: *const Entry, alloc: std.mem.Allocator) !Entry {
    const k = if (CachedKey.isFromCache(self.key)) self.key else try alloc.dupe(u8, self.key);
    errdefer if (!CachedKey.isFromCache(self.key)) {
        alloc.free(k);
    };
    const v = try alloc.dupe(u8, self.value);
    return .{ .key = k, .value = v };
}

/// Deinitialise the content which is not from cache.
pub fn deinit(self: *const Entry, alloc: std.mem.Allocator) void {
    if (!CachedKey.isFromCache(self.key)) {
        alloc.free(self.key);
    }
    alloc.free(self.value);
}

pub const ListItem = struct {
    value: []const u8,
    /// Weight parameter. `q=0.5` and this field is `0.5`.
    q: ?f16 = null,
};

pub const ListIterator = struct {
    itemIterator: std.mem.TokenIterator(u8, .scalar),

    /// Get next item.
    ///
    /// Note: the weight parameter is ignored and always be `null`.
    pub fn next(self: *ListIterator) ?ListItem {
        if (self.itemIterator.next()) |untrimmedItem| {
            const item = std.mem.trim(u8, untrimmedItem, " ");
            if (std.mem.indexOfScalar(u8, item, ';')) |ppos| {
                const value = std.mem.trim(u8, item[0..ppos], " ");

                const pstr = if (ppos + 1 < item.len) item[ppos + 1 ..] else {
                    return .{ .value = value };
                };
                const qstart = std.mem.indexOf(u8, pstr, "q=") orelse return .{ .value = value };
                const numberStart = qstart + 2;
                if (numberStart >= item.len) {
                    return .{ .value = value };
                }
                const numberText = item[numberStart..];
                if (std.fmt.parseFloat(f16, numberText) catch null) |q| {
                    return .{ .value = value, .q = q };
                } else {
                    return .{ .value = value };
                }
            } else {
                return .{
                    .value = item,
                };
            }
        }
        return null;
    }
};

/// Iterate the value as a list.
///
/// This function deals with values like `gzip, chunked; q=0.5, br`
/// The weight parameter (`q=0.5`) is ignored, won't affect the returning order,
/// and always be `null`.
pub fn iterateList(self: Entry) ListIterator {
    return ListIterator{
        .itemIterator = std.mem.tokenizeScalar(u8, self.value, ','),
    };
}
