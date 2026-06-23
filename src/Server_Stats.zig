gpa: std.mem.Allocator,
start_time: tempora.Date_Time,
artifacts_served: std.atomic.Value(usize),
upstream_artifacts_downloaded: std.atomic.Value(usize),
cache_evictions_mem: std.atomic.Value(usize),
cache_evictions_fs: std.atomic.Value(usize),
expected_upstream_head_time_ms_archive: std.atomic.Value(u32),
expected_upstream_head_time_ms_minisig: std.atomic.Value(u32),
upstream_transfer_speeds: []u32,
downstream_transfer_speeds: []u32,

const unused_transfer_speed_slot: u32 = @bitCast(@as(f32, -1));

pub fn init(io: std.Io, gpa: std.mem.Allocator, config: *const Config) !Server_Stats {
    const upstream_transfer_speeds = try gpa.alloc(u32, config.upstream.max_connections);
    errdefer gpa.free(upstream_transfer_speeds);
    @memset(upstream_transfer_speeds, unused_transfer_speed_slot);

    const downstream_transfer_speeds = try gpa.alloc(u32, config.max_concurrent_downloads);
    errdefer gpa.free(downstream_transfer_speeds);
    @memset(downstream_transfer_speeds, unused_transfer_speed_slot);

    const default_upstream_head_time_ms = config.upstream.default_connect_timeout_seconds * std.time.ms_per_s / 2;
    return .{
        .gpa = gpa,
        .start_time = tempora.now_utc(io).dt,
        .artifacts_served = .init(0),
        .upstream_artifacts_downloaded = .init(0),
        .cache_evictions_mem = .init(0),
        .cache_evictions_fs = .init(0),
        .expected_upstream_head_time_ms_archive = .init(default_upstream_head_time_ms),
        .expected_upstream_head_time_ms_minisig = .init(default_upstream_head_time_ms),
        .upstream_transfer_speeds = upstream_transfer_speeds,
        .downstream_transfer_speeds = downstream_transfer_speeds,
    };
}

pub fn deinit(self: *Server_Stats) void {
    self.gpa.free(self.upstream_transfer_speeds);
    self.gpa.free(self.downstream_transfer_speeds);
}

pub fn claim_upstream_transfer_speed(self: *Server_Stats) ?*f32 {
    for (self.upstream_transfer_speeds) |*slot| {
        if (@cmpxchgStrong(u32, slot, unused_transfer_speed_slot, 0, .monotonic, .monotonic)) |_| continue;
        return @ptrCast(slot);
    }
    return null;
}

pub fn claim_downstream_transfer_speed(self: *Server_Stats) ?*f32 {
    for (self.downstream_transfer_speeds) |*slot| {
        if (@cmpxchgStrong(u32, slot, unused_transfer_speed_slot, 0, .monotonic, .monotonic)) |_| continue;
        return @ptrCast(slot);
    }
    return null;
}

pub fn update_transfer_speed(self: *Server_Stats, transfer_speed_ptr: ?*f32, bytes_per_second: f32) void {
    _ = self;
    if (transfer_speed_ptr) |ptr| @atomicStore(u32, @as(*u32, @ptrCast(ptr)), @bitCast(bytes_per_second), .monotonic);
}

pub fn release_transfer_speed(self: *Server_Stats, transfer_speed_ptr: ?*f32) void {
    _ = self;
    if (transfer_speed_ptr) |ptr| @atomicStore(u32, @as(*u32, @ptrCast(ptr)), unused_transfer_speed_slot, .monotonic);
}

pub const Transfer_Stats = struct {
    bps: f32,
    count: u32,
};

pub const Combined_Transfer_Stats = struct {
    upstream: Transfer_Stats,
    downstream: Transfer_Stats,
};
pub fn transfer_stats(self: *Server_Stats) Combined_Transfer_Stats {
    var upstream_count: u32 = 0;
    var downstream_count: u32 = 0;
    var upstream: f32 = 0;
    var downstream: f32 = 0;

    for (self.upstream_transfer_speeds) |*slot| {
        const bps: f32 = @bitCast(@atomicLoad(u32, slot, .monotonic));
        if (bps >= 0) {
            upstream += bps;
            upstream_count += 1;
        }
    }
    for (self.downstream_transfer_speeds) |*slot| {
        const bps: f32 = @bitCast(@atomicLoad(u32, slot, .monotonic));
        if (bps >= 0) {
            downstream += bps;
            downstream_count += 1;
        }
    }

    return .{
        .upstream = .{
            .bps = upstream,
            .count = upstream_count,
        },
        .downstream = .{
            .bps = downstream,
            .count = downstream_count,
        },
    };
}

const Server_Stats = @This();

const Config = @import("Config.zig");
const tempora = @import("tempora");
const std = @import("std");
