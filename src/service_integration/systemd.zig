var socket_path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var notify_socket_addr: ?std.Io.net.UnixAddress = null;

pub fn init(io: std.Io, env: *const std.process.Environ.Map) void {
    _ = io;
    notify_socket_addr = null;
    if (env.get("NOTIFY_SOCKET")) |socket_path| {
        const socket_path_final = if (std.mem.startsWith(u8, socket_path, "@")) p: {
            break :p std.fmt.bufPrint(&socket_path_buf, "\x00{s}", .{ socket_path[1..] }) catch {
                log.err("NOTIFY_SOCKET path too long!", .{});
                return;
            };
        } else if (std.mem.startsWith(u8, socket_path, "/")) p: {
            break :p std.fmt.bufPrint(&socket_path_buf, "{s}", .{ socket_path }) catch {
                log.err("NOTIFY_SOCKET path too long!", .{});
                return;
            };
        } else {
            log.err("Invalid NOTIFY_SOCKET path: {s}", .{ socket_path });
            return;
        };
        notify_socket_addr = std.Io.net.UnixAddress.init(socket_path_final) catch {
            log.err("NOTIFY_SOCKET path too long!", .{});
            return;
        };
    }
}

pub fn ready(loop: *http.Loop) void {
    log.debug("zigmirror service is ready!", .{});
    notify(loop.io, "READY=1");
}

pub fn stopping(loop: *http.Loop) void {
    log.debug("zigmirror service is stopping!", .{});
    notify(loop.io, "STOPPING=1");
}

fn notify(io: std.Io, msg: []const u8) void {
    if (msg.len == 0) return;
    const addr = notify_socket_addr orelse return;
    var con = addr.connect(io) catch |err| {
        log.err("Failed to connect to NOTIFY_SOCKET: {t}", .{ err });
        return;
    };
    defer con.close(io);

    var writer = con.writer(io, &.{});
    writer.interface.writeAll(msg) catch {
        log.err("Failed to write to NOTIFY_SOCKET: {t}", .{ writer.err orelse error.WriteFailed });
        return;
    };
}

const log = std.log.scoped(.zigmirror);

const http = @import("http");
const std = @import("std");
