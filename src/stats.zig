pub fn get(request: *http.Request, config: *const Config, server_stats: *Server_Stats, cache: *Caches, arena: std.mem.Allocator, rate_limiter: *Rate_Limiter, downloads: *Download_Permission) !void {
    const server_start_time = server_stats.start_time.with_offset(0);
    const now = tempora.now_utc(request.io);
    const now_ts = now.timestamp_ms();

    const ms_since_start: f64 = @floatFromInt(now_ts - server_start_time.timestamp_ms());
    const hours_since_start = ms_since_start / std.time.ms_per_hour;

    const artifacts_served: f64 = @floatFromInt(server_stats.artifacts_served.load(.monotonic));
    const artifacts_downloaded: f64 = @floatFromInt(server_stats.upstream_artifacts_downloaded.load(.monotonic));

    const evictions_mem: f64 = @floatFromInt(server_stats.cache_evictions_mem.load(.monotonic));
    const evictions_fs: f64 = @floatFromInt(server_stats.cache_evictions_fs.load(.monotonic));

    var cache_entry_arena: std.heap.ArenaAllocator = .init(arena);
    defer cache_entry_arena.deinit();

    const mem_entries: Cache_Entry_Collection = .{
        .io = request.io,
        .now = now_ts,
        .arena = &cache_entry_arena,
        .entries = cache.mem.entries,
    };

    const fs_entries: Cache_Entry_Collection = .{
        .io = request.io,
        .now = now_ts,
        .arena = &cache_entry_arena,
        .entries = cache.fs.entries,
    };

    const cache_mem: Cache_Stats = .{
        .active_entries = try cache.mem.active_entries(),
        .bytes = cache.mem.total_bytes.load(.monotonic),
        .evictions = evictions_mem,
        .evictions_per_hour = round1(evictions_mem / hours_since_start),
        .entries = .{
            .data = &mem_entries,
            .size = cache.mem.entries.len,
            .element = Cache_Entry_Collection.element,
        },
    };

    const cache_fs: Cache_Stats = .{
        .active_entries = try cache.fs.active_entries(),
        .bytes = cache.fs.total_bytes.load(.monotonic),
        .evictions = evictions_fs,
        .evictions_per_hour = round1(evictions_fs / hours_since_start),
        .entries = .{
            .data = &fs_entries,
            .size = cache.fs.entries.len,
            .element = Cache_Entry_Collection.element,
        },
    };

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

    const downstream_permits_remaining = @atomicLoad(usize, &downloads.downstream_semaphore.permits, .seq_cst);
    const overflow_permits_remaining = @atomicLoad(usize, &downloads.overload_semaphore.permits, .seq_cst);

    const num_transfers_in_progress_downstream = config.max_concurrent_downloads - downstream_permits_remaining;
    const num_transfers_pending = config.max_concurrent_connections - overflow_permits_remaining -| num_transfers_in_progress_downstream;

    try request.render("stats.zk", .{
        .hostname = config.public_hostname,
        .server_start_time = server_start_time.fmt(dtf),
        .artifacts_served = artifacts_served,
        .artifacts_served_per_hour = round1(artifacts_served / hours_since_start),
        .artifacts_downloaded = artifacts_downloaded,
        .artifacts_downloaded_per_hour = round1(artifacts_downloaded / hours_since_start),
        .upstream_head_time_archive = std.Io.Duration.fromMilliseconds(server_stats.expected_upstream_head_time_ms_archive.load(.monotonic) * 2),
        .upstream_head_time_minisig = std.Io.Duration.fromMilliseconds(server_stats.expected_upstream_head_time_ms_minisig.load(.monotonic) * 2),
        .max_transfers_in_progress_upstream = config.upstream.max_connections,
        .max_transfers_in_progress_downstream = config.max_concurrent_downloads,
        .num_transfers_pending = num_transfers_pending,
        .transfers = server_stats.transfer_stats(),
        .cache = .{
            .mem = cache_mem,
            .fs = cache_fs,
        },
        .zigmirror_version = build_options.version,
        .zig_version = @import("builtin").zig_version,
        .show_rate_limit_stats = config.show_rate_limit_stats,
        .rate_limits = rate_limits,
    }, .{ .Context = Context });
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
    entries: zkittle.Collection,
};

const Cache_Entry = struct {
    index: usize,
    locked: bool,
    filename: []const u8,
    version: []const u8,
    artifact_type: []const u8,
    extension: ?Artifact.Extension,
    bytes: ?usize,
    transfer: ?struct {
        bytes: usize,
    },
    hash: []const u8,
    request_count: ?usize,
    requests_per_day: ?f64,
    first_request_time: ?i64,
    last_request_time: ?i64,
    request_duration_min: ?i64,
    request_duration_max: ?i64,
    request_duration_avg: ?i64,
    eviction_score: ?u64,
};

