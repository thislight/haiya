const std = @import("std");
const lx = std.os.linux;
const errors = @import("./errors.zig");
const log = std.log.scoped(.IoUring);

raw: lx.IoUring,

const Ring = @This();

pub const Fd = lx.fd_t;

pub const Op = lx.IORING_OP;

pub const Submission = opaque {
    fn raw(self: *Submission) *lx.io_uring_sqe {
        return @alignCast(@ptrCast(self));
    }

    fn rawConst(self: *const Submission) *const lx.io_uring_sqe {
        return @ptrCast(self);
    }

    pub fn accept(self: *Submission, fd: Fd) void {
        self.raw().prep_accept(fd, null, null, 0);
    }

    pub fn recv(self: *Submission, fd: Fd, buffer: []u8) void {
        self.raw().prep_recv(fd, buffer, 0);
    }

    pub fn send(self: *Submission, fd: Fd, buffer: []const u8) void {
        self.raw().prep_send(fd, buffer, 0);
    }

    pub fn close(self: *Submission, fd: Fd) void {
        self.raw().prep_close(fd);
    }

    pub fn nop(self: *Submission) void {
        self.raw().prep_nop();
    }

    pub fn cancel(self: *Submission, cancelUd: u64) void {
        self.raw().prep_cancel(cancelUd, 0);
    }

    pub fn ud(self: *Submission, udata: u64) void {
        self.raw().user_data = udata;
    }

    pub fn udPtr(self: *Submission, ptr: ?*anyopaque) void {
        self.raw().user_data = @ptrFromInt(ptr);
    }

    pub fn operation(self: *const Submission) Op {
        return self.rawConst().opcode;
    }
};

pub const RecvError = errors.RecvError;

pub const AcceptError = errors.AcceptError;

pub const SendError = errors.SendError;

pub const CloseError = errors.CloseError;

pub const CancelError = errors.CancelError;

pub const Completion = struct {
    raw: lx.io_uring_cqe,

    pub fn res(self: Completion) i32 {
        return self.raw.res;
    }

    pub fn ud(self: Completion) u64 {
        return self.raw.user_data;
    }

    pub fn flags(self: Completion) u32 {
        return self.raw.flags;
    }

    pub fn err(self: Completion) lx.E {
        return self.raw.err();
    }

    pub fn resAsRecv(self: Completion) RecvError!u31 {
        return switch (self.err()) {
            .SUCCESS => @intCast(self.res()),
            .AGAIN => RecvError.WouldBlock,
            .BADF => RecvError.NetworkSubsystemFailed,
            .CONNREFUSED => RecvError.ConnectionRefused,
            .FAULT => RecvError.Unexpected,
            .INTR => RecvError.Unexpected,
            .INVAL => RecvError.Unexpected,
            .NOTCONN => RecvError.SocketNotConnected,
            .NOTSOCK => RecvError.Unexpected,
            .CONNRESET => RecvError.ConnectionResetByPeer,
            else => |v| blk: {
                log.err("resAsRecv() unknown code {}", .{v});
                break :blk RecvError.Unexpected;
            },
        };
    }

    pub fn resAsAccept(self: Completion) AcceptError!Fd {
        return switch (self.err()) {
            .SUCCESS => self.res(),
            .AGAIN => AcceptError.WouldBlock,
            .BADF => AcceptError.Unexpected,
            .NOTSOCK => AcceptError.FileDescriptorNotASocket,
            .OPNOTSUPP => AcceptError.OperationNotSupported,
            .FAULT => AcceptError.Unexpected,
            .PERM => AcceptError.BlockedByFirewall,
            .NOMEM, .NOBUFS => AcceptError.SystemResources,
            else => AcceptError.Unexpected,
        };
    }

    pub fn resAsSend(self: Completion) SendError!u31 {
        return switch (self.err()) {
            .SUCCESS => @intCast(self.res()),
            .BADF => SendError.Unexpected,
            .NOTSOCK => SendError.FileDescriptorNotASocket,
            .FAULT => SendError.Unexpected,
            .MSGSIZE => SendError.MessageTooBig,
            .AGAIN => SendError.WouldBlock,
            .NOBUFS => SendError.SystemResources,
            .INTR => SendError.Unexpected,
            .NOMEM => SendError.Unexpected,
            .INVAL => SendError.Unexpected,
            .PIPE => SendError.BrokenPipe,
            else => SendError.Unexpected,
        };
    }

    pub fn resAsClose(self: Completion) CloseError!void {
        return switch (self.err()) {
            .SUCCESS => {},
            .BADF => CloseError.BadFd,
            .INTR => CloseError.Intrrupted,
            .IO => CloseError.IO,
            else => CloseError.Unexpected,
        };
    }

    pub fn resAsCancel(self: Completion) CancelError!void {
        return switch (self.err()) {
            .SUCCESS => {},
            .NOENT => CancelError.NoEntity,
            .INVAL => CancelError.Invalid,
            .ALREADY => CancelError.Already,
            else => CancelError.Unexpected,
        };
    }

    /// `true` if the socket have more data can be read.
    pub fn sockNonEmpty(self: Completion) bool {
        return (self.raw.flags & lx.IORING_CQE_F_SOCK_NONEMPTY) > 0;
    }

    pub fn sqNeedWakeup(self: Completion) bool {
        return (self.raw.flags & lx.IORING_SQ_NEED_WAKEUP) > 0;
    }
};

