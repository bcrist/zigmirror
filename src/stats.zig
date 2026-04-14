pub fn get(request: *http.Request, config: *const Config, server_stats: *Server_Stats, cache: *Caches, arena: std.mem.Allocator) !void {
    const server_start_time = server_stats.start_time.with_offset(0);
    const now = tempora.now(request.io);

    const ms_since_start: f64 = @floatFromInt(now.timestamp_ms() - server_start_time.timestamp_ms());
    const hours_since_start = ms_since_start / std.time.ms_per_hour;

    const artifacts_served: f64 = @floatFromInt(server_stats.artifacts_served.load(.monotonic));
    const artifacts_downloaded: f64 = @floatFromInt(server_stats.upstream_artifacts_downloaded.load(.monotonic));

    const evictions_mem: f64 = @floatFromInt(server_stats.cache_evictions_mem.load(.monotonic));
    const evictions_fs: f64 = @floatFromInt(server_stats.cache_evictions_fs.load(.monotonic));

    const cache_mem: Cache_Stats = .{
        .active_entries = try cache.mem.active_entries(),
        .bytes = fmt.bytes(cache.mem.total_bytes.load(.monotonic)),
        .evictions = evictions_mem,
        .evictions_per_hour = round1(evictions_mem / hours_since_start),
        .entries = try arena.alloc(Cache_Entry, cache.mem.entries.len),
    };
    try populate_cache_entries(cache.mem.io, arena, cache.mem.entries, cache_mem.entries, now.timestamp_ms());

    const cache_fs: Cache_Stats = .{
        .active_entries = try cache.fs.active_entries(),
        .bytes = fmt.bytes(cache.fs.total_bytes.load(.monotonic)),
        .evictions = evictions_fs,
        .evictions_per_hour = round1(evictions_fs / hours_since_start),
        .entries = try arena.alloc(Cache_Entry, cache.fs.entries.len),
    };
    try populate_cache_entries(cache.fs.io, arena, cache.fs.entries, cache_fs.entries, now.timestamp_ms());

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
    }, .{ .Context = Context });
}

// round to 1 decimal place
fn round1(val: f64) f64 {
    return @round(val * 10) / 10;
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

        stats.* = .{
            .index = index,
            .filename = filename,
            .version = version,
            .artifact_type = artifact_type,
            .extension = if (artifact) |a| a.extension else null,
            .bytes = if (bytes) |b| fmt.bytes(b) else null,
            .first_request_time = if (request_count > 0) DTO.from_timestamp_ms(state.requests.first_time.load(.monotonic), null).fmt(dtf) else null,
            .last_request_time = if (request_count > 0) DTO.from_timestamp_ms(state.requests.last_time.load(.monotonic), null).fmt(dtf) else null,
            .request_count = if (artifact) |_| request_count else null,
            .request_duration_min = if (duration_count > 0) std.Io.Duration.fromMilliseconds(state.requests.duration_min.load(.monotonic)) else null,
            .request_duration_max = if (duration_count > 0) std.Io.Duration.fromMilliseconds(state.requests.duration_max.load(.monotonic)) else null,
            .request_duration_avg = if (duration_count > 0) std.Io.Duration.fromMilliseconds(@intCast(duration_total / duration_count)) else null,
            .eviction_score = eviction_score,
        };
    }
}

const Cache_Stats = struct {
    active_entries: usize,
    bytes: @TypeOf(fmt.bytes(0)),
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
    bytes: ?@TypeOf(fmt.bytes(0)),
    request_count: ?usize,
    first_request_time: ?DTF,
    last_request_time: ?DTF,
    request_duration_min: ?std.Io.Duration,
    request_duration_max: ?std.Io.Duration,
    request_duration_avg: ?std.Io.Duration,
    eviction_score: ?u64,
};

const Context = struct {
    pub const cache = struct {
        pub const mem = struct {
            pub const bytes = "d:.1";
            pub const entries = struct {
                pub const bytes = "d:.1";
            };
        };
        pub const fs = mem;
    };
};

const DTO = tempora.Date_Time.With_Offset;
const dtf = DTO.sql_local;
const DTF = DTO.Formatter(dtf);

const zon = @import("zon");
const Config = @import("Config.zig");
const Cache = @import("Cache.zig");
const Caches = @import("Caches.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const http = @import("http");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
