pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config) !void {
    const artifact = maybe_artifact orelse return error.NotFound;

    const now = request.received_dt.with_offset(0).timestamp_ms();

    if (try cache.mem.get(artifact, .shared)) |ref| {
        defer ref.unlock();

        if (ref.ptr.data) |data| {
            Caches.report_hit(request, server_stats, ref.ptr);
            try headers.check_and_set_headers(request, ref.ptr);
            try request.respond(data);
            return;
        }

        if (now - ref.ptr.requests.last_time.load(.monotonic) < config.upstream.recheck_not_found_after_seconds * 1000) {
            ref.ptr.requests.hit_not_found(now);
            return error.NotFound;
        }

        _ = try request.chain("upstream");
        return;
    }

    if (try cache.fs.get(artifact, .shared)) |ref| {
        defer ref.unlock();

        if (ref.ptr.bytes) |bytes| {
            if (request.req.head.method == .HEAD) {
                try headers.check_and_set_headers(request, ref.ptr);
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

            Caches.report_hit(request, server_stats, ref.ptr);
            try headers.check_and_set_headers(request, ref.ptr);
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
const headers = @import("headers.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
