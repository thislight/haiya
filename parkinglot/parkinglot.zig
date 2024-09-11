//! Fast and small locks.
//! This implementation based on WebKit's https://webkit.org/blog/6161/locking-in-webkit/
const std = @import("std");
const builtin = @import("builtin");
const typetool = @import("typetool");
const futex = std.Thread.Futex;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const assert = std.debug.assert;

fn sched_yield() !void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.sched_yield(),
        .wasi => _ = std.os.wasi.sched_yield(),
        else => try std.Thread.yield(),
    }
}

const ThreadData = struct {
    shouldPark: bool = false,
    futexMark: Atomic(u32) = Atomic(u32).init(0),
    next: ?*ThreadData = null,
    tail: ?*ThreadData = null,
    firstTimeParking: bool = true,

    switchToWaiting: Atomic(bool) = Atomic(bool).init(false),
};

threadlocal var perThreadData = ThreadData{};

var gParkingLot: ?ParkingLot = null;

pub const ParkingLot = struct {
    alloc: Allocator,
    lot: *Lot,

    const Self = @This();
    const hashCtx = std.array_hash_map.AutoContext(usize){};

    fn init(alloc: Allocator) Allocator.Error!Self {
        var lot = try Lot.init(alloc, 1);
        errdefer lot.deinit();
        return Self{
            .alloc = alloc,
            .lot = lot,
        };
    }

    /// Call this function when program just started.
    pub fn initGlobal(alloc: Allocator) Allocator.Error!void {
        if (gParkingLot == null) {
            gParkingLot = try Self.init(alloc);
        }
    }

    pub fn isGlobalInitialised() bool {
        return gParkingLot != null;
    }

    fn deinit(self: *Self) void {
        self.lot.freeAll();
        self.lot.deinit();
    }

    /// Call this function when program is going to exit.
    pub fn deinitGlobal() void {
        if (gParkingLot) |*g| {
            g.deinit();
            gParkingLot = null;
        }
    }

    const Lot = struct {
        refcnt: Atomic(usize),
        buckets: []*Bucket,
        alloc: Allocator,
        old: ?*Lot,

        pub fn init(alloc: Allocator, bucketN: usize) Allocator.Error!*Lot {
            return expandFrom(alloc, bucketN, null);
        }

        fn expandFrom(alloc: Allocator, bucketN: usize, old: ?*Lot) Allocator.Error!*Lot {
            const buckets = try expandBucketN(alloc, bucketN, if (old) |oldObj| oldObj.buckets else &.{});
            errdefer destroyBuckets(alloc, buckets);
            const object = try alloc.create(Lot);
            errdefer alloc.destroy(object);
            object.* = Lot{
                .refcnt = Atomic(usize).init(if (old) |oldObj| oldObj.refcnt.raw else 0),
                .buckets = buckets,
                .alloc = alloc,
                .old = old,
            };
            return object;
        }

        fn expandBucketN(alloc: Allocator, bucketN: usize, old: []*Bucket) Allocator.Error![]*Bucket {
            assert(bucketN >= old.len);
            var newSli = try alloc.alloc(*Bucket, bucketN);
            errdefer alloc.free(newSli);
            std.mem.copyForwards(*Bucket, newSli, old);
            for (newSli[old.len..bucketN], old.len..bucketN) |*ptr, i| {
                errdefer {
                    for (newSli[old.len .. old.len + i]) |obj| {
                        alloc.destroy(obj);
                    }
                }
                ptr.* = try alloc.create(Bucket);
                ptr.*.* = Bucket{
                    .head = null,
                    .tail = null,
                };
            }
            return newSli;
        }

        fn destroyBuckets(alloc: Allocator, buckets: []*Bucket) void {
            for (buckets) |bptr| {
                alloc.destroy(bptr);
            }
            alloc.free(buckets);
        }

        /// Enqueue thread.
        /// That will wait of wake from `thread.futexMark`.
        pub fn enqueue(self: *Lot, lockAddr: usize, thread: *ThreadData, validation: anytype, beforeSleep: anytype, timeout: ?u64) Allocator.Error!bool {
            {
                var bucket = self.getBucket(lockAddr, self.buckets.len);
                bucket.safelock();
                defer bucket.safeunlock();
                if (@typeInfo(@TypeOf(validation)) != .Null) {
                    if (!typetool.invokeClosure(validation, .{})) {
                        return false;
                    }
                }
                _ = self.refcnt.fetchAdd(1, .seq_cst);
                var node = try self.alloc.create(WakeRequest);
                errdefer self.alloc.destroy(node);
                node.* = WakeRequest{
                    .lockAddress = lockAddr,
                    .thread = thread,
                    .next = null,
                    .prev = null,
                };
                if (bucket.tail) |tail| {
                    tail.next = node;
                    node.prev = tail;
                } else {
                    bucket.head = node;
                }
                bucket.tail = node;
                assert(bucket.head != null);
            }
            if (@typeInfo(@TypeOf(beforeSleep)) != .Null) {
                _ = typetool.invokeClosure(beforeSleep, .{});
            }
            thread.shouldPark = true;
            if (timeout) |ntimeout| {
                futex.timedWait(&thread.futexMark, 0, ntimeout) catch return false;
            } else {
                while (thread.shouldPark) {
                    futex.wait(&thread.futexMark, 0);
                }
            }

            return true;
        }

        fn getBucket(self: *Lot, lockAddr: usize, bucketN: usize) *Bucket {
            return self.getBucketByHash(getHashOf(lockAddr), bucketN);
        }

        fn getHashOf(lockAddr: usize) u32 {
            return hashCtx.hash(lockAddr);
        }

        fn getBucketByHash(self: *Lot, hash: u32, bucketN: usize) *Bucket {
            const bukpos = hash % bucketN;
            return self.buckets[bukpos];
        }

        fn findNodeOf(node: ?*WakeRequest, lockAddr: usize) ?*WakeRequest {
            var curr = node;
            while (curr) |nncurr| : (curr = nncurr.next) {
                if (nncurr.lockAddress == lockAddr) {
                    break;
                }
            }
            return curr;
        }

        fn hasNode(self: *Lot, lockAddr: usize, node: *WakeRequest) bool {
            var curr = self.getBucket(lockAddr, self.buckets.len).head;
            while (curr != null and curr != node) : (curr = curr.?.next) {}
            return curr != null;
        }

        fn dequeueFromBucket(bucket: *Bucket, lockAddr: usize) ?*WakeRequest {
            if (bucket.head) |bhead| {
                if (Lot.findNodeOf(bhead, lockAddr)) |node| {
                    if (node.prev) |prev| {
                        prev.next = node.next;
                    }
                    if (node.next) |next| {
                        next.prev = node.prev;
                    }
                    if (bucket.head == node) {
                        bucket.head = node.next;
                    }
                    if (bucket.tail == node) {
                        bucket.tail = node.prev;
                    }
                    return node;
                } else return null;
            } else return null;
        }

        fn deref(self: *Lot, lockAddr: usize, node: *WakeRequest) void {
            if (self.hasNode(lockAddr, node)) {
                _ = self.refcnt.fetchSub(1, .seq_cst);
            }
            if (self.old) |old| {
                old.deref(lockAddr, node);
                if (old.refcnt.load(.seq_cst) == 0) {
                    if (@cmpxchgStrong(?*Lot, &self.old, old, null, .seq_cst, .seq_cst) != null) {
                        old.deinit();
                        self.old = null;
                    }
                }
            }
        }

        pub fn dequeue(self: *Lot, lockAddr: usize, callback: anytype) ?*ThreadData {
            const hash = getHashOf(lockAddr);
            { // Lock all corresponding locks.
                var current = self;
                while (true) {
                    var bucket = self.getBucketByHash(hash, current.buckets.len);
                    bucket.safelock();
                    current = current.old orelse break;
                }
            }
            defer { // Unlock all locked buckets
                var current = self;
                while (true) {
                    var bucket = self.getBucketByHash(hash, current.buckets.len);
                    bucket.safeunlock();
                    current = current.old orelse break;
                }
            }
            {
                var current = self;
                const foundNode: ?*WakeRequest = nodeFind: {
                    while (true) {
                        const bucket = self.getBucketByHash(hash, current.buckets.len);
                        if (dequeueFromBucket(bucket, lockAddr)) |node| {
                            node.thread.shouldPark = false;
                            futex.wake(&node.thread.futexMark, 1);
                            if (@typeInfo(@TypeOf(callback)) != .Null) {
                                _ = typetool.invokeClosure(callback, .{
                                    UnparkResult{
                                        .didUnparkThread = true,
                                        .mayHaveMoreThread = findNodeOf(node.next, lockAddr) != null,
                                    },
                                });
                            }
                            break :nodeFind node;
                        }
                        current = current.old orelse break :nodeFind null;
                    }
                };
                if (foundNode) |node| {
                    defer self.alloc.destroy(node);
                    self.deref(lockAddr, node);
                    return node.thread;
                } else {
                    if (@typeInfo(@TypeOf(callback)) != .Null) {
                        _ = typetool.invokeClosure(
                            callback,
                            .{UnparkResult{
                                .didUnparkThread = false,
                                .mayHaveMoreThread = false,
                            }},
                        );
                    }
                    return null;
                }
            }
        }

        /// Deinitialise structure.
        ///
        /// This function does not free the memory used by nodes.
        /// See freeAll to free the memory used by nodes.
        fn deinit(self: *Lot) void {
            const bucketDestoryStart = if (self.old) |oldLot| oldLot.buckets.len else 0;
            if (self.old) |oldLot| {
                oldLot.deinit();
            }
            for (self.buckets[bucketDestoryStart..self.buckets.len]) |buk| {
                self.alloc.destroy(buk);
                // avoid double free: oldLot.deinit() will do the same as we do here for the latest lot.
            }
            self.alloc.free(self.buckets);
            self.alloc.destroy(self);
        }

        /// Free all memory used by this strutcure. You don't need call this on old lots,
        /// Since the old buckets will be reused in new lots.
        ///
        /// Warning: This function will lock down all locks of bucket and won't release.
        /// That helps to identify if someone does not leave queue when program exits.
        fn freeAll(self: *Lot) void {
            for (self.buckets) |buk| {
                buk.safelock();
            }
            for (self.buckets) |buk| {
                var curr = buk.head;
                while (curr) |node| {
                    const next = node.next;
                    self.alloc.destroy(node);
                    curr = next;
                }
            }
        }

        /// Return a resized lot. You must use this new lot instantly.
        /// After the new lot is set, use completeResizing to unlock buckets.
        fn resize(self: *Lot, newBucketN: usize) Allocator.Error!*Lot {
            assert(newBucketN > self.buckets.len); // TODO: implement resize buckets to small size
            for (self.buckets) |buk| {
                buk.safelock();
            }
            errdefer {
                for (self.buckets) |buk| {
                    buk.safeunlock();
                }
            }
            var newLot = try Lot.expandFrom(self.alloc, newBucketN, self);
            errdefer newLot.deinit();
            return newLot;
        }

        fn completeResizing(self: *Lot) void {
            for (self.buckets) |buk| {
                buk.safeunlock();
            }
        }
    };

    const Bucket = struct {
        head: ?*WakeRequest,
        tail: ?*WakeRequest,
        lock: WordLock = WordLock{},
        usingBy: ?*const ThreadData = null,

        fn safelock(self: *Bucket) void {
            if (self.usingBy != &perThreadData) {
                self.lock.lock();
                self.usingBy = &perThreadData;
            }
        }

        fn safeunlock(self: *Bucket) void {
            if (self.usingBy == &perThreadData) {
                self.usingBy = null;
                self.lock.unlock();
            } else if (self.usingBy != null) {
                unreachable; // It should not happen
            }
        }
    };

    const WakeRequest = struct {
        lockAddress: usize,
        thread: *ThreadData,
        next: ?*WakeRequest = null,
        prev: ?*WakeRequest = null,
    };

    fn prepareThread(self: *Self) void {
        if (perThreadData.firstTimeParking) {
            const refcnt = self.lot.refcnt.load(.seq_cst);
            if (refcnt > @divTrunc(self.lot.buckets.len, 3)) {
                var currentLot = @atomicLoad(*Lot, &self.lot, .seq_cst);
                var newLot = currentLot.resize(currentLot.buckets.len * 2) catch return;
                while (@cmpxchgWeak(*Lot, &self.lot, currentLot, newLot, .seq_cst, .seq_cst)) |_| {}
                newLot.completeResizing();
            }
            perThreadData.firstTimeParking = false;
        }
    }

    fn parkConditionally(self: *Self, lockAddr: usize, validation: anytype, beforeSleep: anytype, timeout: ?u64) Allocator.Error!bool {
        return try self.lot.enqueue(lockAddr, &perThreadData, validation, beforeSleep, timeout);
    }

    pub const UnparkResult = struct {
        didUnparkThread: bool,
        mayHaveMoreThread: bool,
    };

    fn unparkOne(self: *Self, lockAddr: usize, callback: anytype) void {
        _ = self.lot.dequeue(lockAddr, callback);
    }

    fn unpackAll(self: *Self, lockAddr: usize) void {
        while (self.lot.dequeue(lockAddr, null)) |_| {}
    }

    fn getCurrentThread() usize {
        return @intFromPtr(&perThreadData);
    }
};

