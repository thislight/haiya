const std = @import("std");
const parkinglot = @import("parkinglot");
const po = std.posix;
const Work = @import("./poll/Work.zig");
const Workgroup = @import("./poll/Workgroup.zig");
const errors = @import("./errors.zig");

lock: parkinglot.Lock = .{},
workgrp: *Workgroup,
pool: std.heap.MemoryPoolExtra(Work.Queue.Node, .{ .growable = false }),

sq: std.DoublyLinkedList(Work) = .{},
flushedSqeCount: u32 = 0,

cq: std.DoublyLinkedList(Work) = .{},

pub const Fd = @import("./posix.zig").Fd;

pub const Op = Work.Op;

pub const RecvError = errors.RecvError;
pub const SendError = errors.SendError;
pub const CloseError = errors.CloseError;
pub const CancelError = errors.CancelError;

pub const Submission = Work.Submission;

pub const Completion = Work.Completion;

const Ring = @This();

pub const InitFlags = struct {};

pub const InitError = std.mem.Allocator.Error;

pub fn init(entries: u32, _: InitFlags) !Ring {
    const wg = try std.heap.page_allocator.create(Workgroup);
    errdefer std.heap.page_allocator.destroy(wg);
    wg.* = .{};
    wg.ref();
    errdefer wg.unref();

    var pool = try std.heap.MemoryPoolExtra(Work.Queue.Node, .{ .growable = false })
        .initPreheated(wg.gpa.allocator(), entries);
    errdefer pool.deinit();

    return .{
        .workgrp = wg,
        .pool = pool,
    };
}

pub fn deinit(self: *Ring) void {
    self.pool.deinit();
    self.workgrp.unref();
    self.* = undefined;
}

pub fn sqe(self: *Ring) !*Submission {
    self.lock.lock();
    defer self.lock.unlock();

    const node = self.pool.create() catch return error.SubmissionQueueFull;
    node.* = .{ .data = .{ .source = self, .sqe = .{
        .op = .NOP,
        .udata = 0,
    }, .cqe = null } };

    self.sq.append(node);

    return &node.data.sqe;
}

fn flushSq(self: *Ring, to_submit: u32) !u32 {
    var submited: u32 = 0;

    {
        self.workgrp.lock.lock();
        defer self.workgrp.lock.unlock();
        while (self.sq.popFirst()) |node| {
            try self.workgrp.submit(&node.data);
            submited += 1;
            if (submited >= to_submit) {
                break;
            }
        }
    }

    self.flushedSqeCount += 1;

    return submited;
}

fn enterUntilComplete(self: *Ring, min_complete: u32) !u32 {
    const nstart = self.cq.len;
    while ((self.cq.len - nstart) < min_complete) {
        const requiredN = min_complete - @as(u32, @intCast(self.cq.len - nstart));
        try self.workgrp.enter(@min(requiredN, std.math.maxInt(u32)));
    }
    return @intCast(self.cq.len - nstart);
}

pub const EnterFlags = struct {};

pub fn enter(self: *Ring, to_submit: u32, min_complete: u32, flags: EnterFlags) !u32 {
    _ = flags;
    self.lock.lock();
    defer self.lock.unlock();

    if (to_submit > 0) {
        _ = try self.flushSq(to_submit);
    }

    return try self.enterUntilComplete(min_complete);
}

pub fn submit(self: *Ring, wait_n: u32) !u32 {
    return try self.enter(std.math.maxInt(u32), wait_n, .{});
}

pub const FromFlags = struct {};

pub fn from(self: *Ring, entries: u32, flags: FromFlags) !Ring {
    _ = flags;
    self.workgrp.ref();
    errdefer self.workgrp.unref();

    var pool = try std.heap.MemoryPoolExtra(Work.Queue.Node, .{ .growable = false })
        .initPreheated(self.workgrp.gpa.allocator(), entries);
    errdefer pool.deinit();

    return .{
        .workgrp = self.workgrp,
        .pool = pool,
    };
}

pub fn cqReady(self: Ring) u32 {
    return @intCast(self.cq.len);
}

pub fn sqReady(self: Ring) u32 {
    return @as(u32, @intCast(self.sq.len)) + self.flushedSqeCount; // FIXME: include flushed sqes
}

pub fn cqe(self: *Ring) !Completion {
    while (true) {
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.cq.popFirst()) |node| {
                defer self.pool.destroy(node);
                self.flushedSqeCount -= 1;
                return node.data.cqe.?;
            }
        }

        _ = try self.enter(0, 1, .{});
    }
}

pub fn nop(self: *Ring, ud: u64) !*Submission {
    const e = try self.sqe();
    e.nop();
    e.ud(ud);
    return e;
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

pub fn cancel(self: *Ring, ud: u64, udMatch: u64) !*Submission {
    const e = try self.sqe();
    e.cancel(udMatch);
    e.ud(ud);
    return e;
}

pub const os = @import("./posix.zig");
