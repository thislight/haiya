//! Router with comptime-resolved dependency injection.
//!
//! - `DefineRouter`: the router implementation
//!
//! ## Route Matchers
//!
//! Route matchers organize and dispatch handlers based on the request.
//!
//! - `Host`: only match specific matchers when the Host header is same to the specified
//! - `Path`: use specific handler if the request path matches the specified
//! - `Always`: always use the handler
//! - `Blueprint`: organizing matchers
//!
//! If you are interested on writing you own matchers, see `DefineRouter`.
const std = @import("std");
const Transcation = @import("./http/Transcation.zig");
const Request = @import("./http/Request.zig");
const log = std.log.scoped(.routers);
const injects = @import("./inject.zig");
const typetool = @import("typetool");

/// Define a router type.
///
/// `Injects` is the type of injected dependencies, `routes` is the tuple of route matchers.
///
/// ````zig
/// const Router = DefineRouter(std.meta.Tuple(&.{}), .{
///     Path("/", handleIndex),
///     Path("/docs/{}", handleDocPage),
/// });
/// ````
/// The router matchers will be run in order. If you use `"/{}"` to match all the path before
/// more specific path like `"/docs"`, the `"/{}"` one will always be picked and the more specific
/// one will never reached.
///
/// To use the router serving requests, use the `.route` function as the callback and the pointer
/// to the router as the userdata.
///
/// ````zig
/// const Router = DefineRouter(...);
/// var router = Router.init(.{});
///
/// Server.init(
///     ring,
///     Router.route, // Use the .route function from the router
///     &router, // Pass the router instance as the userdata
///     allocator,
///     .{},
/// );
/// ````
///
/// ## Dependency Injection
///
/// Instead of userdata, haiya Router implements comptime-resolved dependency injection.
/// That's way the routes is part of the Router type.
///
/// A common dependency is the PathArgs:
///
/// ````
/// const PathArgs = @import("haiya").routers.PathArgs;
///
/// fn handleRequest(pathArgs: PathArgs) !void {
///     useThePathArgs(pathArgs);
/// }
///
/// const Router = DefineRouter(std.meta.Tuple(&.{}), .{
///     Path("/{}", handleRequest),
/// })
/// ````
/// `PathArgs` is directly injected as a static dependencies by the router, only when
/// the route matcher may return any argument.
/// Since the dependencies is resolved in comptime, you will get an error if the dependency is missing.
/// Take the code above as an example, if you use `Alaways` instead of `Path`: `Always(handleRequest)`,
/// zig will complain you don't have such thing injected.
///
/// ## Derived Dependencies
///
/// Dependencies can be derived from static dependencies. The type pattern should follow:
///
/// ````zig
/// const UseHostStr = struct {
///     ref: ?[]const u8,
///
///     pub const Requires = HostStr;
/// };
///
/// const HostStr = struct {
///     pub fn inject(self: @This(), t: *haiya.Transcation) ?[]const u8 {
///         return t.request.headers.getOne("Host");
///     }
/// }
/// ````
///
/// ## Route Matcher Protocol
/// `DefineRouter` build a DSL based on types. With understanding of this protocol,
/// you can build the route matcher for you application needs. Note that this protocol
/// is implementation detail and counted as the ABI not the API.
///
/// That's two kind of nodes of route matchers:
/// - `routerMatchTuple` - with this decl, is interminated node.
/// - `routerTerminatedAt` - with this decl, is terminated node.
///
/// `routerMatchTuple` must be a tuple. If this node matches, the router will
/// iterate the tuple to match a node.
///
/// `routerTerminatedAt` must be a function. If this node matches, the router will
/// run this function as the handler.
///
/// Matching is optional, by defining one of the functions below:
///
/// - `contextlessMatch(request: *const haiya.Request) bool` - supported in interminated nodes
/// - `match(self: *@This(), request: *const haiya.Request) bool` - supported in terminated nodes
///
/// If no function available, the node is treated as matched.
///
/// `routerTerminatedAt` supports an additional (optional) field: `routerArguments`.
/// It can be any object has `constSlice() []const []const u8` method, like `std.BoundedArray([]const u8, ...)`.
///
/// If this field presents, after `match()` called, the router will inject a `PathArgs`
/// with the content from the `constSlice()` method above.
pub fn DefineRouter(Injects: type, routes: anytype) type {
    return struct {
        injects: Injects,

        const Router = @This();

        pub fn init(injectValues: Injects) Router {
            return .{ .injects = injectValues };
        }

        fn matchAndExecRoute(self: Router, Routed: type, t: *Transcation) !bool {
            if (@hasDecl(Routed, "routerMatchTuple")) {
                if (@hasDecl(Routed, "contextlessMatch") and !Routed.contextlessMatch(&t.request)) {
                    return false;
                }
                inline for (std.meta.fieldNames(@TypeOf(Routed.routerMatchTuple))) |fname| {
                    if (try self.matchAndExecRoute(@field(route, fname), t)) {
                        return true;
                    }
                }
            } else if (@hasDecl(Routed, "routerTerminateAt")) {
                if (@hasDecl(Routed, "contextlessMatch") and !Routed.contextlessMatch(&t.request)) {
                    return false;
                }
                if (@hasDecl(Routed, "match")) {
                    var matchContext = Routed{};
                    if (!matchContext.match(&t.request)) {
                        return false;
                    }
                    if (@hasField(Routed, "routerArguments")) {
                        try injects.run(
                            Routed.routerTerminateAt,
                            typetool.MergeTuple(.{
                                self.injects,
                                .{ t, PathArgs{ .ref = matchContext.routerArguments.constSlice() } },
                            }),
                        );
                    } else {
                        try injects.run(Routed.routerTerminateAt, typetool.MergeTuple(.{ self.injects, .{t} }));
                    }
                } else {
                    try injects.run(Routed.routerTerminateAt, typetool.MergeTuple(.{ self.injects, .{t} }));
                }
                return true;
            }
        }

        fn matchAndExec(self: Router, t: *Transcation) !void {
            inline for (comptime std.meta.fieldNames(@TypeOf(routes))) |fname| {
                if (try self.matchAndExecRoute(@field(routes, fname), t)) {
                    break;
                }
            }
        }

        pub fn route(ud: ?*anyopaque, t: *Transcation) void {
            routeOrErr(ud, t) catch |err| {
                log.err("uncaught error! {}, stack trace: {?}", .{ err, @errorReturnTrace() });
            };
        }

        pub fn routeOrErr(ud: ?*anyopaque, t: *Transcation) !void {
            const self: *Router = @alignCast(@ptrCast(ud));
            try self.matchAndExec(t);
        }
    };
}

