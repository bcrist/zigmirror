mem: Cache,
fs: Cache,

pub fn evict_all_mem(cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    for (cache.mem.entries) |*entry| {
        const ref: Cache.Entry.Ref = .init_shared(cache.mem.io, entry);
        try ref.lock();

        if (entry.artifact) |artifact| {
            cache.evict_from_mem_cache(server_stats, config, ref) catch |err| {
                log.err("Error attempting to evict {f} from mem cache: {t}", .{ artifact, err });
            };
        } else {
            ref.unlock();
        }
    }
}

pub fn periodic_cleanup(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    const peconfig = config.cache.mem.periodic_eviction.?;
    for (cache.mem.entries) |*entry| {
        const ref: Cache.Entry.Ref = .init_shared(cache.mem.io, entry);
        try ref.lock();

        if (entry.artifact == null or entry.requests.count.load(.monotonic) < peconfig.min_requests) {
            ref.unlock();
            continue;
        }

        const now = tempora.now(cache.mem.io).timestamp_ms();

        const age = now - entry.requests.first_time.load(.monotonic);
        const inactive = now - entry.requests.last_time.load(.monotonic);
        if (age < peconfig.min_age_minutes * std.time.ms_per_min or inactive < peconfig.min_inactive_minutes * std.time.ms_per_min) {
            ref.unlock();
            continue;
        }

        const artifact = entry.artifact.?;

        cache.evict_from_mem_cache(server_stats, config, ref) catch |err| {
            log.err("Error attempting to evict {f} from mem cache: {t}", .{ artifact, err });
        };
    }
}

pub fn cleanup(cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    try cache.cleanup_mem(server_stats, config);
    try cache.cleanup_fs(server_stats, config);
}

fn cleanup_mem(cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    for (0..100) |_| {
        if (cache.mem.total_bytes.load(.monotonic) <= config.cache.mem.max_bytes) return;
        try cache.maybe_evict_from_mem_cache(server_stats, config);
    } else {
        log.warn("Memory cache oversize ({d} / {d}) after 100 attempts to evict from it", .{
            fmt.bytes(cache.mem.total_bytes.load(.monotonic)),
            fmt.bytes(config.cache.mem.max_bytes),
        });
    }
}

fn cleanup_fs(cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    for (0..100) |_| {
        if (cache.fs.total_bytes.load(.monotonic) <= config.cache.fs.max_bytes) return;
        try maybe_evict_from_fs_cache(&cache.fs, server_stats, config.cache.fs.path);
    } else {
        log.warn("FS cache oversize ({d} / {d}) after 100 attempts to evict from it", .{
            fmt.bytes(cache.fs.total_bytes.load(.monotonic)),
            fmt.bytes(config.cache.fs.max_bytes),
        });
    }
}

pub fn maybe_evict_from_mem_cache(cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    log.debug("maybe_evict_from_mem_cache", .{});
    if (try cache.mem.get_worst()) |mem_ref| {
        try cache.evict_from_mem_cache(server_stats, config, mem_ref);
    }
}

fn evict_from_mem_cache(cache: *Caches, server_stats: *Server_Stats, config: *const Config, mem_ref: Cache.Entry.Ref) !void {
    const artifact_to_remove = mem_ref.ptr.artifact.?;
    log.debug("evict_from_mem_cache {f}", .{ artifact_to_remove });

    if (mem_ref.ptr.data) |data| {
        errdefer mem_ref.unlock();

        var add_to_fs_cache = mem_ref.ptr.requests.count.load(.monotonic) >= config.cache.fs.min_requests;

        if (add_to_fs_cache) {
            const active_entries = try cache.fs.active_entries();
            if (active_entries >= cache.fs.entries.len or cache.fs.total_bytes.load(.monotonic) + data.len > config.cache.fs.max_bytes) {
                var fs_artifact: ?Artifact = null;
                if (try cache.fs.get_worst()) |fs_ref| {
                    defer fs_ref.unlock();

                    const now = tempora.now(cache.mem.io).timestamp_ms();

                    if (mem_ref.ptr.order(fs_ref.ptr, now) != .lt) {
                        // worst item in fs cache is better than the item we're evicting from mem cache, so don't add it to the fs cache
                        add_to_fs_cache = false;
                    } else {
                        fs_artifact = fs_ref.ptr.artifact.?;
                    }
                }
                if (fs_artifact) |artifact| {
                    try evict_from_fs_cache(&cache.fs, server_stats, artifact, config.cache.fs.path);
                }
            }
        }

        if (add_to_fs_cache) {
            try cache.add_artifact_to_fs_cache(server_stats, mem_ref, config.cache.fs.path);
        }
    }

    mem_ref.unlock();

    if (try cache.mem.remove(artifact_to_remove)) |ref| {
        defer ref.unlock();
        _ = server_stats.cache_evictions_mem.fetchAdd(1, .monotonic);
        log.info("Evicted {f} from mem cache", .{ artifact_to_remove });
    }

    try cache.cleanup_fs(server_stats, config);
}