pub const getCurrentThreadId = ParkingLot.getCurrentThread;

/// Independent lock which uses usize length.
pub const WordLock = struct {
    word: Atomic(usize) = Atomic(usize).init(0),
    trace: std.debug.Trace = std.debug.Trace.init,

    const Self = @This();

    const IS_LOCKED_MASK = @as(usize, 1);
    const IS_QUEUE_LOCKED_MASK = @as(usize, 2);
    const QUEUE_HEAD_MASK = @as(usize, 3);

    pub fn lock(self: *Self) void {
        if (self.word.cmpxchgWeak(0, IS_LOCKED_MASK, .seq_cst, .seq_cst)) |_| {
            // quick path failed
            self.lockSlow();
        }
        self.trace.add("the lock is locked here");
    }

    fn lockSlow(self: *Self) void {
        var spinCount: u8 = 0;
        const spinLimit = 40;
        while (true) {
            var currentWord = self.word.load(.seq_cst);
            if ((currentWord & IS_LOCKED_MASK) == 0) {
                assert((currentWord & IS_QUEUE_LOCKED_MASK) == 0);

                if (self.word.cmpxchgWeak(currentWord, currentWord | IS_LOCKED_MASK, .seq_cst, .seq_cst) == null) {
                    return;
                }
            }
            if ((currentWord & ~QUEUE_HEAD_MASK) == 0 and spinCount < spinLimit) {
                spinCount += 1;
                sched_yield() catch {}; // just try
                continue;
            }
            var me = &perThreadData;
            assert(!me.shouldPark);
            assert(me.next == null);
            assert(me.tail == null);

            currentWord = self.word.load(.seq_cst);

            if ((currentWord & IS_QUEUE_LOCKED_MASK) != 0 or
                (currentWord & IS_LOCKED_MASK) == 0 or self.word.cmpxchgWeak(
                currentWord,
                currentWord | IS_QUEUE_LOCKED_MASK,
                .seq_cst,
                .seq_cst,
            ) != null) {
                sched_yield() catch {};
                continue;
            }

            currentWord |= IS_QUEUE_LOCKED_MASK;

            me.shouldPark = true;
            const qhead: ?*ThreadData = @ptrFromInt(currentWord & ~QUEUE_HEAD_MASK);
            if (qhead) |head| {
                head.tail.?.tail = me;
                head.tail = me;

                assert(self.word.raw == currentWord);
                self.word.store(currentWord & ~IS_QUEUE_LOCKED_MASK, .seq_cst);
            } else {
                me.tail = me;
                var newWord = currentWord;
                newWord |= @intFromPtr(me);
                newWord &= ~IS_QUEUE_LOCKED_MASK;
                self.word.store(newWord, .seq_cst);
            }

            {
                while (me.shouldPark) {
                    futex.wait(&me.futexMark, 0);
                }
                break;
            }

            assert(!me.shouldPark);
            assert(me.next == null);
            assert(me.tail == null);
        }
    }

    pub fn unlock(self: *Self) void {
        if (self.word.cmpxchgStrong(IS_LOCKED_MASK, 0, .seq_cst, .seq_cst)) |_| {
            // quick path failed
            self.unlockSlow();
        }
    }

    fn unlockSlow(self: *Self) void {
        while (true) {
            const currentWord = self.word.load(.seq_cst);
            assert(currentWord & IS_LOCKED_MASK != 0);
            if (currentWord == IS_LOCKED_MASK) {
                if (self.word.cmpxchgWeak(IS_LOCKED_MASK, 0, .seq_cst, .seq_cst) == null) {
                    return;
                }
                sched_yield() catch {};
                continue;
            }

            if (currentWord & IS_QUEUE_LOCKED_MASK != 0) {
                sched_yield() catch {};
                continue;
            }

            assert((currentWord & ~QUEUE_HEAD_MASK) != 0);

            if (self.word.cmpxchgWeak(currentWord, currentWord | IS_QUEUE_LOCKED_MASK, .seq_cst, .seq_cst) == null) {
                break;
            }
        }

        const currentWord = self.word.load(.seq_cst);
        assert(currentWord & IS_LOCKED_MASK != 0);
        assert(currentWord & IS_QUEUE_LOCKED_MASK != 0);
        var qhead: *ThreadData = @ptrFromInt(currentWord & ~QUEUE_HEAD_MASK);
        const nextPtr = @intFromPtr(qhead.next);
        if (qhead.next) |nextHead| {
            nextHead.tail = qhead.tail;
        }
        assert(currentWord & IS_LOCKED_MASK != 0);
        assert(currentWord & IS_QUEUE_LOCKED_MASK != 0);
        assert((currentWord & (~QUEUE_HEAD_MASK)) == @intFromPtr(qhead));
        var newWord = currentWord;
        newWord &= ~IS_LOCKED_MASK;
        newWord &= ~IS_QUEUE_LOCKED_MASK;
        newWord &= QUEUE_HEAD_MASK;
        newWord |= nextPtr;
        self.word.store(newWord, .seq_cst);

        qhead.next = null;
        qhead.tail = null;
        qhead.shouldPark = false;
        futex.wake(&qhead.futexMark, 1);
    }
};