pub const MatchKind = enum {
    Host,
    Path,
};

pub fn Host(comptime hostname: []const u8, subRoutes: anytype) type {
    return struct {
        const routerMatchTuple = subRoutes;

        pub fn contextlessMatch(request: *const Request) bool {
            const value = request.headers.getOne("Host") orelse return false;
            return std.mem.eql(u8, value, hostname);
        }
    };
}

/// Segment of a expected path.
const PathToken = union(enum) {
    /// The string must be same with this token.
    Identity: []const u8,
    /// Consume the string as the argument until the specific string ("termination string"),
    /// or until the string ends when it's an empty slice.
    ///
    /// So the runtime code doesn't need to actually do the look ahead if
    /// the look-ahead value can be read directly.
    /// A memory access is avoided. (exchanging for a complex parser, but anyway,
    /// how complex can it be, with just two kinds of nodes?)
    MatchUntil: []const u8,
};

fn countPathToken(comptime path: []const u8) usize {
    const TokenState = enum {
        @"{",
        Identity,
    };

    comptime var cnt = 1;
    comptime var prevState = TokenState.Identity;
    inline for (path, 0..path.len) |c, pos| {
        switch (c) {
            '{' => {
                prevState = .@"{";
            },
            '}' => {
                if (prevState == .@"{") {
                    cnt += 1;
                    prevState = .Identity;
                } else {
                    @compileError(std.fmt.comptimePrint("Unmatched \"{s}\" at position {}", .{ c, pos }));
                }
            },
            else => {
                if (prevState == .@"{") {
                    @compileError(std.fmt.comptimePrint("Unmatched \"{s}\" at position {}", .{ "{", pos }));
                }
            },
        }
    }

    return cnt;
}

