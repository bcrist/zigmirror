allocator: std.mem.Allocator,
uncompressed_length: usize,
compressed_data: []const u8,
etag: []const u8,
last_modified: tempora.Date_Time,

pub fn init(io: std.Io, gpa: std.mem.Allocator, config: *const Config) !Root {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();

    try w.ensureUnusedCapacity(1024);
    var deflate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&w.writer, &deflate_buf, .zlib, .best);
    var hasher: std.Io.Writer.Hashed(std.crypto.hash.sha2.Sha256) = .initHasher(&compress.writer, .init(.{}), &.{});

    try @import("root").resources.templates.@"root.zk".render(&hasher.writer, .{
        .hostname = config.public_hostname,
        .zigmirror_version = @import("build_options").version,
        .zig_version = @import("builtin").zig_version,
        .allow_devkits = config.allow_devkit_artifacts,
    }, .{});

    try compress.finish();

    const hash = hasher.hasher.finalResult();
    const etag = try std.fmt.allocPrint(gpa, "{x}", .{ hash });
    errdefer gpa.free(etag);

    return .{
        .allocator = gpa,
        .uncompressed_length = hasher.hasher.total_len,
        .compressed_data = try w.toOwnedSlice(),
        .etag = etag,
        .last_modified = tempora.now_utc(io).dt,
    };
}

pub fn deinit(self: *Root) void {
    self.allocator.free(self.compressed_data);
    self.allocator.free(self.etag);
}

pub fn get(request: *http.Request, root: Root, arena: std.mem.Allocator) !void {
    try request.maybe_add_common_response_headers_comptime(.{
        .content_type = .html_utf8,
    });

    try request.maybe_add_common_response_headers(.{
        .etag = root.etag,
        .last_modified_utc = root.last_modified,
    });

    try request.check_not_modified(root.last_modified, root.etag);

    if (request.check_accept_encoding(.deflate)) {
        try request.set_response_header("content-encoding", "deflate");
        try request.respond_ranged(root.compressed_data, .{});
    } else {
        var compressed_reader = std.Io.Reader.fixed(root.compressed_data);
        var decompress: std.http.Decompress = undefined;
        const decompress_buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
        decompress = .{ .flate = .init(&compressed_reader, .zlib, decompress_buffer) };
        _ = try decompress.flate.reader.streamRemaining(try request.response_writer_ranged(root.uncompressed_length, .{}));
    }
}

const Root = @This();

const Config = @import("Config.zig");
const tempora = @import("tempora");
const http = @import("http");
const std = @import("std");
