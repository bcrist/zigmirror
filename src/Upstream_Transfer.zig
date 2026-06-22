id: [4]u8,
data: []const u8, // only valid when bytes_available > 0
hash: [std.crypto.hash.sha2.Sha256.digest_length]u8, // only valid when status == .complete
status: std.atomic.Value(Status),
bytes_available: std.atomic.Value(u32),

pub const Status = enum(u8) {
    in_progress,
    failed,
    not_found,
    complete,
};

pub fn init(io: std.Io) Upstream_Transfer {
    var id: [4]u8 = undefined;
    io.random(&id);
    return .{
        .id = id,
        .data = &.{},
        .hash = @splat(0),
        .status = .init(.in_progress),
        .bytes_available = .init(0),
    };
}

pub fn deinit(self: *Upstream_Transfer, gpa: std.mem.Allocator) void {
    if (self.data.len > 0) {
        gpa.free(self.data);
    }
}

pub fn execute(self: *Upstream_Transfer, io: std.Io, upstream_path: []const u8, ext: ?Artifact.Extension, server_stats: *Server_Stats, config: *const Config, gpa: std.mem.Allocator) error{Canceled}!void {
    const request_started = tempora.now_utc(io).timestamp_ms();

    var query_string_buf: [256]u8 = undefined;
    const query_string = std.fmt.bufPrint(&query_string_buf, "source={s}", .{ config.public_hostname }) catch "";

    const uri: std.Uri = .{
        .scheme = "https",
        .host = .{ .raw = "ziglang.org" },
        .path = .{ .raw = upstream_path },
        .query = if (query_string.len == 0) null else .{ .raw = query_string },
    };

    log.debug("Upstream {x}: Starting download for {f}", .{ self.id, uri });
    const client_now: std.Io.Timestamp = .now(io, .real);

    var ca_bundle: std.crypto.Certificate.Bundle = .empty;
    ca_bundle.rescan(gpa, io, client_now) catch |err| switch (err) {
        error.Canceled => {
            self.status.store(.failed, .monotonic);
            ca_bundle.deinit(gpa);
            return;
        },
        else => {
            self.status.store(.failed, .monotonic);
            ca_bundle.deinit(gpa);
            log.err("Upstream {x}: [fail] {t} while initializing certificate bundle", .{ self.id, err });
            return;
        },
    };

    var client: std.http.Client = .{
        .allocator = gpa, // probably could use arena?
        .io = io,
        .ca_bundle = ca_bundle,
        .now = client_now,
    };
    defer client.deinit();

    const head_time_ptr: *std.atomic.Value(u32) = switch (ext orelse .txz) {
        .txz, .zip => &server_stats.expected_upstream_head_time_ms_archive,
        .txz_minisig, .zip_minisig => &server_stats.expected_upstream_head_time_ms_minisig,
    };
    const expected_head_time = head_time_ptr.load(.monotonic);

    const con = client.connectTcpOptions(.{
        .host = .{ .bytes = uri.host.?.toRaw(&.{}) catch unreachable },
        .port = 443,
        .protocol = .tls,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(expected_head_time * 2),
            .clock = .real,
        }},
    }) catch |err| switch (err) {
        error.Canceled => {
            self.status.store(.failed, .monotonic);
            return;
        },
        else => {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [fail] {t} while connecting", .{ self.id, err });
            return;
        },
    };

    var req = client.request(.GET, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .connection = con,
    }) catch |err| switch (err) {
        error.Canceled => {
            self.status.store(.failed, .monotonic);
            return;
        },
        else => {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [fail] {t} while generating request", .{ self.id, err });
            return;
        },
    };
    defer req.deinit();

    const Response_Or_Timeout = union (enum) {
        timeout: std.Io.Cancelable!void,
        response: std.Io.Cancelable!void,
    };
    var buf: [2]Response_Or_Timeout = undefined;
    var select: std.Io.Select(Response_Or_Timeout) = .init(io, &buf);
    defer select.cancelDiscard();

    select.concurrent(.timeout, watchdog, .{ self, io, request_started, config }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [fail] {t} while starting watchdog task", .{ self.id, err });
            return;
        },
    };

    select.async(.response, transfer_impl, .{
        self,
        io,
        gpa,
        &req,
        request_started,
        expected_head_time,
        if (ext == null) null else head_time_ptr,
        config.upstream.min_connect_timeout_seconds,
    });

    const result = select.await() catch |err| switch (err) {
        error.Canceled => {
            self.status.store(.failed, .monotonic);
            return;
        },
    };

    switch (result) {
        .response => |ret| {
            if (ret == error.Canceled) {
                self.status.store(.failed, .monotonic);
            }
        },
        .timeout => |ret| {
            self.status.store(.failed, .monotonic);
            if (ret != error.Canceled) {
                log.info("Upstream {x}: [timeout] {f}", .{ self.id, uri });
            }
        },
    }
}

