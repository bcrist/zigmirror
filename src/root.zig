pub fn get(request: *http.Request, config: *const Config) !void {
    try request.render("root.zk", .{
        .hostname = config.public_hostname,
        .zigmirror_version = build_options.version,
        .zig_version = @import("builtin").zig_version,
        .allow_devkits = config.allow_devkit_artifacts,
    }, .{});
}

const Config = @import("Config.zig");
const build_options = @import("build_options");
const http = @import("http");
const std = @import("std");
