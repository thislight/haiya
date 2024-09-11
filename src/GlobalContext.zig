const parkinglot = @import("parkinglot");
const std = @import("std");

pub const InitError = error{
    Initialised,
};

/// Initialise environment used by haiya. If initialised, return an error.
///
/// Some operations allocate memory. If you ignore the error, these operation
/// may use unexpected allocator.
///
/// Don't forget to use `deinit()` to deinitialise global context when you exiting.
pub fn init(alloc: std.mem.Allocator) !void {
    if (parkinglot.ParkingLot.isGlobalInitialised()) {
        return InitError.Initialised;
    }
    try parkinglot.ParkingLot.initGlobal(alloc);
}

pub fn deinit() void {
    parkinglot.ParkingLot.deinitGlobal();
}
