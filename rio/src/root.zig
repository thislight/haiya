const builtin = @import("builtin");

pub const Backend = enum {
    IoUring,
    Poll,
    EPoll,
};

fn selectBackend() ?Backend {
    return switch (builtin.target.os.tag) {
        .linux => linux: {
            if (builtin.target.os.isAtLeast(.linux, .{
                .major = 5,
                .minor = 15,
                .patch = 0,
            }) orelse false) {
                break :linux .IoUring;
            } else if (builtin.target.os.isAtLeast(.linux, .{
                .major = 2,
                .minor = 5,
                .patch = 44,
            }) orelse false) {
                break :linux .EPoll;
            } else {
                break :linux .Poll;
            }
        },
        .windows => .Poll,
        .macos, .ios, .tvos, .watchos => .Poll,
        .wasi => .Poll,
        else => null,
    };
}

pub const backend: ?Backend = @as(?Backend, .IoUring) orelse selectBackend();

pub const Ring = switch (backend orelse @compileError("could not detect backend, you can still specify backend manually")) {
    .IoUring => @import("./Ring/io_uring.zig"),
    else => @compileError("unknown backend: " ++ @tagName(backend.?)),
};

pub const Fd = Ring.Fd;

pub const InitError = Ring.InitError;
pub const AcceptError = Ring.AcceptError;
pub const RecvError = Ring.RecvError;
pub const SendError = Ring.SendError;
pub const CloseError = Ring.CloseError;
pub const CancelError = Ring.CancelError;
pub const GetSqeError = Ring.GetSqeError;