fn workLockThread(lock: *WordLock, n: *u32) !void {
    lock.lock();
    defer lock.unlock();
    n.* = 0;
}

test "WordLock functional test" {
    const t = std.testing;
    var lock = WordLock{};
    var shared: u32 = 1;
    lock.lock();
    var t0 = try std.Thread.spawn(.{}, workLockThread, .{ &lock, &shared });
    t0.detach();
    try t.expectEqual(@as(u32, 1), shared);
    lock.unlock();
    while (shared == 1) {
        sched_yield() catch {};
    }
    try t.expectEqual(@as(u32, 0), shared);
    lock.lock();
    lock.unlock();
}

fn getParkingLot() *ParkingLot {
    if (gParkingLot) |*plot| {
        plot.prepareThread();
        return plot;
    } else unreachable; // The global parkinglot is not initialised
}

/// High performance small lock.
///
/// This structure is only 2-bit sized. Note: the actual size may not be 2 bits
/// due to the alignment.
///
/// **Debugging Deadlock**:
/// This structure tracks the locking in `Debug` mode, uses `std.debug.Trace`.
///
/// If you need to explore the deadlock, you can dump the stack trace from the trace.
pub const BargingLock = struct {
    word: u2 = 0,
    trace: std.debug.Trace = std.debug.Trace.init,

    const Self = @This();

    const IS_LOCKED_MASK = 1;
    const IS_PARKED_MASK = 2;

    pub fn lock(self: *Self) void {
        defer self.trace.add("The lock is locked here");
        if (@cmpxchgWeak(u2, &self.word, 0, IS_LOCKED_MASK, .seq_cst, .seq_cst) == null) {
            return;
        }
        {
            var i = @as(u8, 40);
            while (i > 0) : (i -= 1) {
                if (@atomicLoad(u2, &self.word, .seq_cst) & IS_PARKED_MASK != 0) {
                    break;
                }
                if (@cmpxchgWeak(u2, &self.word, 0, IS_LOCKED_MASK, .seq_cst, .seq_cst) == null) {
                    return;
                }
                sched_yield() catch {};
            }
        }
        while (true) {
            const word = @atomicLoad(u2, &self.word, .seq_cst);
            if ((word & IS_LOCKED_MASK == 0) and (@cmpxchgWeak(u2, &self.word, word, word | IS_LOCKED_MASK, .seq_cst, .seq_cst) == null)) {
                return;
            }

            _ = @cmpxchgWeak(u2, &self.word, word, word | IS_PARKED_MASK, .seq_cst, .seq_cst);

            const validation = struct {
                lock: *Self,

                pub fn call(this: @This()) bool {
                    return @atomicLoad(u2, &this.lock.word, .seq_cst) == (IS_LOCKED_MASK | IS_PARKED_MASK);
                }
            }{ .lock = self };

            while (true) {
                _ = getParkingLot().parkConditionally(@intFromPtr(self), validation, null, null) catch {
                    sched_yield() catch {};
                    continue;
                };
                break;
            }
        }
    }

    pub fn unlock(self: *Self) void {
        if (@cmpxchgWeak(u2, &self.word, IS_LOCKED_MASK, 0, .seq_cst, .seq_cst) == null) {
            return;
        }

        const callback = struct {
            lock: *Self,

            pub fn call(this: @This(), result: ParkingLot.UnparkResult) void {
                if (result.mayHaveMoreThread) {
                    @atomicStore(u2, &this.lock.word, IS_PARKED_MASK, .seq_cst);
                } else {
                    @atomicStore(u2, &this.lock.word, 0, .seq_cst);
                }
            }
        }{ .lock = self };

        getParkingLot().unparkOne(@intFromPtr(self), callback);
    }
};

