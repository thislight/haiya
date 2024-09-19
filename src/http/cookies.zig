const std = @import("std");
const Headers = @import("./Headers.zig");

/// The cookie.
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

    /// Configuration of a cookie.
    pub const Cfg = struct {
        /// Matching domain
        domain: []const u8 = &.{},
        /// Matching path
        path: []const u8 = &.{},
        expires: ?void = null, // std does not have date processing
        /// This cookie should be only set under a secure context.
        secure: bool = false,
        /// This cookie only should be accessed via HTTP.
        httponly: bool = false,
        /// The same-site policy
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

/// Set of the cookies.
pub const Set = struct {
    entries: std.ArrayListUnmanaged(Cookie) = .{},

    /// Replace the cookie. Return the old cookie.
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

    /// Replace an existing cookie, or put a new cookie.
    pub fn replaceOrPut(self: *Set, alloc: std.mem.Allocator, cookie: Cookie) !?Cookie {
        if (self.replace(cookie)) |o| {
            return o;
        } else {
            self.entries.append(alloc, cookie);
            return null;
        }
    }

    /// Deinitialise the list.
    pub fn deinit(self: *Set, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    /// Search a cookie by name.
    pub fn get(self: *const Set, key: []const u8) ?*const Cookie {
        for (self.entries.items) |*item| {
            if (std.mem.eql(u8, item.name, key)) {
                return item;
            }
        }

        return null;
    }
};
