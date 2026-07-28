io: std.Io,
gpa: std.mem.Allocator,
entries: []Entry,
lookup: std.AutoHashMapUnmanaged(Artifact, usize),
lookup_lock: std.Io.RwLock,
last_removed_index: std.atomic.Value(usize),
total_bytes: std.atomic.Value(usize),

pub fn init(io: std.Io, gpa: std.mem.Allocator, max_entries: usize) !Cache {
    const entries = try gpa.alloc(Entry, max_entries);
    errdefer gpa.free(entries);

    @memset(entries, .init);

    return .{
        .io = io,
        .gpa = gpa,
        .entries = entries,
        .lookup = .empty,
        .lookup_lock = .init,
        .last_removed_index = .init(0),
        .total_bytes = .init(0),
    };
}

pub fn deinit(self: *Cache) void {
    self.lookup.deinit(self.gpa);

    for (self.entries) |entry| {
        switch (entry.data) {
            .none => {},
            .transfer => {},
            .owned => |data| {
                self.gpa.free(data);
            },
        }
    }

    self.gpa.free(self.entries);
}

pub fn active_entries(self: *Cache) error{Canceled}!usize {
    try self.lookup_lock.lockShared(self.io);
    defer self.lookup_lock.unlockShared(self.io);
    return self.lookup.size;
}

fn get_index(self: *Cache, artifact: Artifact) error{Canceled}!?usize {
    try self.lookup_lock.lockShared(self.io);
    defer self.lookup_lock.unlockShared(self.io);
    return self.lookup.get(artifact);
}

// Call Entry.Ref.unlock when finished
pub fn get(self: *Cache, artifact: Artifact, mode: Entry.Ref.Locking_Mode) error{Canceled}!?Entry.Ref {
    for (0..10) |_| {
        const index = try self.get_index(artifact) orelse return null;
        const ref: Entry.Ref = .init(self.io, &self.entries[index], mode);
        try ref.lock();
        if (ref.ptr.artifact) |found_artifact| {
            if (std.meta.eql(found_artifact, artifact)) return ref;
        }
        ref.unlock();
    } else {
        log.debug("Failed to find/lock artifact {f} after 10 attempts!", .{ artifact });
        return null;
    }
}

// Call Entry.Ref.unlock when finished
pub fn get_or_add(self: *Cache, artifact: Artifact) error{Canceled}!?Entry.Ref {
    for (0..10) |_| {
        if (try self.get(artifact, .exclusive)) |ref| return ref;

        const locked_index = self.find_free_index() orelse self.find_free_index() orelse {
            log.debug("Failed to find/lock free slot for artifact {f} after 2 attempts!", .{ artifact });
            return null;
        };

        try self.lookup_lock.lock(self.io);
        defer self.lookup_lock.unlock(self.io);

        const gop = self.lookup.getOrPut(self.gpa, artifact) catch |err| switch (err) {
            error.OutOfMemory => {
                log.debug("Failed to find/add/lock artifact {f}: {t}", .{ artifact, err });
                return null;
            },
        };
        if (gop.found_existing) {
            self.entries[locked_index].unlock_exclusive(self.io);
            continue;
        } else {
            gop.key_ptr.* = artifact;
            gop.value_ptr.* = locked_index;
            self.entries[locked_index].artifact = artifact;
            self.entries[locked_index].bytes = null;
            self.entries[locked_index].hash = null;
            self.entries[locked_index].data = .none;
            self.entries[locked_index].requests = .init;
            return .init(self.io, &self.entries[locked_index], .exclusive);
        }
    } else {
        log.debug("Failed to find/add/lock artifact {f} after 10 attempts!", .{ artifact });
        return null;
    }
}
fn find_free_index(self: *Cache) ?usize {
    const first = self.last_removed_index.load(.monotonic);
    var next = first;
    defer self.last_removed_index.store(next, .monotonic);

    while (true) {
        const index = next;
        next = (next + 1) % self.entries.len;

        const entry = &self.entries[index];
        if (entry.try_lock_exclusive(self.io)) {
            if (entry.artifact == null) return index;
            entry.unlock_exclusive(self.io);
        }
        if (next == first) return null;
    }
}

pub fn report_added_bytes(self: *Cache, bytes: u32) void {
    _ = self.total_bytes.fetchAdd(bytes, .monotonic);
}

