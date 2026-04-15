io: std.Io,
gpa: std.mem.Allocator,
entries: []Entry,
lookup: std.AutoHashMapUnmanaged(Artifact, usize),
last_removed_index: usize,
total_bytes: std.atomic.Value(usize),
lock: std.Io.RwLock,

pub fn init(io: std.Io, gpa: std.mem.Allocator, max_entries: usize) !Cache {
    const entries = try gpa.alloc(Entry, max_entries);
    errdefer gpa.free(entries);

    @memset(entries, .init);

    return .{
        .io = io,
        .gpa = gpa,
        .entries = entries,
        .lookup = .empty,
        .last_removed_index = 0,
        .total_bytes = .init(0),
        .lock = .init,
    };
}

pub fn deinit(self: *Cache) void {
    self.lookup.deinit(self.gpa);

    for (self.entries) |entry| {
        if (entry.data) |data| {
            self.gpa.free(data);
        }
    }

    self.gpa.free(self.entries);
}

pub fn active_entries(self: *Cache) !usize {
    try self.lock.lockShared(self.io);
    defer self.lock.unlockShared(self.io);
    return self.lookup.size;
}

// Call Entry.Ref.unlock when finished
pub fn get(self: *Cache, artifact: Artifact) !?Entry.Ref {
    try self.lock.lockShared(self.io);
    defer self.lock.unlockShared(self.io);

    if (self.lookup.get(artifact)) |index| {
        const ref: Entry.Ref = .init_shared(self.io, &self.entries[index]);
        try ref.lock();
        return ref;
    }

    return null;
}

// Call Entry.Ref.unlock when finished
pub fn get_or_add(self: *Cache, artifact: Artifact) !?Entry.Ref {
    {
        try self.lock.lockShared(self.io);
        defer self.lock.unlockShared(self.io);

        if (self.lookup.get(artifact)) |index| {
            const ref: Entry.Ref = .init_exclusive(self.io, &self.entries[index]);
            try ref.lock();
            return ref;
        }
    }

    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    const gop = try self.lookup.getOrPut(self.gpa, artifact);
    if (gop.found_existing) {
        const ref: Entry.Ref = .init_exclusive(self.io, &self.entries[gop.value_ptr.*]);
        try ref.lock();
        return ref;
    } else {
        gop.key_ptr.* = artifact;
        errdefer _ = self.lookup.remove(artifact);
        const index = try self.find_free_index() orelse {
            _ = self.lookup.remove(artifact);
            return null;
        };
        gop.value_ptr.* = index;
        self.entries[index].artifact = artifact;
        self.entries[index].bytes = null;
        self.entries[index].data = null;
        self.entries[index].requests = .init;
        return .init_exclusive(self.io, &self.entries[index]);
    }
}
fn find_free_index(self: *Cache) !?usize {
    const first = self.last_removed_index;
    var next = first;
    defer self.last_removed_index = next;

    while (true) {
        const index = next;
        next = (next + 1) % self.entries.len;

        const entry = &self.entries[index];
        try entry.lock_exclusive(self.io);
        if (entry.artifact == null) return index;
        entry.unlock_exclusive(self.io);
        if (next == first) return null;
    }
}

pub fn report_added_bytes(self: *Cache, bytes: u32) void {
    _ = self.total_bytes.fetchAdd(bytes, .monotonic);
}

// Call Entry.Ref.unlock when finished
pub fn remove(self: *Cache, artifact: Artifact) !?Entry.Ref {
    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    if (self.lookup.fetchRemove(artifact)) |kv| {
        const entry = &self.entries[kv.value];
        try entry.lock_exclusive(self.io);
        errdefer entry.unlock_exclusive(self.io);

        if (entry.data) |data| {
            self.gpa.free(data);
            entry.data = null;
        }

        if (entry.bytes) |bytes| {
            _ = self.total_bytes.fetchSub(bytes, .monotonic);
            entry.bytes = null;
        }

        std.debug.assert(std.meta.eql(artifact, entry.artifact.?));
        entry.artifact = null;

        entry.requests = .init;

        self.last_removed_index = kv.value;
        return .init_exclusive(self.io, entry);
    }

    return null;
}

