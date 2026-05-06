artifact_type: Type,
extension: Extension,
major: u16,
minor: u16,
patch: u16,
pre: ?Buffer_Slice,
build: ?Buffer_Slice,
buf: [64]u8,

pub fn maybe_parse(filename: []const u8) ?Artifact {
    return parse(filename) catch null;
}

pub fn parse(filename: []const u8) !Artifact {
    if (!std.mem.startsWith(u8, filename, "zig")) return error.InvalidArtifactFilename;
    if (std.mem.findAny(u8, filename, "/\\")) |_| return error.InvalidArtifactFilename;

    const is_minisig = std.mem.endsWith(u8, filename, ".minisig");
    const filename_no_minisig = if (is_minisig) filename[0 .. filename.len - ".minisig".len] else filename;
    var extension: Extension = undefined;
    if (std.mem.endsWith(u8, filename_no_minisig, ".tar.xz")) {
        extension = if (is_minisig) .txz_minisig else .txz;
    } else if (std.mem.endsWith(u8, filename_no_minisig, ".zip")) {
        extension = if (is_minisig) .zip_minisig else .zip;
    } else return error.InvalidArtifactFilename;

    const filename_no_ext = filename[0 .. filename.len - extension.slice().len];

    var last_dash = std.mem.findScalarLast(u8, filename_no_ext, '-') orelse return error.InvalidArtifactFilename;
    var version_str = filename_no_ext[last_dash + 1 ..];

    if (std.mem.startsWith(u8, version_str, "dev.")) {
        last_dash = std.mem.findScalarLast(u8, filename_no_ext[0..last_dash], '-') orelse return error.InvalidArtifactFilename;
        version_str = filename_no_ext[last_dash + 1 ..];
    }

    const sv = std.SemanticVersion.parse(version_str) catch return error.InvalidArtifactFilename;

    var buf: [64]u8 = @splat(0);
    var w = std.Io.Writer.fixed(&buf);

    const pre: ?Buffer_Slice = if (sv.pre) |str| s: {
        const begin = w.end;
        w.writeAll(str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return error.InvalidArtifactFilename;
        };
        break :s .init_begin_end(begin, w.end);
    } else null;

    const build: ?Buffer_Slice = if (sv.build) |str| s: {
        const begin = w.end;
        w.writeAll(str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return error.InvalidArtifactFilename;
        };
        break :s .init_begin_end(begin, w.end);
    } else null;

    var artifact_type: Type = .source;

    // errdefer std.log.err("last_dash = {}", .{ last_dash });

    if (last_dash > devkit_prefix.len and std.mem.startsWith(u8, filename, devkit_prefix)) {
        const arch_os_str = filename[devkit_prefix.len .. last_dash];
        const begin = w.end;
        w.writeAll(arch_os_str) catch {
            log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
            return error.InvalidArtifactFilename;
        };
        artifact_type = .{ .devkit = .init_begin_end(begin, w.end) };
    } else if (last_dash > build_prefix.len and std.mem.startsWith(u8, filename, build_prefix)) {
        const arch_os_str = filename[build_prefix.len .. last_dash];
        if (std.mem.eql(u8, arch_os_str, "bootstrap")) {
            artifact_type = .bootstrap;
        } else {
            const begin = w.end;
            w.writeAll(arch_os_str) catch {
                log.err("Filename too long: \"{f}\"", .{ std.zig.fmtString(filename) });
                return error.InvalidArtifactFilename;
            };
            artifact_type = .{ .build = .init_begin_end(begin, w.end) };
        }
    } else if (last_dash > source_prefix.len) {
        return error.InvalidArtifactFilename;
    }

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
        .source => try writer.writeAll(source_prefix),
        .bootstrap => try writer.writeAll(bootstrap_prefix),
        .build => |s| try writer.print(build_prefix ++ "{s}-", .{ s.slice(&self.buf) }),
        .devkit => |s| try writer.print(devkit_prefix ++ "{s}-", .{ s.slice(&self.buf) }),
    }
    try writer.print("{f}{f}", .{ self.version(), self.extension });
}

test "parse/format round trip" {
    try test_parse_format("zig-0.15.2.tar.xz");
    try test_parse_format("zig-0.15.2.tar.xz.minisig");
    try test_parse_format("zig-0.16.0-dev.3153+d6f43caad.tar.xz");
    try test_parse_format("zig-aarch64-freebsd-0.16.0-dev.3144+ac6fb0b59.tar.xz");
    try test_parse_format("zig-aarch64-linux-0.16.0-dev.3144+ac6fb0b59.tar.xz");
    try test_parse_format("zig-arm-linux-0.16.0-dev.3144+ac6fb0b59.tar.xz");
    try test_parse_format("zig-arm-netbsd-0.16.0-dev.3144+ac6fb0b59.tar.xz");
    try test_parse_format("zig-arm-netbsd-0.16.0-dev.3144+ac6fb0b59.tar.xz.minisig");
    try test_parse_format("zig-bootstrap-0.15.2.tar.xz.minisig");
    try test_parse_format("zig-bootstrap-0.16.0-dev.3153+d6f43caad.tar.xz.minisig");
    try test_parse_format("zig-win64-0.2.0.zip");
    try test_parse_format("zig-x86_64-linux-0.15.2.tar.xz");
    try test_parse_format("zig-x86_64-linux-0.15.2.tar.xz.minisig");
    try test_parse_format("zig-x86_64-windows-0.16.0-dev.3153+d6f43caad.zip");
    try test_parse_format("zig-x86_64-windows-0.16.0-dev.3153+d6f43caad.zip.minisig");
    try test_parse_format("zig-0.16.0.tar.xz");
    try test_parse_format("zig-bootstrap-0.1.0-dev.asdfasdf.tar.xz");
    try test_parse_format("zig-0.16.0.zip.minisig");
    try test_parse_format("zig-x86_64-linux-0.14.1.tar.xz");
    try test_parse_format("zig-asdf-0.17.0-dev.203+073889523.tar.xz");
    try test_parse_format("zig-asdf-asdf-0.17.0-dev.203+073889523.tar.xz");
    try test_parse_format("zig-asdf-asdf-asdt-0.17.0-dev.203+073889523.tar.xz");
    try test_parse_format("zig+llvm+lld+clang-$TARGET-0.17.0-dev.203+073889523.zip");
    try std.testing.expectError(error.InvalidArtifactFilename, test_parse_format(""));
    try std.testing.expectError(error.InvalidArtifactFilename, test_parse_format("zig+llvm+lld+clang-/-0.17.0-dev.203+073889523.tar.xz"));
}

fn test_parse_format(input: []const u8) !void {
    const artifact = try parse(input);
    const output = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{ artifact });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(input, output);
}


pub fn upstream_path(self: *const Artifact, allocator: std.mem.Allocator) ![]const u8 {
    if (self.artifact_type == .devkit) {
        return try std.fmt.allocPrint(allocator, "/deps/{f}", .{
            self.*,
        });
    } else if (self.pre == null) {
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
    if (self.artifact_type == .devkit) {
        return try std.fmt.allocPrint(allocator, "https://ziglang.org/deps/{f}", .{
            self.*,
        });
    } else if (self.pre == null) {
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
    devkit: Buffer_Slice,

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

const source_prefix = "zig-";
const build_prefix = "zig-";
const bootstrap_prefix = "zig-bootstrap-";
const devkit_prefix = "zig+llvm+lld+clang-";

const Artifact = @This();

const log = std.log.scoped(.zigmirror);

const Content_Type = @import("http").Content_Type;
const std = @import("std");