// If a non-null entry ref is returned, caller is responsible for:
//      * calling Cache.reset_entry(ref.ptr)
//      * calling ref.unlock()
pub fn remove(self: *Cache, artifact: Artifact) error{Canceled}!?Entry.Ref {
    const index = self.remove_lookup(artifact) orelse return null;

    const entry = &self.entries[index];
    try entry.lock_exclusive(self.io);
    errdefer entry.unlock_exclusive(self.io);

    if (entry.artifact) |found_artifact| {
        if (std.meta.eql(found_artifact, artifact)) {
            self.last_removed_index.store(index, .monotonic);
            return .init(self.io, entry, .exclusive);
        } else {
            log.err("Attempting to remove artifact {f} from cache slot {}, but that slot unexpectedly contains {f}", .{ artifact, index, found_artifact, });
        }
    } else {
        log.err("Attempting to remove artifact {f} from cache slot {}, but that slot has already been reset.  This should not be possible.", .{ artifact, index });
    }

    entry.unlock_exclusive(self.io);
    return null;
}

pub fn remove_lookup(self: *Cache, artifact: Artifact) ?usize {
    self.lookup_lock.lockUncancelable(self.io);
    defer self.lookup_lock.unlock(self.io);
    return if (self.lookup.fetchRemove(artifact)) |kv| kv.value else null;
}

pub fn reset_entry(self: *Cache, entry: *Entry) void {
    switch (entry.data) {
        .none => {},
        .transfer => unreachable,
        .owned => |data| {
            self.gpa.free(data);
            entry.data = .none;
        },
    }

    if (entry.bytes) |bytes| {
        _ = self.total_bytes.fetchSub(bytes, .monotonic);
        entry.bytes = null;
    }

    entry.hash = null;
    entry.artifact = null;
    entry.requests = .init;
}

// Call Entry.Ref.unlock when finished
pub fn get_worst(self: *Cache) error{Canceled}!?Entry.Ref {
    const now = tempora.now_utc(self.io).timestamp_ms();

    var maybe_worst_index: ?usize = null;
    var worst_entry: Entry = undefined;
    for (0.., self.entries) |index, *entry| {
        _ = entry.try_lock_shared(self.io) or continue;
        defer entry.unlock_shared(self.io);

        if (entry.artifact == null) continue;
        if (entry.data == .transfer) continue;

        if (maybe_worst_index) |_| {
            if (entry.order(&worst_entry, now) == .gt) {
                maybe_worst_index = index;
                worst_entry = entry.clone();
            }
        } else {
            maybe_worst_index = index;
            worst_entry = entry.clone();
        }
    }
    if (maybe_worst_index) |index| {
        const ref: Entry.Ref = .init(self.io, &self.entries[index], .exclusive);
        try ref.lock();
        return ref;
    }
    return null;
}

