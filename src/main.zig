pub fn main(init: std.process.Init) !void {
    const config = try load_config(init.arena.allocator(), init.gpa, init.io, init.minimal.args);

    var threaded_io: std.Io.Threaded = .init(init.gpa, .{
        .stack_size = 1024 * 1024,
    });
    defer threaded_io.deinit();

    var loop: http.Loop = .init(threaded_io.io(), init.gpa);
    defer loop.deinit();

    var server: Server = .init(&loop, try .init(loop.io, init.gpa, config));
    defer server.deinit();

    try server.router("", .{
        http.routing.resource("style.css"),
        .{ "/stats", Module(@import("stats.zig")) },
        .{ "/shutdown", Config.shutdown_check, Caches.evict_all_mem, http.routing.shutdown },
        // .{ "/index.json", rate_limiter, Module(@import("index.zig")) },
        .{ "/**", rate_limiter, Module(@import("handle_from_cache.zig")) },
    });

    try server.register("upstream", Module(@import("download_and_add_to_cache.zig")));

    loop.start();
    defer loop.finish_running();

    for (config.listen) |host_and_port| {
        try server.lookup_and_start(host_and_port.host, host_and_port.port, .{ .start_options = .{
            .temp_allocator_pool_size = 100,
            .temp_allocator_reservation_size = 1024 * 1024,
        }});
    }

    loop.begin_running();

    if (config.request_rate_limit) |rlconfig| {
        try server.tasks.group.concurrent(loop.io, rate_limit_cleanup_task, .{
            loop.io,
            rlconfig.cleanup_interval_seconds,
            &server.injector_context.rate_limiter,
        });
    }

    if (config.cache.mem.periodic_eviction) |_| {
        try server.tasks.group.concurrent(loop.io, mem_cache_cleanup_task, .{
            loop.io,
            &server.injector_context.cache,
            &server.injector_context.server_stats,
            config,
        });
    }

    // TODO periodic download index.json from ziglang.org
}

fn rate_limit_cleanup_task(io: std.Io, period_seconds: i64, rate_limit: *Rate_Limiter) error{Canceled}!void {
    while (true) {
        try io.sleep(.fromSeconds(period_seconds), .real);
        try rate_limit.cleanup(tempora.now(io).timestamp_ms());

    }
}

fn mem_cache_cleanup_task(io: std.Io, cache: *Caches, server_stats: *Server_Stats, config: Config) error{Canceled}!void {
    while (true) {
        try io.sleep(.fromSeconds(config.cache.mem.periodic_eviction.?.interval_minutes * 60), .real);
        try cache.periodic_cleanup(server_stats, &config);
    }
}


fn load_config(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) !Config {
    var args_iter = try args.iterateAllocator(gpa);
    defer args_iter.deinit();

    _ = args_iter.next(); // exe name
    const config_path = args_iter.next() orelse "etc/zigmirror.sx";

    var parent_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_path_len = try std.process.executableDirPath(io, &parent_path_buf);
    var parent_path: []const u8 = parent_path_buf[0..parent_path_len];

    const config_file: std.Io.File = while (true) {
        log.info("Searching for {s} in {s}", .{ config_path, parent_path });
        
        const dir = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
        defer dir.close(io);

        break dir.openFile(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.Io.Dir.path.isAbsolute(config_path)) return error.ConfigFileNotFound;
                parent_path = std.Io.Dir.path.dirname(parent_path) orelse return error.ConfigFileNotFound;
                continue;
            },
            else => |e| return e,
        };
    };
    defer config_file.close(io);

    var buf: [8192]u8 = undefined;
    var file_reader = config_file.reader(io, &buf);
    return try Config.load(&file_reader, arena, gpa);
}

