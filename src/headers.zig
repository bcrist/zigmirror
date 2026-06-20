/// Assumes ref is locked
pub fn check_and_set_headers(ref: *Cache.Entry.Ref, request: *http.Request) !void {
    try request.set_response_header("server", zon.version);
    try request.try_set_date();

    const first_request_ts = ref.ptr.requests.first_time.load(.monotonic);
    const last_modified_dt = if (first_request_ts != 0) tempora.Date_Time.With_Offset.from_timestamp_ms(first_request_ts).dt else request.received_dt;
    

    var not_modified_by_date: ?bool = null;
    var not_modified_by_etag: ?bool = null;

    var iter = request.header_iterator();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
            const last_seen = tempora.Date_Time.With_Offset.from_string(tempora.Date_Time.With_Offset.http, header.value) catch continue;
            not_modified_by_date = !last_seen.dt.is_before(last_modified_dt);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
            var inm_iter: http.ETag_Iterator = .{ .remaining = header.value };
            not_modified_by_etag = while (try inm_iter.next()) |entry| {
                if (std.mem.eql(u8, entry.value, etag)) {
                    break true;
                }
            } else false;
        }
    }

    if (not_modified_by_etag orelse not_modified_by_date orelse false) {
        return error.NotModified;
    }

    try request.set_response_header("content-type", ref.ptr.artifact.?.extension.content_type());
    try request.set_response_header("cache-control", "max-age=31536000, immutable, public");
    try request.set_response_header("last-modified", try request.fmt_http_date(last_modified_dt));
    try request.set_response_header("etag", );
}

const zon = @import("zon");
const Cache = @import("Cache.zig");
const Artifact = @import("Artifact.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
