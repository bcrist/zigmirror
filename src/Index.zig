gpa: std.mem.Allocator,
lock: std.Io.RwLock,
last_checked_upstream: tempora.Date_Time,
min_recheck_index_interval_seconds: u32,
recheck_expired_index_interval_seconds: u32,
current: ?Content,

pub fn init(gpa: std.mem.Allocator, config: *const Config) Index {
    return .{
        .gpa = gpa,
        .lock = .init,
        .last_checked_upstream = .epoch,
        .min_recheck_index_interval_seconds = config.upstream.min_recheck_index_interval_seconds,
        .recheck_expired_index_interval_seconds = config.upstream.recheck_expired_index_interval_seconds,
        .current = null,
    };
}

pub fn deinit(self: *Index) void {
    if (self.current) |*current| {
        current.deinit(self.gpa);
    }
}

pub fn get(
    self: *Index,
    loop: *http.Loop,
    request: *http.Request,
    cache: *Caches,
    server_stats: *Server_Stats,
    config: *const Config,
    downloads: *Download_Permission,
    _: Download_Permission.Upstream,
    _: Download_Permission.Downstream,
) !void {
    {
        try self.lock.lockShared(request.io);
        defer self.lock.unlockShared(request.io);

        if (!self.is_outdated(request.received_dt)) {
            if (self.current) |content| {
                try content.respond(request);
                return;
            } else return error.BadGateway;
        }
    }

    try self.lock.lock(request.io);
    defer self.lock.unlock(request.io);

    if (self.is_outdated(tempora.now_utc(request.io).dt)) {
        try self.locked_regenerate(loop, cache, server_stats, config, downloads);
    }
    
    if (self.current) |content| {
        try content.respond(request);
    } else return error.BadGateway;
}

pub fn maybe_regenerate(self: *Index, loop: *http.Loop, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission, _: Download_Permission.Upstream) error{Canceled}!void {
    try self.lock.lock(loop.io);
    defer self.lock.unlock(loop.io);

    if (self.is_outdated(tempora.now_utc(loop.io).dt)) {
        try self.locked_regenerate(loop, cache, server_stats, config, downloads);
    }
}

pub fn regenerate(self: *Index, loop: *http.Loop, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission, _: Download_Permission.Upstream) error{Canceled}!void {
    try self.lock.lock(loop.io);
    defer self.lock.unlock(loop.io);

    try self.locked_regenerate(loop, cache, server_stats, config, downloads);
}

// assumes lock is held exclusively before calling
fn locked_regenerate(self: *Index, loop: *http.Loop, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission) error{Canceled}!void {
    const now = tempora.now_utc(loop.io).dt;
    if (now.is_before(self.last_checked_upstream) or now.duration_since(self.last_checked_upstream).toSeconds() < self.min_recheck_index_interval_seconds) return;
    log.info("Beginning index.json refresh", .{});
    self.last_checked_upstream = now;
    const content = Content.generate(loop, cache, server_stats, config, downloads) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.err("Failed to regenerate index.json: {t}", .{ err });
            if (@errorReturnTrace()) |ert| {
                std.debug.dumpErrorReturnTrace(ert);
            }
            return;
        }
    };
    if (self.current) |*current| {
        current.deinit(self.gpa);
    }
    self.current = content;
}

// assumes lock is held (either shared or exclusively) before calling
fn is_outdated(self: *const Index, now: tempora.Date_Time) bool {
    if (now.is_before(self.last_checked_upstream) or now.duration_since(self.last_checked_upstream).toSeconds() < self.min_recheck_index_interval_seconds) return false;
    if (self.current) |current| {
        const expiration = current.master_date.plus_days(2).with_time(.midnight);
        if (now.is_before(expiration)) return false;
        if (now.duration_since(self.last_checked_upstream).toSeconds() < self.recheck_expired_index_interval_seconds) return false;
    }
    return true;
}

