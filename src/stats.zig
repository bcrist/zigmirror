pub fn get(request: *http.Request, config: *const Config, server_stats: *Server_Stats, cache: *Caches, arena: std.mem.Allocator, rate_limiter: *Rate_Limiter) !void {
    const server_start_time = server_stats.start_time.with_offset(0);
    const now = tempora.now(request.io);
    const now_ts = now.timestamp_ms();

    const ms_since_start: f64 = @floatFromInt(now_ts - server_start_time.timestamp_ms());
    const hours_since_start = ms_since_start / std.time.ms_per_hour;

    const artifacts_served: f64 = @floatFromInt(server_stats.artifacts_served.load(.monotonic));
    const artifacts_downloaded: f64 = @floatFromInt(server_stats.upstream_artifacts_downloaded.load(.monotonic));

    const evictions_mem: f64 = @floatFromInt(server_stats.cache_evictions_mem.load(.monotonic));
    const evictions_fs: f64 = @floatFromInt(server_stats.cache_evictions_fs.load(.monotonic));

    const cache_mem: Cache_Stats = .{
        .active_entries = try cache.mem.active_entries(),
        .bytes = cache.mem.total_bytes.load(.monotonic),
        .evictions = evictions_mem,
        .evictions_per_hour = round1(evictions_mem / hours_since_start),
        .entries = try arena.alloc(Cache_Entry, cache.mem.entries.len),
    };
    try populate_cache_entries(cache.mem.io, arena, cache.mem.entries, cache_mem.entries, now_ts);

    const cache_fs: Cache_Stats = .{
        .active_entries = try cache.fs.active_entries(),
        .bytes = cache.fs.total_bytes.load(.monotonic),
        .evictions = evictions_fs,
        .evictions_per_hour = round1(evictions_fs / hours_since_start),
        .entries = try arena.alloc(Cache_Entry, cache.fs.entries.len),
    };
    try populate_cache_entries(cache.fs.io, arena, cache.fs.entries, cache_fs.entries, now_ts);

    var rate_limits: []Rate_Limit_Entry = &.{};
    
    if (config.show_rate_limit_stats) {
        if (rate_limiter.config) |rlconfig| {
            try rate_limiter.mutex.lock(rate_limiter.io);
            defer rate_limiter.mutex.unlock(rate_limiter.io);

            var list: std.ArrayList(Rate_Limit_Entry) = try .initCapacity(arena, rate_limiter.clients.count());
            defer list.deinit(arena);

            var iter = rate_limiter.clients.iterator();
            while (iter.next()) |entry| {
                var state = entry.value_ptr.*;
                _ = state.update(now_ts, rlconfig);
                try list.append(arena, .{
                    .ip = entry.key_ptr.*,
                    .requests_remaining = state.requests_remaining,
                    .last_generation_time = state.last_generation_time,
                });
            }

            rate_limits = try list.toOwnedSlice(arena);
        }
    }

    try request.render("stats.zk", .{
        .hostname = config.public_hostname,
        .server_start_time = server_start_time.fmt(dtf),
        .artifacts_served = artifacts_served,
        .artifacts_served_per_hour = round1(artifacts_served / hours_since_start),
        .artifacts_downloaded = artifacts_downloaded,
        .artifacts_downloaded_per_hour = round1(artifacts_downloaded / hours_since_start),
        .upstream_head_time_archive = std.Io.Duration.fromMilliseconds(server_stats.expected_upstream_head_time_ms_archive.load(.monotonic) * 2),
        .upstream_head_time_minisig = std.Io.Duration.fromMilliseconds(server_stats.expected_upstream_head_time_ms_minisig.load(.monotonic) * 2),
        .cache = .{
            .mem = cache_mem,
            .fs = cache_fs,
        },
        .zigmirror_version = zon.version,
        .show_rate_limit_stats = config.show_rate_limit_stats,
        .rate_limits = rate_limits,
    }, .{ .Context = Context });
}

