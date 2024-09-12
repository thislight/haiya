//! HTTP Headers
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
pub const Entry = @import("./HeaderEntry.zig");

entries: std.ArrayListUnmanaged(Entry) = .{},

const Self = @This();

/// Duplicate the key (if it's not in cache) and value, then appended as an entry.
///
/// If you don't want to duplicate the content, you can operate on `.entries` directly.
pub fn append(self: *Self, alloc: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    const nvalue = try alloc.dupe(u8, value);
    errdefer alloc.free(nvalue);
    if (Entry.CachedKey.findCache(key)) |cache| {
        try self.entries.append(alloc, .{ .key = cache.key, .value = value });
    } else {
        const nkey = try alloc.dupe(u8, key);
        try self.entries.append(alloc, .{ .key = nkey, .value = value });
    }
}

pub fn replaceOrPut(self: *Self, alloc: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
    var iter = self.findKey(key);
    while (iter.next()) |item| {
        const oval = item.value;
        item.value = try alloc.dupe(u8, value);
        alloc.free(oval);
        return;
    }
    try self.append(alloc, key, value);
}

pub const KeyFinder = struct {
    key: []const u8,
    offset: usize = 0,
    headers: *const Self,

    pub fn next(self: *KeyFinder) ?*Entry {
        const headers = &self.headers.entries;
        while (headers.items.len > self.offset) {
            defer self.offset += 1;
            if (std.ascii.eqlIgnoreCase(self.key, headers.items[self.offset].key)) {
                return &headers.items[self.offset];
            }
        }
        return null;
    }

    /// Remove this entry.
    ///
    /// The only safe function if you want to remove any entry while iterating.
    ///
    /// This method won't deinitialise the entry.
    /// If the entry content uses heap memory, you must free them after used.
    pub fn removeThis(self: *KeyFinder, headers: *Self) Entry {
        assert(headers == self.headers);
        assert(headers.entries.items.len >= self.offset);
        defer self.offset -= 1;
        return headers.orderedRemove(self.offset);
    }
};

pub fn findKey(self: *const Self, key: []const u8) KeyFinder {
    return .{
        .key = key,
        .headers = self,
    };
}

fn getOneEntry(self: *const Self, key: []const u8) ?*Entry {
    var it = self.findKey(key);
    while (it.next()) |e| {
        return e;
    }
    return null;
}

pub fn getOne(self: *const Self, key: []const u8) ?[]const u8 {
    return if (self.getOneEntry(key)) |entry| entry.value else null;
}

pub fn orderedRemove(self: *Self, i: usize) Entry {
    return self.entries.orderedRemove(i);
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.entries.deinit(alloc);
}

pub fn pop(self: *Self) Entry {
    return self.entries.pop();
}

/// Only duplicate content (entries and its content), and return a new instance in value.
pub fn dupe(self: Self, alloc: std.mem.Allocator) !Self {
    var copiedEntries = try std.ArrayListUnmanaged(Entry).initCapacity(alloc, self.entries.items.len);
    errdefer for (copiedEntries.items) |item| {
        item.deinit(alloc);
    };
    for (self.entries.items) |entry| {
        const nentry = try entry.dupe(alloc);
        copiedEntries.appendAssumeCapacity(nentry);
    }
    return Self{ .entries = copiedEntries };
}

pub fn setContentLength(self: *Self, alloc: Allocator, value: u64) !void {
    const valueText = try std.fmt.allocPrint(alloc, "{}", .{value});
    errdefer alloc.free(valueText);
    return try self.replaceOrPut(
        alloc,
        "Content-Length",
        valueText,
    );
}

pub fn contentLength(self: *const Self) ?u64 {
    const valueText = self.getOne("Content-Length") orelse return null;
    return std.fmt.parseUnsigned(u64, valueText, 0) catch return null;
}

pub const ContentEncoding = enum {
    chunked,
    gzip,

    fn match(valueText: []const u8) ?ContentEncoding {
        const eql = std.mem.eql;
        if (eql(u8, valueText, "chunked")) {
            return .chunked;
        }
        if (eql(u8, valueText, "gzip")) {
            return .gzip;
        }
        return null;
    }

    fn text(self: ContentEncoding) []const u8 {
        return switch (self) {
            .chunked => "chunked",
            .gzip => "gzip",
        };
    }
};

pub fn transferEncoding(self: *const Self) ?ContentEncoding {
    const valueText = self.getOne("Transfer-Encoding") orelse return null;
    return ContentEncoding.match(valueText);
}

pub fn transferEncodingHas(self: *const Self, encoding: ContentEncoding) bool {
    const encodings = self.getOneEntry("Transfer-Encoding") orelse return false;
    var iter = encodings.iterateList();
    while (iter.next()) |item| {
        if (std.mem.eql(u8, encoding.text(), item.value)) {
            return true;
        }
    }
    return false;
}

/// Set header "Transfer-Encoding".
///
/// If the `value` is `null`, the header will be removed.
/// This function deinitialise the header entry.
pub fn setTransferEncoding(self: *Self, alloc: Allocator, value: ?ContentEncoding) !void {
    if (value) |val| {
        const valueText = val.text();
        try self.replaceOrPut(alloc, "Transfer-Encoding", valueText);
    } else {
        var iter = self.findKey("Transfer-Encoding");
        while (iter.next()) |_| {
            const entry = iter.removeThis(self);
            entry.deinit(alloc);
        }
    }
}

pub fn contentEncoding(self: *const Self) ?ContentEncoding {
    const valueText = self.getOne("Content-Encoding") orelse return null;
    return ContentEncoding.match(valueText);
}

/// Set header "Content-Encoding".
///
/// If the `value` is `null`, the header will be removed.
/// This function deinitialise the header entry.
pub fn setContentEncoding(self: *Self, alloc: Allocator, value: ?ContentEncoding) !void {
    if (value) |val| {
        const valueText = val.text();
        try self.replaceOrPut(alloc, "Content-Encoding", valueText);
    } else {
        var iter = self.findKey("Content-Encoding");
        while (iter.next()) |_| {
            const entry = iter.removeThis(self);
            entry.deinit(alloc);
        }
    }
}

/// Copy all values of `Accept-Encoding` into `buf`. Return a slice of the parsed values.
///
/// Note: the weight parameter (like `;q=0.5`) is not implemented.
pub fn acceptEncodings(self: *const Self, buf: []ContentEncoding) []const ContentEncoding {
    const entry = self.getOneEntry("Accept-Encoding") orelse return buf[0..0];
    var iter = entry.iterateList();
    var idx: usize = 0;
    while (iter.next()) |item| {
        if (idx >= buf.len) {
            break;
        }

        const value = ContentEncoding.match(item.value) orelse continue;
        buf[idx] = value;
        idx += 1;
    }
    const values = buf[0..idx];
    return values;
}

/// Sets "Content-Type".
pub fn setContentType(self: *Self, alloc: Allocator, value: []const u8) !void {
    try self.append(
        alloc,
        "Content-Type",
        value,
    );
}

/// Check if the Connection header has "keep-alive"
///
/// `null` means the header not found.
pub fn isConnectionKeepAlive(self: *const Self) ?bool {
    const valueText = self.getOne("Connection") orelse return null;
    var iter = std.mem.tokenizeScalar(u8, valueText, ',');
    while (iter.next()) |item| {
        const otext = std.mem.trim(u8, item, " ");
        if (std.mem.eql(u8, otext, "keep-alive")) {
            return true;
        }
    }
    return false;
}
