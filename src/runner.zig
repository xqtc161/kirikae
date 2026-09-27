const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const nix = @import("nix.zig");
const ssh = @import("ssh.zig");
const output = @import("output.zig");

pub const Options = struct {
    subcommand: cli.Subcommand,
    flake: []const u8,
    builders: ?[]const []const u8,
    exec_args: []const []const u8,
    reboot: bool,
    sequential: bool,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    environ_map: *const std.process.Environ.Map,
    hosts: []const config.SelectedHost,
    options: Options,
) !void {
    var tasks: std.ArrayList(HostTask) = .empty;
    defer tasks.deinit(gpa);

    for (hosts) |host| {
        try tasks.append(gpa, .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .subcommand = options.subcommand,
            .hostname = host.name,
            .host = host.config,
            .flake = options.flake,
            .builders = options.builders,
            .environ_map = environ_map,
            .exec_args = options.exec_args,
            .reboot = options.reboot,
            .show_progress = options.sequential,
        });
    }

    if (options.sequential) {
        runSequentially(tasks.items, options.subcommand);
    } else if (options.subcommand == .apply) {
        try buildAllThenDeployByPriority(gpa, tasks.items);
    } else {
        try runConcurrently(gpa, tasks.items);
    }
}

fn runSequentially(tasks: []HostTask, subcommand: cli.Subcommand) void {
    if (subcommand == .apply) {
        std.mem.sort(HostTask, tasks, {}, HostTask.higherNice);
    }
    for (tasks) |*task| task.run();
}

/// All build attempts finish before deployment starts.
fn buildAllThenDeployByPriority(
    gpa: std.mem.Allocator,
    tasks: []HostTask,
) !void {
    try spawnJoin(HostTask.runBuildStore, gpa, tasks);

    std.mem.sort(HostTask, tasks, {}, HostTask.higherNice);

    var start: usize = 0;
    while (start < tasks.len) {
        const nice = tasks[start].host.nice;
        var end = start;
        while (end < tasks.len and tasks[end].host.nice == nice) end += 1;

        try spawnJoin(HostTask.runDeploy, gpa, tasks[start..end]);
        start = end;
    }
}

fn runConcurrently(gpa: std.mem.Allocator, tasks: []HostTask) !void {
    try spawnJoin(HostTask.run, gpa, tasks);
}

/// Spawns one thread per task running `func`, then joins them all.
/// The slice must be finalised before calling so realloc can't invalidate pointers.
fn spawnJoin(
    comptime func: fn (*HostTask) void,
    gpa: std.mem.Allocator,
    tasks: []HostTask,
) !void {
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);
    // reserve up front so append cant fail after a thread is spawned
    // and join whatever started if a later spawn fails
    try threads.ensureTotalCapacity(gpa, tasks.len);
    errdefer for (threads.items) |thread| thread.join();
    for (tasks) |*task| {
        threads.appendAssumeCapacity(try std.Thread.spawn(.{}, func, .{task}));
    }
    for (threads.items) |thread| thread.join();
}

const HostTask = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    subcommand: cli.Subcommand,
    hostname: []const u8,
    host: config.HostConfig,
    flake: []const u8,
    builders: ?[]const []const u8,
    environ_map: *const std.process.Environ.Map,
    exec_args: []const []const u8,
    reboot: bool,
    show_progress: bool,
    store_path: ?[]u8 = null,

    fn higherNice(_: void, a: HostTask, b: HostTask) bool {
        return a.host.nice > b.host.nice;
    }

    fn run(self: *HostTask) void {
        switch (self.subcommand) {
            .build => self.runBuild(),
            .apply => self.runApply(),
            .exec => self.runExec() catch |err| {
                self.out.errPrint("[{f}] exec failed: {s}\n", .{
                    self.out.bold(self.hostname),
                    @errorName(err),
                });
            },
            else => unreachable,
        }
    }

    fn build(self: *const HostTask) ?[]u8 {
        self.out.print("[{f}] building...\n", .{self.out.bold(self.hostname)});
        const path = nix.buildSystem(
            self.gpa,
            self.io,
            self.out,
            self.flake,
            self.hostname,
            self.builders,
            self.show_progress,
        ) catch |err| {
            self.out.errPrint("[{f}] build failed: {s}\n", .{
                self.out.bold(self.hostname),
                @errorName(err),
            });
            return null;
        };
        self.out.print("[{f}] => {f}\n", .{
            self.out.bold(self.hostname),
            self.out.dim(std.mem.trimEnd(u8, path, "\n")),
        });
        return path;
    }

    fn runBuild(self: *const HostTask) void {
        const path = self.build() orelse return;
        self.gpa.free(path);
    }

    fn runBuildStore(self: *HostTask) void {
        self.store_path = self.build();
    }

    fn runApply(self: *HostTask) void {
        self.runBuildStore();
        self.runDeploy();
    }

    fn runDeploy(self: *HostTask) void {
        const path = self.store_path orelse return;
        self.store_path = null; // clear so it can't dangle or be double-freed
        defer self.gpa.free(path);
        const store_path = std.mem.trimEnd(u8, path, "\n");

        self.out.print("[{f}] copying...\n", .{self.out.bold(self.hostname)});
        nix.copyToHost(
            self.gpa,
            self.io,
            self.out,
            self.environ_map,
            store_path,
            self.host,
        ) catch |err| {
            self.out.errPrint("[{f}] copy failed: {s}\n", .{
                self.out.bold(self.hostname),
                @errorName(err),
            });
            return;
        };
        self.out.print("[{f}] copying {f}\n", .{
            self.out.bold(self.hostname),
            self.out.green("done"),
        });

        self.out.print("[{f}] activating...\n", .{self.out.bold(self.hostname)});
        ssh.activate(
            self.gpa,
            self.io,
            self.out,
            store_path,
            self.host,
            self.reboot,
        ) catch |err| {
            self.out.errPrint("[{f}] activation failed: {s}\n", .{
                self.out.bold(self.hostname),
                @errorName(err),
            });
            return;
        };
        self.out.print("[{f}] {f}\n", .{ self.out.bold(self.hostname), self.out.green("done") });
    }

    fn runExec(self: *const HostTask) !void {
        try ssh.runRemoteCmd(
            self.gpa,
            self.io,
            self.out,
            self.host,
            self.hostname,
            self.exec_args,
        );
    }
};
