const std = @import("std");
const Headers = @import("./Headers.zig");

pub const Cookie = struct {
    /// The cookie name.
    ///
    /// **Cookie Prefixes**:
    ///
    /// - `__Host-`: requires `.secure = true`, `.domain` is empty and `.path = "/"`
    /// - `__Secure-`: requires `.secure = true`
    name: []const u8,
    value: []const u8,
    /// Cookie configuration.
    ///
    /// `null` = unknown. If the cookie is sent from the client, the cfg is unknown.
    cfg: ?Cfg = null,

    pub const SameSite = enum {
        /// The browser to only send the cookie in response to requests originating from the cookie's origin site.
        Strict,
        /// The browser sends the cookie when requesting on the cookie's origin site.
        Lax,
        /// The browser sends the cookie on both originating and cross-site requests
        ///
        /// Only be valid when `.secure = true`.
        None,
    };

    pub const Cfg = struct {
        domain: []const u8 = &.{},
        path: []const u8 = &.{},
        expires: ?void = null, // std does not have date processing
        secure: bool = false,
        httponly: bool = false,
        sameSite: SameSite = .Lax,
    };

    pub fn format(self: Cookie, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.format(writer, "{s}={s};", .{ self.name, self.value });
        if (self.cfg) |cfg| {
            if (cfg.domain.len > 0) {
                try std.fmt.format(writer, "Domain={s};", .{cfg.domain});
            }
            if (cfg.path.len > 0) {
                try std.fmt.format(writer, "Path={s};", .{cfg.path});
            }
            // TODO: expires
            if (cfg.secure) {
                try std.fmt.format(writer, "Secure;", .{});
            }
            if (cfg.httponly) {
                try std.fmt.format(writer, "HttpOnly;", .{});
            }
            if (cfg.sameSite != .Lax) {
                try std.fmt.format(writer, "SameSite={s};", .{@tagName(cfg.sameSite)});
            }
        }
    }
};

pub const Set = struct {
    entries: std.ArrayListUnmanaged(Cookie) = .{},

    pub fn replace(self: *Set, cookie: Cookie) ?Cookie {
        for (self.entries.items) |*item| {
            if (std.mem.eql(u8, item.name, cookie.name)) {
                const ock = item.*;
                item.* = cookie;
                return ock;
            }
        }

        return null;
    }

    pub fn replaceOrPut(self: *Set, alloc: std.mem.Allocator, cookie: Cookie) !?Cookie {
        if (self.replace(cookie)) |o| {
            return o;
        } else {
            self.entries.append(alloc, cookie);
            return null;
        }
    }

    pub fn deinit(self: *Set, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    pub fn get(self: *const Set, key: []const u8) ?*const Cookie {
        for (self.entries.items) |*item| {
            if (std.mem.eql(u8, item.name, key)) {
                return item;
            }
        }

        return null;
    }
};
