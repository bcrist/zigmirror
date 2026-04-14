pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    const artifact = maybe_artifact orelse return error.NotFound;

    const now = request.received_dt.with_offset(0).timestamp_ms();

    if (try cache.mem.get(artifact)) |ref| {
        defer ref.unlock();

        if (ref.ptr.data) |data| {
            try request.set_response_header("content-type", ref.ptr.artifact.?.extension.content_type());
            try request.respond(data);

            const end = tempora.now(request.io).timestamp_ms();
            const request_duration: u32 = @intCast(std.math.clamp(end - now, 0, std.math.maxInt(u32)));

            log.info("{f}: took {f}", .{
                request.cid,
                std.Io.Duration.fromMilliseconds(request_duration),
            });

            ref.ptr.requests.hit(now, request_duration);
            _ = server_stats.artifacts_served.fetchAdd(1, .monotonic);
            return;
        }

        if (now - ref.ptr.requests.last_time.load(.monotonic) < config.recheck_not_found_after_seconds * 1000) {
            ref.ptr.requests.hit_not_found(now);
            return error.NotFound;
        }

        _ = try request.chain("upstream");
        return;
    }

    if (try cache.fs.get(artifact)) |ref| {
        defer ref.unlock();

        if (ref.ptr.bytes) |bytes| {
            if (request.req.head.method == .HEAD) {
                try request.set_response_header("content-type", ref.ptr.artifact.?.extension.content_type());
                try request.respond("");
                return;
            }

            const cache_dir = std.Io.Dir.cwd().createDirPathOpen(request.io, config.cache.fs.path, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => |e| {
                    log.err("{f}: Failed to create/open fs cache directory: {t}", .{
                        request.cid,
                        e,
                    });
                    _ = try request.chain("upstream");
                    return;
                },
            };
            defer cache_dir.close(request.io);

            const filename = try request.fmt("{f}", .{ artifact });
            const cache_file = cache_dir.openFile(request.io, filename, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => |e| {
                    log.err("{f}: Failed to open file \"{f}\" from fs cache: {t}", .{
                        request.cid,
                        std.zig.fmtString(filename),
                        e,
                    });
                    _ = try request.chain("upstream");
                    return;
                },
            };
            defer cache_file.close(request.io);

            var file_reader = cache_file.reader(request.io, &.{});

            try request.set_response_header("content-type", ref.ptr.artifact.?.extension.content_type());
            request.response.content_length = bytes;

            var writer: *std.Io.Writer = try request.response_writer();
            _ = writer.sendFileAll(&file_reader, .unlimited) catch |err| switch (err) {
                error.ReadFailed => {
                    if (file_reader.err) |e| if (e == error.Canceled) return e;
                    if (file_reader.seek_err) |e| if (e == error.Canceled) return e;
                    if (file_reader.size_err) |e| if (e == error.Canceled) return e;
                    // issue with filesystem; try to download file again
                    _ = try request.chain("upstream");
                    return;
                },
                else => |e| return e,
            };

            const end = tempora.now(request.io).timestamp_ms();
            const request_duration: u32 = @intCast(std.math.clamp(end - now, 0, std.math.maxInt(u32)));

            log.info("{f}: took {f}", .{
                request.cid,
                std.Io.Duration.fromMilliseconds(request_duration),
            });

            ref.ptr.requests.hit(now, request_duration);
            _ = server_stats.artifacts_served.fetchAdd(1, .monotonic);
            return;
        }
    }

    _ = try request.chain("upstream");
}

const log = std.log.scoped(.zigmirror);

const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Config = @import("Config.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
