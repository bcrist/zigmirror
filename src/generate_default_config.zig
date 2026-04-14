pub fn main(init: std.process.Init) !void {
    try save_config(.{}, init.gpa, init.io, init.minimal.args);
}

fn save_config(config: Config, gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) !void {
    var args_iter = try args.iterateAllocator(gpa);
    defer args_iter.deinit();

    _ = args_iter.next(); // exe name
    const config_path = args_iter.next() orelse "zigmirror.sx";

    const config_file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
    defer config_file.close(io);

    var buf: [8192]u8 = undefined;
    var file_writer = config_file.writer(io, &buf);
    try config.save(&file_writer.interface, gpa);
    try file_writer.flush();
}

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .sx, .level = .warn },
    },
};

const Config = @import("Config.zig");
const std = @import("std");
