//! Server manages connections and sessions.
//!
//! When new transcation is created, the callback will be executed.
//! The function signature must be:
//!
//! ````zig
//! fn (ud: ?*anyopaque, transcation: *Transcation) void,
//! ````
//!
//! Example:
//! ````zig
//! try haiya.GlobalContext.init(allocator);
//!
//! var server = try haiya.Server.init(io, handleRequest, null, allocator, .{});
//! try server.dispatch();
//! ````
//!
//! ## I/O Model
const std = @import("std");
const xev = @import("xev");
const Transcation = @import("./http/Transcation.zig");
const parkinglot = @import("parkinglot");
const Session = @import("./Session.zig");
const log = std.log.scoped(.Server);
const Stream = @import("./Stream.zig");
const FileSize = @import("./units.zig").FileSize;
const rio = @import("rio");
const ServerEvent = @import("./ServerEvent.zig");
const GlobalContext = @import("./GlobalContext.zig");

/// Structure lock, lock if you need to access the fields in this struct.
lock: parkinglot.Lock = .{},
/// The main ring for IO.
///
/// This ring is for accepting new connections and reading data for sessions.
///
/// The subrings will be used to write data.
io: rio.Ring,
callback: *const fn (ud: ?*anyopaque, transcation: *Transcation) void,
ud: ?*anyopaque,
allocator: std.mem.Allocator,
tcpSockets: std.ArrayListUnmanaged(Accept(rio.Fd)) = .{},
udpSockets: std.ArrayListUnmanaged(Accept(rio.Fd)) = .{},
cfg: Cfg,
threadpool: xev.ThreadPool,
status: Status = .Idle,
/// Session Trackings.
sessions: parkinglot.Mutex(std.ArrayListUnmanaged(*Session)) = .{ .value = .{} },
// Can we use an ECS instead of this dependecy-alike system?

onSqAvailable: parkinglot.Condition = .{},

trace: std.debug.Trace = std.debug.Trace.init,

const Server = @This();

pub const VCallback = *const fn (ud: ?*anyopaque, transcation: *Transcation) void;

pub fn Accept(T: type) type {
    return struct {
        server: *Server,
        address: std.net.Address,
        context: T,
    };
}

pub const Cfg = struct {
    bufferSize: usize = FileSize(usize).pack(16, .kibibyte).to(.byte).number(),
};

pub const Status = enum {
    Idle,
    Active,
    Stopping,
};

pub fn init(io: rio.Ring, callback: VCallback, ud: ?*anyopaque, alloc: std.mem.Allocator, cfg: Cfg) !Server {
    return Server{
        .io = io,
        .callback = callback,
        .ud = ud,
        .allocator = alloc,
        .cfg = cfg,
        .threadpool = xev.ThreadPool.init(.{}),
    };
}

/// Listen on a TCP address for HTTP/1.x or h2 transport.
pub fn tcpListen(self: *Server, address: std.net.Address) !*Accept(rio.Fd) {
    const tcp = try self.tcpSockets.addOne(self.allocator);
    errdefer _ = self.tcpSockets.pop();
    const proto: u32 = if (address.any.family == std.posix.AF.UNIX) 0 else std.posix.IPPROTO.TCP;
    tcp.* = .{
        .context = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            proto,
        ),
        .address = address,
        .server = self,
    };
    errdefer std.posix.close(tcp.context);
    try rio.os.bind(tcp.context, address);
    try rio.os.listen(tcp.context, 128);
    tcp.address = try rio.os.getsockname(tcp.context);

    return tcp;
}

pub fn createSession(self: *Server, fd: rio.Fd, transport: Session.Transport) !*Session {
    const n = try Session.create(self, fd, transport, self.allocator);
    errdefer n.destory();
    const sessions = self.sessions.lock();
    defer self.sessions.unlock();
    try sessions.append(self.allocator, n);
    return n;
}

fn runner(task: *xev.ThreadPool.Task) void {
    const cx: *TranscationContext = @fieldParentPtr("task", task);
    defer cx.destory();
    const self = cx.server;
    const transcation = cx.transcation;
    self.callback(self.ud, transcation);
}

fn handleTooManyRequests(transcation: *Transcation) !void {
    _ = transcation.resetResponse(.@"Too Many Requuests");
    try transcation.writeResponse();
    try transcation.stream.flush();
    transcation.deinit();
}

const TranscationContext = struct {
    task: xev.ThreadPool.Task,
    server: *Server,
    transcation: *Transcation,

    fn destory(self: *@This()) void {
        const server = self.server;
        server.allocator.destroy(self);
    }
};

fn submitTranscation(self: *Server, transcation: *Transcation) !void {
    const cx = try self.allocator.create(TranscationContext);
    cx.* = .{
        .transcation = transcation,
        .server = self,
        .task = .{
            .callback = Server.runner,
        },
    };
    self.threadpool.schedule(xev.ThreadPool.Batch.from(&cx.task));
    log.debug("transcation ${x} is submitted", .{@intFromPtr(transcation)});
}

