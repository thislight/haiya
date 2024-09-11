const std = @import("std");
const parkinglot = @import("parkinglot");

pub const ChannelError = error{
    Closed,
};

pub fn Send(T: type) type {
    return struct {
        target: ?*Recv(T) = null,

        const Self = @This();

        pub fn put(self: *Self, value: T) ChannelError!void {
            self.target.lock.lock();
            defer self.target.lock.unlock();
            while (true) {
                if (self.target) |target| {
                    switch (target.state) {
                        .Idle => break,
                        else => target.condition.wait(&target.lock),
                    }
                } else {
                    return error.Closed;
                }
            }

            self.target.state = .{ .Received = value };
            self.target.condition.notifyAll();
        }

        pub fn close(self: *Self) void {
            self.target.close();
        }
    };
}

pub fn Recv(T: type) type {
    return struct {
        lock: parkinglot.Lock = .{},
        condition: parkinglot.Condition = .{},
        state: State = .Idle,
        sender: ?*Send(T) = null,

        const Self = @This();

        const State = struct {
            Idle: void,
            Received: T,
        };

        pub fn get(self: *Self) ChannelError!T {
            self.lock.lock();
            defer self.lock.unlock();
            while (true) {
                switch (self.state) {
                    .Idle => {
                        if (self.sender == null) {
                            return error.Closed;
                        }
                        self.condition.wait(&self.lock);
                    },
                    .Received => |value| {
                        defer self.state = .Idle;
                        defer self.condition.notifyAll();
                        return value;
                    },
                }
            }
        }

        pub fn close(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.sender.target = null;
            self.sender = null;
            self.condition.notifyAll();
        }
    };
}

pub fn Port(R: type, O: type) type {
    return struct {
        from: Recv(R) = .{},
        to: Send(O) = .{},

        const Self = @This();

        pub fn recv(self: *Self) !R {
            return try self.from.get();
        }

        pub fn send(self: *Self, value: O) ChannelError!O {
            return try self.to.put(value);
        }

        pub fn close(self: *Self) void {
            self.from.close();
            self.to.close();
        }

        pub fn connect(self: *Self, other: *Port(O, R)) void {
            other.to.target = &self.from;
            self.to.target = &other.from;
            other.from.sender = &self.to;
            self.from.sender = &other.to;
        }
    };
}

/// Create a pair of ports. They are allocated with Allocator to ensure
/// their addresses are pinned.
///
/// The two ports are separatly allocated. You must ensure no one waiting on them
/// before destorying them.
pub fn channel(T: type, K: type, alloc: std.mem.Allocator) !std.meta.Tuple(&[_]type{ *Port(T, K), *Port(K, T) }) {
    const p0 = try alloc.create(Port(T, K));
    errdefer alloc.destroy(p0);
    p0.* = .{};
    const p1 = try alloc.create(Port(K, T));
    errdefer alloc.destroy(p1);
    p1.* = .{};
    p0.connect(p1);
    return .{ p0, p1 };
}

pub fn Promise(T: type) type {
    return struct {
        state: State,
        recv: Recv(State),

        const State = union(enum) {
            Wait: void,
            Success: T,
            Error: struct {
                err: anyerror,
                stacktrace: ?*std.builtin.StackTrace,
            },
        };
    };
}

pub fn Resolver(T: type) type {
    return struct {
        send: Send(Promise(T).State),
    };
}
