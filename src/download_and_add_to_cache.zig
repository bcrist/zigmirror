pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, arena: std.mem.Allocator, _: Download_Authority) !void {
    const artifact = maybe_artifact orelse return error.NotFound;
    try download(request, artifact, cache, server_stats, config, arena);
    try cache.cleanup(server_stats, config);
}

fn download(request: *http.Request, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, arena: std.mem.Allocator) !void {
    log.debug("{f}: Preparing to download {f}", .{ request.cid, artifact });
    const upstream_path = try artifact.upstream_path(arena);

    const request_started = request.received_dt.with_offset(0).timestamp_ms();

    const mem_ref: Cache.Entry.Ref = for (0..100) |_| {
        if (try cache.mem.get_or_add(artifact)) |ref| break ref;
        try cache.maybe_evict_from_mem_cache(server_stats, config);
    } else {
        log.warn("Failed to add {f} to mem cache: could not find free slot", .{ artifact });
        return error.ServiceUnavailable;
    };
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

        Caches.report_hit(request, server_stats, mem_ref.ptr);
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
    const client_now: std.Io.Timestamp = .now(cache.mem.io, .awake);

    var ca_bundle: std.crypto.Certificate.Bundle = .empty;
    {
        errdefer ca_bundle.deinit(cache.mem.gpa);
        try ca_bundle.rescan(cache.mem.gpa, cache.mem.io, client_now);
    }

    var client: std.http.Client = .{
        .allocator = cache.mem.gpa, // probably could use arena?
        .io = cache.mem.io,
        .ca_bundle = ca_bundle,
        .now = client_now,
    };
    defer client.deinit();

    const head_time_ptr: *std.atomic.Value(u32) = switch (artifact.extension) {
        .txz, .zip => &server_stats.expected_upstream_head_time_ms_archive,
        .txz_minisig, .zip_minisig => &server_stats.expected_upstream_head_time_ms_minisig,
    };
    var expected_head_time = head_time_ptr.load(.monotonic);

    const con = client.connectTcpOptions(.{
        .host = .{ .bytes = uri.host.?.toRaw(&.{}) catch unreachable },
        .port = 443,
        .protocol = .tls,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(expected_head_time * 2),
            .clock = .awake,
        }},
    }) catch |err| {
        log.err("{f}: Upstream [fail] {s} while connecting for {f}", .{
            request.cid,
            @errorName(err),
            uri,
        });
        return error.GatewayTimeout;
    };

    var upstream_req = try client.request(.GET, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .connection = con,
    });
    defer upstream_req.deinit();

    var bytes: std.atomic.Value(usize) = .init(0);
    var buf: [2]Response_Or_Timeout = undefined;
    var select: std.Io.Select(Response_Or_Timeout) = .init(request.io, &buf);
    defer select.cancelDiscard();

    try select.concurrent(.timeout, transfer_watchdog, .{
        request.io,
        request.cid,
        request_started,
        config,
        &bytes,
    });

    select.async(.response, transfer, .{
        request,
        &upstream_req,
        request_started,
        mem_ref.ptr.artifact.?.extension.content_type(),
        &collector.writer,
        &bytes,
    });

    switch (try select.await()) {
        .response => |result| switch (try result) {
            .send_failed => {
                if (upstream_req.connection.?.stream_writer.err) |e| {
                    log.err("{f}: Upstream [fail] WriteFailed: {s} while sending {f}", .{
                        request.cid,
                        @errorName(e),
                        uri,
                    });
                    if (e == error.Canceled) return error.Canceled;
                } else {
                    log.err("{f}: Upstream [fail] WriteFailed while sending {f}", .{
                        request.cid,
                        uri,
                    });
                }
                return error.GatewayTimeout;
            },
            .receive_failed => |err| switch (err) {
                error.WriteFailed => {
                    if (upstream_req.connection.?.stream_writer.err) |e| {
                        log.err("{f}: Upstream [fail] WriteFailed: {s} while receiving {f}", .{
                            request.cid,
                            @errorName(e),
                            uri,
                        });
                        if (e == error.Canceled) return error.Canceled;
                    } else {
                        log.err("{f}: Upstream [fail] WriteFailed while receiving {f}", .{
                            request.cid,
                            uri,
                        });
                    }
                    return error.GatewayTimeout;
                },
                error.ReadFailed => {
                    if (upstream_req.connection.?.stream_reader.err) |e| {
                        log.err("{f}: Upstream [fail] ReadFailed: {s} while receiving {f}", .{
                            request.cid,
                            @errorName(e),
                            uri,
                        });
                        if (e == error.Canceled) return error.Canceled;
                    } else {
                        log.err("{f}: Upstream [fail] ReadFailed while receiving {f}", .{
                            request.cid,
                            uri,
                        });
                    }
                    return error.GatewayTimeout;
                },
                else => |e| {
                    log.err("{f}: Upstream [fail] {s} while sending {f}", .{
                        request.cid,
                        @errorName(e),
                        uri,
                    });
                    return error.GatewayTimeout;
                },
            },
            .unexpected_status => |status| {
                log.err("{f}: Upstream [{}] {f}", .{
                    request.cid,
                    @intFromEnum(status),
                    uri,
                });
                return error.GatewayTimeout;
            },
            .not_found => {
                mem_ref.ptr.requests.hit_not_found(request_started);

                log.info("{f}: Upstream [404] {f}", .{
                    request.cid,
                    uri,
                });
                
                // returning error.NotFound would cause mem_ref.artifact to be cleared, but we want
                // to cache the fact that this artifact is unavailable from the ziglang.org
                try request.respond_err(.{ .status = .not_found });
            },
            .complete => |head_time_ms| {
                log.info("{f}: Upstream [200] {f}", .{
                    request.cid,
                    uri,
                });

                for (0..100) |_| {
                    const new = @max((expected_head_time * 15 + head_time_ms) / 16, config.upstream.min_connect_timeout_seconds * std.time.ms_per_s / 2);
                    if (head_time_ptr.cmpxchgWeak(expected_head_time, new, .monotonic, .monotonic)) |new_expected| {
                        expected_head_time = new_expected;
                    } else {
                        log.debug("{f}: Updated expected upstream request head time to {f}", .{ request.cid, std.Io.Duration.fromMilliseconds(new) });
                        break;
                    }
                }

                _ = server_stats.upstream_artifacts_downloaded.fetchAdd(1, .monotonic);
                
                const data = try collector.toOwnedSlice();
                const num_bytes: u32 = @intCast(data.len);
                mem_ref.ptr.bytes = num_bytes;
                mem_ref.ptr.data = data;
                cache.mem.report_added_bytes(num_bytes);
                Caches.report_hit(request, server_stats, mem_ref.ptr);
            },
        },
        .timeout => |result| {
            try result;
            log.info("{f}: Upstream [timeout] {f}", .{
                request.cid,
                uri,
            });
            return error.GatewayTimeout;
        },
    }
}