fn transfer_impl(self: *Upstream_Transfer, io: std.Io, gpa: std.mem.Allocator, req: *std.http.Client.Request, request_started: i64, expected_head_time: u32, head_time_ptr: ?*std.atomic.Value(u32), min_connect_timeout_seconds: u32) std.Io.Cancelable!void {
    req.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => {
            self.status.store(.failed, .monotonic);
            if (req.connection.?.stream_writer.err) |e| {
                log.err("Upstream {x}: [fail] WriteFailed: {t} while sending request", .{ self.id, e });
                if (e == error.Canceled) return error.Canceled;
            } else {
                log.err("Upstream {x}: [fail] WriteFailed while sending request", .{ self.id });
            }
            return;
        },
    };

    var result = req.receiveHead(&.{}) catch |err| switch (err) {
        error.WriteFailed => {
            self.status.store(.failed, .monotonic);
            if (req.connection.?.stream_writer.err) |e| {
                if (e == error.Canceled) return error.Canceled;
                log.err("Upstream {x}: [fail] WriteFailed: {t} while receiving response headers", .{ self.id, e });
            } else {
                log.err("Upstream {x}: [fail] WriteFailed while receiving response headers", .{ self.id });
            }
            return;
        },
        error.ReadFailed => {
            self.status.store(.failed, .monotonic);
            if (req.connection.?.stream_reader.err) |e| {
                if (e == error.Canceled) return error.Canceled;
                log.err("Upstream {x}: [fail] ReadFailed: {t} while receiving response headers", .{ self.id, e });
            } else {
                log.err("Upstream {x}: [fail] ReadFailed while receiving response headers", .{ self.id });
            }
            return;
        },
        error.Canceled => |e| {
            self.status.store(.failed, .monotonic);
            return e;
        },
        else => {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [fail] {t} while receiving response headers", .{ self.id, err });
            return;
        },
    };

    switch (result.head.status) {
        .ok => {},
        .not_found => {
            self.status.store(.not_found, .monotonic);
            log.info("Upstream {x}: [404] {f}", .{ self.id, req.uri });
            return;
        },
        else => |status| {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [{}] {f}", .{ self.id, @intFromEnum(status), req.uri });
            return;
        },
    }

    const head_received = tempora.now_utc(io).timestamp_ms();
    const head_time_ms: u32 = @intCast(std.math.clamp(head_received - request_started, 0, std.math.maxInt(u32)));

    const decompress_buffer: []u8 = switch (result.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => gpa.alloc(u8, std.compress.flate.max_window_len) catch |err| switch (err) {
            error.OutOfMemory => {
                self.status.store(.failed, .monotonic);
                log.err("Upstream {x}: [fail] {t} while allocating decompress buffer", .{ self.id, err });
                return;
            },
        },
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len) catch |err| switch (err) {
            error.OutOfMemory => {
                self.status.store(.failed, .monotonic);
                log.err("Upstream {x}: [fail] {t} while allocating decompress buffer", .{ self.id, err });
                return;
            },
        },
        .compress => {
            self.status.store(.failed, .monotonic);
            log.err("Upstream {x}: [fail] unsupported content-encoding: {t}", .{ self.id, result.head.content_encoding });
            return;
        },
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);

    var decompress: std.http.Decompress = undefined;
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    var transfer_buffer: [32 * 1024]u8 = undefined;
    const reader = result.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    if (result.head.content_length) |content_length| {
        const data = gpa.alloc(u8, content_length) catch |err| switch (err) {
            error.OutOfMemory => {
                self.status.store(.failed, .monotonic);
                log.err("Upstream {x}: [fail] {t} while allocating content buffer", .{ self.id, err });
                return;
            },
        };
        self.data = data;

        var collector = std.Io.Writer.fixed(data);

        while (true) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    self.status.store(.failed, .monotonic);
                    if (req.connection.?.stream_reader.err) |e| {
                        if (e == error.Canceled) return error.Canceled;
                        log.err("Upstream {x}: [fail] ReadFailed: {t} while receiving content", .{ self.id, e });
                    } else {
                        log.err("Upstream {x}: [fail] ReadFailed while receiving content", .{ self.id });
                    }
                    return;
                },
            };
            const buffered_bytes = reader.buffered();
            collector.writeAll(buffered_bytes) catch |err| switch (err) {
                error.WriteFailed => {
                    self.status.store(.failed, .monotonic);
                    log.err("Upstream {x}: [fail] received too much content", .{ self.id });
                    return;
                },
            };
            _ = self.bytes_available.fetchAdd(@intCast(buffered_bytes.len), .acq_rel);
            io.futexWake(u32, &self.bytes_available.raw, std.math.maxInt(u32));
            hasher.update(buffered_bytes);
            reader.toss(buffered_bytes.len);
        }

    } else {
        var collector: std.Io.Writer.Allocating = .init(gpa);
        defer collector.deinit();

        while (true) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    self.status.store(.failed, .monotonic);
                    if (req.connection.?.stream_reader.err) |e| {
                        if (e == error.Canceled) return error.Canceled;
                        log.err("Upstream {x}: [fail] ReadFailed: {t} while receiving content", .{ self.id, e });
                    } else {
                        log.err("Upstream {x}: [fail] ReadFailed while receiving content", .{ self.id });
                    }
                    return;
                },
            };
            const buffered_bytes = reader.buffered();
            collector.writer.writeAll(buffered_bytes) catch |err| switch (err) {
                error.WriteFailed => {
                    self.status.store(.failed, .monotonic);
                    log.err("Upstream {x}: [fail] OutOfMemory while allocating content buffer", .{ self.id });
                    return;
                },
            };
            hasher.update(buffered_bytes);
            reader.toss(buffered_bytes.len);
        }

        self.data = collector.toOwnedSlice() catch |err| switch (err) {
            error.OutOfMemory => {
                self.status.store(.failed, .monotonic);
                log.err("Upstream {x}: [fail] {t} while allocating content buffer", .{ self.id, err });
                return;
            },
        };
        self.bytes_available.store(@intCast(self.data.len), .release);
        io.futexWake(u32, &self.bytes_available.raw, std.math.maxInt(u32));
    }

    self.hash = hasher.finalResult();
    if (self.bytes_available.load(.seq_cst) != self.data.len) {
        self.status.store(.failed, .monotonic);
        log.err("Upstream {x}: [fail] did not receive full content", .{ self.id });
        return;
    }
    self.status.store(.complete, .monotonic);
    log.info("Upstream {x}: [200] {f}", .{ self.id, req.uri });

    if (head_time_ptr) |ptr| {
        var old = expected_head_time;
        for (0..100) |_| {
            const new = @max((old * 15 + head_time_ms) / 16, min_connect_timeout_seconds * std.time.ms_per_s / 2);
            if (ptr.cmpxchgWeak(old, new, .monotonic, .monotonic)) |new_expected| {
                old = new_expected;
            } else {
                log.debug("Upstream {x}: Updated expected upstream request head time to {f}", .{ self.id, std.Io.Duration.fromMilliseconds(new) });
                break;
            }
        }
    }
}

