start_time: tempora.Date_Time,
artifacts_served: std.atomic.Value(usize),
upstream_artifacts_downloaded: std.atomic.Value(usize),
cache_evictions_mem: std.atomic.Value(usize),
cache_evictions_fs: std.atomic.Value(usize),
expected_upstream_head_time_ms_archive: std.atomic.Value(u32),
expected_upstream_head_time_ms_minisig: std.atomic.Value(u32),

pub fn init(io: std.Io, default_upstream_head_time_ms: u32) Server_Stats {
    return .{
        .start_time = tempora.now(io).dt,
        .artifacts_served = .init(0),
        .upstream_artifacts_downloaded = .init(0),
        .cache_evictions_mem = .init(0),
        .cache_evictions_fs = .init(0),
        .expected_upstream_head_time_ms_archive = .init(default_upstream_head_time_ms),
        .expected_upstream_head_time_ms_minisig = .init(default_upstream_head_time_ms),
    };
}

const Server_Stats = @This();

const tempora = @import("tempora");
const std = @import("std");
