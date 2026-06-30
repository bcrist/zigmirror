pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, index: *Index, arena: std.mem.Allocator, _: Download_Permission.Upstream, _: Download_Permission.Downstream) !void {
    const artifact = maybe_artifact orelse return error.NotFound;
    
    downstream(request, artifact, cache, server_stats) catch |err| switch (err) {
        error.NotFound, // retrying an artifact that previously 404'd
        error.NotInCache, // expected case
        => {
            const upstream_path = try artifact.upstream_path(arena);
            var transfer: Upstream_Transfer = undefined;
            var upstream_future: ?std.Io.Future(error{Canceled}!void) = null;
            if (try init_upstream_transfer(&transfer, request.io, artifact, cache, server_stats, config)) {
                upstream_future = try std.Io.concurrent(request.io, upstream, .{ &transfer, request.io, request.cid, artifact, upstream_path, cache, server_stats, config });
            }

            downstream(request, artifact, cache, server_stats) catch |err2| switch (err2) {
                // Normally a failed upstream transfer is handled in downstream(), but there is a race condition
                // where another request owns the transfer and cleans up the cache entry before we can grab the shared lock
                error.NotInCache => {
                    if (upstream_future) |*f| try f.await(request.io);
                    return error.GatewayTimeout;
                },
                else => |e| {
                    if (upstream_future) |*f| try f.await(request.io);
                    return e;
                },
            };

            if (upstream_future) |*f| try f.await(request.io);
        }, 
        else => |e| return e,
    };

    if (index.is_outdated_by_artifact(request.io, request.received_dt, artifact)) {
        _ = try request.chain("regenerate_index");
    }
}

pub fn prewarm(io: std.Io, gpa: std.mem.Allocator, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission) error{Canceled}!void {
    // skip if artifact already exists in either cache
    if (try cache.mem.get(artifact, .shared)) |ref| {
        ref.unlock();
        return;
    }
    if (try cache.fs.get(artifact, .shared)) |ref| {
        ref.unlock();
        return;
    }

    const permission = Download_Permission.Upstream.init_timeout(downloads, .{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(config.upstream.recheck_expired_index_interval_seconds),
    }}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.InsufficientResources => {
            log.warn("prewarm: Timed out waiting for permission to download {f}", .{ artifact });
            return;
        },
    };
    defer permission.deinit();

    // Check caches again since some time may have passed while waiting for permission to do an upstream transfer
    if (try cache.mem.get(artifact, .shared)) |ref| {
        ref.unlock();
        return;
    }
    if (try cache.fs.get(artifact, .shared)) |ref| {
        ref.unlock();
        return;
    }
    
    const upstream_path = artifact.upstream_path(gpa) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
    defer gpa.free(upstream_path);

    var transfer: Upstream_Transfer = undefined;
    if (init_upstream_transfer(&transfer, io, artifact, cache, server_stats, config) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.ServiceUnavailable => return,
    }) {
        try upstream(&transfer, io, null, artifact, upstream_path, cache, server_stats, config);
    }
}

fn init_upstream_transfer(transfer: *Upstream_Transfer, io: std.Io, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config) !bool {
    const mem_ref: Cache.Entry.Ref = for (0..100) |_| {
        if (try cache.mem.get_or_add(artifact)) |ref| break ref;
        try cache.maybe_evict_from_mem_cache(server_stats, config);
    } else {
        log.warn("Failed to add {f} to mem cache: could not find free slot", .{ artifact });
        return error.ServiceUnavailable;
    };
    defer mem_ref.unlock();

    switch (mem_ref.ptr.data) {
        .none => {
            transfer.* = Upstream_Transfer.init(io);
            mem_ref.ptr.data = .{ .transfer = transfer };
            return true;
        },
        .transfer, .owned => return false,
    }
}

