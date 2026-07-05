io: std.Io,
upstream_semaphore: std.Io.Semaphore,
downstream_semaphore: std.Io.Semaphore,
overload_semaphore: std.Io.Semaphore,
prewarm_semaphore: std.Io.Semaphore,

pub const Prewarm = struct {
    io: std.Io,
    semaphore: *std.Io.Semaphore,

    pub fn init(dl: *Download_Permission, config: *const Config) !Prewarm {
        return .init_timeout(dl, .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(config.prewarm.max_wait_time_seconds),
        }});
    }

    pub fn init_timeout(dl: *Download_Permission, timeout: std.Io.Timeout) !Prewarm {
        dl.prewarm_semaphore.waitTimeout(dl.io, timeout) catch |err| switch (err) {
            error.Timeout => return error.InsufficientResources,
            else => |e| return e,
        };
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Prewarm download permission acquired ({} available)", .{
                @atomicLoad(usize, &dl.prewarm_semaphore.permits, .seq_cst),
            });
        }
        return .{
            .io = dl.io,
            .semaphore = &dl.prewarm_semaphore,
        };
    }

    pub fn deinit(self: Prewarm) void {
        self.semaphore.post(self.io);
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Prewarm download permission returned ({} available)", .{
                @atomicLoad(usize, &self.semaphore.permits, .seq_cst),
            });
        }
    }
};

pub const Upstream = struct {
    io: std.Io,
    semaphore: *std.Io.Semaphore,

    pub fn init(dl: *Download_Permission, config: *const Config) !Upstream {
        return .init_timeout(dl, .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(config.upstream.max_wait_time_seconds),
        }});
    }

    pub fn init_timeout(dl: *Download_Permission, timeout: std.Io.Timeout) !Upstream {
        dl.upstream_semaphore.waitTimeout(dl.io, timeout) catch |err| switch (err) {
            error.Timeout => return error.InsufficientResources,
            else => |e| return e,
        };
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Upstream download permission acquired ({} available)", .{
                @atomicLoad(usize, &dl.upstream_semaphore.permits, .seq_cst),
            });
        }
        return .{
            .io = dl.io,
            .semaphore = &dl.upstream_semaphore,
        };
    }

    pub fn deinit(self: Upstream) void {
        self.semaphore.post(self.io);
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Upstream download permission returned ({} available)", .{
                @atomicLoad(usize, &self.semaphore.permits, .seq_cst),
            });
        }
    }
};

pub const Downstream = struct {
    io: std.Io,
    semaphore: *std.Io.Semaphore,
    overload_semaphore: *std.Io.Semaphore,

    pub fn init(dl: *Download_Permission, config: *const Config) !Downstream {
        return .init_timeout(dl, .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(config.max_wait_time_seconds),
        }});
    }

    pub fn init_timeout(dl: *Download_Permission, timeout: std.Io.Timeout) !Downstream {
        dl.overload_semaphore.waitTimeout(dl.io, .{ .duration = .{
            .clock = .awake,
            .raw = .zero,
        }}) catch |err| switch (err) {
            error.Timeout => return error.InsufficientResources,
            else => |e| return e,
        };
        errdefer dl.overload_semaphore.post(dl.io);

        dl.downstream_semaphore.waitTimeout(dl.io, timeout) catch |err| switch (err) {
            error.Timeout => return error.InsufficientResources,
            else => |e| return e,
        };
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Downstream download permission acquired ({} available, {} connections until overload)", .{
                @atomicLoad(usize, &dl.downstream_semaphore.permits, .seq_cst),
                @atomicLoad(usize, &dl.overload_semaphore.permits, .seq_cst),
            });
        }
        return .{
            .io = dl.io,
            .semaphore = &dl.downstream_semaphore,
            .overload_semaphore = &dl.overload_semaphore,
        };
    }

    pub fn deinit(self: Downstream) void {
        self.semaphore.post(self.io);
        self.overload_semaphore.post(self.io);
        if (comptime std.log.logEnabled(.debug, .locking)) {
            locking_log.debug("Downstream download permission returned ({} available, {} connections until overload)", .{
                @atomicLoad(usize, &self.semaphore.permits, .seq_cst),
                @atomicLoad(usize, &self.overload_semaphore.permits, .seq_cst),
            });
        }
    }
};

const locking_log = std.log.scoped(.locking);

const Download_Permission = @This();

const Config = @import("Config.zig");
const std = @import("std");
