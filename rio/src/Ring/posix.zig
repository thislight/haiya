const std = @import("std");

pub const Fd = std.posix.fd_t;

pub const close = std.posix.close;

pub fn bind(fd: Fd, address: std.net.Address) std.posix.BindError!void {
    try std.posix.bind(fd, &address.any, address.getOsSockLen());
}

pub const listen = std.posix.listen;

pub fn getsockname(fd: Fd) std.posix.GetSockNameError!std.net.Address {
    var addrbuf: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(@TypeOf(addrbuf));

    try std.posix.getsockname(fd, @ptrCast(&addrbuf), &addrlen);
    const actualAddress = std.net.Address.initPosix(@ptrCast(&addrbuf));

    return actualAddress;
}
