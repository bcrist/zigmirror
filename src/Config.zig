public_hostname: []const u8 = "localhost",
listen: []const struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
} = &.{ .{} },
cache: struct {
    mem: struct {
        max_entries: usize = 50,
        max_bytes: usize = 1024 * 1024 * 1024,
        recheck_not_found_after_seconds: usize = 60,
        periodic_eviction: ?struct {
            interval_minutes: u32 = 5,
            min_age_minutes: i64 = 15,
            min_inactive_minutes: i64 = 0,
            min_requests: usize = 2,
        } = .{},
    } = .{},
    fs: struct {
        max_entries: usize = 1000,
        max_bytes: usize = 20 * 1024 * 1024 * 1024,
        path: []const u8 = "/usr/local/var/cache/zigmirror",
        min_requests: u32 = 1,
    } = .{},
} = .{},
request_rate_limit: ?Rate_Limiter.Config = .{},
default_upstream_timeout_seconds: u32 = 5,
min_upstream_timeout_seconds: u32 = 2,
max_concurrent_upstream_downloads: usize = 4,
// TODO index_json_refresh_interval_minutes: usize = 60,
// TODO show_rate_limit_stats: bool = false,
allow_shutdown: bool = false,

pub fn load(reader: *std.Io.File.Reader, arena: std.mem.Allocator, temp: std.mem.Allocator) !Config {
    var sx_reader = sx.reader(temp, &reader.interface);
    defer sx_reader.deinit();

    return load_internal(&sx_reader, arena) catch |err| switch (err) {
        error.SExpressionSyntaxError => {
            var buf: [64]u8 = undefined;
            var stderr = std.debug.lockStderr(&buf);
            defer std.debug.unlockStderr();
            const ctx = try sx_reader.token_context();
            try ctx.print_for_file(reader, &stderr.file_writer.interface, 100);
            try stderr.file_writer.interface.flush();
            return error.InvalidConfigFile;
        },
        else => |e| return e,
    };
}

fn load_internal(reader: *sx.Reader, arena: std.mem.Allocator) !Config {
    try reader.require_expression("zigmirror");
    const config = try reader.require_object(arena, Config, Reader_Context);
    try reader.require_close();
    return config;
}

pub fn save(self: Config, writer: *std.Io.Writer, temp: std.mem.Allocator) !void {
    var sx_writer = sx.writer(temp, writer);
    defer sx_writer.deinit();

    try sx_writer.expression_expanded("zigmirror");
    try sx_writer.object(self, Writer_Context);
    try sx_writer.done();
}

const Writer_Context = struct {
    pub const listen = struct {
        pub const inline_fields = &.{ "host", "port" };
    };
    pub const cache = struct {
        pub const mem = struct {
            pub const inline_fields = &.{ "max_entries", "max_bytes" };
            pub fn max_bytes(bytes: usize, writer: *sx.Writer, wrap: bool) !void {
                if (wrap) try writer.expression("max_bytes");
                try writer.print_quoted("{d}", .{ fmt.bytes(bytes) });
                if (wrap) try writer.close();
            }
        };
        pub const fs = struct {
            pub const inline_fields = &.{ "max_entries", "max_bytes" };
            pub const max_bytes = mem.max_bytes;
        };
    };
};

const Reader_Context = struct {
    pub const listen = Writer_Context.listen;
    pub const cache = struct {
        pub const mem = struct {
            pub const inline_fields = Writer_Context.cache.mem.inline_fields;
            pub fn max_bytes(arena: std.mem.Allocator, reader: *sx.Reader, wrap: bool) !?usize {
                _ = arena;
                if (wrap) {
                    if (!try reader.expression("max_bytes")) return null;
                }
                var raw = try reader.require_any_string();
                raw = std.mem.trim(u8, raw, &std.ascii.whitespace);

                var mult: f64 = 1;

                var last_char: u8 = if (raw.len > 0) raw[raw.len - 1] else 0;
                if (last_char == 'B' or last_char == 'b') {
                    raw = raw[0 .. raw.len - 1];
                    if (raw.len > 0) last_char = raw[raw.len - 1];
                }

                if (last_char == 'K' or last_char == 'k') {
                    raw = raw[0 .. raw.len - 1];
                    mult = 1024;
                } else if (last_char == 'M' or last_char == 'm') {
                    raw = raw[0 .. raw.len - 1];
                    mult = 1024 * 1024;
                } else if (last_char == 'G' or last_char == 'g') {
                    raw = raw[0 .. raw.len - 1];
                    mult = 1024 * 1024 * 1024;
                } else if (last_char == 'T' or last_char == 't') {
                    raw = raw[0 .. raw.len - 1];
                    mult = 1024 * 1024 * 1024 * 1024;
                }

                raw = std.mem.trimEnd(u8, raw, &std.ascii.whitespace);

                const mantissa = std.fmt.parseFloat(f64, raw) catch return error.SExpressionSyntaxError;
                const bytes: usize = @intFromFloat(mantissa * mult);

                if (wrap) try reader.require_close();

                return bytes;
            }
        };
        pub const fs = struct {
            pub const inline_fields = Writer_Context.cache.fs.inline_fields;
            pub const max_bytes = mem.max_bytes;
        };
    };
};

pub fn shutdown_check(self: *const Config) !void {
    if (!self.allow_shutdown) return error.NotFound;
}

const Config = @This();

const Rate_Limiter = @import("Rate_Limiter.zig");
const fmt = @import("fmt");
const sx = @import("sx");
const std = @import("std");
