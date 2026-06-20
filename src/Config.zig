/// The hostname that should be used to create links in /stats, /index.json, etc.
public_hostname: []const u8 = "localhost:8080",

/// The IP addresses/hostnames and port numbers to listen on.
/// You may specify multiple entries (e.g. to listen on both IPv4 and IPv6)
listen: []const struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
} = &.{ .{} },

cache: struct {
    mem: struct {
        /// The maximum number of artifacts that can be held in memory before an entry will be pushed to the filesystem or evicted.
        /// Note this includes cached "not found" placeholder entries.
        max_entries: usize = 50,

        /// The maximum total size of in-memory artifact data before an entry will be pushed to the filesystem or evicted.
        max_bytes: usize = 1024 * 1024 * 1024,

        /// A background job periodically looks to move entries from the memory cache to the filesystem or evict, even before the memory cache is not yet full.
        periodic_eviction: ?struct {
            /// Determines how often the in-memory cache will be scanned.
            interval_minutes: u32 = 5,

            /// Entries newer than this will not be evicted by the periodic eviction job.
            min_age_minutes: i64 = 15,

            /// Entries that have been used more recently than this will not be evicted by the periodic eviction job.
            min_inactive_minutes: i64 = 0,

            /// Entries that have been requested fewer than this many times in total will not be evicted by the periodic eviction job
            min_requests: usize = 2,
        } = .{},
    } = .{},
    fs: struct {
        /// The maximum number of artifacts that can be stored on disk before one will be deleted.
        max_entries: usize = 1000,

        /// The maximum total size of on-disk artifact data before one will be deleted.
        max_bytes: usize = 20 * 1024 * 1024 * 1024,

        /// The directory where on-disk artifacts should be stored.
        /// zigmirror must have read and write access to this directory.
        path: []const u8 = "/usr/local/var/cache/zigmirror",

        /// When an artifact is being evicted from the in-memory cache, it will only be added to the filesystem cache if it has been requested at least this many times.
        /// If you set this higher than 1, you probably will also need to tune the in-memory cache configuration.  In particular,
        /// cache.mem.periodic_eviction.min_requests should be >= cache.fs.min_requests.
        min_requests: u32 = 1,
    } = .{},
} = .{},

/// If a downstream client attempts to start a download, but there are already this many open connections, the new connection will immediately fail with a 503 response.
max_concurrent_connections: u32 = 100,

/// If a downstream client attempts to start a download, but there are already this many downloads in progress, the new connection will be queued to wait until one or more downloads complete.
/// This ensures that once a download starts, it should continue with some minimum acceptable bandwidth until it finishes (at least for artifacts that are already cached).
max_concurrent_downloads: u32 = 10,

/// The maximum amount of time a connection can remain open while waiting for a slot in `max_concurrent_downloads` to open up.
/// Note the client may decide to give up on the connection earlier than this.
max_wait_time_seconds: u32 = 15,

/// The maximum total time that a single request may use before it will be cancelled.
/// Avoid setting this less than a few minutes, since users with slow connections may not be able to download a 20-100MB file in that amount of time.
request_timeout_seconds: u32 = 60 * 10,

request_rate_limit: ?Rate_Limiter.Config = .{},

upstream: struct {
    /// If a requested artifact is not cached, but there are already this many open connections to ziglang.org, the request will be queued to wait until one or more upstream downloads complete.
    /// This ensures that once an upstream download starts, it should continue with some minimum acceptable bandwidth until it finishes, and that we won't contribute significantly to a DDoS volume amplification attack against ziglang.org.
    max_connections: u32 = 4,

    /// The maximum amount of time a connection can remain open while waiting for a slot in `upstream.max_connections` to open up.
    max_wait_time_seconds: u32 = 30,

    /// When the server first starts, if a TCP connection to ziglang.org can't be achieved within this amount of time, the request fails.
    /// N.B. the actual connect timeout is slowly nudged over time based on how long ziglang.org actually takes to respond with the HTTP headers.
    default_connect_timeout_seconds: u32 = 5,

    /// The actual connect timeout will never be decreased below this threshold, even if ziglang.org responds much faster in most cases.
    min_connect_timeout_seconds: u32 = 2,

    /// Once ziglang.org responds with HTTP headers, it has this long to begin sending file content; otherwise the request will be aborted.
    initial_transfer_timeout_seconds: u32 = 5,

    /// Once an upstream transfer has begun, if the transfer speed goes to zero and no progress is made for this long, it will be aborted.
    dead_transfer_timeout_seconds: u32 = 1,

    /// Upstream downloads may not take longer than this total amount of time, or they will be aborted.
    /// This will have no effect if it's less than `request_timeout_seconds`, but note that since reading from the upstream connection and writing to the downstream client connection are interleaved,
    /// a slow client connection may cause this upstream transfer time limit to be exceeded accidentally, so don't set it too low.
    max_transfer_time_seconds: u32 = 60 * 5,

    /// If the upstream endpoint returns a 404 Not Found for an artifact, that response will normally be recorded in the in-memory cache.
    /// This helps avoid participating in DDoS volume amplification attacks against ziglang.org.
    /// But there are also cases where the not found status can become stale (e.g. if someone requests a new nightly/release just before it becomes available on ziglang.org).
    /// So "not found" entries are rechecked even while still in the cache, as long as the last upstream check was at least this long ago.
    recheck_not_found_after_seconds: u32 = 60,
} = .{},

/// When set to true, rate limit information will be included in the /stats endpoint.
show_rate_limit_stats: bool = false,

/// When set to false, llvm/lld/clang devkit artifacts will not be served or cached.
/// Zig community mirrors are not required to host these, but they are served from ziglang.org/deps/ and are especially useful for building the zig compiler on Windows.
allow_devkit_artifacts: bool = true,

/// When set to true, the server can be gracefully shut down by sending a GET request to the /shutdown endpoint.
/// Generally this should only be enabled for local testing.
allow_shutdown: bool = false,

// TODO index_json_refresh_interval_minutes: usize = 60,

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
