const std = @import("std");
const parkinglot = @import("parkinglot");
const Work = @import("./Work.zig");
const po = std.posix;

lock: parkinglot.Lock = .{},
refc: usize = 0,
interests: std.ArrayListUnmanaged(std.posix.pollfd) = .{},
interestedWorks: std.ArrayListUnmanaged(*Work) = .{},
gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},

const Workgroup = @This();

pub fn ref(self: *Workgroup) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.refc += 1;
}

pub fn unref(self: *Workgroup) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.refc -= 1;
    if (self.refc == 0) {
        std.debug.assert(self.gpa.deinit() == .ok);
    }
}

pub fn enter(self: *Workgroup, wait_n: u32) !void {
    var n: usize = 0;
    while (wait_n > n) {
        self.lock.lock();
        defer self.lock.unlock();
        _ = try po.poll(self.interests.items, 1);
        for (self.interests.items, 0..self.interests.items.len) |pollfd, idx| {
            const work = self.interestedWorks.items[idx];
            if (pollfd.revents & po.POLL.IN > 0) {
                switch (work.sqe.op) {
                    .RECV => |r| {
                        const rsize = po.recv(pollfd.fd, r.dst, po.SOCK.NONBLOCK) catch |err| switch (err) {
                            po.RecvFromError.WouldBlock => continue,
                            else => {
                                work.setComplete(err);
                                n += 1;
                                continue;
                            },
                        };
                        work.setComplete(@intCast(rsize));
                        n += 1;
                    },
                    .ACCEPT => |fd| {
                        const nfd = po.accept(fd, null, null, po.SOCK.NONBLOCK) catch |err| switch (err) {
                            po.AcceptError.WouldBlock => continue,
                            else => {
                                work.setComplete(err);
                                n += 1;
                                continue;
                            },
                        };
                        work.setComplete(@intCast(nfd));
                        n += 1;
                    },
                    else => unreachable,
                }
            } else if (pollfd.revents & po.POLL.OUT > 0) {
                const src = work.sqe.op.SEND.src;
                const wsize = po.send(pollfd.fd, src, po.SOCK.NONBLOCK) catch |err| switch (err) {
                    po.SendError.WouldBlock => continue,
                    else => {
                        work.setComplete(err);
                        n += 1;
                        continue;
                    },
                };
                work.setComplete(@intCast(wsize));
                n += 1;
            }
        }

        {
            var idx: usize = 0;
            while (self.interestedWorks.items.len > idx) {
                const item = self.interestedWorks.items[idx];
                if (item.cqe != null) {
                    _ = self.interestedWorks.swapRemove(idx);
                    _ = self.interests.swapRemove(idx);
                    continue;
                }
                idx += 1;
            }
        }
    }
}

fn searchAndCancel(self: *Workgroup, ud: u64) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (self.interestedWorks.items.len > idx) {
        const work = self.interestedWorks.items[idx];
        if (work.sqe.udata == ud) {
            count += 1;
            _ = self.interestedWorks.swapRemove(idx);
            _ = self.interests.swapRemove(idx);
            continue;
        }
        idx += 1;
    }
    return count;
}

const CancelResult = enum {
    NotFound,
    NotCancelled,
    Cancelled,
};

fn searchAndCancelFirst(self: *Workgroup, ud: u64) CancelResult {
    var idx: usize = 0;
    while (self.interestedWorks.items.len > idx) {
        const work = self.interestedWorks.items[idx];
        if (work.sqe.udata == ud) {
            if (work.cqe) |_| {
                return .NotCancelled;
            } else {
                _ = self.interestedWorks.swapRemove(idx);
                _ = self.interests.swapRemove(idx);
                return .Cancelled;
            }
        }
        idx += 1;
    }
    return .NotFound;
}

pub fn submit(self: *Workgroup, work: *Work) !void {
    switch (work.sqe.op) {
        .NOP => {
            work.setComplete(0);
        },
        .CLOSE => |fd| {
            po.close(fd);
            work.setComplete(@intCast(fd));
        },
        .ACCEPT => |fd| {
            try self.interests.append(self.gpa.allocator(), .{ .fd = fd, .events = po.POLL.IN, .revents = 0 });
            errdefer _ = self.interests.swapRemove(self.interests.items.len - 1);
            try self.interestedWorks.append(self.gpa.allocator(), work);
        },
        .ASYNC_CANCEL => |ud| {
            const n = self.searchAndCancelFirst(ud);
            work.setComplete(switch (n) {
                .NotFound => error.NotEntity,
                .NotCancelled => error.Already,
                .Cancelled => 0,
            });
        },
        .SEND => |p| {
            try self.interests.append(self.gpa.allocator(), .{ .fd = p.fd, .events = po.POLL.OUT, .revents = 0 });
            errdefer _ = self.interests.swapRemove(self.interests.items.len - 1);
            try self.interestedWorks.append(self.gpa.allocator(), work);
        },
        .RECV => |p| {
            try self.interests.append(self.gpa.allocator(), .{ .fd = p.fd, .events = po.POLL.IN, .revents = 0 });
            errdefer _ = self.interests.swapRemove(self.interests.items.len - 1);
            try self.interestedWorks.append(self.gpa.allocator(), work);
        },
    }
}
