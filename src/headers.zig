/// Assumes ref is locked
pub fn check_and_set_headers(request: *http.Request, entry: *Cache.Entry) !void {
    try request.set_response_header("server", try request.fmt("zigmirror {s}", .{ zon.version }));
    try request.try_set_date();

    const request_count = entry.requests.count.load(.monotonic);
    const first_request_ts = entry.requests.first_time.load(.monotonic);
    const last_modified_dt = if (request_count > 0) tempora.Date_Time.With_Offset.from_timestamp_ms(first_request_ts, null).dt else request.received_dt;
    
    var not_modified_by_date: ?bool = null;
    var not_modified_by_etag: ?bool = null;

    var iter = request.header_iterator();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
            const last_seen = tempora.Date_Time.With_Offset.from_string(tempora.Date_Time.With_Offset.http, header.value) catch continue;
            not_modified_by_date = !last_seen.dt.is_before(last_modified_dt);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
            if (entry.hash) |hash| {
                var inm_iter: http.ETag_Iterator = .{ .remaining = header.value };
                not_modified_by_etag = while (try inm_iter.next()) |etag_entry| {
                    if (etag_entry.value.len != hash.len * 2) continue;
                    const hash_matches = for (0.., hash) |i, hash_byte| {
                        const found_byte = std.fmt.parseUnsigned(u8, etag_entry.value[i * 2 ..][0..2], 16) catch break false;
                        if (found_byte != hash_byte) break false;
                    } else true;
                    if (hash_matches) break true;
                } else false;
            }
        }
    }

    if (not_modified_by_etag orelse not_modified_by_date orelse false) {
        return error.NotModified;
    }

    try request.set_response_header("content-type", entry.artifact.?.extension.content_type());
    try request.set_response_header("content-disposition", http.Content_Disposition.to_string(.attachment));
    try request.set_response_header("cache-control", "max-age=31536000, immutable, public");
    try request.set_response_header("last-modified", try request.fmt_http_date(last_modified_dt));
    if (entry.hash) |hash| {
        try request.set_response_header("etag", try request.fmt("\"{x}\"", .{ hash }));
    }
}

const log = std.log.scoped(.zigmirror);

const zon = @import("zon");
const Cache = @import("Cache.zig");
const Artifact = @import("Artifact.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