pub const GetSqeError = @typeInfo(@typeInfo(@TypeOf(lx.IoUring.get_sqe)).Fn.return_type.?).ErrorUnion.error_set;

pub fn sqe(self: *Ring) !*Submission {
    const ptr = try self.raw.get_sqe();
    return @ptrCast(ptr);
}

/// Submit submissions and wait for `wait_nr` completion(s).
///
/// Returns the number of SQE(s) submitted.
pub fn submit(self: *Ring, wait_nr: u32) !u32 {
    return self.raw.submit_and_wait(wait_nr);
}

pub const EnterFlags = packed struct {
    getEvents: bool = false,

    pub fn toInt(self: @This()) u32 {
        var result: u32 = 0;
        if (self.getEvents) {
            result &= lx.IORING_ENTER_GETEVENTS;
        }
        return result;
    }
};

pub fn enter(self: *Ring, to_submit: u32, min_complete: u32, flags: EnterFlags) !u32 {
    return try self.raw.enter(
        to_submit,
        min_complete,
        flags.toInt(),
    );
}

/// Options for initialisation.
///
/// For best compatibility, only sets a field when you need it to be `true`.
/// Some options may be omitted for some backend since it's impossible on these targets.
/// Like you could not support `sqPoll` on cloudflare worker.
pub const InitFlags = packed struct {
    /// Asks for a separate thread to poll on the SQ.
    ///
    /// If this flag specified, the kernel will starts kthreads to
    /// poll on the SQ. So you don't need to do `Ring.enter()` in userspace
    /// (this is automatically decided by `Ring.cqe()`).
    ///
    /// The thread may sleep if the SQ is idle for a certain millseconds.
    /// In this situation, `Completion.sqNeedWakeup()` returns `true`.
    /// When this happens, a call to `Ring.enter()` is needed to wake up the thread.
    /// The thread never sleeps while the IO is kept busy.
    ///
    /// **For `.IoUring` backend**:
    /// Before Linux 5.11, the fds used in this mode must be registered by
    /// `io_uring_register(2)`  - this case is not supported by rio
    /// (the function is not even provided).
    ///
    /// Linux 5.11 and 5.12 allow this mode for a non-root user as the user
    /// has `CAP_SYS_NICE`. The requirement is further relaxed in 5.13, as no
    /// special privileges is needed for SQPOLL.
    /// Certain stale kernels older than 5.13 may also support this feature.
    ///
    /// Auto dectection requires Linux 5.15 for `.IoUring` backend, which is by
    /// default no privileges needed.
    sqPoll: bool = false,
    /// A hint that the requests will come from a single task (or thread).
    ///
    /// **For `.IoUring` backend**:
    /// The submission task is either the task enables the ring
    /// (from a `IORING_SETUP_R_DISABLED` ring), or the task creates the ring.
    /// Available since Linux 6.0.
    singleIssuer: bool = false,

    pub fn toInt(self: @This()) u32 {
        var result: u32 = 0;
        if (self.sqPoll) {
            result |= lx.IORING_SETUP_SQPOLL;
        }
        if (self.singleIssuer) {
            result |= lx.IORING_SETUP_SINGLE_ISSUER;
        }
        return result;
    }
};

pub const InitError = @typeInfo(@typeInfo(@TypeOf(lx.IoUring.init_params)).Fn.return_type.?).ErrorUnion.error_set;

pub fn init(entries: u16, flags: InitFlags) InitError!Ring {
    const raw = try lx.IoUring.init(entries, flags.toInt());
    return .{ .raw = raw };
}

pub fn deinit(self: *Ring) void {
    self.raw.deinit();
}

pub fn sqReady(self: *Ring) u32 {
    return self.raw.sq_ready();
}

pub fn cqe(self: *Ring) !Completion {
    return .{ .raw = try self.raw.copy_cqe() };
}

pub fn cqReady(self: *Ring) u32 {
    return self.raw.cq_ready();
}

/// Create a subring.
pub fn from(self: *Ring, entries: u16, flags: InitFlags) InitError!Ring {
    var params = std.mem.zeroInit(lx.io_uring_params, .{
        .wq_fd = @as(u31, @intCast(self.raw.fd)),
        .flags = flags.toInt() | lx.IORING_SETUP_ATTACH_WQ,
        .sq_thread_idle = 1000,
    });
    const raw = try lx.IoUring.init_params(entries, &params);
    return .{ .raw = raw };
}

pub fn accept(self: *Ring, ud: u64, fd: Fd) !*Submission {
    const e = try self.sqe();
    e.accept(fd);
    e.ud(ud);
    return e;
}

pub fn close(self: *Ring, ud: u64, fd: Fd) !*Submission {
    const e = try self.sqe();
    e.close(fd);
    e.ud(ud);
    return e;
}

pub fn recv(self: *Ring, ud: u64, fd: Fd, dst: []u8) !*Submission {
    const e = try self.sqe();
    e.recv(fd, dst);
    e.ud(ud);
    return e;
}

pub fn send(self: *Ring, ud: u64, fd: Fd, src: []const u8) !*Submission {
    const e = try self.sqe();
    e.send(fd, src);
    e.ud(ud);
    return e;
}

pub fn nop(self: *Ring, ud: u64) !*Submission {
    const e = try self.sqe();
    e.nop();
    e.ud(ud);
    return e;
}

pub fn cancel(self: *Ring, ud: u64, cancelUd: u64) !*Submission {
    const e = try self.sqe();
    e.cancel(cancelUd);
    e.ud(ud);
    return e;
}

pub const os = @import("./posix.zig");
