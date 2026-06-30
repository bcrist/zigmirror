/// equivalent to request.respond(data), but uses streaming to track transfer speed
pub fn respond_slice(request: *http.Request, data: []const u8, server_stats: *Server_Stats) !void {
    const transfer_speed_ptr = server_stats.claim_downstream_transfer_speed();
    defer server_stats.release_transfer_speed(transfer_speed_ptr);

    request.response.content_length = data.len;

    var remaining = data;
    var last_reported_transfer_speed = std.Io.Timestamp.now(request.io, .awake).subDuration(.fromSeconds(1));
    var bytes_since_last_reported_transfer_speed: usize = 0;
    var limit: std.Io.Limit = .limited(64 * 1024);
    while (true) {
        const bytes_written = send_slice(request, remaining, data.len, server_stats, transfer_speed_ptr, &limit, &bytes_since_last_reported_transfer_speed, &last_reported_transfer_speed) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        remaining = remaining[bytes_written..];
    }

    try request.end_response();
}

pub fn send_slice(
    request: *http.Request,
    data: []const u8,
    full_content_length: usize,
    server_stats: *Server_Stats,
    transfer_speed_ptr: ?*f32,
    limit: *std.Io.Limit,
    bytes_since_last_reported_transfer_speed: *usize,
    last_reported_transfer_speed: *std.Io.Timestamp,
) !usize {
    var reader = std.Io.Reader.fixed(data);
    const writer: *std.Io.Writer = try request.response_writer_ranged(full_content_length, .{
        .ignore_bad_range = false,
        .ignore_range_not_satisfiable = false,
    });

    while (true) {
        const bytes_written = reader.stream(writer, limit.*) catch |err| switch (err) {
            error.ReadFailed => unreachable,
            else => |e| return e,
        };

        const end_ts: std.Io.Timestamp = .now(request.io, .awake);

        if (bytes_written > 0) {
            bytes_since_last_reported_transfer_speed.* += bytes_written;

            const duration_us: f32 = @floatFromInt(last_reported_transfer_speed.durationTo(end_ts).toMicroseconds());
            if (duration_us >= 1_000_000) {
                const bps = 1000_000 * @as(f32, @floatFromInt(bytes_written)) / duration_us;

                server_stats.update_transfer_speed(transfer_speed_ptr, bps);

                log.debug("{f}: Transferring at {d:.1}, total transferred so far: {f}", .{
                    request.cid,
                    fmt.si.value(bps, "B/s"),
                    fmt.bytes(reader.seek),
                });

                if (!std.math.isInf(bps) and !std.math.isNan(bps)) {
                    limit.* = .limited(@max(4096, @as(usize, @intFromFloat(bps))));
                }

                last_reported_transfer_speed.* = end_ts;
                bytes_since_last_reported_transfer_speed.* = 0;
            }
        }

        if (reader.buffered().len < limit.toInt().?) return reader.seek;
    }
}

const log = std.log.scoped(.zigmirror);

const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const http = @import("http");
const fmt = @import("fmt");
const std = @import("std");
