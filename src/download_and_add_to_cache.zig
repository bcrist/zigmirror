pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, arena: std.mem.Allocator, _: Download_Authority) !void {
    const artifact = maybe_artifact orelse return error.NotFound;
    try download(request, artifact, cache, server_stats, config, arena);
    try cache.cleanup(server_stats, config);
}

fn download(request: *http.Request, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, arena: std.mem.Allocator) !void {
    log.debug("{f}: Preparing to download {f}", .{ request.cid, artifact });
    const upstream_path = try artifact.upstream_path(arena);

    const now = request.received_dt.with_offset(0).timestamp_ms();

    const mem_ref: Cache.Entry.Ref = for (0..100) |_| {
        if (try cache.mem.get_or_add(artifact)) |ref| break ref;
        try cache.maybe_evict_from_mem_cache(server_stats, config);
    } else return error.ServiceUnavailable;
    defer mem_ref.unlock();
    errdefer {
        mem_ref.ptr.artifact = null;
        mem_ref.ptr.bytes = null;
        mem_ref.ptr.data = null;
    }

    if (mem_ref.ptr.data) |data| {
        // Another thread already downloaded our file :)
        try request.set_response_header("content-type", mem_ref.ptr.artifact.?.extension.content_type());
        try request.respond(data);

        const end = tempora.now(request.io).timestamp_ms();
        const request_duration: u32 = @intCast(std.math.clamp(end - now, 0, std.math.maxInt(u32)));

        log.info("{f}: took {f}", .{
            request.cid,
            std.Io.Duration.fromMilliseconds(request_duration),
        });

        mem_ref.ptr.requests.hit(now, request_duration);
        _ = server_stats.artifacts_served.fetchAdd(1, .monotonic);
        return;
    }

    var collector: std.Io.Writer.Allocating = .init(cache.mem.gpa);
    defer collector.deinit();

    const uri: std.Uri = .{
        .scheme = "https",
        .host = .{ .raw = "ziglang.org" },
        .path = .{ .raw = upstream_path },
        .query = .{ .raw = try request.fmt("source={s}", .{ config.public_hostname }) },
    };

    log.debug("{f}: Starting download for {f}", .{ request.cid, uri });

    {
        var client: std.http.Client = .{
            .allocator = cache.mem.gpa, // probably could use arena?
            .io = request.io,
            .now = .now(request.io, .real),
        };
        defer client.deinit();

        const head_time_ptr: *std.atomic.Value(u32) = switch (artifact.extension) {
            .txz, .zip => &server_stats.expected_upstream_head_time_ms_archive,
            .txz_minisig, .zip_minisig => &server_stats.expected_upstream_head_time_ms_minisig,
        };
        var expected_head_time = head_time_ptr.load(.monotonic);

        const con = try client.connectTcpOptions(.{
            .host = .{ .bytes = uri.host.?.toRaw(&.{}) catch unreachable },
            .port = 443,
            .protocol = .tls,
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(expected_head_time * 2),
                .clock = .real,
            }},
        });

        var upstream_req = try client.request(.GET, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .connection = con,
        });
        defer upstream_req.deinit();

        try upstream_req.sendBodiless();
        var upstream_res = try upstream_req.receiveHead(&.{});

        switch (upstream_res.head.status) {
            .ok => {},
            .not_found => {
                mem_ref.ptr.requests.hit_not_found(now);

                log.info("{f}: Upstream [{}] {f}", .{
                    request.cid,
                    @intFromEnum(upstream_res.head.status),
                    uri,
                });
                
                // returning error.NotFound would cause mem_ref.artifact to be cleared, but we want
                // to cache the fact that this artifact is unavailable from the ziglang.org
                try request.respond_err(.{ .status = .not_found });
                return;
            },
            else => {
                log.warn("{f}: Upstream [{}] {f}", .{
                    request.cid,
                    @intFromEnum(upstream_res.head.status),
                    uri,
                });
                return error.GatewayTimeout;
            },
        }

        if (upstream_res.head.content_encoding != .identity) {
            return error.UnsupportedUpstreamContentEncoding;
        }

        const head_received = tempora.now(request.io).timestamp_ms();
        const head_time: u32 = @intCast(std.math.clamp(head_received - now, 0, std.math.maxInt(u32)));

        for (0..100) |_| {
            const new = @max((expected_head_time * 15 + head_time) / 16, config.min_upstream_timeout_seconds * std.time.ms_per_s / 2);
            if (head_time_ptr.cmpxchgWeak(expected_head_time, new, .monotonic, .monotonic)) |new_expected| {
                expected_head_time = new_expected;
            } else {
                log.debug("{f}: Updated expected upstream request head time to {f}", .{ request.cid, std.Io.Duration.fromMilliseconds(new) });
                break;
            }
        }

        try request.set_response_header("content-type", mem_ref.ptr.artifact.?.extension.content_type());
        request.response.content_length = upstream_res.head.content_length;

        var response_writer = try request.response_writer();

        var transfer_buffer: [64 * 1024]u8 = undefined;
        const upstream_reader = upstream_res.reader(&transfer_buffer);

        while (true) {
            upstream_reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.GatewayTimeout,
            };
            const bytes = upstream_reader.buffered();
            try response_writer.writeAll(bytes);
            try collector.writer.writeAll(bytes);
            upstream_reader.toss(bytes.len);
        }

        try request.end_response();
    }

    const end = tempora.now(request.io).timestamp_ms();
    const request_duration: u32 = @intCast(std.math.clamp(end - now, 0, std.math.maxInt(u32)));

    log.info("{f}: Upstream [200] {f}", .{
        request.cid,
        uri,
    });
    log.info("{f}: took {f}", .{
        request.cid,
        std.Io.Duration.fromMilliseconds(request_duration),
    });

    const data = try collector.toOwnedSlice();
    const bytes: u32 = @intCast(data.len);
    mem_ref.ptr.bytes = bytes;
    mem_ref.ptr.data = data;
    cache.mem.report_added_bytes(bytes);
    mem_ref.ptr.requests.hit(now, request_duration);
    _ = server_stats.artifacts_served.fetchAdd(1, .monotonic);
    _ = server_stats.upstream_artifacts_downloaded.fetchAdd(1, .monotonic);
}

const log = std.log.scoped(.zigmirror);

const Download_Authority = @import("Download_Authority.zig");
const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Config = @import("Config.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
