const std = @import("std");

/// Atomic Reference Counting
///
/// Managing unpredictable references.
/// If `T` has `deinit` method. It will be called before deinitialising the memory.
///
/// Use `.clone()` to create a new reference, `.deinit()` to destory the reference.
/// `.ptr()` returns the pointer to the value. `.create()` to create a new ref from the value.
///
/// If you need to get the Arc instance from the pointer, use `.fromPtr()`.
pub fn Arc(T: type) type {
    return struct {
        state: *State,
        trace: std.debug.Trace = std.debug.Trace.init,

        pub const State = struct {
            value: T,
            counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
            allocator: std.mem.Allocator,
        };

        /// Create a new reference to the value.
        ///
        /// You must remember to call the `.deinit()` when you received one.
        pub fn clone(self: @This()) @This() {
            const refc = self.state.counter.fetchAdd(1, .seq_cst);
            if (refc <= 1) {
                std.debug.panic("this value is already dropped. {}", .{
                    self.trace,
                });
            }
            var ref: @This() = .{ .state = self.state };
            ref.trace.add("the value is cloned here");
            return ref;
        }

        /// Destory the reference.
        ///
        /// If the no others referencing this value, the value will be dropped.
        pub fn deinit(self: @This()) void {
            if (self.state.counter.fetchSub(1, .seq_cst) <= 1) {
                if (@hasDecl(T, "deinit")) {
                    self.state.value.deinit();
                }
                self.state.allocator.destroy(self.state);
            }
        }

        pub fn create(allocator: std.mem.Allocator, value: T) !@This() {
            const state = try allocator.create(State);
            state.* = .{ .allocator = allocator, .value = value };
            var self: @This() = .{ .state = state };
            self.trace.add("the value is created here");
            return self;
        }

        /// Get the pointer to the value.
        ///
        /// The accessing result is undefined when the instance reference count < 1
        /// (the value is dropped).
        pub fn ptr(self: @This()) *T {
            return &self.state.value;
        }

        /// Get the Arc instance contains the value.
        ///
        /// You must ensure the pointer is from an Arc instance `.ptr()`.
        /// There is no safety check for this, use at your own risk.
        pub fn fromPtr(value: *T) Arc(T) {
            const state: *State = @fieldParentPtr("value", value);
            var self: @This() = .{ .state = state };
            return self.clone();
        }
    };
}