pub const Lock = BargingLock;

fn bargingLockThread(lock: *BargingLock, n: *u32) !void {
    while (true) {
        lock.lock();
        defer lock.unlock();
        if (n.* > 0) {
            n.* -= 1;
        } else break;
    }
}

test "BargingLock functional test" {
    const t = std.testing;
    try ParkingLot.initGlobal(t.allocator);
    defer ParkingLot.deinitGlobal();
    var lock = BargingLock{};
    var shared: u32 = 1;
    lock.lock();
    var t0 = try std.Thread.spawn(.{}, bargingLockThread, .{ &lock, &shared });
    t0.detach();
    try t.expectEqual(@as(u32, 1), shared);
    lock.unlock();
    while (shared == 1) {
        sched_yield() catch {};
    }
    lock.lock();
    try t.expectEqual(@as(u32, 0), shared);
    lock.unlock();
}

fn assertLockPtr(comptime T: type) void {
    if (!(@typeInfo(T) == .Pointer and @typeInfo(T).Pointer.size == .One and
        @typeInfo(@typeInfo(T).Pointer.child) == .Struct and
        std.meta.hasMethod(@typeInfo(T).Pointer.child, "lock") and
        std.meta.hasMethod(@typeInfo(T).Pointer.child, "unlock")))
    {
        @compileError("expect a pointer to a structure with declaration of lock() and unlock()");
    }
}

