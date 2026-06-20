
pub fn init(io: std.Io, env: *const std.process.Environ.Map) void {
    _ = io;
    _ = env;
}

pub fn ready(loop: *http.Loop) void {
    log.debug("zigmirror service is ready!", .{});
    _ = loop;
}

pub fn stopping(loop: *http.Loop) void {
    log.debug("zigmirror service is stopping!", .{});
    _ = loop;
}

const log = std.log.scoped(.zigmirror);

const http = @import("http");
const std = @import("std");