pub inline fn call(self: *Server, transcation: *Transcation) void {
    self.submitTranscation(transcation) catch |err| {
        log.err("failed to spawn thread: {}", .{err});
        handleTooManyRequests(transcation) catch |e| {
            log.err("failed to respond with too many requests: {}", .{e});
        };
    };
}

pub fn deinit(self: *Server) void {
    self.threadpool.shutdown();
    self.lock.lock();
    while (self.tcpSockets.popOrNull()) |item| {
        rio.os.close(item.context);
    }
    self.tcpSockets.deinit(self.allocator);
    const sessions = self.sessions.lock();
    var unclosed: usize = 0;
    while (sessions.popOrNull()) |s| {
        unclosed += 1;
        while (s.streams.popOrNull()) |st| {
            for (0..self.io.cqReady()) |_| {
                _ = self.io.cqe() catch break;
            }
            st.close();
            st.destory();
        }
        for (0..self.io.cqReady()) |_| {
            _ = self.io.cqe() catch break;
        }
        s.destory();
    }
    log.info("{} session(s) is destoryed", .{unclosed});
    sessions.deinit(self.allocator);
    self.io.deinit();
    log.debug("${x} deinitialised", .{@intFromPtr(self)});
}

fn setupNewSession(self: *Server, subring: *rio.Ring, nfd: rio.Fd) !void {
    var dontClose = false; // Session.deinit includes close()
    errdefer if (!dontClose) {
        _ = subring.close(0, nfd) catch {};
    };
    const nsession = try self.createSession(nfd, .http1);
    errdefer nsession.destory();
    dontClose = true;
    nsession.lock.lock();
    defer nsession.lock.unlock();
    try nsession.setReadBuffer();
}

pub fn dispatch(self: *Server) !void {
    const ring = &self.io;
    defer {
        log.debug("leaving dispatch()", .{});
        self.lock.lock();
        defer self.lock.unlock();
        self.status = .Idle;
    }
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.status == .Idle) {
            self.status = .Active;
        } else {
            std.debug.panic("the server is already in use. {}", .{self.trace});
        }
        self.trace.add("the server is used here");
        for (self.tcpSockets.items) |*cx| {
            _ = ring.accept(@intFromPtr(cx), cx.context) catch unreachable;
        }
        _ = try ring.submit(0);
    }

    const tcpSocketStart = @intFromPtr(self.tcpSockets.items.ptr);
    const tcpSocketEnd = @intFromPtr(&self.tcpSockets.items[self.tcpSockets.items.len - 1]);

    log.debug("dispatch() is starting soon", .{});

    while (true) {
        const cqe = ring.cqe() catch |err| {
            log.err("fetch CQE error: {}", .{err});
            continue;
        };
        defer self.onSqAvailable.notifyOne();
        const ud = cqe.ud();
        if (ud == 0) {
            continue;
        }

        const isAccept = ud >= tcpSocketStart and
            ud <= tcpSocketEnd;

        if (isAccept) {
            const cx: *Accept(rio.Fd) = @ptrFromInt(ud);

            _ = try ring.accept(cqe.ud(), cx.context);

            const nfd = cqe.resAsAccept() catch |err| {
                log.err("accept error: {}", .{err});
                continue;
            };
            self.setupNewSession(ring, nfd) catch |err| {
                log.err("setup new session fail: {}", .{err});
            }; // Includes submit()
        } else {
            const oact: *ServerEvent = @ptrFromInt(ud);
            var act = oact.*;
            // The event may be from Session.closingEvent,
            // the memory will be unusable after the stream is destoryed.
            switch (act.operation) {
                .CloseStream => |st| {
                    if (st.inProgressTranscation) |_| {
                        _ = try self.io.nop(@intFromPtr(oact));
                        _ = try self.io.submit(0);
                    } else {
                        _ = act.session.findAndRemoveStream(st) catch {};
                        st.destory();

                        const canDestory = act.session.checkClosing() catch |err| waitForNextTurn: {
                            log.err("failed to check closing: {}", .{err});
                            _ = try self.io.nop(@intFromPtr(oact));
                            _ = try self.io.submit(0);
                            break :waitForNextTurn false;
                        };

                        if (canDestory) {
                            const sessions = self.sessions.lock();
                            defer self.sessions.unlock();
                            if (std.mem.indexOfScalar(*Session, sessions.items, act.session)) |idx| {
                                _ = sessions.orderedRemove(idx);
                            }
                            act.session.destory();
                        }
                    }
                },
                .CancelReadBuffer => |buffer| {
                    if (act.session.activeEvent) |_| {
                        act.session.activeEvent = null;
                        buffer.unref();
                    }

                    const canDestory = act.session.checkClosing() catch |err| waitForNextTurn: {
                        log.err("failed to check closing: {}", .{err});
                        _ = try self.io.nop(@intFromPtr(oact));
                        _ = try self.io.submit(0);
                        break :waitForNextTurn false;
                    };

                    if (canDestory) {
                        const sessions = self.sessions.lock();
                        defer self.sessions.unlock();
                        if (std.mem.indexOfScalar(*Session, sessions.items, act.session)) |idx| {
                            _ = sessions.orderedRemove(idx);
                        }
                        act.session.destory();
                    }
                },
                .CheckServerStatus => {
                    const status = getServerStatus: {
                        self.lock.lock();
                        defer self.lock.unlock();
                        break :getServerStatus self.status;
                    };
                    if (status == .Stopping) {
                        break;
                    }
                },
                .ReadBuffer => |buffer| {
                    act.session.receiveReadBuffer(
                        cqe,
                        buffer,
                    ) catch |err| {
                        log.err("session read error: {}", .{err});
                        act.session.close();
                    };
                },
            }
        }
    }
}

