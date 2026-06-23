pub fn get(request: *http.Request, maybe_artifact: ?Artifact, cache: *Caches, server_stats: *Server_Stats, config: *const Config, index: *Index, _: Download_Permission.Downstream) !void {
    const artifact = maybe_artifact orelse return error.NotFound;

    const now = request.received_dt.with_offset(0).timestamp_ms();

    if (try cache.mem.get(artifact, .shared)) |ref| {
        defer ref.unlock();

        switch (ref.ptr.data) {
            .none => {
                if (now - ref.ptr.requests.last_time.load(.monotonic) < config.upstream.recheck_not_found_after_seconds * 1000) {
                    ref.ptr.requests.hit_not_found(now);
                    return error.NotFound;
                }
                _ = try request.chain("upstream");
            },
            .transfer => {
                _ = try request.chain("upstream");
            },
            .owned => |data| {
                try headers.check_and_set_headers(request, ref.ptr);
                try downstream_transfer.respond_slice(request, data, server_stats);
                Caches.report_hit(request, server_stats, ref.ptr);
                if (index.is_outdated_by_artifact(request.io, request.received_dt, artifact)) {
                    _ = try request.chain("regenerate_index");
                }
            },
        }
        return;
    }

    if (try cache.fs.get(artifact, .shared)) |ref| {
        defer ref.unlock();

        if (ref.ptr.bytes) |bytes| {
            if (request.req.head.method == .HEAD) {
                try headers.check_and_set_headers(request, ref.ptr);
                try request.respond("");
                if (index.is_outdated_by_artifact(request.io, request.received_dt, artifact)) {
                    _ = try request.chain("regenerate_index");
                }
                return;
            }

            const cache_dir = std.Io.Dir.cwd().createDirPathOpen(request.io, config.cache.fs.path, .{}) catch |err| switch (err) {
                error.Canceled => |e| return e,
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
            const cache_file = cache_dir.openFile(request.io, filename, .{ .lock = .shared }) catch |err| switch (err) {
                error.Canceled => |e| return e,
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

            var file_buf: [32768]u8 = undefined; // normally won't be used, but on systems that don't support sendfile, it's needed for a fallback.
            var file_reader = cache_file.reader(request.io, &file_buf);

            const file_size = file_reader.getSize() catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| {
                    log.err("{f}: Failed to retrieve file size for \"{f}\": {t}", .{
                        request.cid,
                        std.zig.fmtString(filename),
                        e,
                    });
                    _ = try request.chain("upstream");
                    return;
                },
            };

            if (file_size != bytes) {
                // file size doesn't match what we expected; download it again.
                _ = try request.chain("upstream");
                return;
            }

            try headers.check_and_set_headers(request, ref.ptr);

            {
                const transfer_speed_ptr = server_stats.claim_downstream_transfer_speed();
                defer server_stats.release_transfer_speed(transfer_speed_ptr);

                request.response.content_length = bytes;
                const writer: *std.Io.Writer = try request.response_writer();

                var begin_ts: std.Io.Timestamp = .now(request.io, .awake);
                var limit: std.Io.Limit = .limited(64 * 1024);

                var total_bytes_written: usize = 0;

                while (!file_reader.atEnd()) {
                    const bytes_written = writer.sendFile(&file_reader, limit) catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.Unimplemented => bytes: {
                            file_reader.mode = file_reader.mode.toSimple();
                            break :bytes try writer.sendFileReading(&file_reader, limit);
                        },
                        error.ReadFailed => {
                            if (file_reader.err) |e| if (e == error.Canceled) return e;
                            if (file_reader.seek_err) |e| if (e == error.Canceled) return e;
                            if (file_reader.size_err) |e| if (e == error.Canceled) return e;

                            Caches.evict_from_fs_cache(&cache.fs, server_stats, artifact, config.cache.fs.path) catch |err2| switch (err2) {
                                error.Canceled => |e| return e,
                                else => {
                                    log.warn("{f}: Failed to evict {f} from fs cache after failed sendfile: {t}", .{ request.cid, artifact, err2 });
                                },
                            };

                            if (file_reader.err) |e| return e;
                            if (file_reader.seek_err) |e| return e;
                            if (file_reader.size_err) |e| return e;
                            return error.InternalServerError;
                        },
                        else => |e| return e,
                    };

                    const end_ts: std.Io.Timestamp = .now(request.io, .awake);
                    if (bytes_written > 0) {
                        const duration_us: f32 = @floatFromInt(begin_ts.durationTo(end_ts).toMicroseconds());
                        const bps = 1000_000 * @as(f32, @floatFromInt(bytes_written)) / duration_us;

                        total_bytes_written += bytes_written;

                        server_stats.update_transfer_speed(transfer_speed_ptr, bps);

                        log.debug("{f}: Transferring at {d:.1} via sendfile, total transferred so far: {f}", .{
                            request.cid,
                            fmt.si.value(bps, "B/s"),
                            fmt.bytes(total_bytes_written),
                        });

                        if (!std.math.isInf(bps) and !std.math.isNan(bps)) {
                            limit = .limited(@max(4096, @as(usize, @intFromFloat(bps))));
                        }
                    }

                    begin_ts = end_ts;
                }

                if (total_bytes_written != bytes) {
                    log.err("{f}: sendfile wrote {} bytes, but {} bytes were expected for {f}", .{ request.cid, total_bytes_written, bytes, artifact });
                    return error.InternalServerError;
                }

                try request.end_response();
            }

            Caches.report_hit(request, server_stats, ref.ptr);
            
            if (index.is_outdated_by_artifact(request.io, request.received_dt, artifact)) {
                _ = try request.chain("regenerate_index");
            }
            return;
        }
    }

    _ = try request.chain("upstream");
}

const log = std.log.scoped(.zigmirror);

const downstream_transfer = @import("downstream_transfer.zig");
const Download_Permission = @import("Download_Permission.zig");
const Server_Stats = @import("Server_Stats.zig");
const Index = @import("Index.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Config = @import("Config.zig");
const headers = @import("headers.zig");
const tempora = @import("tempora");
const http = @import("http");
const fmt = @import("fmt");
const std = @import("std");