fn tokenizePath(comptime path: []const u8) [countPathToken(path)]PathToken {
    comptime var tokens: std.BoundedArray(PathToken, countPathToken(path)) = .{};
    comptime {
        const TokenState = enum {
            @"{",
            @"}",
            Identity,
        };

        var prevState = TokenState.Identity;
        var lastMatcherEnds: usize = 0;
        const lastIdentityStarts: usize = 0;

        for (path, 0..path.len) |c, pos| {
            switch (c) {
                '{' => {
                    if (prevState == .@"}") {
                        // We could not determine the .MatchUntil node until now
                        tokens.appendAssumeCapacity(.{ .MatchUntil = path[lastMatcherEnds + 1 .. pos] });
                    } else if (prevState == .Identity) {
                        tokens.appendAssumeCapacity(.{ .Identity = path[lastIdentityStarts..pos] });
                    }
                    prevState = .@"{";
                },
                '}' => {
                    if (prevState != .@"{") {
                        @compileError(std.fmt.comptimePrint("Unmatched \"{}\" at position {}", .{ c, pos }));
                    }
                    lastMatcherEnds = pos;
                    prevState = .@"}";
                },
                else => {
                    switch (prevState) {
                        .@"{" => @compileError(std.fmt.comptimePrint("Unmatched \"{}\" at position {}", .{ "{", pos })),
                        .@"}" => {
                            // Do nothing. collecting next .MatchUntil
                        },
                        .Identity => {
                            // Do nothing, still in the identity.
                            // We can safely assume the identity can only exists at the first node.
                            // Starts with the first .MatchUntil, there will no .Identity node can be matched
                            // Rubicon: may be we can further optimize based on this
                        },
                    }
                },
            }
        }

        switch (prevState) {
            .Identity => tokens.appendAssumeCapacity(.{ .Identity = path[lastIdentityStarts..] }),
            .@"{" => @compileError(std.fmt.comptimePrint("Unmatched \"{}\" at position {}", .{ "{", path.len - 1 })),
            .@"}" => {
                tokens.appendAssumeCapacity(.{ .MatchUntil = path[lastMatcherEnds + 1 ..] });
            },
        }
    }
    return tokens.buffer[0..tokens.len].*;
}

test "tokenizePath full match string" {
    const t = std.testing;
    const toks = comptime tokenizePath("/example");

    try t.expectEqual(1, toks.len);

    try t.expectEqual(std.meta.Tag(PathToken).Identity, std.meta.activeTag(toks[0]));
    try t.expectEqualStrings("/example", toks[0].Identity);
}

test "tokenizePath replacement in the end without termination" {
    const t = std.testing;
    const toks = comptime tokenizePath("/docs/{}");

    try t.expectEqual(2, toks.len);

    try t.expectEqual(PathToken.Identity, std.meta.activeTag(toks[0]));
    try t.expectEqualStrings("/docs/", toks[0].Identity);

    try t.expectEqual(PathToken.MatchUntil, std.meta.activeTag(toks[1]));
    try t.expectEqualStrings("", toks[1].MatchUntil);
}

test "tokenizePath replacement in the end with termination" {
    const t = std.testing;
    const toks = comptime tokenizePath("/users/{}/orders");

    try t.expectEqual(2, toks.len);

    try t.expectEqual(PathToken.MatchUntil, std.meta.activeTag(toks[1]));
    try t.expectEqualStrings("/orders", toks[1].MatchUntil);
}

