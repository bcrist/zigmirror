// Allowed locking order for deadlock safety:
//  1. at most one Entry from mem cache
//  2. at most one Entry from fs cache
//  3. mem.lookup_lock or fs.lookup_lock (not both simultaneously)

mem: Cache,
fs: Cache,

pub fn evict_all_mem(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    for (cache.mem.entries) |*entry| {
        const ref: Cache.Entry.Ref = .init(cache.mem.io, entry, .shared);
        _ = ref.try_lock() or continue;

        if (entry.artifact) |artifact| {
            cache.evict_from_mem_cache(server_stats, config, ref) catch |err| {
                log.err("Error attempting to evict {f} from mem cache: {t}", .{ artifact, err });
            };
        } else {
            ref.unlock();
        }
    }

    persist_fs_cache_metadata(&cache.fs, config.cache.fs.path) catch |err| {
        log.err("Failed to persist fs cache metadata: {t}", .{ err });
    };
}

pub fn periodic_cleanup(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    const peconfig = config.cache.mem.periodic_eviction.?;
    for (cache.mem.entries) |*entry| {
        const ref: Cache.Entry.Ref = .init(cache.mem.io, entry, .shared);
        _ = ref.try_lock() or continue;

        if (entry.artifact == null or entry.requests.count.load(.monotonic) < peconfig.min_requests) {
            ref.unlock();
            continue;
        }

        const now = tempora.now_utc(cache.mem.io).timestamp_ms();

        const age = now - entry.requests.first_time.load(.monotonic);
        const inactive = now - entry.requests.last_time.load(.monotonic);
        if (age < peconfig.min_age_minutes * std.time.ms_per_min or inactive < peconfig.min_inactive_minutes * std.time.ms_per_min) {
            ref.unlock();
            continue;
        }

        cache.evict_from_mem_cache(server_stats, config, ref) catch |err| {
            log.err("Error attempting to evict {f} from mem cache: {t}", .{ entry.artifact.?, err });
        };
    }

    persist_fs_cache_metadata(&cache.fs, config.cache.fs.path) catch |err| {
        log.warn("Failed to persist fs cache metadata: {t}", .{ err });
    };
}

pub fn cleanup(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    try cache.cleanup_mem(server_stats, config);
    try cache.cleanup_fs(server_stats, config);
}

