comptime {
    // tests:
    _ = @import("Artifact.zig");
}

pub fn main(init: std.process.Init) !void {
    log.info("zigmirror {f} starting up...", .{ build_options.version });

    const config = try load_config(init.arena.allocator(), init.gpa, init.io, init.minimal.args);

    var threaded_io: std.Io.Threaded = .init(init.gpa, .{
        .stack_size = 10 * 1024 * 1024,
    });
    defer threaded_io.deinit();

    service_integration.init(threaded_io.io(), init.environ_map);

    var loop: http.Loop = .init(threaded_io.io(), init.gpa);
    defer loop.deinit();

    var server: Server = .init(&loop, try .init(loop.io, init.gpa, &config));
    defer server.deinit();

    const ctx = &server.injector_context;

    try server.router("", .{
        http.routing.resource("style.css"),
        .{ "/", headers.set_server_and_date, Module(Root) },
        .{ "/stats", headers.set_server_and_date, Module(@import("stats.zig")) },
        .{ "/shutdown", Config.shutdown_check, service_integration.stopping, Caches.evict_all_mem, http.routing.shutdown },
        .{ "/index.json", headers.set_server_and_date, rate_limiter, Module(Index) },
        .{ "/**", headers.set_server_and_date, rate_limiter, Module(@import("handle_from_cache.zig")) },
    });

    try server.register("upstream", Module(@import("download_and_add_to_cache.zig")));
    try server.register("regenerate_index", Index.regenerate);

    loop.start();
    defer loop.finish_running();

    for (config.listen) |host_and_port| {
        try server.lookup_and_start(host_and_port.host, host_and_port.port, .{ .start_options = .{
            .listen_options = .{
                .reuse_address = true,
            },
            .temp_allocator_pool_size = config.max_concurrent_connections,
            .temp_allocator_reservation_size = 1024 * 1024,
            .request_timeout = .fromSeconds(config.request_timeout_seconds),
        }});
    }

    loop.begin_running();
    loop.io.sleep(.fromSeconds(1), .awake) catch {};
    service_integration.ready(&loop);

    try ctx.cache.validate_fs_cache(&ctx.server_stats, config.cache.fs.path);

    if (config.request_rate_limit) |rlconfig| {
        try server.tasks.group.concurrent(loop.io, rate_limit_cleanup_task, .{
            loop.io,
            rlconfig.cleanup_interval_seconds,
            &ctx.rate_limiter,
        });
    }

    if (config.cache.mem.periodic_eviction) |_| {
        try server.tasks.group.concurrent(loop.io, mem_cache_cleanup_task, .{
            loop.io,
            &ctx.cache,
            &ctx.server_stats,
            &config,
        });
    }

    if (config.upstream.recheck_expired_index_interval_seconds > 0) {
        try server.tasks.group.concurrent(loop.io, recheck_index_task, .{
            &loop,
            &ctx.index,
            &ctx.cache,
            &ctx.downloads,
            &ctx.server_stats,
            &config,
        });
    }

    if (std.posix.Sigaction != void) {
        signal_handler_io = loop.io;
        try server.tasks.group.concurrent(loop.io, signal_handler_shutdown_task, .{
            &loop,
            &ctx.cache,
            &ctx.server_stats,
            &config,
        });
        
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = &signal_handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
}

var signal_handler_io: std.Io = undefined;
var graceful_shutdown_latch: std.Io.Semaphore = .{};

fn signal_handler(_: std.posix.SIG) callconv(.c) void {
    graceful_shutdown_latch.post(signal_handler_io);
}

fn rate_limit_cleanup_task(io: std.Io, period_seconds: i64, rate_limit: *Rate_Limiter) error{Canceled}!void {
    while (true) {
        try io.sleep(.fromSeconds(period_seconds), .awake);
        try rate_limit.cleanup(tempora.now_utc(io).timestamp_ms());

    }
}

fn mem_cache_cleanup_task(io: std.Io, cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    while (true) {
        try io.sleep(.fromSeconds(config.cache.mem.periodic_eviction.?.interval_minutes * 60), .awake);
        try cache.periodic_cleanup(server_stats, config);
    }
}

fn recheck_index_task(loop: *http.Loop, index: *Index, cache: *Caches, downloads: *Download_Permission, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    while (true) {
        try loop.io.sleep(.fromSeconds(config.upstream.recheck_expired_index_interval_seconds), .awake);
        const permission = Download_Permission.Upstream.init(downloads, config) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.InsufficientResources => continue,
        };
        defer permission.deinit();
        index.maybe_regenerate(loop, cache, server_stats, config, downloads, permission) catch |err| switch (err) {
            error.Canceled => |e| return e,
        };
    }
}

