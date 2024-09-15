//! ## Haiya
//!
//! Haiya is a HTTP server designed as a library, with config-as-code in mind.
//!
//! ### I/O component
//!
//! - `GlobalContext` - you must initialise it before the other code
//! - the server entry point - `Server`
//! - a `Session` represents a TCP connection (in HTTP/1.1 or h2) or a QUIC connection (in h3)
//! - a `Stream` is a byte stream in a `Session`
//!
//! ### HTTP component
//!
//! - a `Request` or `Response` is a HTTP message without the body
//! - HTTP `Transcation` is the context with a `Request` and a `Response`
//! - `Headers` is a paired list of HTTP headers
//! - `StatusCode` has all defined HTTP status code
//!
//! ### Router component
//!
//! - `routers` is the core component of the router
//!   - use `routers.DefineRouter` to define the router type
//! - `handlers` has handlers for specific usecases. Like:
//!   - `handlers.AlwaysNotFound` makes handlers which are always return HTTP "Not Found"
const std = @import("std");

pub const GlobalContext = @import("./GlobalContext.zig");
pub const Server = @import("./Server.zig");
pub const Session = @import("./Session.zig");
pub const Stream = @import("./Stream.zig");

pub const Request = @import("./http/Request.zig");
pub const Response = @import("./http/Response.zig");
pub const Transcation = @import("./http/Transcation.zig");
pub const Headers = @import("./http/Headers.zig");
pub const StatusCode = @import("./http/statuses.zig").Code;

pub const routers = @import("./routers.zig");
pub const handlers = @import("./handlers.zig");

test {
    _ = @import("./inject.zig");
    _ = @import("./http/h1.zig");
    _ = @import("./routers.zig");
}