fn cleanup_mem(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
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

fn cleanup_fs(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
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

pub fn maybe_evict_from_mem_cache(cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    log.debug("maybe_evict_from_mem_cache", .{});
    const mem_ref = cache.mem.get_worst() catch |err| switch (err) {
        error.Canceled => |e| return e,
    } orelse return;
    cache.evict_from_mem_cache(server_stats, config, mem_ref) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => log.warn("Error while trying to evict {f} from memory cache: {t}", .{ mem_ref.ptr.artifact.?, err }),
    };
}

fn evict_from_mem_cache(cache: *Caches, server_stats: *Server_Stats, config: *const Config, mem_ref: Cache.Entry.Ref) !void {
    const artifact_to_remove = mem_ref.ptr.artifact.?;
    log.debug("evict_from_mem_cache {f}", .{ artifact_to_remove });

    switch (mem_ref.ptr.data) {
        .owned => |data| {
            errdefer mem_ref.unlock();

            var add_to_fs_cache = mem_ref.ptr.requests.count.load(.monotonic) >= config.cache.fs.min_requests;

            if (add_to_fs_cache) {
                const active_entries = try cache.fs.active_entries();
                if (active_entries >= cache.fs.entries.len or cache.fs.total_bytes.load(.monotonic) + data.len > config.cache.fs.max_bytes) {
                    var fs_artifact: ?Artifact = null;
                    if (try cache.fs.get_worst()) |fs_ref| {
                        defer fs_ref.unlock();

                        const now = tempora.now_utc(cache.mem.io).timestamp_ms();

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
        },
        else => {},
    }

    mem_ref.unlock();

    if (try cache.mem.remove(artifact_to_remove)) |ref| {
        defer ref.unlock();

        const now = tempora.now_utc(cache.mem.io).timestamp_ms();
        const score = mem_ref.ptr.order_score(now);

        cache.mem.reset_entry(ref.ptr);

        _ = server_stats.cache_evictions_mem.fetchAdd(1, .monotonic);

        log.info("Evicted {f} from mem cache (score {})", .{ artifact_to_remove, score });
    }

    try cache.cleanup_fs(server_stats, config);
}

fn add_artifact_to_fs_cache(cache: *Caches, server_stats: *Server_Stats, mem_ref: Cache.Entry.Ref, cache_path: []const u8) !void {
    const mem_artifact = mem_ref.ptr.artifact.?;
    const data = mem_ref.ptr.data.owned;

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
        error.Canceled => |e| return e,
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
        .flags = .{
            .lock = .exclusive,
        },
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| {
            log.err("Failed to add {f} to fs cache: error writing file: {t}", .{ mem_artifact, e });
            return;
        },
    };

    fs_ref.ptr.bytes = @intCast(data.len);
    fs_ref.ptr.hash = mem_ref.ptr.hash;
    fs_ref.ptr.requests.first_time.store(mem_ref.ptr.requests.first_time.load(.monotonic), .monotonic);
    fs_ref.ptr.requests.last_time.store(mem_ref.ptr.requests.last_time.load(.monotonic), .monotonic);
    fs_ref.ptr.requests.count.store(mem_ref.ptr.requests.count.load(.monotonic), .monotonic);

    log.info("Added {f} to fs cache", .{ mem_artifact });
}

pub fn maybe_evict_from_fs_cache(fs_cache: *Cache, server_stats: *Server_Stats, cache_path: []const u8) error{Canceled}!void {
    log.debug("maybe_evict_from_mem_cache", .{});
    const maybe_ref = fs_cache.get_worst() catch |err| switch (err) {
        error.Canceled => |e| return e,
    };

    const artifact_to_remove: Artifact = if (maybe_ref) |ref| artifact_to_remove: {
        defer ref.unlock();
        break :artifact_to_remove ref.ptr.artifact.?;
    } else return;

    evict_from_fs_cache(fs_cache, server_stats, artifact_to_remove, cache_path) catch |err| switch (err) {
        error.Canceled => |e| return e,
    };
}

pub fn evict_from_fs_cache(fs_cache: *Cache, server_stats: *Server_Stats, artifact: Artifact, cache_path: []const u8) !void {
    log.debug("evict_from_mem_cache {f}", .{ artifact });
    const cache_dir = std.Io.Dir.cwd().createDirPathOpen(fs_cache.io, cache_path, .{}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| {
            log.err("Failed to delete {f} after evicting from fs cache: error opening fs cache directory: {t}", .{ artifact, e });
            return;
        },
    };
    defer cache_dir.close(fs_cache.io);

    try evict_from_fs_cache_dir(fs_cache, server_stats, artifact, cache_dir);
}

pub fn evict_from_fs_cache_dir(fs_cache: *Cache, server_stats: *Server_Stats, artifact: Artifact, cache_dir: std.Io.Dir) error{Canceled}!void {
    log.debug("evict_from_fs_cache_dir {f}", .{ artifact });
    if (try fs_cache.remove(artifact)) |ref| {
        defer ref.unlock();

        const now = tempora.now_utc(fs_cache.io).timestamp_ms();
        const score = ref.ptr.order_score(now);

        fs_cache.reset_entry(ref.ptr);

        _ = server_stats.cache_evictions_fs.fetchAdd(1, .monotonic);

        var filename_buf: [Artifact.max_filename_length]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{f}", .{ artifact }) catch unreachable;
        cache_dir.deleteFile(fs_cache.io, filename) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| {
                log.err("Failed to delete {f} after evicting from fs cache: {t}", .{ artifact, e });
                return;
            },
        };
        
        log.info("Evicted {f} from fs cache (score {})", .{ artifact, score });
    }
}

pub fn report_hit(request: *http.Request, server_stats: *Server_Stats, entry: *Cache.Entry) void {
    const start = request.received_dt.with_offset(0).timestamp_ms();

    if (request.range("bytes", true) catch null) |range_iter| {
        const total_bytes = entry.bytes orelse switch (entry.data) {
            .none => return log.err("{f}: unable to determine artifact size", .{ request.cid }),
            .transfer => |upstream| upstream.data.len,
            .owned => |buf| buf.len,
        };

        var iter = range_iter;
        var requested_bytes: usize = 0;
        while (iter.next_valid()) |range| {
            const satisfied = range.satisfy(total_bytes) catch continue;
            requested_bytes += satisfied.len;
        }

        entry.requests.hit_partial(start, requested_bytes, total_bytes);
    } else {
        const end = tempora.now_utc(request.io).timestamp_ms();
        const request_duration: u32 = @intCast(std.math.clamp(end - start, 0, std.math.maxInt(u32)));

        if (request.get_header("x-forwarded-for")) |header| {
            log.debug("{f}: artifact download took {f} (XFF: {f})", .{
                request.cid,
                std.Io.Duration.fromMilliseconds(request_duration),
                std.zig.fmtString(header),
            });
        } else {
            log.debug("{f}: artifact download took {f}", .{
                request.cid,
                std.Io.Duration.fromMilliseconds(request_duration),
            });
        }
        entry.requests.hit(start, request_duration);
    }

    _ = server_stats.artifacts_served.fetchAdd(1, .monotonic);
}

pub fn persist_fs_cache_metadata(fs_cache: *Cache, cache_path: []const u8) !void {
    const dir = try std.Io.Dir.cwd().openDir(fs_cache.io, cache_path, .{});
    defer dir.close(fs_cache.io);

    var af = try dir.createFileAtomic(fs_cache.io, "cache.sx", .{ .replace = true });
    defer af.deinit(fs_cache.io);

    var buf: [4096]u8 = undefined;
    var writer = af.file.writer(fs_cache.io, &buf);

    var sxw = sx.writer(fs_cache.gpa, &writer.interface);
    defer sxw.deinit();

    try sxw.expression_expanded("zigmirror_cache");

    for (fs_cache.entries) |*entry| {
        const ref: Cache.Entry.Ref = .init(fs_cache.io, entry, .shared);
        const locked = ref.try_lock();
        defer if (locked) ref.unlock();
        
        const artifact = ref.ptr.artifact orelse continue;

        try sxw.open();
        try sxw.print_value("{f}", .{ artifact });

        if (ref.ptr.hash) |hash| {
            try sxw.expression("sha256");
            try sxw.print_value("{x}", .{ hash });
            try sxw.close();
        }

        const request_count = ref.ptr.requests.count.load(.monotonic);
        if (request_count > 0) {
            const first_time = ref.ptr.requests.first_time.load(.monotonic);
            const last_time = ref.ptr.requests.last_time.load(.monotonic);
            const first_dto: tempora.Date_Time.With_Offset = .from_timestamp_ms(first_time, null);
            const last_dto: tempora.Date_Time.With_Offset = .from_timestamp_ms(last_time, null);
            try sxw.expression("requests");
            try sxw.int(request_count, 10);
            try sxw.print_value("{f}", .{ first_dto.fmt(tempora.Date_Time.With_Offset.iso8601_local) });
            try sxw.print_value("{f}", .{ last_dto.fmt(tempora.Date_Time.With_Offset.iso8601_local) });
            try sxw.close();
        }

        const duration_count = ref.ptr.requests.duration_count.load(.monotonic);
        if (duration_count > 0) {
            const total = ref.ptr.requests.duration_total.load(.monotonic);
            const min = ref.ptr.requests.duration_min.load(.monotonic);
            const max = ref.ptr.requests.duration_max.load(.monotonic);
            try sxw.expression("duration");
            try sxw.int(duration_count, 10);
            try sxw.int(total, 10);
            try sxw.int(min, 10);
            try sxw.int(max, 10);
            try sxw.close();
        }

        try sxw.close();
    }

    try sxw.done();

    try writer.flush();
    try af.replace(fs_cache.io);
}

pub fn load_fs_cache(fs_cache: *Cache, server_stats: *Server_Stats, cache_path: []const u8, allow_devkit_artifacts: bool) !void {
    var cache_dir = try std.Io.Dir.cwd().createDirPathOpen(fs_cache.io, cache_path, .{ .open_options = .{ .iterate = true } });
    defer cache_dir.close(fs_cache.io);

    const startup_time = server_stats.start_time.with_offset(0).timestamp_ms();

    var iter = cache_dir.iterateAssumeFirstIteration();
    while (try iter.next(fs_cache.io)) |entry| {
        if (Artifact.maybe_parse(entry.name)) |artifact| {
            const stat = cache_dir.statFile(fs_cache.io, entry.name, .{}) catch |err| switch (err) {
                error.IsDir => continue,
                else => |e| return e,
            };

            if (artifact.artifact_type == .devkit and !allow_devkit_artifacts) continue;

            const fs_ref: Cache.Entry.Ref = for (0..100) |_| {
                if (try fs_cache.get_or_add(artifact)) |ref| break ref;
                try maybe_evict_from_fs_cache(fs_cache, server_stats, cache_path);
            } else {
                return error.FsCacheInitError;
            };
            defer fs_ref.unlock();

            const bytes: u32 = @intCast(stat.size);
            fs_ref.ptr.bytes = bytes;
            fs_ref.ptr.hash = null;
            fs_ref.ptr.requests.first_time.store(startup_time, .monotonic);
            fs_ref.ptr.requests.last_time.store(startup_time, .monotonic);
            fs_ref.ptr.requests.count.store(1, .monotonic);
            fs_cache.report_added_bytes(bytes);
            log.info("Initializing fs cache: {f}", .{ artifact });
        }
    }

    try load_fs_cache_metadata(fs_cache, cache_dir, server_stats);
}

pub fn load_fs_cache_metadata(fs_cache: *Cache, cache_dir: std.Io.Dir, server_stats: *Server_Stats) !void {
    var metadata_file = cache_dir.openFile(fs_cache.io, "cache.sx", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer metadata_file.close(fs_cache.io);

    var buf: [4096]u8 = undefined;
    var reader = metadata_file.reader(fs_cache.io, &buf);

    var sxr = sx.reader(fs_cache.gpa, &reader.interface);
    defer sxr.deinit();

    load_fs_cache_metadata_internal(fs_cache, cache_dir, &sxr, server_stats) catch |err| switch (err) {
        error.SExpressionSyntaxError => {
            const context = try sxr.token_context();
            var stderr_buf: [64]u8 = undefined;
            const stderr = std.debug.lockStderr(&stderr_buf);
            defer std.debug.unlockStderr();
            try context.print_for_file(&reader, &stderr.file_writer.interface, 160);
            return err;
        },
        else => |e| return e,
    };
}

fn load_fs_cache_metadata_internal(fs_cache: *Cache, cache_dir: std.Io.Dir, sxr: *sx.Reader, server_stats: *Server_Stats) !void {
    try sxr.require_expression("zigmirror_cache");

    while (try sxr.any_expression()) |artifact_name| {
        const artifact = Artifact.parse(artifact_name) catch {
            log.warn("Found invalid artifact name in persisted cache metadata: {s}", .{ artifact_name });
            try sxr.ignore_remaining_expression();
            continue;
        };

        const ref = (try fs_cache.get(artifact, .exclusive)) orelse {
            log.warn("Found artifact in persisted cache metadata that no longer exists in fs: {s}", .{ artifact_name });
            try sxr.ignore_remaining_expression();
            continue;
        };
        defer ref.unlock();

        if (try sxr.expression("sha256")) {
            const hash_hex = try sxr.require_any_string();
            try sxr.require_close();

            var found_hash_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            var found_valid_hash = false;
            if (hash_hex.len == found_hash_bytes.len * 2) {
                for (0.., &found_hash_bytes) |i, *hash_byte| {
                    hash_byte.* = std.fmt.parseInt(u8, hash_hex[i * 2 ..][0..2], 16) catch break;
                } else {
                    found_valid_hash = true;
                }
            }

            if (found_valid_hash) {
                if (ref.ptr.hash) |computed_hash| {
                    if (!std.mem.eql(u8, &found_hash_bytes, &computed_hash)) {
                        log.err("Artifact hash from persisted metadata doesn't match file contents for {s}", .{ artifact_name });
                        try evict_from_fs_cache_dir(fs_cache, server_stats, artifact, cache_dir);
                        try sxr.ignore_remaining_expression();
                        continue;
                    }
                } else {
                    ref.ptr.hash = found_hash_bytes;
                }
            } else {
                log.warn("Ignoring invalid persisted artifact hash for {s}: expected length {}; found {}", .{
                    artifact_name,
                    found_hash_bytes.len * 2,
                    hash_hex.len,
                });
            }
        }

        if (try sxr.expression("requests")) {
            const DTO = tempora.Date_Time.With_Offset;

            const count = try sxr.require_any_int(u32, 10);

            const first_str = try sxr.require_any_string();
            const first_dto = DTO.from_string(DTO.iso8601_local, first_str) catch {
                sxr.state = .val; // unconsume date string
                return error.SExpressionSyntaxError;
            };

            const last_str = try sxr.require_any_string();
            const last_dto = DTO.from_string(DTO.iso8601_local, last_str) catch {
                sxr.state = .val; // unconsume date string
                return error.SExpressionSyntaxError;
            };

            try sxr.require_close();

            ref.ptr.requests.first_time.store(first_dto.timestamp_ms(), .monotonic);
            ref.ptr.requests.last_time.store(last_dto.timestamp_ms(), .monotonic);
            ref.ptr.requests.count.store(count, .monotonic);
        }

        if (try sxr.expression("duration")) {
            const count = try sxr.require_any_int(u32, 10);
            const total = try sxr.require_any_int(u64, 10);
            const min = try sxr.require_any_int(u32, 10);
            const max = try sxr.require_any_int(u32, 10);
            try sxr.require_close();

            ref.ptr.requests.duration_min.store(min, .monotonic);
            ref.ptr.requests.duration_max.store(max, .monotonic);
            ref.ptr.requests.duration_total.store(total, .monotonic);
            ref.ptr.requests.duration_count.store(count, .monotonic);
        }

        try sxr.require_close();
    }

    try sxr.require_close();
    try sxr.require_done();
}

pub fn validate_fs_cache(cache: *Caches, server_stats: *Server_Stats, cache_path: []const u8) !void {
    var cache_dir = try std.Io.Dir.cwd().createDirPathOpen(cache.fs.io, cache_path, .{});
    defer cache_dir.close(cache.fs.io);

    var filename_buf: [Artifact.max_filename_length]u8 = undefined;

    for (cache.fs.entries) |*entry| {
        const artifact: Artifact, const expected_len: usize, const expected_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = e: {
            const ref: Cache.Entry.Ref = .init(cache.fs.io, entry, .exclusive);
            try ref.lock();
            defer ref.unlock();
            const artifact = ref.ptr.artifact orelse continue;
            const bytes = ref.ptr.bytes orelse 0;
            const hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = ref.ptr.hash orelse @splat(0);
            break :e .{ artifact, bytes, hash };
        };
        
        const filename = std.fmt.bufPrint(&filename_buf, "{f}", .{ artifact }) catch unreachable;
        const cache_file = cache_dir.openFile(cache.fs.io, filename, .{ .lock = .shared }) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => |e| {
                log.err("validate: {f}: Failed to open file from fs cache: {t}", .{ artifact, e });
                try evict_from_fs_cache_dir(&cache.fs, server_stats, artifact, cache_dir);
                return;
            },
        };
        defer cache_file.close(cache.fs.io);

        var hash_buf: [16384]u8 = undefined;
        var reader = cache_file.reader(cache.fs.io, &hash_buf);
        var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

        while (!reader.atEnd()) {
            reader.interface.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    log.err("validate: {f}: Failed to calculate SHA256: {t}", .{ artifact, reader.err orelse error.ReadFailed });
                    try evict_from_fs_cache_dir(&cache.fs, server_stats, artifact, cache_dir);
                    continue;
                },
            };
            const buffered = reader.interface.buffered();
            hasher.update(buffered);
            reader.interface.toss(buffered.len);
        }

        if (hasher.total_len != expected_len) {
            log.err("validate: {f}: expected {} bytes but found {}", .{ artifact, expected_len, hasher.total_len });
            try evict_from_fs_cache_dir(&cache.fs, server_stats, artifact, cache_dir);
            continue;
        }

        const found_hash = hasher.finalResult();
        if (!std.mem.eql(u8, &expected_hash, &found_hash)) {
            log.err("validate: {f}: SHA25 mismatch; expected {x} bytes but found {x}", .{ artifact, &expected_hash, &found_hash });
            try evict_from_fs_cache_dir(&cache.fs, server_stats, artifact, cache_dir);
            continue;
        }

        log.debug("validate: {f}: File size and SHA256 matches expectation", .{ artifact });
    }
}

const Caches = @This();

const log = std.log.scoped(.zigmirror);

const http = @import("http");
const Config = @import("Config.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const Cache = @import("Cache.zig");
const sx = @import("sx");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
