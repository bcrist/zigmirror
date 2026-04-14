artifact_type: Type,
extension: Extension,
major: u16,
minor: u16,
patch: u16,
pre: ?Buffer_Slice,
build: ?Buffer_Slice,
buf: [64]u8,

pub fn parse(filename: []const u8) ?Artifact {
    if (!std.mem.startsWith(u8, filename, "zig-")) return null;
    if (std.mem.findAny(u8, filename, "/\\")) |_| return null;

    const is_minisig = std.mem.endsWith(u8, filename, ".minisig");
    const filename_no_minisig = if (is_minisig) filename[0 .. filename.len - ".minisig".len] else filename;
    var extension: Extension = undefined;
    if (std.mem.endsWith(u8, filename_no_minisig, ".tar.xz")) {
        extension = if (is_minisig) .txz_minisig else .txz;
    } else if (std.mem.endsWith(u8, filename_no_minisig, ".zip")) {
        extension = if (is_minisig) .zip_minisig else .zip;
    } else return null;

    const filename_no_ext = filename[0 .. filename.len - extension.slice().len];

    var last_dash = std.mem.findScalarLast(u8, filename_no_ext, '-') orelse return null;
    var version_str = filename_no_ext[last_dash + 1 ..];

    if (std.mem.startsWith(u8, version_str, "dev.")) {
        last_dash = std.mem.findScalarLast(u8, filename_no_ext[0..last_dash], '-') orelse return null;
        version_str = filename_no_ext[last_dash + 1 ..];
    }

    const sv = std.SemanticVersion.parse(version_str) catch return null;

    var buf: [64]u8 = @splat(0);
    var w = std.Io.Writer.fixed(&buf);

    const pre: ?Buffer_Slice = if (sv.pre) |str| s: {
        const begin = w.end;
        w.writeAll(str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return null;
        };
        break :s .init_begin_end(begin, w.end);
    } else null;

    const build: ?Buffer_Slice = if (sv.build) |str| s: {
        const begin = w.end;
        w.writeAll(str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return null;
        };
        break :s .init_begin_end(begin, w.end);
    } else null;

    const arch_os_str: ?[]const u8 = if (last_dash > "zig".len) filename["zig-".len .. last_dash] else null;
    const artifact_type: Type = if (arch_os_str) |str| t: {
        if (std.mem.eql(u8, str, "bootstrap")) break :t .bootstrap;
        const begin = w.end;
        w.writeAll(str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return null;
        };
        break :t .{ .build = .init_begin_end(begin, w.end) };
    } else .source;

    return .{
        .artifact_type = artifact_type,
        .extension = extension,
        .major = @intCast(std.math.clamp(sv.major, 0, std.math.maxInt(u16))),
        .minor = @intCast(std.math.clamp(sv.minor, 0, std.math.maxInt(u16))),
        .patch = @intCast(std.math.clamp(sv.patch, 0, std.math.maxInt(u16))),
        .pre = pre,
        .build = build,
        .buf = buf,
    };
}

pub fn version(self: *const Artifact) std.SemanticVersion {
    return .{
        .major = self.major,
        .minor = self.minor,
        .patch = self.patch,
        .pre = if (self.pre) |pre| pre.slice(&self.buf) else null,
        .build = if (self.build) |build| build.slice(&self.buf) else null,
    };
}

pub fn format(self: *const Artifact, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.artifact_type) {
        .source => try writer.writeAll("zig-"),
        .bootstrap => try writer.writeAll("zig-bootstrap-"),
        .build => |s| try writer.print("zig-{s}-", .{ s.slice(&self.buf) }),
    }
    try writer.print("{f}{f}", .{ self.version(), self.extension });
}

pub fn upstream_path(self: *const Artifact, allocator: std.mem.Allocator) ![]const u8 {
    if (self.pre == null) {
        return try std.fmt.allocPrint(allocator, "/download/{f}/{f}", .{
            self.version(),
            self.*,
        });
    } else {
        return try std.fmt.allocPrint(allocator, "/builds/{f}", .{
            self.*,
        });
    }
}

pub fn upstream_url(self: *const Artifact, allocator: std.mem.Allocator) ![]const u8 {
    if (self.pre == null) {
        return try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{f}/{f}", .{
            self.version(),
            self.*,
        });
    } else {
        return try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/{f}", .{
            self.*,
        });
    }
}

pub const Type = union (enum) {
    source,
    bootstrap,
    build: Buffer_Slice,

    pub fn fmt(self: Type, buf: []const u8) Formatter {
        return .{
            .artifact_type = self,
            .buf = buf,
        };
    }

    pub const Formatter = struct {
        artifact_type: Type,
        buf: []const u8,

        pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@tagName(self.artifact_type));
            if (self.artifact_type == .build) {
                try writer.print(": {s}", .{ self.artifact_type.build.slice(self.buf) });
            }
        }
    };
};

pub const Extension = enum {
    txz,
    zip,
    txz_minisig,
    zip_minisig,

    pub fn format(self: Extension, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.slice());
    }

    pub fn slice(self: Extension) []const u8 {
        return switch (self) {
            .txz => ".tar.xz",
            .zip => ".zip",
            .txz_minisig => ".tar.xz.minisig",
            .zip_minisig => ".zip.minisig",
        };
    }

    pub fn content_type(self: Extension) []const u8 {
        return switch (self) {
            .txz => @as(Content_Type, .xz).to_string(),
            .zip => @as(Content_Type, .zip).to_string(),
            .txz_minisig => Content_Type.text_utf8.to_string(),
            .zip_minisig => Content_Type.text_utf8.to_string(),
        };
    }
};

const Buffer_Slice = struct {
    offset: u8,
    len: u8,

    pub fn init(offset: usize, len: usize) Buffer_Slice {
        return .{
            .offset = @intCast(offset),
            .len = @intCast(len),
        };
    }

    pub fn init_begin_end(begin: usize, end: usize) Buffer_Slice {
        return .{
            .offset = @intCast(begin),
            .len = @intCast(end - begin),
        };
    }

    pub fn slice(self: Buffer_Slice, buf: []const u8) []const u8 {
        return buf[self.offset..][0..self.len];
    }
};

const Artifact = @This();

const log = std.log.scoped(.zigmirror);

const Content_Type = @import("http").Content_Type;
const std = @import("std");