fn populate_cache_entries(io: std.Io, arena: std.mem.Allocator, state_entries: []Cache.Entry, stats_entries: []Cache_Entry, now: i64) !void {
    for (0.., state_entries, stats_entries) |index, *state, *stats| {
        var artifact: ?Artifact = null;
        var version: []const u8 = "";
        var artifact_type: []const u8 = "";
        var filename: []const u8 = "";
        var bytes: ?usize = null;
        var eviction_score: ?u64 = null;
        {
            try state.lock_shared(io);
            defer state.unlock_shared(io);

            if (state.artifact) |a| {
                artifact = a;
                filename = try std.fmt.allocPrint(arena, "{f}", .{ a });
                version = try std.fmt.allocPrint(arena, "{f}", .{ a.version() });
                artifact_type = try std.fmt.allocPrint(arena, "{f}", .{ a.artifact_type.fmt(&a.buf) });
                eviction_score = state.order_score(now);
            }
            if (state.data) |data| bytes = data.len else if (state.bytes) |b| bytes = b;
        }

        const request_count = state.requests.count.load(.monotonic);
        const duration_count = state.requests.duration_count.load(.monotonic);
        const duration_total = state.requests.duration_total.load(.monotonic);
        const first_time = state.requests.first_time.load(.monotonic);
        const last_time = state.requests.last_time.load(.monotonic);
        const first_to_last_ms: f64 = if (request_count > 0 and last_time > first_time) @floatFromInt(last_time - first_time) else 0;
        const first_to_last_days = first_to_last_ms / std.time.ms_per_day;

        stats.* = .{
            .index = index,
            .filename = filename,
            .version = version,
            .artifact_type = artifact_type,
            .extension = if (artifact) |a| a.extension else null,
            .bytes = bytes,
            .first_request_time = if (request_count > 0) first_time else null,
            .last_request_time = if (request_count > 0) last_time else null,
            .request_count = if (artifact) |_| request_count else null,
            .requests_per_day = if (first_to_last_days > 0) request_count / first_to_last_days else null,
            .request_duration_min = if (duration_count > 0) state.requests.duration_min.load(.monotonic) else null,
            .request_duration_max = if (duration_count > 0) state.requests.duration_max.load(.monotonic) else null,
            .request_duration_avg = if (duration_count > 0) @intCast(duration_total / duration_count) else null,
            .eviction_score = eviction_score,
        };
    }
}

// round to 1 decimal place
fn round1(val: f64) f64 {
    return @round(val * 10) / 10;
}

const Cache_Stats = struct {
    active_entries: usize,
    bytes: usize,
    evictions: f64,
    evictions_per_hour: f64,
    entries: []Cache_Entry,
};

const Cache_Entry = struct {
    index: usize,
    filename: []const u8,
    version: []const u8,
    artifact_type: []const u8,
    extension: ?Artifact.Extension,
    bytes: ?usize,
    request_count: ?usize,
    requests_per_day: ?f64,
    first_request_time: ?i64,
    last_request_time: ?i64,
    request_duration_min: ?i64,
    request_duration_max: ?i64,
    request_duration_avg: ?i64,
    eviction_score: ?u64,
};

const Rate_Limit_Entry = struct {
    ip: std.Io.net.IpAddress,
    requests_remaining: u64,
    last_generation_time: i64,
};

const Context = struct {
    pub const cache = struct {
        pub const mem = struct {
            pub fn bytes(b: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
                try w.print("{d:.1}", .{ fmt.bytes(b) });
            }

            pub const entries = struct {
                pub const bytes = mem.bytes;

                pub const requests_per_day = " ({d:.0}/d)";

                pub fn first_request_time(ts: i64, w: *std.Io.Writer) std.Io.Writer.Error!void {
                    try w.print("{f}", .{ DTO.from_timestamp_ms(ts, null).fmt(dtf) });
                }
                pub const last_request_time = first_request_time;

                pub fn request_duration_min(ms: i64, w: *std.Io.Writer) std.Io.Writer.Error!void {
                    try w.print("{f}", .{ std.Io.Duration.fromMilliseconds(ms) });
                }
                pub const request_duration_max = request_duration_min;
                pub const request_duration_avg = request_duration_min;
            };
        };
        pub const fs = mem;
    };
    pub const rate_limits = struct {
        pub fn last_generation_time(ts: i64, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{f}", .{ DTO.from_timestamp_ms(ts, null).fmt(dtf) });
        }
    };
};

const DTO = tempora.Date_Time.With_Offset;
const dtf = DTO.sql_local;

const zon = @import("zon");
const Rate_Limiter = @import("Rate_Limiter.zig");
const Config = @import("Config.zig");
const Cache = @import("Cache.zig");
const Caches = @import("Caches.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const http = @import("http");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
