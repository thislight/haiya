//! HTTP Request
//!
const std = @import("std");
const Headers = @import("./Headers.zig");

method: []const u8,
path: []const u8,
headers: Headers,
version: Version,

pub const Version = enum {
    http1_0,
    http1_1,
    h2,

    pub fn format(self: *const Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.format(writer, "HTTP/{s}", .{
            switch (self.*) {
                .http1_0 => "1.0",
                .http1_1 => "1.1",
                .h2 => "2",
            },
        });
    }
};

pub const CachedMethod = struct {
    key: []const u8,

    /// If the `other` can be replaced by the cache key.
    pub fn eql(self: CachedMethod, other: []const u8) bool {
        if (other.len != self.key.len) {
            return false;
        }
        return std.ascii.eqlIgnoreCase(self.key, other);
    }

    /// Return the cache entry by the key if possible.
    /// You can use this function to check the key if it is from the cache.
    pub fn cacheRef(other: []const u8) ?*const CachedMethod {
        inline for (ALL) |*item| {
            if (item.key.ptr == other.ptr) {
                return item;
            }
        }
        return null;
    }

    pub const ALL: []const CachedMethod = &.{
        .{ .key = "GET" },
        .{ .key = "POST" },
        .{ .key = "HEAD" },
        .{ .key = "PUT" },
        .{ .key = "DELETE" },
        .{ .key = "CONNECT" },
        .{ .key = "OPTIONS" },
        .{ .key = "TRACE" },
    };
};

const Request = @This();

/// Set method, use cached value if possible.
///
/// Cached values are store in the program binary.
pub fn setMethod(self: *Request, method: []const u8) bool {
    for (CachedMethod.ALL) |cached| {
        if (cached.eql(method)) {
            self.method = cached.key;
            return true;
        }
    }
    self.method = method;
    return false;
}

pub fn format(self: *const Request, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    const outDefault = fmt.len == 0;
    const outRequestLine = outDefault or std.mem.indexOfScalar(u8, fmt, 'r') != null;
    const outHeaders = outDefault or std.mem.indexOfScalar(u8, fmt, 'h') != null;
    const outAsZigStr = std.mem.indexOfScalar(u8, fmt, 's') != null;
    if (outRequestLine) {
        if (outAsZigStr) {
            _ = try writer.write("\\\\");
        }
        try std.fmt.format(writer, "{s} {s} {}\r\n", .{
            self.method,
            self.path,
            self.version,
        });
    }
    if (outHeaders) {
        for (self.headers.entries.items) |entry| {
            if (outAsZigStr) {
                _ = try writer.write("\\\\");
            }
            try std.fmt.format(writer, "{s}: {s}\r\n", .{ entry.key, entry.value });
        }
    }
    _ = try writer.write(if (outAsZigStr) "\\\\\r\n" else "\r\n");
}

/// Get an empty Request. All fields are initialised to default.
pub fn empty() Request {
    return Request{
        .headers = Headers{},
        .method = CachedMethod.ALL[0].key,
        .path = "",
        .version = .http1_1,
    };
}

/// Deinitialise additional memory used by this structure.
///
/// For now it's only the memory used by headers unmanaged list.
pub fn shallowDeinit(self: *Request, alloc: std.mem.Allocator) void {
    self.headers.deinit(alloc);
}

/// Deinitialise all memory used using `alloc`.
pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
    if (CachedMethod.cacheRef(self.method) == null) {
        alloc.free(self.method);
    }
    self.shallowDeinit(alloc);
}

/// Duplicate the request content.
/// Including headers and the content of headers (unless they are cached).
pub fn dupe(self: *const Request, alloc: std.mem.Allocator) !Request {
    const methodNameCached = CachedMethod.cacheRef(self.method) != null;
    var copy = Request.empty();
    copy.method = if (methodNameCached) try alloc.dupe(u8, self.method) else self.method;
    errdefer if (methodNameCached) {
        alloc.free(copy.method);
    };
    copy.path = try alloc.dupe(u8, self.path);
    errdefer alloc.free(copy.path);
    copy.version = self.version;
    copy.headers = try self.headers.dupe(alloc);
    return copy;
}
