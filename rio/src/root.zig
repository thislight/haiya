const builtin = @import("builtin");

pub const Backend = enum {
    /// the asynchronous syscall interface on the linux kernel.
    IoUring,
    /// poll(2) is a POSIX API to fetch events on file descriptors.
    Poll,
    /// e(xtended) poll is a linux API to fetch events on file descriptors.
    /// (not implemented)
    EPoll,
};

pub const backend: Backend = @enumFromInt(@intFromEnum(@import("build_opts").backend));

pub const Ring = switch (backend) {
    .IoUring => @import("./Ring/io_uring.zig"),
    .Poll => @import("./Ring/poll.zig"),
    .EPoll => @compileError("TODO"),
};

pub const Fd = Ring.Fd;
pub const os = Ring.os;

pub const InitError = Ring.InitError;
pub const AcceptError = Ring.AcceptError;
pub const RecvError = Ring.RecvError;
pub const SendError = Ring.SendError;
pub const CloseError = Ring.CloseError;
pub const CancelError = Ring.CancelError;
pub const GetSqeError = Ring.GetSqeError;