pub const Entry = struct {
    rl: std.Io.RwLock,
    artifact: ?Artifact,
    bytes: ?u32,
    hash: ?[std.crypto.hash.sha2.Sha256.digest_length]u8,
    data: union (enum) {
        none,
        transfer: *Upstream_Transfer,
        owned: []const u8,
    },
    requests: struct {
        first_time: std.atomic.Value(i64),
        last_time: std.atomic.Value(i64),
        count: std.atomic.Value(u32),
        duration_min: std.atomic.Value(u32),
        duration_max: std.atomic.Value(u32),
        duration_total: std.atomic.Value(u64),
        duration_count: std.atomic.Value(u32),

        pub const init: @This() = .{
            .first_time = .init(std.math.maxInt(i64)),
            .last_time = .init(std.math.minInt(i64)),
            .count = .init(0),
            .duration_min = .init(std.math.maxInt(u32)),
            .duration_max = .init(0),
            .duration_total = .init(0),
            .duration_count = .init(0),
        };

        pub fn clone(self: *@This()) @This() {
            return .{
                .first_time = .init(self.first_time.load(.monotonic)),
                .last_time = .init(self.last_time.load(.monotonic)),
                .count = .init(self.count.load(.monotonic)),
                .duration_min = .init(self.duration_min.load(.monotonic)),
                .duration_max = .init(self.duration_max.load(.monotonic)),
                .duration_total = .init(self.duration_total.load(.monotonic)),
                .duration_count = .init(self.duration_count.load(.monotonic)),
            };
        }

        pub fn hit(self: *@This(), request_time: i64, request_duration: u32) void {
            _ = self.first_time.fetchMin(request_time, .monotonic);
            _ = self.last_time.fetchMax(request_time, .monotonic);
            _ = self.count.fetchAdd(1, .monotonic);
            _ = self.duration_min.fetchMin(request_duration, .monotonic);
            _ = self.duration_max.fetchMax(request_duration, .monotonic);
            _ = self.duration_total.fetchAdd(request_duration, .monotonic);
            _ = self.duration_count.fetchAdd(1, .monotonic);
        }

        pub fn hit_not_found(self: *@This(), request_time: i64) void {
            _ = self.first_time.fetchMin(request_time, .monotonic);
            _ = self.last_time.fetchMax(request_time, .monotonic);
            _ = self.count.fetchAdd(1, .monotonic);
        }
    },

    pub const init: Entry = .{
        .rl = .init,
        .artifact = null,
        .bytes = null,
        .hash = null,
        .data = .none,
        .requests = .init,
    };

    pub fn clone(self: *@This()) @This() {
        return .{
            .rl = .init,
            .artifact = self.artifact,
            .bytes = self.bytes,
            .hash = self.hash,
            .data = self.data,
            .requests = self.requests.clone(),
        };
    }

    pub fn lock_exclusive(self: *@This(), io: std.Io) !void {
        locking_log.debug("lock_exclusive {*}", .{ &self.rl });
        try self.rl.lock(io);
    }

    pub fn try_lock_exclusive(self: *@This(), io: std.Io) bool {
        if (self.rl.tryLock(io)) {
            locking_log.debug("try_lock_exclusive {*}", .{ &self.rl });
            return true;
        }
        return false;
    }

    pub fn unlock_exclusive(self: *@This(), io: std.Io) void {
        locking_log.debug("unlock_exclusive {*}", .{ &self.rl });
        self.rl.unlock(io);
    }

    pub fn lock_shared(self: *@This(), io: std.Io) !void {
        locking_log.debug("lock_shared {*}", .{ &self.rl });
        try self.rl.lockShared(io);
    }
    
    pub fn try_lock_shared(self: *@This(), io: std.Io) bool {
        if (self.rl.tryLockShared(io)) {
            locking_log.debug("try_lock_shared {*}", .{ &self.rl });
            return true;
        }
        return false;
    }

    pub fn unlock_shared(self: *@This(), io: std.Io) void {
        locking_log.debug("unlock_shared {*}", .{ &self.rl });
        self.rl.unlockShared(io);
    }

    /// smaller is better (entry is more important to keep in cache)
    pub fn order_score(self: *Entry, now: i64) u64 {
        // N.B. the memory pointed to by self.data.owned may be freed/reused concurrently; do not access it!

        const first = self.requests.first_time.load(.monotonic);
        const last = self.requests.last_time.load(.monotonic);
        const requests = self.requests.count.load(.monotonic);

        if (requests == 0) return 10_000_000_000_000_000_000;

        const time_in_cache: u64 = if (now > first) std.math.cast(u64, now -% first) orelse 0 else 0;
        const time_since_last: u64 = if (now > last) std.math.cast(u64, now -% last) orelse 0 else 0;
        const dev_penalty: u64 = if (self.artifact != null and self.artifact.?.pre != null) 60_000 else 1000;
        const not_found_penalty: u64 = if (self.bytes == null and self.data == .none) 1_000_000 else 0;
        const time_factor: u64 = if (self.artifact != null and self.artifact.?.extension.is_minisig()) 2 else 1;

        const numer = (time_in_cache + time_since_last) * time_factor + dev_penalty + not_found_penalty;
        const denom = if (requests > 1) requests + 10 else 1;

        return numer / denom;
    }

    pub fn order(self: *Entry, other: *Entry, now: i64) std.math.Order {
        // N.B. the memory pointed to by self.data.owned and other.data.owned may be freed/reused concurrently; do not access it!

        const self_score = self.order_score(now);
        const other_score = other.order_score(now);

        return std.math.order(self_score, other_score);
    }

    pub const Ref = struct {
        io: std.Io,
        ptr: *Entry,
        mode: Locking_Mode,

        pub const Locking_Mode = enum {
            exclusive,
            shared,
        };

        pub fn init(io: std.Io, ptr: *Entry, mode: Locking_Mode) Ref {
            return .{
                .io = io,
                .ptr = ptr,
                .mode = mode,
            };
        }

        pub fn lock(self: Ref) !void {
            switch (self.mode) {
                .shared => try self.ptr.lock_shared(self.io),
                .exclusive => try self.ptr.lock_exclusive(self.io),
            }
        }

        pub fn try_lock(self: Ref) bool {
            return switch (self.mode) {
                .shared => self.ptr.try_lock_shared(self.io),
                .exclusive => self.ptr.try_lock_exclusive(self.io),
            };
        }

        pub fn unlock(self: Ref) void {
            switch (self.mode) {
                .shared => self.ptr.unlock_shared(self.io),
                .exclusive => self.ptr.unlock_exclusive(self.io),
            }
        }
    };
};

const Cache = @This();

const locking_log = std.log.scoped(.locking);
const log = std.log.scoped(.zigmirror);

const Upstream_Transfer = @import("Upstream_Transfer.zig");
const Artifact = @import("Artifact.zig");
const tempora = @import("tempora");
const std = @import("std");
