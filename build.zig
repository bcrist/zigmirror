pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(zon.version) catch @panic("Invalid version"));

    const build_options_mod = build_options.createModule();

    const resources = shittip.resources(b, &.{
        .{ .path = "resources" },
    }, .{
        .install = if (optimize == .Debug) "resources" else null,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "Temp_Allocator", .module = b.dependency("Temp_Allocator", .{}).module("Temp_Allocator") },
        .{ .name = "fmt", .module = b.dependency("fmt_helper", .{}).module("fmt") },
        .{ .name = "sx", .module = b.dependency("sx", .{}).module("sx") },
        .{ .name = "tempora", .module = b.dependency("tempora", .{}).module("tempora") },
        .{ .name = "dizzy", .module = b.dependency("dizzy", .{}).module("dizzy") },
        .{ .name = "http", .module = b.dependency("shittip", .{}).module("http") },
        .{ .name = "resources", .module = resources },
        .{ .name = "build_options", .module = build_options_mod },
    };

    const exe = b.addExecutable(.{
        .name = "zigmirror",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .strip = false,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "run zigmirror").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = b.graph.host,
            .imports = imports,
        }),
    });
    b.step("test", "run tests").dependOn(&b.addRunArtifact(tests).step);

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

    const upgrade_bin_path = b.option([]const u8, "upgrade-bin-path", "Path to copy zig-out/bin/zigmirror to when using the `upgrade` step (defaults to `/usr/local/bin/zigmirror`)") orelse "/usr/local/bin/zigmirror";
    const upgrade = b.addSystemCommand(&.{ "install", "-CD", "-m", "0750" });
    if (b.option([]const u8, "upgrade-bin-user", "User/group name to assign to executable from -Dupgrade-bin-path when installing")) |user| {
        upgrade.addArgs(&.{ "-o", user, "-g", user });
    }
    upgrade.addFileArg(exe.getEmittedBin());
    upgrade.addArg(upgrade_bin_path);

    const systemd_stop = b.addSystemCommand(&.{ "systemctl", "stop", "zigmirror" });
    systemd_stop.has_side_effects = true;

    const systemd_start = b.addSystemCommand(&.{ "systemctl", "start", "zigmirror" });
    systemd_start.has_side_effects = true;

    systemd_stop.step.dependOn(&exe.step);
    upgrade.step.dependOn(&systemd_stop.step);
    systemd_start.step.dependOn(&upgrade.step);
    b.step("upgrade", "Copies the new zigmirror executable to the system bin path (-Dupgrade-bin-path) and restarts the zigmirror systemd service").dependOn(&systemd_start.step);
}

const zon = @import("build.zig.zon");
const shittip = @import("shittip");
const std = @import("std");
