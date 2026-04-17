pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    const resources = shittip.resources(b, &.{
        .{ .path = "resources" },
    }, .{
        .install = if (optimize == .Debug) "resources" else null,
    });

    const exe = b.addExecutable(.{
        .name = "zigmirror",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .strip = false,
            .imports = &.{
                .{ .name = "Temp_Allocator", .module = b.dependency("Temp_Allocator", .{}).module("Temp_Allocator") },
                .{ .name = "fmt", .module = b.dependency("fmt_helper", .{}).module("fmt") },
                .{ .name = "sx", .module = b.dependency("sx", .{}).module("sx") },
                .{ .name = "tempora", .module = b.dependency("tempora", .{}).module("tempora") },
                .{ .name = "dizzy", .module = b.dependency("dizzy", .{}).module("dizzy") },
                .{ .name = "http", .module = b.dependency("shittip", .{}).module("http") },
                .{ .name = "resources", .module = resources },
                .{ .name = "zon", .module = zon },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run zigmirror").dependOn(&run.step);

    if (b.option(bool, "generate-config", "Generate a default configuration file at zig-out/etc/default.zigmirror.sx") orelse true) {
        const generate_default_config_exe = b.addExecutable(.{
            .name = "generate_default_config",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/generate_default_config.zig"),
                .optimize = .Debug,
                .target = b.graph.host,
                .imports = &.{
                    .{ .name = "fmt", .module = b.dependency("fmt_helper", .{}).module("fmt") },
                    .{ .name = "sx", .module = b.dependency("sx", .{}).module("sx") },
                },
            }),
        });
        const generate_default_config = b.addRunArtifact(generate_default_config_exe);
        const default_config = generate_default_config.addOutputFileArg("zigmirror.sx");
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(default_config, .{ .custom = "etc" }, "default.zigmirror.sx").step);
    }
}

const shittip = @import("shittip");
const std = @import("std");
