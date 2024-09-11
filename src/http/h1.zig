const std = @import("std");
const Headers = @import("./Headers.zig");
const Request = @import("./Request.zig");
const Response = @import("./Response.zig");

pub const RequestState = struct {
    /// The characters accepted.
    walkedOffset: usize = 0,
    isFirstLine: bool = true,
    final: bool = false,
};

pub const FromatError = error{
    UnsupportedVersion,
    Unspecified,
};

/// Parse HTTP/1.x Request.
///
/// The memory is owned by the caller. `alloc` is only used to append entries into headers,
/// this function doesn't allocate additional memory.
///
/// if completed, the result's `.final` will be `true`.
///
/// Note: this function is used to handle external input.
pub fn requestFromStr(state: RequestState, request: *Request, alloc: std.mem.Allocator, src: []const u8) !RequestState {
    var it = std.mem.splitSequence(u8, src, "\r\n");
    var walked = state.walkedOffset;
    var isFirstLine = state.isFirstLine;
    if (isFirstLine) requestLine: {
        const firstLine = it.next() orelse {
            return state;
        };
        defer isFirstLine = false;
        defer walked += firstLine.len;
        if (firstLine.len == 0) {
            break :requestLine;
        }
        if (firstLine[0] == '/') { // HTTP/1.0 - only contains path, no version and method
            request.version = .http1_0;
            request.path = firstLine;
            break :requestLine;
        }
        const methodEnd = std.mem.indexOfScalar(u8, firstLine, ' ') orelse {
            return state;
        };
        const pathEnd = std.mem.indexOfScalarPos(u8, firstLine, methodEnd + 1, ' ') orelse {
            return state;
        };
        const version = if (pathEnd + 1 < firstLine.len) firstLine[pathEnd + 1 ..] else {
            return FromatError.Unspecified;
        };
        if (version.len != 8 or !std.mem.eql(u8, version[0..7], "HTTP/1.")) {
            return FromatError.Unspecified;
        }
        const lastChar = version[version.len - 1];
        switch (lastChar) {
            '1' => request.version = .http1_1,
            '0' => request.version = .http1_0,
            else => return FromatError.UnsupportedVersion,
        }
        _ = request.setMethod(firstLine[0..methodEnd]);
        request.path = firstLine[methodEnd + 1 .. pathEnd];
    }
    var pushedHeaderCount: usize = 0;
    const headers = &request.headers.entries;
    errdefer while (pushedHeaderCount > 0) : (pushedHeaderCount -= 1) {
        _ = headers.pop();
    };
    while (it.next()) |headerLine| {
        walked += 2 + headerLine.len;
        if (headerLine.len == 0 and it.peek() != null) {
            // Only when we have the "next line" (another CRLF), the header part is completed.
            return RequestState{
                .final = true,
                .isFirstLine = isFirstLine,
                .walkedOffset = walked + 2,
            };
        }
        const splitIndex = std.mem.indexOfScalar(u8, headerLine, ':') orelse {
            if (it.peek()) |_| {
                // The request is malformed.
                // The next line exists, but the header line is incomplete
                return FromatError.Unspecified;
            } else {
                // The buffer is incomplete, ask caller to feed more
                while (pushedHeaderCount > 0) : (pushedHeaderCount -= 1) {
                    _ = headers.pop();
                }
                return RequestState{
                    .final = false,
                    .isFirstLine = isFirstLine,
                    .walkedOffset = walked - (headerLine.len + 2),
                };
            }
        };
        const key = headerLine[0..splitIndex];
        const value = if (headerLine.len > splitIndex + 1) headerLine[splitIndex + 1 ..] else "";
        const trimmedValue = std.mem.trim(u8, value, " ");
        try headers.append(alloc, Headers.Entry{ .key = key, .value = trimmedValue });
        pushedHeaderCount += 1;
    }
    return RequestState{
        .final = false,
        .isFirstLine = isFirstLine,
        .walkedOffset = walked,
    };
}

fn useCRLF(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    return try std.mem.replaceOwned(u8, alloc, text, "\n", "\r\n");
}

test "requestFromStr for a complete HTTP/1.1 request" {
    const t = std.testing;
    const reqText = try useCRLF(t.allocator,
        \\GET /random HTTP/1.1
        \\Host: example.com
        \\Connection: close
        \\
        \\
    );
    defer t.allocator.free(reqText);
    var state = RequestState{};
    var request = Request.empty();
    defer request.deinit(t.allocator);
    state = try requestFromStr(state, &request, t.allocator, reqText);
    try t.expect(state.final);
    try t.expectEqual(@as(@TypeOf(request.version), .http1_1), request.version);
    try t.expectEqual(reqText.len, state.walkedOffset);
    // TODO: test method, path and headers is correctly parsed.
}

test "requestFromStr for a complete HTTP/1.0 request" {
    const t = std.testing;
    const reqText = try useCRLF(t.allocator,
        \\GET /random HTTP/1.0
        \\Host: example.com
        \\
        \\
    );
    defer t.allocator.free(reqText);
    var state = RequestState{};
    var request = Request.empty();
    defer request.deinit(t.allocator);
    state = try requestFromStr(state, &request, t.allocator, reqText);
    try t.expect(state.final);
    try t.expectEqual(@as(@TypeOf(request.version), .http1_0), request.version);
    try t.expectEqual(reqText.len, state.walkedOffset);
}

test "requestFromStr for a HTTP/1.0 request with only path as the request line" {
    const t = std.testing;
    const reqText = try useCRLF(t.allocator,
        \\/random
        \\Host: example.com
        \\
        \\
    );
    defer t.allocator.free(reqText);
    var state = RequestState{};
    var request = Request.empty();
    defer request.deinit(t.allocator);
    state = try requestFromStr(state, &request, t.allocator, reqText);
    try t.expect(state.final);
    try t.expectEqual(@as(@TypeOf(request.version), .http1_0), request.version);
    try t.expectEqual(reqText.len, state.walkedOffset);
}

test "requestFromStr won't complete request with a empty line" {
    const t = std.testing;
    const reqText = try useCRLF(t.allocator,
        \\GET /random HTTP/1.0
        \\Host: example.com
        \\
    );
    defer t.allocator.free(reqText);
    var state = RequestState{};
    var request = Request.empty();
    defer request.deinit(t.allocator);
    state = try requestFromStr(state, &request, t.allocator, reqText);
    try t.expect(!state.final);
}

/// Format Response (Headers).
///
/// This function renders the status line and the headers.
/// Use `Stream.write*` to send the actual content
/// (note: don't forget to set Content-Length or Transfer-Encoding).
pub fn fmtResponse(writer: anytype, response: Response, version: Request.Version) !void {
    try std.fmt.format(writer, "{} {} {s}\r\n", .{ version, response.statusCode, response.statusText });
    for (response.headers.entries.items) |entry| {
        try std.fmt.format(writer, "{s}: {s}\r\n", .{ entry.key, entry.value });
    }
    _ = try writer.write("\r\n");
}

pub fn countResponse(response: Response, version: Request.Version) u64 {
    var writer = std.io.countingWriter(std.io.null_writer);
    fmtResponse(writer.writer(), response, version) catch unreachable;
    return writer.bytes_written;
}
