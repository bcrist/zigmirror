io: std.Io,
gpa: std.mem.Allocator,
clients: std.AutoArrayHashMapUnmanaged(std.Io.net.IpAddress, State),
config: ?Config,
mutex: std.Io.Mutex,

pub fn init(io: std.Io, gpa: std.mem.Allocator, config: ?Config) Rate_Limiter {
    var sanitized_config = config;
    if (config) |c| {
        if (c.bucket_size == 0 or c.refill_per_minute == 0 or c.max_x_forwarded_for_ips == 0) sanitized_config = null;
    }
    return .{
        .io = io,
        .gpa = gpa,
        .clients = .empty,
        .config = sanitized_config,
        .mutex = .init,
    };
}

pub fn deinit(self: *Rate_Limiter) void {
    self.clients.deinit(self.gpa);
}

pub fn get(self: *Rate_Limiter, request: *http.Request) !void {
    if (self.config) |config| {
        if (request.get_header("x-forwarded-for")) |header| {
            const now = request.received_dt.with_offset(0).timestamp_ms();

            var iter = std.mem.tokenizeAny(u8, header.value, ", ");
            var n: usize = 0;
            while (iter.next()) |ip_str| {
                n += 1;
                if (n > config.max_x_forwarded_for_ips) {
                    log.warn("{f}: Too many IPs in X-Forwarded-For", .{
                        request.cid,
                    });
                    return error.BadRequest;
                }

                const ip = std.Io.net.IpAddress.parse(ip_str, 0) catch {
                    log.warn("{f}: Invalid IP found in X-Forwarded-For: \"{f}\"", .{
                        request.cid,
                        std.zig.fmtString(ip_str),
                    });
                    return error.BadRequest;
                };
                
                try self.check(ip, now);
            }
        } else if (!config.accept_without_x_forwarded_for) {
            log.warn("{f}: X-Forwarded-For header not found", .{
                request.cid,
            });
            return error.BadRequest;
        }
    }
}

pub fn check(self: *Rate_Limiter, ip: std.Io.net.IpAddress, now: i64) !void {
    if (self.config) |config| {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const gop = try self.clients.getOrPut(self.gpa, ip);
        if (gop.found_existing) {
            const requests_remaining = gop.value_ptr.update(now, config);
            if (requests_remaining == 0) return error.TooManyRequests;
            gop.value_ptr.requests_remaining = requests_remaining - 1;
        } else {
            gop.key_ptr.* = ip;
            gop.value_ptr.* = .{
                .last_generation_time = now,
                .requests_remaining = config.bucket_size - 1,
            };
        }
    }
}

pub fn cleanup(self: *Rate_Limiter, now: i64) error{Canceled}!void {
    if (self.config) |config| {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var iter = self.clients.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.update(now, config) == config.bucket_size) {
                if (self.clients.swapRemove(kv.key_ptr.*)) {
                    iter.len -= 1;
                    iter.index -= 1;
                }
            }
        }
    }
}

const State = struct {
    last_generation_time: i64,
    requests_remaining: u64,

    pub fn update(self: *State, now: i64, config: Config) u64 {
        if (self.last_generation_time > now) return self.requests_remaining;
        const ms_til_now: u64 = @intCast(now - self.last_generation_time);
        const requests_to_refill = config.refill_per_minute * ms_til_now / std.time.ms_per_min;
        const new_requests_remaining = @min(self.requests_remaining + requests_to_refill, config.bucket_size);
        self.requests_remaining = new_requests_remaining;
        self.last_generation_time = if (new_requests_remaining == config.bucket_size) now else t: {
            const dt: i64 = @intCast(@divTrunc(requests_to_refill * std.time.ms_per_min, config.refill_per_minute));
            break :t self.last_generation_time + dt;
        };
        return new_requests_remaining;
    }
};

pub const Config = struct {
    bucket_size: u64 = 10,
    refill_per_minute: u32 = 2,
    accept_without_x_forwarded_for: bool = false,
    max_x_forwarded_for_ips: usize = 10,
    cleanup_interval_seconds: u32 = 60,
};

const Rate_Limiter = @This();

const log = std.log.scoped(.zigmirror);

const http = @import("http");
const std = @import("std");