pub const Condition = struct {
    hasWaiters: bool = false,

    const Self = @This();

    fn BeforeSleepCallback(comptime L: type) type {
        return struct {
            cond: *Self,
            lock: L,

            pub fn call(this: @This()) void {
                this.lock.unlock();
            }
        };
    }

    pub fn wait(self: *Self, lock: anytype) void {
        assertLockPtr(@TypeOf(lock));
        const validation = struct {
            cond: *Self,

            pub fn call(this: @This()) bool {
                @atomicStore(bool, &this.cond.hasWaiters, true, .seq_cst);
                return true;
            }
        }{ .cond = self };

        const beforeSleep = BeforeSleepCallback(@TypeOf(lock)){ .cond = self, .lock = lock };
        while (true) {
            _ = getParkingLot().parkConditionally(
                @intFromPtr(self),
                validation,
                beforeSleep,
                null,
            ) catch {
                sched_yield() catch {};
                continue;
            };
            break;
        }
        lock.lock();
    }

    pub fn notifyOne(self: *Self) void {
        if (@atomicLoad(bool, &self.hasWaiters, .seq_cst)) {
            const callback = struct {
                cond: *Self,

                pub fn call(this: @This(), result: ParkingLot.UnparkResult) void {
                    @atomicStore(bool, &this.cond.hasWaiters, result.mayHaveMoreThread, .seq_cst);
                }
            }{ .cond = self };
            getParkingLot().unparkOne(@intFromPtr(self), callback);
        }
    }

    pub fn notifyAll(self: *Self) void {
        if (@atomicLoad(bool, &self.hasWaiters, .seq_cst)) {
            @atomicStore(bool, &self.hasWaiters, false, .seq_cst);
            getParkingLot().unpackAll(@intFromPtr(self));
        }
    }
};