pub fn is_outdated_by_artifact(self: *Index, io: std.Io, now: tempora.Date_Time, artifact: Artifact) bool {
    if (artifact.pre == null) return false;
    if (artifact.artifact_type == .devkit) return false;

    self.lock.lockSharedUncancelable(io);
    defer self.lock.unlockShared(io);

    if (now.is_before(self.last_checked_upstream) or now.duration_since(self.last_checked_upstream).toSeconds() < self.min_recheck_index_interval_seconds) return false;

    const current = self.current orelse return true;

    return artifact.version_order(current.master_src) == .gt;
}

const Content = struct {
    generated: tempora.Date_Time,
    etag: []const u8,
    uncompressed_length: usize,
    compressed_json: []const u8,
    master_date: tempora.Date,
    master_src: Artifact,

    pub fn generate(loop: *http.Loop, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission) !Content {
        var transfer: Upstream_Transfer = .init(loop.io);
        defer transfer.deinit(loop.gpa);

        try transfer.execute(loop.io, "/download/index.json", null, server_stats, config, loop.gpa);

        switch (transfer.status.raw) {
            .in_progress => unreachable,
            .failed => return error.GatewayTimeout,
            .not_found => return error.BadGateway,
            .complete => {},
        }

        const total_bytes = transfer.bytes_available.raw;
        std.debug.assert(total_bytes == transfer.data.len);

        const parsed = try std.json.parseFromSlice(std.json.Value, loop.gpa, transfer.data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.BadGateway;

        const master_value = parsed.value.object.get("master") orelse return error.BadGateway;
        if (master_value != .object) return error.BadGateway;

        const master_version_value = master_value.object.get("version") orelse return error.BadGateway;
        if (master_version_value != .string) return error.BadGateway;

        const master_src_name = try std.fmt.allocPrint(parsed.arena.allocator(), "zig-{s}.tar.xz", .{ master_version_value.string });
        const master_src: Artifact = try .parse(master_src_name);

        const master_date_value = master_value.object.get("date") orelse return error.BadGateway;
        if (master_date_value != .string) return error.BadGateway;

        const master_date = tempora.Date.from_string(tempora.Date.iso8601, master_date_value.string) catch return error.BadGateway;

        var min_prewarm_version = master_src.version();
        if (config.prewarm.min_version.len > 0 and !std.mem.eql(u8, config.prewarm.min_version, "master")) {
            if (std.SemanticVersion.parse(config.prewarm.min_version)) |version| {
                min_prewarm_version = version;
            } else |err| {
                log.warn("Invalid prewarm.min_version configuration: {t}", .{ err });
            }
        }

        var version_iter = parsed.value.object.iterator();
        while (version_iter.next()) |version_entry| {
            if (version_entry.value_ptr.* != .object) return error.BadGateway;
            var iter = version_entry.value_ptr.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* != .object) continue; // "version", "date", "docs", "stdDocs", etc.
                const artifact_object = &entry.value_ptr.object;
                const tarball_value = artifact_object.get("tarball") orelse return error.BadGateway;
                if (tarball_value != .string) return error.BadGateway;
                var tarball = tarball_value.string;
                if (std.mem.startsWith(u8, tarball, "https://ziglang.org/builds/")) {
                    tarball = tarball["https://ziglang.org/builds/".len..];
                } else if (std.mem.startsWith(u8, tarball, "https://ziglang.org/download/")) {
                    tarball = tarball["https://ziglang.org/download/".len..];
                    if (std.mem.findScalar(u8, tarball, '/')) |slash_pos| {
                        tarball = tarball[slash_pos + 1 ..];
                    }
                } else continue;

                const artifact = Artifact.parse(tarball) catch continue;

                tarball = try std.fmt.allocPrint(parsed.arena.allocator(), "https://{s}/{s}", .{ config.public_hostname, tarball });
                try artifact_object.put(parsed.arena.allocator(), "tarball", .{ .string = tarball });

                if (artifact.version().order(min_prewarm_version) != .lt) {
                    try prewarm_artifact(loop, artifact, cache, server_stats, config, downloads);
                }
            }
        }

        var writer: std.Io.Writer.Allocating = .init(loop.gpa);
        defer writer.deinit();

        try writer.ensureUnusedCapacity(4096);

        var deflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor: std.compress.flate.Compress = try .init(&writer.writer, &deflate_buffer, .zlib, .default);
        var hasher: std.Io.Writer.Hashed(std.crypto.hash.sha2.Sha256) = .initHasher(&compressor.writer, .init(.{}), &.{});
        
        std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &hasher.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        compressor.finish() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        const hash = hasher.hasher.finalResult();
        const etag = try std.fmt.allocPrint(loop.gpa, "{x}", .{ hash });
        errdefer loop.gpa.free(etag);

        return .{
            .generated = tempora.now_utc(loop.io).dt,
            .etag = etag,
            .uncompressed_length = hasher.hasher.total_len,
            .compressed_json = try writer.toOwnedSlice(),
            .master_date = master_date,
            .master_src = master_src,
        };
    }
    
    pub fn deinit(self: *Content, gpa: std.mem.Allocator) void {
        gpa.free(self.etag);
        gpa.free(self.compressed_json);
    }

    pub fn respond(self: *const Content, request: *http.Request) !void {
        try request.maybe_add_common_response_headers_comptime(.{
            .content_type = .json_utf8,
        });
        try request.maybe_add_common_response_headers_and_check_not_modified(.{
            .etag = self.etag,
            .last_modified_utc = self.generated,
        });
        
        if (request.check_accept_encoding(.deflate)) {
            try request.set_response_header("content-encoding", "deflate");
            try request.respond_ranged(self.compressed_json, .{});
        } else {
            var compressed_reader = std.Io.Reader.fixed(self.compressed_json);
            var decompress: std.http.Decompress = undefined;
            const decompress_buffer = try request.arena().alloc(u8, std.compress.flate.max_window_len);
            decompress = .{ .flate = .init(&compressed_reader, .zlib, decompress_buffer) };
            const reader = &decompress.flate.reader;
            _ = try reader.streamRemaining(try request.response_writer_ranged(self.uncompressed_length, .{}));
        }
    }

};