const Cache_Entry_Collection = struct {
    io: std.Io,
    now: i64,
    arena: *std.heap.ArenaAllocator,
    entries: []Cache.Entry,

    pub fn element(self_raw: *const anyopaque, index: usize) zkittle.Ref {
        const self_ptr: *const Cache_Entry_Collection = @ptrCast(@alignCast(self_raw));
        const self = self_ptr.*;
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const state = &self.entries[index];
        const entry = arena.create(Cache_Entry) catch return .nil;

        var artifact: ?Artifact = null;
        var version: []const u8 = "";
        var artifact_type: []const u8 = "";
        var filename: []const u8 = "";
        var bytes: ?usize = null;
        var transfer_bytes: ?usize = null;
        var hash: []const u8 = "";
        var eviction_score: ?u64 = null;
        var locked = false;
        {
            locked = state.try_lock_shared(self.io);
            defer if (locked) state.unlock_shared(self.io);

            if (state.artifact) |a| {
                artifact = a;
                filename = std.fmt.allocPrint(arena, "{f}", .{ a }) catch "OOM!";
                version = std.fmt.allocPrint(arena, "{f}", .{ a.version() }) catch "OOM!";
                artifact_type = std.fmt.allocPrint(arena, "{f}", .{ a.artifact_type.fmt(&a.buf) }) catch "OOM!";
                eviction_score = state.order_score(self.now);
            }

            switch (state.data) {
                .none => {
                    if (state.bytes) |b| {
                        bytes = b;
                    }
                },
                .transfer => |transfer| {
                    transfer_bytes = transfer.bytes_available.load(.acquire);
                    if (transfer_bytes.? > 0) {
                        bytes = transfer.data.len;
                    }
                },
                .owned => |data| {
                    bytes = data.len;
                },
            }

            if (state.hash) |digest| {
                hash = std.fmt.allocPrint(arena, "{x}", .{ digest }) catch "OOM";
            }
        }

        const request_count = state.requests.count.load(.monotonic);
        const duration_count = state.requests.duration_count.load(.monotonic);
        const duration_total = state.requests.duration_total.load(.monotonic);
        const first_time = state.requests.first_time.load(.monotonic);
        const last_time = state.requests.last_time.load(.monotonic);
        const ms_since_first: f64 = if (request_count > 0) @floatFromInt(self.now - first_time) else 0;
        const days_since_first = ms_since_first / std.time.ms_per_day;

        entry.* = .{
            .index = index,
            .locked = locked,
            .filename = filename,
            .version = version,
            .artifact_type = artifact_type,
            .extension = if (artifact) |a| a.extension else null,
            .bytes = bytes,
            .transfer = if (transfer_bytes) |b| .{ .bytes = b } else null,
            .hash = hash,
            .first_request_time = if (request_count > 0) first_time else null,
            .last_request_time = if (request_count > 0) last_time else null,
            .request_count = if (artifact) |_| request_count else null,
            .requests_per_day = if (days_since_first > 1.0 / 24.0) request_count / days_since_first else null,
            .request_duration_min = if (duration_count > 0) state.requests.duration_min.load(.monotonic) else null,
            .request_duration_max = if (duration_count > 0) state.requests.duration_max.load(.monotonic) else null,
            .request_duration_avg = if (duration_count > 0) std.math.cast(i64, duration_total / duration_count) else null,
            .eviction_score = eviction_score,
        };

        return zkittle.ref_from_ptr(Cache_Entry, entry, Context.cache.mem.entries);
    }
};

const Rate_Limit_Entry = struct {
    ip: std.Io.net.IpAddress,
    requests_remaining: u64,
    last_generation_time: i64,
};

const Context = struct {
    pub const transfers = struct {
        pub const upstream = struct {
            pub fn bps(b: f32, w: *std.Io.Writer) std.Io.Writer.Error!void {
                try w.print("{d:.1}", .{ fmt.si.value(b, "B/s") });
            }
        };
        pub const downstream = upstream;
    };

    pub const cache = struct {
        pub const mem = struct {
            pub fn bytes(b: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
                try w.print("{d:.1}", .{ fmt.bytes(b) });
            }

            pub const entries = struct {
                pub const bytes = mem.bytes;

                pub const transfer = struct {
                    pub const bytes = mem.bytes;
                };

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

const build_options = @import("build_options");
const Download_Permission = @import("Download_Permission.zig");
const Rate_Limiter = @import("Rate_Limiter.zig");
const Config = @import("Config.zig");
const Cache = @import("Cache.zig");
const Caches = @import("Caches.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const http = @import("http");
const tempora = @import("tempora");
const zkittle = @import("zkittle");
const fmt = @import("fmt");
const std = @import("std");