fn add_artifact_to_fs_cache(cache: *Caches, server_stats: *Server_Stats, mem_ref: Cache.Entry.Ref, cache_path: []const u8) !void {
    const mem_artifact = mem_ref.ptr.artifact.?;
    const data = mem_ref.ptr.data.?;

    log.debug("add_artifact_to_fs_cache {f}", .{ mem_artifact });

    const fs_ref: Cache.Entry.Ref = for (0..100) |_| {
        if (try cache.fs.get_or_add(mem_artifact)) |ref| break ref;
        try maybe_evict_from_fs_cache(&cache.fs, server_stats, cache_path);
    } else {
        log.warn("Failed to add {f} to fs cache: could not find free slot", .{ mem_artifact });
        return;
    };
    defer fs_ref.unlock();

    const cache_dir = std.Io.Dir.cwd().createDirPathOpen(cache.fs.io, cache_path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("Failed to add {f} to fs cache: error opening fs cache directory: {t}", .{ mem_artifact, e });
            return;
        },
    };
    defer cache_dir.close(cache.fs.io);

    var filename_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "{f}", .{ mem_artifact });
    cache_dir.writeFile(cache.fs.io, .{
        .sub_path = filename,
        .data = data,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("Failed to add {f} to fs cache: error writing file: {t}", .{ mem_artifact, e });
            return;
        },
    };

    fs_ref.ptr.bytes = @intCast(data.len);
    fs_ref.ptr.requests.first_time.store(mem_ref.ptr.requests.first_time.load(.monotonic), .monotonic);
    fs_ref.ptr.requests.last_time.store(mem_ref.ptr.requests.last_time.load(.monotonic), .monotonic);
    fs_ref.ptr.requests.count.store(mem_ref.ptr.requests.count.load(.monotonic), .monotonic);

    log.info("Added {f} to fs cache", .{ mem_artifact });
}

pub fn maybe_evict_from_fs_cache(fs_cache: *Cache, server_stats: *Server_Stats, cache_path: []const u8) !void {
    log.debug("maybe_evict_from_mem_cache", .{});
    const artifact_to_remove: Artifact = if (try fs_cache.get_worst()) |ref| artifact_to_remove: {
        defer ref.unlock();
        break :artifact_to_remove ref.ptr.artifact.?;
    } else return;

    try evict_from_fs_cache(fs_cache, server_stats, artifact_to_remove, cache_path);
}

pub fn evict_from_fs_cache(fs_cache: *Cache, server_stats: *Server_Stats, artifact: Artifact, cache_path: []const u8) !void {
    log.debug("evict_from_mem_cache {f}", .{ artifact });
    if (try fs_cache.remove(artifact)) |ref| {
        defer ref.unlock();
        _ = server_stats.cache_evictions_fs.fetchAdd(1, .monotonic);

        const cache_dir = std.Io.Dir.cwd().createDirPathOpen(fs_cache.io, cache_path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| {
                log.err("Failed to delete {f} after evicting from fs cache: error opening fs cache directory: {t}", .{ artifact, e });
                return;
            },
        };
        defer cache_dir.close(fs_cache.io);

        var filename_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{f}", .{ artifact });
        cache_dir.deleteFile(fs_cache.io, filename) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => |e| {
                log.err("Failed to delete {f} after evicting from fs cache: {t}", .{ artifact, e });
                return;
            },
        };
        
        log.info("Evicted {f} from fs cache", .{ artifact });
    }
}

const Caches = @This();

const log = std.log.scoped(.zigmirror);

const Config = @import("Config.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const Cache = @import("Cache.zig");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