/// N.B. Assumes config.prewarm.min_version has already been checked!
pub fn prewarm_artifact(loop: *http.Loop, artifact: Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, downloads: *Download_Permission) error{Canceled}!void {
    switch (artifact.artifact_type) {
        .source => if (!config.prewarm.source) return,
        .bootstrap => if (!config.prewarm.bootstrap) return,
        .build => |target_bs| {
            const target = target_bs.slice(&artifact.buf);
            for (config.prewarm.build_target) |prewarmed_target| {
                if (std.mem.eql(u8, prewarmed_target, target)) break;
                if (std.mem.eql(u8, prewarmed_target, "*")) break;
            } else return;
        },
        .devkit => return,
    }

    loop.concurrent(download_and_add_to_cache.prewarm, .{ loop.io, loop.gpa, artifact, cache, server_stats, config, downloads }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.warn("Failed to prewarm artifact {f}: {t}", .{ artifact, err });
        },
    };

    if (config.prewarm.minisig and !artifact.extension.is_minisig()) {
        const minisig_artifact = artifact.to_minisig_artifact();
        loop.concurrent(download_and_add_to_cache.prewarm, .{ loop.io, loop.gpa, minisig_artifact, cache, server_stats, config, downloads }) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {
                log.warn("Failed to prewarm minisig {f}: {t}", .{ minisig_artifact, err });
            },
        };
    }
}

const Index = @This();

const log = std.log.scoped(.zigmirror);

const download_and_add_to_cache = @import("download_and_add_to_cache.zig");
const Upstream_Transfer = @import("Upstream_Transfer.zig");
const Download_Permission = @import("Download_Permission.zig");
const Caches = @import("Caches.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const Config = @import("Config.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
