const std = @import("std");
const Ring = @import("../poll.zig");
const Fd = @import("../posix.zig").Fd;
const errors = @import("../errors.zig");

source: *Ring,
sqe: Submission,
cqe: ?Completion,

const Work = @This();

pub const Queue = std.DoublyLinkedList(Work);

pub const Op = enum {
    NOP,
    CLOSE,
    ACCEPT,
    ASYNC_CANCEL,
    SEND,
    RECV,
};

pub const Request = union(Op) {
    NOP: void,
    CLOSE: Fd,
    ACCEPT: Fd,
    ASYNC_CANCEL: u64,
    SEND: Send,
    RECV: Recv,

    const Send = struct {
        fd: Fd,
        src: []const u8,
    };

    const Recv = struct {
        fd: Fd,
        dst: []u8,
    };
};

pub const Submission = struct {
    op: Request,
    udata: u64,

    pub fn send(self: *Submission, fd: Fd, src: []const u8) void {
        self.op = .{ .SEND = .{
            .fd = fd,
            .src = src,
        } };
    }

    pub fn nop(self: *Submission) void {
        self.op = .NOP;
    }

    pub fn accept(self: *Submission, fd: Fd) void {
        self.op = .{ .ACCEPT = fd };
    }

    pub fn recv(self: *Submission, fd: Fd, dst: []u8) void {
        self.op = .{ .RECV = .{
            .fd = fd,
            .dst = dst,
        } };
    }

    pub fn close(self: *Submission, fd: Fd) void {
        self.op = .{ .CLOSE = fd };
    }

    pub fn cancel(self: *Submission, udMatch: u64) void {
        self.op = .{ .ASYNC_CANCEL = udMatch };
    }

    pub fn ud(self: *Submission, uda: u64) void {
        self.udata = uda;
    }
};

pub const Completion = struct {
    ret: anyerror!u31,
    udata: u64,

    pub fn ud(self: Completion) u64 {
        return self.udata;
    }

    pub fn resAsSend(self: Completion) errors.SendError!u31 {
        if (self.ret) |code| {
            return code;
        } else |err| {
            return @as(errors.SendError, @errorCast(err));
        }
    }

    pub fn resAsAccept(self: Completion) errors.AcceptError!Fd {
        if (self.ret) |code| {
            return code;
        } else |err| {
            return @as(errors.AcceptError, @errorCast(err));
        }
    }

    pub fn resAsRecv(self: Completion) errors.RecvError!u31 {
        if (self.ret) |code| {
            return code;
        } else |err| {
            return @as(errors.RecvError, @errorCast(err));
        }
    }

    pub fn resAsClose(self: Completion) errors.CloseError!void {
        _ = self;
        return;
    }

    pub fn resAsCancel(self: Completion) errors.CancelError!void {
        if (self.ret) |_| {
            return;
        } else |err| {
            return @as(errors.CancelError, @errorCast(err));
        }
    }
};

pub fn setComplete(self: *@This(), ret: anyerror!u31) void {
    self.cqe = .{ .ret = ret, .udata = self.sqe.udata };
    self.source.cq.append(@fieldParentPtr("data", self));
}