const Response_Or_Timeout = union (enum) {
    timeout: std.Io.Cancelable!void,
    response: Transfer_Error!Transfer_Result,
};

const Transfer_Result = union (enum) {
    send_failed,
    receive_failed: std.http.Client.Request.ReceiveHeadError,
    unexpected_status: std.http.Status,
    not_found,
    complete: u32, // head_time_ms
};

const Transfer_Error = error {
    Canceled,
    OutOfMemory,
    ResponseAlreadyStarted,
    ResponseAlreadySent,
    HttpExpectationFailed,
    WriteFailed,
    NotFound,
};

fn transfer(request: *http.Request, upstream_req: *std.http.Client.Request, request_started: i64, content_type: []const u8, collector: *std.Io.Writer, bytes: *std.atomic.Value(usize)) Transfer_Error!Transfer_Result {
    upstream_req.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => return .send_failed,
    };
    var upstream_res = upstream_req.receiveHead(&.{}) catch |err| return .{ .receive_failed = err };

    switch (upstream_res.head.status) {
        .ok => {},
        .not_found => return .not_found,
        else => return .{ .unexpected_status = upstream_res.head.status },
    }

    if (upstream_res.head.content_encoding != .identity) {
        return .{ .receive_failed = error.HttpContentEncodingUnsupported };
    }

    const head_received = tempora.now(request.io).timestamp_ms();
    const head_time: u32 = @intCast(std.math.clamp(head_received - request_started, 0, std.math.maxInt(u32)));

    try request.set_response_header("content-type", content_type);
    request.response.content_length = upstream_res.head.content_length;

    var response_writer = try request.response_writer();

    var transfer_buffer: [64 * 1024]u8 = undefined;
    const upstream_reader = upstream_res.reader(&transfer_buffer);

    while (true) {
        upstream_reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return .{ .receive_failed = error.ReadFailed },
        };
        const buffered_bytes = upstream_reader.buffered();
        try response_writer.writeAll(buffered_bytes);
        try collector.writeAll(buffered_bytes);
        upstream_reader.toss(buffered_bytes.len);
        _ = bytes.fetchAdd(buffered_bytes.len, .monotonic);
    }

    try request.end_response();

    return .{ .complete = head_time };
}

fn transfer_watchdog(io: std.Io, cid: http.Connection_Id, request_started: i64, config: *const Config, bytes: *std.atomic.Value(usize)) error{Canceled}!void {
    var timeout_seconds = config.upstream.initial_transfer_timeout_seconds;
    try io.sleep(.fromSeconds(timeout_seconds), .awake);
    var last_seen_bytes: usize = 0;
    while (true) {
        const now = tempora.now(io).timestamp_ms();
        if (now - request_started > config.upstream.max_transfer_time_seconds * std.time.ms_per_s) return;

        const bytes_now = bytes.load(.monotonic);
        if (bytes_now == last_seen_bytes) return;

        const delta_bytes = bytes_now - last_seen_bytes;
        const bps = (delta_bytes + timeout_seconds - 1) / timeout_seconds;

        log.info("{f}: Upstream transferring at {f}/s, total transferred so far: {f}", .{
            cid,
            fmt.bytes(bps),
            fmt.bytes(bytes_now),
        });

        last_seen_bytes = bytes_now;
        timeout_seconds = config.upstream.dead_transfer_timeout_seconds;
        try io.sleep(.fromSeconds(timeout_seconds), .awake);
    }
}

const log = std.log.scoped(.zigmirror);

const Download_Authority = @import("Download_Authority.zig");
const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Config = @import("Config.zig");
const tempora = @import("tempora");
const fmt = @import("fmt");
const http = @import("http");
const std = @import("std");
