artifact_type: Type,
extension: Extension,
major: u16,
minor: u16,
patch: u16,
pre: ?Buffer_Slice,
build: ?Buffer_Slice,
buf: [buffer_len]u8,

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

pub fn to_minisig_artifact(self: *const Artifact) Artifact {
    return .{
        .artifact_type = self.artifact_type,
        .extension = self.extension.to_minisig(),
        .major = self.major,
        .minor = self.minor,
        .patch = self.patch,
        .pre = self.pre,
        .build = self.build,
        .buf = self.buf,
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

/// Equivalent to lhs.version().order(rhs.version())
pub fn version_order(lhs: *const Artifact, rhs: Artifact) std.math.Order {
    if (lhs.major < rhs.major) return .lt;
    if (lhs.major > rhs.major) return .gt;
    if (lhs.minor < rhs.minor) return .lt;
    if (lhs.minor > rhs.minor) return .gt;
    if (lhs.patch < rhs.patch) return .lt;
    if (lhs.patch > rhs.patch) return .gt;
    if (lhs.pre != null and rhs.pre == null) return .lt;
    if (lhs.pre == null and rhs.pre == null) return .eq;
    if (lhs.pre == null and rhs.pre != null) return .gt;

    // Iterate over pre-release identifiers until a difference is found.
    var lhs_pre_it = std.mem.splitScalar(u8, lhs.pre.?.slice(&lhs.buf), '.');
    var rhs_pre_it = std.mem.splitScalar(u8, rhs.pre.?.slice(&rhs.buf), '.');
    while (true) {
        const next_lid = lhs_pre_it.next();
        const next_rid = rhs_pre_it.next();

        // A larger set of pre-release fields has a higher precedence than a smaller set.
        if (next_lid == null and next_rid != null) return .lt;
        if (next_lid == null and next_rid == null) return .eq;
        if (next_lid != null and next_rid == null) return .gt;

        const lid = next_lid.?; // Left identifier
        const rid = next_rid.?; // Right identifier

        // Attempt to parse identifiers as numbers. Overflows are checked by parse.
        const lnum: ?usize = std.fmt.parseUnsigned(usize, lid, 10) catch |err| switch (err) {
            error.InvalidCharacter => null,
            error.Overflow => unreachable,
        };
        const rnum: ?usize = std.fmt.parseUnsigned(usize, rid, 10) catch |err| switch (err) {
            error.InvalidCharacter => null,
            error.Overflow => unreachable,
        };

        // Numeric identifiers always have lower precedence than non-numeric identifiers.
        if (lnum != null and rnum == null) return .lt;
        if (lnum == null and rnum != null) return .gt;

        // Identifiers consisting of only digits are compared numerically.
        // Identifiers with letters or hyphens are compared lexically in ASCII sort order.
        if (lnum != null and rnum != null) {
            if (lnum.? < rnum.?) return .lt;
            if (lnum.? > rnum.?) return .gt;
        } else {
            const ord = std.mem.order(u8, lid, rid);
            if (ord != .eq) return ord;
        }
    }
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

    pub fn is_minisig(self: Extension) bool {
        return switch (self) {
            .txz, .zip => false,
            .txz_minisig, .zip_minisig => true,
        };
    }

    pub fn to_minisig(self: Extension) Extension {
        return switch (self) {
            .txz => .txz_minisig,
            .zip => .zip_minisig,
            .txz_minisig, .zip_minisig => self,
        };
    }

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

    pub fn content_type(self: Extension) Content_Type {
        return switch (self) {
            .txz => .xz,
            .zip => .zip,
            .txz_minisig => .text_utf8,
            .zip_minisig => .text_utf8,
        };
    }
};

const Buffer_Slice = struct {
    offset: Buffer_Offset,
    len: Buffer_Length,

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
        const begin = @min(buffer_len - 1, self.offset);
        const end = @min(buffer_len, self.offset + self.len);
        return buf[begin..end];
    }
};

const buffer_len = 64;
const Buffer_Length = std.math.IntFittingRange(0, buffer_len);
const Buffer_Offset = std.math.IntFittingRange(0, buffer_len - 1);

const source_prefix = "zig-";
const build_prefix = "zig-";
const bootstrap_prefix = "zig-bootstrap-";
const devkit_prefix = "zig+llvm+lld+clang-";

const Artifact = @This();

const log = std.log.scoped(.zigmirror);

const Content_Type = @import("http").Content_Type;
const std = @import("std");