test "tokenizePath multiple replacements" {
    const t = std.testing;

    const toks = comptime tokenizePath("/users/{}/{}");

    try t.expectEqual(3, toks.len);

    try t.expectEqual(PathToken.MatchUntil, std.meta.activeTag(toks[1]));
    try t.expectEqualStrings("/", toks[1].MatchUntil);

    try t.expectEqual(PathToken.MatchUntil, std.meta.activeTag(toks[2]));
    try t.expectEqualStrings("", toks[2].MatchUntil);
}

fn countMatchUntilToken(path: []const PathToken) usize {
    var n = 0;
    for (path) |item| {
        if (item == .MatchUntil) {
            n += 1;
        }
    }
    return n;
}

/// Matcher against the path tokens.
///
/// This type documents the implementation details.
/// See `Path` for the usage.
///
/// `match()` acts as a finite state machine. Every token is one state of the machine.
/// For the input, 0 or more of characters must be consumed before moving to the next state.
/// If any state is failed to consume any char, the machine moves into failed state, `match()`
/// returns `false`.
///
/// `.Identity` consumes the remaining of the input with the specified string
/// from the token, only when the starts of the remaining equals to the specified from the token.
///
/// `.MatchUntil` consumes two parts of the string:
///
/// - any chars before the termination string from the token,
///     this part will be appended into `routerArguments`
/// - the termination string
///
/// If the termination string is empty, the termination will be the end of the string.
///
/// After the states from the tokens are success, the machine moves to the final "checks" state.
/// If there is any char does not be consumed, the machine moves into failed state;
/// or the `match()` succees, returns `true`.
fn TokenizedPath(comptime path: []const PathToken, comptime handler: anytype) type {
    return struct {
        routerArguments: std.BoundedArray([]const u8, SEG_MATCH_NUM) = .{},

        const routerTerminateAt = handler;

        const SEG_MATCH_NUM = countMatchUntilToken(path);

        /// Check if the request's path can match the tokens.
        ///
        /// The matched arguments will be filled into the `routerArguments`. The caller
        /// owns the memory.
        pub fn match(self: *@This(), request: *const Request) bool {
            var rest = request.path;
            inline for (path) |token| {
                switch (token) {
                    .Identity => |expectedStr| {
                        if (expectedStr.len > rest.len) {
                            return false;
                        }
                        const actual = rest[0..expectedStr.len];
                        if (!std.mem.eql(u8, expectedStr, actual)) {
                            return false;
                        }
                        rest = rest[expectedStr.len..];
                    },
                    .MatchUntil => |nextStr| {
                        if (nextStr.len == 0) {
                            self.routerArguments.appendAssumeCapacity(rest);
                            rest = rest[rest.len..];
                            break; // No need for further processing
                        }
                        const found = std.mem.indexOf(u8, rest, nextStr) orelse return false;
                        self.routerArguments.appendAssumeCapacity(rest[0..found]);
                        rest = rest[found + nextStr.len ..];
                    },
                }
            }

            // If they are unmatched, there should be too early to return.
            std.debug.assert(self.routerArguments.len == SEG_MATCH_NUM);

            return rest.len == 0;
        }
    };
}

fn _emptyFn() void {}

fn getRequestWithPath(path: []const u8) Request {
    var request = Request.empty();
    request.path = path;
    return request;
}

test "TokenizedPath full match string" {
    const t = std.testing;

    const Matcher = TokenizedPath(&.{.{ .Identity = "/example" }}, _emptyFn);

    {
        var matcher = Matcher{};

        try t.expect(matcher.match(&getRequestWithPath("/example")));
        try t.expectEqual(0, matcher.routerArguments.constSlice().len);
    }
    {
        var matcher = Matcher{};

        try t.expect(!matcher.match(&getRequestWithPath("/example/")));
    }
    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/exampl")));
    }
}

test "TokenizedPath replacement in the end without termination" {
    const t = std.testing;

    const Matcher = TokenizedPath(&.{
        .{ .Identity = "/users/" },
        .{ .MatchUntil = &.{} },
    }, _emptyFn);

    {
        var matcher = Matcher{};

        try t.expect(matcher.match(&getRequestWithPath("/users/any")));
        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(1, args.len);
        try t.expectEqualStrings("any", args[0]);
    }
    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users/")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(1, args.len);
        try t.expectEqualStrings("", args[0]);
    }
    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users")));
    }
}