// Call Entry.Ref.unlock when finished
pub fn get_worst(self: *Cache) !?Entry.Ref {
    try self.lock.lockShared(self.io);
    defer self.lock.unlockShared(self.io);

    const now = tempora.now(self.io).timestamp_ms();

    var maybe_worst_entry: ?*Entry = null;
    for (self.entries) |*entry| {
        try entry.lock_shared(self.io);
        defer entry.unlock_shared(self.io);

        if (entry.artifact == null) continue;

        if (maybe_worst_entry) |worst_entry| {
            if (entry.order(worst_entry, now) == .gt) {
                maybe_worst_entry = entry;
            }
        } else {
            maybe_worst_entry = entry;
        }
    }
    if (maybe_worst_entry) |worst_entry| {
        const ref: Entry.Ref = .init_exclusive(self.io, worst_entry);
        try ref.lock();
        return ref;
    }
    return null;
}

pub const Entry = struct {
    rl: std.Io.RwLock,
    artifact: ?Artifact,
    bytes: ?u32,
    data: ?[]const u8,
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
        .data = null,
        .requests = .init,
    };

    pub fn lock_exclusive(self: *@This(), io: std.Io) !void {
        locking_log.debug("lock_exclusive {*}", .{ &self.rl });
        try self.rl.lock(io);
    }

    pub fn unlock_exclusive(self: *@This(), io: std.Io) void {
        locking_log.debug("unlock_exclusive {*}", .{ &self.rl });
        self.rl.unlock(io);
    }

    pub fn lock_shared(self: *@This(), io: std.Io) !void {
        locking_log.debug("lock_shared {*}", .{ &self.rl });
        try self.rl.lockShared(io);
    }

    pub fn unlock_shared(self: *@This(), io: std.Io) void {
        locking_log.debug("unlock_shared {*}", .{ &self.rl });
        self.rl.unlockShared(io);
    }

    /// smaller is better (entry is more important to keep in cache)
    pub fn order_score(self: *Entry, now: i64) u64 {
        const first = self.requests.first_time.load(.monotonic);
        const last = self.requests.last_time.load(.monotonic);
        const requests = self.requests.count.load(.monotonic);

        const time_in_cache: u64 = if (now > first) @intCast(now - first) else 0;
        const time_since_last: u64 = if (now > last) @intCast(now - last) else 0;
        const dev_penalty: u64 = if (self.artifact != null and self.artifact.?.pre != null) 60_000 else 1000;

        const numer = time_in_cache + time_since_last + dev_penalty;
        const denom = if (requests > 1) requests + 10 else 1;

        return numer / denom;
    }

    pub fn order(self: *Entry, other: *Entry, now: i64) std.math.Order {
        const self_score = self.order_score(now);
        const other_score = other.order_score(now);

        return std.math.order(self_score, other_score);
    }

    pub const Ref = struct {
        io: std.Io,
        ptr: *Entry,
        shared: bool,

        pub fn init_shared(io: std.Io, ptr: *Entry) Ref {
            return .{
                .io = io,
                .ptr = ptr,
                .shared = true,
            };
        }

        pub fn init_exclusive(io: std.Io, ptr: *Entry) Ref {
            return .{
                .io = io,
                .ptr = ptr,
                .shared = false,
            };
        }

        pub fn lock(self: Ref) !void {
            if (self.shared) {
                try self.ptr.lock_shared(self.io);
            } else {
                try self.ptr.lock_exclusive(self.io);
            }
        }

        pub fn unlock(self: Ref) void {
            if (self.shared) {
                self.ptr.unlock_shared(self.io);
            } else {
                self.ptr.unlock_exclusive(self.io);
            }
        }
    };
};

const Cache = @This();

const locking_log = std.log.scoped(.locking);
const log = std.log.scoped(.zigmirror);

const Artifact = @import("Artifact.zig");
const tempora = @import("tempora");
const std = @import("std");