fn signal_handler_shutdown_task(loop: *http.Loop, cache: *Caches, server_stats: *Server_Stats, config: *const Config) error{Canceled}!void {
    try graceful_shutdown_latch.wait(loop.io);
    service_integration.stopping(loop);
    defer loop.stop();
    try cache.evict_all_mem(server_stats, config);
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
        index: Index,
        root: Root,
        rate_limiter: Rate_Limiter,
        server_stats: Server_Stats,
        downloads: Download_Permission,

        pub fn init(io: std.Io, gpa: std.mem.Allocator, config: *const Config) !@This() {
            var mem_cache: Cache = try .init(io, gpa, config.cache.mem.max_entries);
            errdefer mem_cache.deinit();

            var fs_cache: Cache = try .init(io, gpa, config.cache.fs.max_entries);
            errdefer fs_cache.deinit();

            var index: Index = .init(gpa, config);
            errdefer index.deinit();

            var root: Root = try .init(io, gpa, config);
            errdefer root.deinit();

            var server_stats: Server_Stats = try .init(io, gpa, config);
            errdefer server_stats.deinit();

            try Caches.load_fs_cache(&fs_cache, &server_stats, config.cache.fs.path, config.allow_devkit_artifacts);

            return .{
                .config = config.*,
                .cache = .{
                    .mem = mem_cache,
                    .fs = fs_cache,
                },
                .index = index,
                .root = root,
                .rate_limiter = .init(io, gpa, config.request_rate_limit),
                .server_stats = server_stats,
                .downloads = .{
                    .io = io,
                    .upstream_semaphore = .{ .permits = config.upstream.max_connections },
                    .downstream_semaphore = .{ .permits = config.max_concurrent_downloads },
                    .overload_semaphore = .{ .permits = config.max_concurrent_connections },
                },
            };
        }

        pub fn deinit(self: *@This()) void {
            self.server_stats.deinit();
            self.root.deinit();
            self.index.deinit();
            self.rate_limiter.deinit();
            self.cache.mem.deinit();
            self.cache.fs.deinit();
        }
    },
};

const Injector = dizzy.Injector(struct {
    pub fn inject_download_permission_upstream(ctx: Context) !Download_Permission.Upstream {
        return .init(&ctx.context.downloads, &ctx.context.config);
    }

    pub fn inject_download_permission_upstream_cleanup(d: Download_Permission.Upstream) void {
        d.deinit();
    }

    pub fn inject_download_permission_downstream(ctx: Context) !Download_Permission.Downstream {
        return .init(&ctx.context.downloads, &ctx.context.config);
    }

    pub fn inject_download_permission_downstream_cleanup(d: Download_Permission.Downstream) void {
        d.deinit();
    }

    pub fn inject_download_permission(ctx: Context) *Download_Permission {
        return &ctx.context.downloads;
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
        var iter = std.mem.splitScalar(u8, ctx.request.target.path_remaining, '/');
        const first = iter.next() orelse return null;
        const second = iter.next();
        if (iter.next() != null) return null;

        const artifact = Artifact.maybe_parse(if (second) |filename| filename else first) orelse return null;
        if (artifact.artifact_type == .devkit and !ctx.context.config.allow_devkit_artifacts) return null;

        if (second != null) {
            const path_version = std.SemanticVersion.parse(first) catch return null;
            if (path_version.order(artifact.version()) != .eq) return null;
            if (artifact.build) |build| {
                const path_build = path_version.build orelse return null;
                if (!std.mem.eql(u8, build.slice(&artifact.buf), path_build)) return null;
            } else if (path_version.build != null) return null;
        }

        return artifact;
    }

    pub fn inject_server_stats(ctx: Context) *Server_Stats {
        return &ctx.context.server_stats;
    }

    pub fn inject_index(ctx: Context) *Index {
        return &ctx.context.index;
    }

    pub fn inject_root_content(ctx: Context) Root {
        return ctx.context.root;
    }

    pub fn inject_request(ctx: Context) *http.Request {
        return ctx.request;
    }

    pub fn inject_allocator(ctx: Context) std.mem.Allocator {
        return ctx.request.arena();
    }

    pub fn inject_temp_allocator(ctx: Context) error{InsufficientResources}!*Temp_Allocator {
        return try ctx.request.temp_allocator();
    }

    pub fn inject_io(ctx: Context) std.Io {
        return ctx.request.io;
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
        .{ .scope = .http, .level = .info },
    },
};

const locking_log = std.log.scoped(.locking);
const log = std.log.scoped(.zigmirror);

pub const resources = @import("resources");

const Download_Permission = @import("Download_Permission.zig");
const Server_Stats = @import("Server_Stats.zig");
const Artifact = @import("Artifact.zig");
const Caches = @import("Caches.zig");
const Cache = @import("Cache.zig");
const Index = @import("Index.zig");
const Root = @import("Root.zig");
const Rate_Limiter = @import("Rate_Limiter.zig");
const Config = @import("Config.zig");
const headers = @import("headers.zig");
const service_integration = @import("service_integration");
const build_options = @import("build_options");
const Temp_Allocator = @import("Temp_Allocator");
const tempora = @import("tempora");
const dizzy = @import("dizzy");
const http = @import("http");
const std = @import("std");