fn safeGetStatus(self: *Server) Status {
    self.lock.lock();
    defer self.lock.unlock();
    return self.status;
}

/// Stop the dispatching and all the running tasks.
/// This function only can be called when you sure the dispatch is running.
///
/// This function is thread-safe.
/// It holds the server's lock.
pub fn stop(self: *Server) void {
    log.debug("stopping: set status", .{});
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.status == .Active) {
            self.status = .Stopping;
        } else {
            log.warn("stopping: server is not in .Active status, skipped", .{});
            log.debug("stopping: the value is {}", .{self.status});
            return;
        }
    }
    log.debug("stopping: submit stop event", .{});
    const event = ServerEvent{
        .session = undefined, // Won't access it
        .operation = .CheckServerStatus,
    };
    while (self.safeGetStatus() == .Stopping) {
        _ = self.io.nop(@intFromPtr(&event)) catch {
            continue;
        };
        _ = self.io.submit(0) catch {
            continue;
        };
        break;
    }
    log.debug("stopping: wait for exiting", .{});
    while (self.safeGetStatus() != .Idle) {
        self.lock.lock();
        defer self.lock.unlock();
    }
}

pub const ServeOptions = struct {
    /// Specify the binding address.
    /// If `null`, random port on "127.0.0.1" will be choose.
    address: ?std.net.Address = null,
    /// Ring size for rio.
    ioQueueDepth: u16 = 256,
};

/// Quickly start a server. This structure is mainly for quick programs and tests.
///
/// The server is started at another thread, so the caller thread
/// can be used to do the main work.
///
/// This structure also manages the `GlobalContext`. Only one instance is allowed
/// at the same time.
///
/// ```zig
/// const served = try haiya.Server.Serve(*Context).create(
///     alloc,
///     handleRequest,
///     &context,
///     .{},
/// );
/// defer served.deinit();
/// ```
pub fn Serve(Ud: type) type {
    return struct {
        server: Server,
        /// The binding address
        address: std.net.Address,
        dispatchThread: std.Thread,
        hostText: [:0]const u8,
        handleFn: *const fn (self: Ud, t: *Transcation) anyerror!void,
        ud: Ud,

        const Context = @This();

        fn serverDispatchRun(self: *Context) !void {
            defer self.server.deinit();
            try self.server.dispatch();
        }

        fn wrappedHandleFn(ud: ?*anyopaque, t: *Transcation) void {
            const self: *Context = @alignCast(@ptrCast(ud));
            self.handleFn(self.ud, t) catch |err| {
                log.err("uncaught error: {}, stack trace: {?}", .{ err, @errorReturnTrace() });
            };
        }

        /// Create a Serve context and start the server in another thread.
        ///
        pub fn create(alloc: std.mem.Allocator, callback: *const fn (self: Ud, t: *Transcation) anyerror!void, ud: Ud, opts: ServeOptions) !*Context {
            try GlobalContext.init(alloc);
            errdefer GlobalContext.deinit();
            const self = try alloc.create(Context);
            var server = createServer: {
                const io = try rio.Ring.init(opts.ioQueueDepth, .{});
                errdefer io.deinit();
                break :createServer try Server.init(
                    io,
                    wrappedHandleFn,
                    self,
                    alloc,
                    .{},
                );
            };
            errdefer server.deinit();
            self.* = .{
                .server = server,
                .dispatchThread = undefined,
                .address = undefined,
                .handleFn = callback,
                .ud = ud,
                .hostText = undefined,
            };
            const accept = try self.server.tcpListen(opts.address orelse
                (std.net.Address.parseIp("127.0.0.1", 0) catch unreachable));
            self.address = accept.address;
            self.hostText = try std.fmt.allocPrintZ(alloc, "{}", .{self.address});
            errdefer alloc.free(self.hostText);
            self.dispatchThread = try std.Thread.spawn(
                .{ .allocator = alloc },
                Context.serverDispatchRun,
                .{self},
            );
            return self;
        }

        /// Stops the server and destory the Serve context.
        pub fn destory(self: *Context) void {
            const alloc = self.server.allocator;
            alloc.free(self.hostText);
            self.server.stop();
            self.dispatchThread.join();
            GlobalContext.deinit();
            alloc.destroy(self);
        }

        pub fn baseUrl(self: *Context) std.Uri {
            return std.Uri{ .scheme = "http", .host = .{ .raw = self.hostText } };
        }
    };
}
