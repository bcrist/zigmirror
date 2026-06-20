upstream_semaphore: std.Io.Semaphore,
downstream_semaphore: std.Io.Semaphore,
overload_semaphore: std.Io.Semaphore,

pub const Upstream = struct {
    io: std.Io,
    semaphore: *std.Io.Semaphore,
};

pub const Downstream = struct {
    io: std.Io,
    semaphore: *std.Io.Semaphore,
    overload_semaphore: *std.Io.Semaphore,
};

const std = @import("std");
