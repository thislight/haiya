const std = @import("std");

/// HTTP Status Code
///
/// Some explainations are copied from
/// [HTTP Response Status Code - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Status#information_responses).
pub const Code = enum(u16) {
    // 1xx - Informational Responses
    Continue = 100,
    @"Switching Protocols" = 101,
    Processing = 102,
    @"Early Hints" = 103,

    // 2xx - Successful Responses
    OK = 200,
    Created = 201,
    Accepted = 202,
    @"Non-Authoritative Information" = 203,
    @"No Content" = 204,
    @"Reset Content" = 205,
    @"Partial Content" = 206,
    @"Multi-Status" = 207,
    @"Already Reported" = 208,
    @"IM Used" = 226,

    // 3xx - Redirection Messages
    @"Multiple Choices" = 300,
    @"Moved Permanently" = 301,
    Found = 302,
    @"See Other" = 303,
    @"Not Modified" = 304,
    /// **deprecated** -
    /// Defined in a previous version of the HTTP specification to indicate
    /// that a requested response must be accessed by a proxy.
    /// It has been deprecated due to security concerns regarding in-band configuration
    /// of a proxy.
    @"Use Proxy" = 305,
    // _unused_0 = 306,
    @"Temporary Redirect" = 307,
    @"Permanent Redirect" = 308,

    // 4xx - Client error response
    @"Bad Request" = 400,
    /// Although the HTTP standard specifies "unauthorized",
    /// semantically this response means "unauthenticated".
    /// That is, the client must authenticate itself to get the requested response.
    Unauthorized = 401,
    @"Payment Required" = 402,
    /// The client does not have access rights to the content;
    /// that is, it is unauthorized, so the server is refusing
    /// to give the requested resource. Unlike 401 Unauthorized,
    /// the client's identity is known to the server.
    Forbidden = 403,
    @"Not Found" = 404,
    @"Method Not Allowed" = 405,
    @"Not Acceptable" = 406,
    @"Proxy Authentication Required" = 407,
    @"Request Timeout" = 408,
    Conflict = 409,
    Gone = 410,
    @"Length Required" = 411,
    @"Precondition Failed" = 412,
    @"Payload Too Large" = 413,
    @"URI Too Long" = 414,
    @"Unsupported Media Type" = 415,
    @"Range Not Satisfiable" = 416,
    @"Expectation Failed" = 417,
    @"I'm a teapot" = 418,
    @"Misdirected Request" = 421,
    @"Unprocessable Content" = 422,
    Locked = 423,
    @"Failed Dependency" = 424,
    @"Too Early" = 425,
    @"Upgrade Required" = 426,
    @"Precondition Required" = 428,
    @"Too Many Requuests" = 429,
    @"Request Header Field Too Large" = 431,
    @"Unavailable For Legal Reasons" = 451,

    // 5xx - Server error responses
    @"Internal Server Error" = 500,
    @"Not Implemented" = 501,
    @"Bad Gateway" = 502,
    @"Service Unavailable" = 503,
    @"Gateway Timeout" = 504,
    @"HTTP Version Not Supported" = 505,
    @"Variant Also Negotiates" = 506,
    @"Insufficient Storage" = 507,
    @"Loop Detected" = 508,
    @"Not Extended" = 510,
    @"Network Authentication Required" = 511,

    pub fn text(self: Code) [:0]const u8 {
        return @tagName(self);
    }

    pub fn fromInt(n: u16) ?Code {
        return std.meta.intToEnum(Code, n) catch null;
    }

    pub fn int(self: Code) u16 {
        return @intFromEnum(self);
    }
};