test "TokenizedPath replacment in the end with termination" {
    const t = std.testing;

    const Matcher = TokenizedPath(&.{
        .{ .Identity = "/users/" },
        .{ .MatchUntil = "/orders" },
    }, _emptyFn);

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users/name/orders")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(1, args.len);
        try t.expectEqualStrings("name", args[0]);
    }

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users//orders")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(1, args.len);
        try t.expectEqualStrings("", args[0]);
    }

    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users/orders")));
    }
    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users/")));
    }
    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users")));
    }
}

test "TokenizedPath multiple replacements" {
    const t = std.testing;

    const Matcher = TokenizedPath(&.{
        .{ .Identity = "/users/" },
        .{ .MatchUntil = "/" },
        .{ .MatchUntil = &.{} },
    }, _emptyFn);

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users/@anyone/title")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(2, args.len);

        try t.expectEqualStrings("@anyone", args[0]);
        try t.expectEqualStrings("title", args[1]);
    }

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users//title")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(2, args.len);

        try t.expectEqualStrings("", args[0]);
        try t.expectEqualStrings("title", args[1]);
    }

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users/@anyone/")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(2, args.len);

        try t.expectEqualStrings("@anyone", args[0]);
        try t.expectEqualStrings("", args[1]);
    }

    {
        var matcher = Matcher{};
        try t.expect(matcher.match(&getRequestWithPath("/users//")));

        const args = matcher.routerArguments.constSlice();
        try t.expectEqual(2, args.len);

        try t.expectEqualStrings("", args[0]);
        try t.expectEqualStrings("", args[1]);
    }

    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users/")));
    }

    {
        var matcher = Matcher{};
        try t.expect(!matcher.match(&getRequestWithPath("/users/@anyone")));
    }
}

/// Matcher against `path`.
///
/// This matcher can extract arguments from the request path, by using `{}` replacement
/// in the `path`:
///
/// ````zig
/// Path("/users/{}", handleRequest)
/// ````
///
/// You can get the arguments by declaring dependency to `PathArgs`. All arguments
///  are extracted as string.
///
/// ````zig
/// fn handleRequest(args: PathArgs) !void {
///     std.debug.print("user = {s}", .{args.ref[0]});
/// }
/// ````
///
/// When the request path is "/users/name", the first element of the arguments is "name".
///
/// The replacements do not aware the separators. The `path` you passed will be treated as
/// a regular string (So things like `"/users/bill-{}"` are valid as well). Assume the `path` is above, when the request path is `/users/name/orders`,
/// you will get "name/orders". This replacement is a match-all replacement.
///
/// If you declare the `path` as `"/users/{}/order"`, the string after the replacement
/// (before the next replacement) can be called the "termination string". If any termination
/// can be found for the replacement, the replacement matching can be stopped before the termination.
/// Like in this example, when the request path is "/users/@anyone/order", you got "@anyone"
/// as the only argument.
///
/// There is no way to stop the matching of a match-all replacement. Normally, you would put the
/// matcher with the match-all replacement in the end of the related matchers:
///
/// ````zig
/// .{
///     Path("/users/{}/orders", handlerOrders),
///     Path("/users/{}/bills", handleBills),
///     Path("/users/{}/{}", AlwaysNotFound(.{}).handle), // If you want to prevent the match-all problem...
///     Path("/users/{}", handleUserInf),
/// }
/// ````
pub fn Path(comptime path: []const u8, comptime handler: anytype) type {
    const toks = tokenizePath(path);
    return TokenizedPath(&toks, handler);
}

pub fn Always(comptime handler: anytype) type {
    return struct {
        const routerTerminateAt = handler;
    };
}

pub fn Blueprint(comptime routes: anytype) type {
    return struct {
        const routerMatchTuple = routes;
    };
}

/// Get all the path arguments.
pub const PathArgs = struct {
    ref: []const []const u8,
};
