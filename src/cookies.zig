const Transcation = @import("./http/Transcation.zig");
pub const RawCookie = @import("./http/cookies.zig").Cookie;
pub const Set = @import("./http/cookies.zig").Set;

pub fn Cookie(comptime key: []const u8) type {
    return struct {
        cx: *Transcation,

        /// Get the cookie value.
        pub fn get(self: @This()) ?[]const u8 {
            const c = self.cx.request.headers.getCookie(key) orelse return null;
            return c.value;
        }

        /// Set the cookie value. This function uses the arena allocator from `Transcation`.
        pub fn set(self: @This(), value: []const u8, cfg: RawCookie.Cfg) !void {
            try self.cx.response.headers.replaceOrPutCookie(self.cx.arena(), .{
                .name = key,
                .value = value,
                .cfg = cfg,
            });
        }

        pub fn inject(t: *Transcation) @This() {
            return .{ .cx = t };
        }
    };
}