fn watchdog(self: *Upstream_Transfer, io: std.Io, request_started: i64, config: *const Config) error{Canceled}!void {
    var timeout_seconds = config.upstream.initial_transfer_timeout_seconds;
    try io.sleep(.fromSeconds(timeout_seconds), .awake);
    var last_seen_bytes: u32 = 0;
    while (true) {
        const now = tempora.now_utc(io).timestamp_ms();
        if (now - request_started > config.upstream.max_transfer_time_seconds * std.time.ms_per_s) return;

        const bytes_now = self.bytes_available.load(.monotonic);
        if (bytes_now == last_seen_bytes) return;

        const delta_bytes = bytes_now - last_seen_bytes;
        const bps = (delta_bytes + timeout_seconds - 1) / timeout_seconds;

        log.info("Upstream {x}: Transferring at {f}/s, total transferred so far: {f}", .{
            self.id,
            fmt.bytes(bps),
            fmt.bytes(bytes_now),
        });

        last_seen_bytes = bytes_now;
        timeout_seconds = config.upstream.dead_transfer_timeout_seconds;
        try io.sleep(.fromSeconds(timeout_seconds), .awake);
    }
}

const Upstream_Transfer = @This();

const log = std.log.scoped(.zigmirror);

const Download_Permission = @import("Download_Permission.zig");
const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Config = @import("Config.zig");
const headers = @import("headers.zig");
const tempora = @import("tempora");
const fmt = @import("fmt");
const http = @import("http");
const std = @import("std");
