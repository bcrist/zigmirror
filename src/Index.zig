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

pub fn get(self: *Index, request: *http.Request, server_stats: *Server_Stats, config: *const Config, _: Download_Permission.Upstream, _: Download_Permission.Downstream) !void {
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
        self.regenerate(request.io, server_stats, config);
    }
    
    if (self.current) |content| {
        try content.respond(request);
    } else return error.BadGateway;
}

pub fn lock_and_regenerate(self: *Index, io: std.Io, server_stats: *Server_Stats, config: *const Config, _: Download_Permission.Upstream) !void {
    try self.lock.lock(io);
    defer self.lock.unlock(io);

    self.regenerate(io, server_stats, config);
}

// assumes lock is held (either shared or exclusively) before calling
fn regenerate(self: *Index, io: std.Io, server_stats: *Server_Stats, config: *const Config) void {
    const now = tempora.now_utc(io).dt;
    if (now.is_before(self.last_checked_upstream) or now.duration_since(self.last_checked_upstream).toSeconds() < self.min_recheck_index_interval_seconds) return;
    self.last_checked_upstream = now;
    const content = Content.generate(io, self.gpa, server_stats, config) catch |err| {
        log.err("Failed to regenerate index.json: {t}", .{ err });
        if (@errorReturnTrace()) |ert| {
            std.debug.dumpErrorReturnTrace(ert);
        }
        return;
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

    return artifact.version().order(current.master_src.version()) == .gt;
}

const Content = struct {
    generated: tempora.Date_Time,
    etag: []const u8,
    compressed_json: []const u8,
    master_date: tempora.Date,
    master_src: Artifact,

    pub fn generate(io: std.Io, gpa: std.mem.Allocator, server_stats: *Server_Stats, config: *const Config) !Content {
        var transfer: Upstream_Transfer = .init(io);
        defer transfer.deinit(gpa);

        transfer.execute(io, "/download/index.json", null, server_stats, config, gpa);

        switch (transfer.status.raw) {
            .in_progress => unreachable,
            .failed => return error.GatewayTimeout,
            .not_found => return error.BadGateway,
            .complete => {},
        }

        const total_bytes = transfer.bytes_available.raw;
        std.debug.assert(total_bytes == transfer.data.len);

        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, transfer.data, .{});
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

        var version_iter = parsed.value.object.iterator();
        while (version_iter.next()) |version_entry| {
            if (version_entry.value_ptr.* != .object) return error.BadGateway;
            var iter = version_entry.value_ptr.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* != .object) continue; // "version", "date", "docs", "stdDocs", etc.
                const artifact = &entry.value_ptr.object;
                const tarball_value = artifact.get("tarball") orelse return error.BadGateway;
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
                tarball = try std.fmt.allocPrint(parsed.arena.allocator(), "https://{s}/{s}", .{ config.public_hostname, tarball });
                try artifact.put(parsed.arena.allocator(), "tarball", .{ .string = tarball });
            }
        }

        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();

        try writer.ensureUnusedCapacity(4096);

        var deflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor: std.compress.flate.Compress = try .init(&writer.writer, &deflate_buffer, .zlib, .default);
        
        std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &compressor.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        compressor.finish() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(writer.writer.buffered(), &hash, .{});

        const etag = try std.fmt.allocPrint(gpa, "{x}", .{ hash });
        errdefer gpa.free(etag);

        return .{
            .generated = tempora.now_utc(io).dt,
            .etag = etag,
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
            try request.respond(self.compressed_json);
        } else {
            var compressed_reader = std.Io.Reader.fixed(self.compressed_json);
            var decompress: std.http.Decompress = undefined;
            const decompress_buffer = try request.arena.alloc(u8, std.compress.flate.max_window_len);
            decompress = .{ .flate = .init(&compressed_reader, .zlib, decompress_buffer) };
            const reader = &decompress.flate.reader;
            _ = try reader.streamRemaining(try request.response_writer());
        }
    }
};

const Index = @This();

const log = std.log.scoped(.zigmirror);

const Upstream_Transfer = @import("Upstream_Transfer.zig");
const Download_Permission = @import("Download_Permission.zig");
const Artifact = @import("Artifact.zig");
const Server_Stats = @import("Server_Stats.zig");
const Config = @import("Config.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
