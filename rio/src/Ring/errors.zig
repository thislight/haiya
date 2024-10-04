const std = @import("std");
pub const RecvError = std.posix.RecvFromError;

pub const AcceptError = std.posix.AcceptError;

pub const SendError = std.posix.SendError;

pub const CloseError = error{
    BadFd,
    Interrupted,
    IO,
} || std.posix.UnexpectedError;

pub const CancelError = error{
    NoEntity,
    Invalid,
    Already,
} || std.posix.UnexpectedError;