const Context = struct {
    request: *http.Request,
    context: *struct {
        config: Config,
        cache: Caches,
        rate_limiter: Rate_Limiter,
        server_stats: Server_Stats,
        upstream_semaphore: std.Io.Semaphore,

        pub fn init(io: std.Io, gpa: std.mem.Allocator, config: Config) !@This() {
            var mem_cache: Cache = try .init(io, gpa, config.cache.mem.max_entries);
            errdefer mem_cache.deinit();

            var fs_cache: Cache = try .init(io, gpa, config.cache.fs.max_entries);
            errdefer fs_cache.deinit();

            var dir = try std.Io.Dir.cwd().createDirPathOpen(io, config.cache.fs.path, .{ .open_options = .{ .iterate = true } });
            defer dir.close(io);

            var server_stats: Server_Stats = .init(io, config.default_upstream_timeout_seconds * std.time.ms_per_s / 2);
            const startup_time = server_stats.start_time.with_offset(0).timestamp_ms();

            var iter = dir.iterateAssumeFirstIteration();
            while (try iter.next(io)) |entry| {
                if (Artifact.parse(entry.name)) |artifact| {
                    const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
                        error.IsDir => continue,
                        else => |e| return e,
                    };

                    const fs_ref: Cache.Entry.Ref = for (0..100) |_| {
                        if (try fs_cache.get_or_add(artifact)) |ref| break ref;
                        try Caches.maybe_evict_from_fs_cache(&fs_cache, &server_stats, config.cache.fs.path);
                    } else {
                        return error.FsCacheInitError;
                    };
                    defer fs_ref.unlock();

                    const bytes: u32 = @intCast(stat.size);
                    fs_ref.ptr.bytes = bytes;
                    fs_ref.ptr.requests.first_time.store(startup_time, .monotonic);
                    fs_ref.ptr.requests.last_time.store(startup_time, .monotonic);
                    fs_ref.ptr.requests.count.store(1, .monotonic);
                    fs_cache.report_added_bytes(bytes);
                    log.info("Initializing fs cache: {f}", .{ artifact });
                }
            }

            return .{
                .config = config,
                .cache = .{
                    .mem = mem_cache,
                    .fs = fs_cache,
                },
                .rate_limiter = .init(io, gpa, config.request_rate_limit),
                .server_stats = server_stats,
                .upstream_semaphore = .{ .permits = config.max_concurrent_upstream_downloads },
            };
        }

        pub fn deinit(self: *@This()) void {
            self.rate_limiter.deinit();
            self.cache.mem.deinit();
            self.cache.fs.deinit();
        }
    },
};

const Injector = dizzy.Injector(struct {
    pub fn inject_download_authority(ctx: Context) !Download_Authority {
        try ctx.context.upstream_semaphore.wait(ctx.request.io);
        locking_log.debug("Download Authority acquired ({} available)", .{ @atomicLoad(usize, &ctx.context.upstream_semaphore.permits, .monotonic) });
        return .{
            .io = ctx.request.io,
            .semaphore = &ctx.context.upstream_semaphore,
        };
    }

    pub fn inject_download_authority_cleanup(da: Download_Authority) void {
        da.semaphore.post(da.io);
        locking_log.debug("Download Authority returned ({} available)", .{ @atomicLoad(usize, &da.semaphore.permits, .monotonic) });
    }

    pub fn inject_config(ctx: Context) *const Config {
        return &ctx.context.config;
    }

    pub fn inject_cache(ctx: Context) *Caches {
        return &ctx.context.cache;
    }

    pub fn inject_rate_limiter(ctx: Context) *Rate_Limiter {
        return &ctx.context.rate_limiter;
    }

    pub fn inject_artifact(ctx: Context) ?Artifact {
        return Artifact.parse(ctx.request.target.path_remaining);
    }

    pub fn inject_server_stats(ctx: Context) *Server_Stats {
        return &ctx.context.server_stats;
    }

    pub fn inject_request(ctx: Context) *http.Request {
        return ctx.request;
    }

    pub fn inject_allocator(ctx: Context) error{InsufficientResources}!std.mem.Allocator {
        try ctx.request.replace_arena();
        return ctx.request.arena;
    }

    pub fn inject_temp_allocator(ctx: Context) error{InsufficientResources}!*Temp_Allocator {
        try ctx.request.replace_arena();
        return &ctx.request.internal.ta_pool.allocators[ctx.request.internal.ta_pool.index.?];
    }

    pub fn inject_loop(ctx: Context) *http.Loop {
        return ctx.request.internal.loop;
    }
}, .{ .Input_Type = Context });

const Server = http.Server(Injector, .{ .connection_write_buffer_bytes = 64 * 1024 });
const Module = http.routing.Module(Injector);
const rate_limiter = Module(Rate_Limiter);

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .sx, .level = .warn },
        .{ .scope = .zkittle, .level = .info },
        .{ .scope = .locking, .level = .info },
    },
};

const locking_log = std.log.scoped(.locking);
const log = std.log.scoped(.zigmirror);

pub const resources = @import("resources");

const Download_Authority = @import("Download_Authority.zig");
const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Rate_Limiter = @import("Rate_Limiter.zig");
const Config = @import("Config.zig");
const Temp_Allocator = @import("Temp_Allocator");
const tempora = @import("tempora");
const dizzy = @import("dizzy");
const http = @import("http");
const std = @import("std");
