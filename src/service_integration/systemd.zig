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
        log.debug("NOTIFY_SOCKET={f}", .{ std.zig.fmtString(socket_path_final) });
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
    _ = io; // maybe someday std.Io.Threaded will support dgram unix sockets...

    if (msg.len == 0) return;
    const addr = notify_socket_addr orelse return;

    const socket_fd = open_socket() catch |err| {
        log.err("Failed to open NOTIFY_SOCKET: {t}", .{ err });
        return;
    };
    defer std.Io.Threaded.closeFd(socket_fd);

    var storage: std.posix.sockaddr.un = .{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    var path_len = addr.path.len;
    @memcpy(storage.path[0..path_len], addr.path);
    if (storage.path.len > path_len) {
        @branchHint(.likely);
        storage.path[path_len] = 0;
        path_len += 1;
    }

    const addr_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path_len);

    connect(socket_fd, @ptrCast(&storage), addr_len) catch |err| {
        log.err("Failed to connect to NOTIFY_SOCKET: {t}", .{ err });
        return;
    };

    const bytes_written = write(socket_fd, msg) catch |err| {
        log.err("Failed to write to NOTIFY_SOCKET: {t}", .{ err });
        return;
    };
    if (bytes_written != msg.len) {
        log.err("Full message could not be written to NOTIFY_SOCKET", .{});
        return;
    }
}

fn open_socket() !std.posix.socket_t {
    while (true) {
        const rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn connect(fd: std.posix.socket_t, addr: *const std.posix.sockaddr, addr_len: std.posix.socklen_t) !void {
    while (true) {
        switch (std.posix.errno(std.posix.system.connect(fd, addr, addr_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN => return error.WouldBlock,
            .INPROGRESS => return error.WouldBlock,
            .ACCES => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            .PERM => return error.PermissionDenied,
            .BADF => |err| return std.Io.Threaded.errnoBug(err), // File descriptor used after closed.
            .CONNABORTED => |err| return std.Io.Threaded.errnoBug(err),
            .FAULT => |err| return std.Io.Threaded.errnoBug(err),
            .ISCONN => |err| return std.Io.Threaded.errnoBug(err),
            .NOTSOCK => |err| return std.Io.Threaded.errnoBug(err),
            .PROTOTYPE => |err| return std.Io.Threaded.errnoBug(err),
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn write(fd: std.posix.socket_t, data: []const u8) !usize {
    while (true) {
        const rc = std.posix.system.write(fd, data.ptr, data.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => |err| return std.Io.Threaded.errnoBug(err),
            .FAULT => |err| return std.Io.Threaded.errnoBug(err),
            .AGAIN => return error.WouldBlock,
            .BADF => |err| return std.Io.Threaded.errnoBug(err),
            .DESTADDRREQ => |err| return std.Io.Threaded.errnoBug(err),
            .IO => return error.InputOutput,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => |err| return std.Io.Threaded.errnoBug(err),
            .BUSY => return error.DeviceBusy,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

const log = std.log.scoped(.zigmirror);

const http = @import("http");
const std = @import("std");