fn conditionThread(cond: *Condition, lock: *Lock, n: *u32, val: u32) void {
    lock.lock();
    defer lock.unlock();
    cond.wait(lock);
    n.* = val;
    cond.notifyOne();
}

test "Condition functional test" {
    const t = std.testing;
    try ParkingLot.initGlobal(t.allocator);
    defer ParkingLot.deinitGlobal();
    var lock = Lock{};
    var cond = Condition{};
    var shared: u32 = 1;
    var t0 = try std.Thread.spawn(.{}, conditionThread, .{ &cond, &lock, &shared, 0 });
    t0.detach();
    try t.expectEqual(@as(u32, 1), shared);
    while (shared == 1) {
        cond.notifyOne(); // It's possible that the thread doesn't wait on condition in first call of notifyOne()
        sched_yield() catch {};
    }
    try t.expectEqual(@as(u32, 0), shared);
}

/// Wait for awaken or timeout.
///
/// `timeout` is nanoseconds. It's recommended to specify timeout to avoid deadlock.
pub fn switchto_wait(timeout: ?u64) void {
    perThreadData.switchToWaiting.store(true, .seq_cst);
    if (timeout) |time| {
        while (perThreadData.switchToWaiting.load(.unordered)) {
            futex.timedWait(&perThreadData.futexMark, 0, time) catch {
                perThreadData.switchToWaiting.store(false, .seq_cst);
                break;
            };
        }
    } else {
        while (perThreadData.switchToWaiting.load(.unordered)) {
            futex.wait(&perThreadData.futexMark, 0);
        }
    }
}