fn upstream(transfer: *Upstream_Transfer, io: std.Io, maybe_cid: ?http.Connection_Id, artifact: Artifact, upstream_path: []const u8, cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    if (maybe_cid) |cid| {
        log.info("{f}: Beginning upstream transfer {x} for {f}", .{ cid, transfer.id, artifact });
    } else {
        log.info("prewarm: Beginning upstream transfer {x} for {f}", .{ transfer.id, artifact });
    }

    const begin = tempora.now_utc(io).timestamp_ms();
    try transfer.execute(io, upstream_path, artifact.extension, server_stats, config, cache.mem.gpa);

    const maybe_ref = cache.mem.get(artifact, .exclusive) catch |err| switch (err) {
        error.Canceled => |e| return e,
    };
    if (maybe_ref) |ref| {
        defer ref.unlock();
        std.debug.assert(ref.ptr.data.transfer == transfer);

        switch (transfer.status.load(.monotonic)) {
            .in_progress => unreachable,
            .failed => {
                _ = cache.mem.remove_lookup(artifact);
                ref.ptr.artifact = null;
                ref.ptr.bytes = null;
                ref.ptr.hash = null;
                ref.ptr.data = .none;
            },
            .not_found => {
                ref.ptr.data = .none;
                ref.ptr.requests.hit_not_found(begin);
            },
            .complete => {
                const total_bytes = transfer.bytes_available.load(.acquire);
                std.debug.assert(total_bytes == transfer.data.len);
                ref.ptr.bytes = total_bytes;
                ref.ptr.hash = transfer.hash;
                ref.ptr.data = .{ .owned = transfer.data };
                cache.mem.report_added_bytes(total_bytes);
                _ = server_stats.upstream_artifacts_downloaded.fetchAdd(1, .monotonic);
                if (maybe_cid == null) {
                    const end = tempora.now_utc(io).timestamp_ms();
                    const duration = end - begin;
                    ref.ptr.requests.hit(begin, @intCast(duration));
                }
            },
        }
    }

    try cache.cleanup(server_stats, config);
}

fn downstream(request: *http.Request, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats) !void {
    if (try cache.mem.get(artifact, .shared)) |ref| {
        defer ref.unlock();

        switch (ref.ptr.data) {
            .none => return error.NotFound,
            .owned => |data| {
                try headers.check_and_set_headers(request, ref.ptr);
                try downstream_transfer.respond_slice(request, data, server_stats);
                Caches.report_hit(request, server_stats, ref.ptr);
            },
            .transfer => |transfer| {
                const transfer_speed_ptr = server_stats.claim_downstream_transfer_speed();
                defer server_stats.release_transfer_speed(transfer_speed_ptr);

                var sent_bytes: usize = 0;
                var last_reported_transfer_speed = std.Io.Timestamp.now(request.io, .awake).subDuration(.fromSeconds(1));
                var bytes_since_last_reported_transfer_speed: usize = 0;
                var limit: std.Io.Limit = .limited(64 * 1024);
                var status = transfer.status.load(.monotonic);
                var headers_set: bool = false;
                while (status == .in_progress) : (status = transfer.status.load(.monotonic)) {
                    const available_bytes = transfer.bytes_available.load(.acquire);
                    if (available_bytes > sent_bytes) {
                        if (!headers_set) {
                            try headers.check_and_set_headers(request, ref.ptr);
                            request.response.content_length = transfer.data.len;
                            last_reported_transfer_speed = std.Io.Timestamp.now(request.io, .awake).subDuration(.fromSeconds(1));
                            headers_set = true;
                        }
                        sent_bytes += try downstream_transfer.send_slice(request, transfer.data[sent_bytes..available_bytes], transfer.data.len, server_stats, transfer_speed_ptr, &limit, sent_bytes, &bytes_since_last_reported_transfer_speed, &last_reported_transfer_speed);
                    } else {
                        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
                        std.Io.futexWaitTimeout(request.io, u32, &transfer.bytes_available.raw, available_bytes, timeout) catch |err| switch (err) {
                            error.Canceled => |e| return e,
                        };
                    }
                }

                switch (status) {
                    .in_progress => unreachable,
                    .complete => {
                        if (!headers_set) {
                            try headers.check_and_set_headers(request, ref.ptr);
                            try downstream_transfer.respond_slice(request, transfer.data, server_stats);
                        } else {
                            while (sent_bytes < transfer.data.len) {
                                sent_bytes += downstream_transfer.send_slice(request, transfer.data[sent_bytes..], transfer.data.len, server_stats, transfer_speed_ptr, &limit, sent_bytes, &bytes_since_last_reported_transfer_speed, &last_reported_transfer_speed) catch |err| switch (err) {
                                    error.EndOfStream => break,
                                    else => |e| return e,
                                };
                            }
                            try request.end_response();
                        }
                        Caches.report_hit(request, server_stats, ref.ptr);
                    },
                    .failed => return error.GatewayTimeout,
                    .not_found => return error.NotFound,
                }
            },
        }
    } else return error.NotInCache;
}

const log = std.log.scoped(.zigmirror);

const downstream_transfer = @import("downstream_transfer.zig");
const Upstream_Transfer = @import("Upstream_Transfer.zig");
const Download_Permission = @import("Download_Permission.zig");
const Server_Stats = @import("Server_Stats.zig");
const Index = @import("Index.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Config = @import("Config.zig");
const headers = @import("headers.zig");
const tempora = @import("tempora");
const fmt = @import("fmt");
const http = @import("http");
const std = @import("std");