/// Resume target thread.
pub fn switchto_resume(target: usize) error{NotWaiting}!void {
    const to: *ThreadData = @ptrFromInt(target);
    if (to.switchToWaiting.cmpxchgStrong(false, true, .seq_cst, .unordered)) |_| {
        return error.NotWaiting;
    }
    futex.wake(&to.futexMark, 1);
}

/// Switch to target thread.
///
/// Note: This is just a hit to the scheduler. The target thread may not be awaken instantly.
pub fn switchto_switch(to: usize) error{NotWaiting}!void {
    const beSwapped = &perThreadData;
    const toHandle: *ThreadData = @ptrFromInt(to);
    if (toHandle.switchToWaiting.cmpxchgStrong(false, true, .seq_cst, .unordered)) |_| {
        return error.NotWaiting;
    }
    futex.wake(&toHandle.futexMark, 1);
    beSwapped.switchToWaiting = true;
    while (beSwapped.switchToWaiting) {
        futex.wait(&beSwapped.futexMark, 0);
    }
}

pub fn Mutex(T: type) type {
    return struct {
        _lock: Lock = .{},
        value: T,

        pub fn lock(self: *@This()) *T {
            self._lock.lock();
            return &self.value;
        }

        pub fn unlock(self: *@This()) void {
            self._lock.unlock();
        }
    };
}
