const std = @import("std");

const cli = @import("./cli.zig");
const config = @import("./config.zig");
const nix = @import("./nix.zig");
const ssh = @import("./ssh.zig");
const output = @import("./output.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var out: output.Output = undefined;
    out.init(init.io, true);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const args = cli.parseArgs(
        &out,
        argv[1..],
    ) catch |err| {
        out.errPrint("try 'kirikae --help' for usage\n", .{});
        return err;
    };

    const subcommand = args.subcommand orelse {
        cli.printUsage(&out);
        return;
    };

    const cfg = try config.load(allocator, init.io, &out, args.flake);
    defer cfg.deinit();

    switch (subcommand) {
        .eval => {
            var entries: std.ArrayList(EvalEntry) = .empty;
            defer entries.deinit(allocator);

            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                if (!config.matchesFilter(
                    entry.key_ptr.*,
                    args.filter,
                    args.exclude,
                )) continue;
                try entries.append(allocator, .{
                    .name = entry.key_ptr.*,
                    .host = entry.value_ptr.*,
                });
            }

            std.mem.sort(EvalEntry, entries.items, {}, EvalEntry.higherNice);
            for (entries.items) |e| {
                out.print("{f}: {s}@{s}:{d} (nice {d})\n", .{
                    out.bold(e.name),
                    e.host.targetUser,
                    e.host.targetHost,
                    e.host.targetPort,
                    e.host.nice,
                });
            }
        },
        .shell => {
            const hostname = args.filter orelse {
                out.errPrint("error: 'shell' requires a hostname\n", .{});
                return error.MissingHostname;
            };
            const host = cfg.value.hosts.map.get(hostname) orelse {
                out.errPrint("error: unknown host '{s}'\n", .{hostname});
                return error.UnknownHost;
            };
            try ssh.shell(allocator, init.io, host);
        },
        .build, .apply, .exec => {
            if (subcommand == .exec and args.exec_args.len == 0) {
                out.errPrint("error: no command supplied.\n", .{});
                return error.NoCommand;
            }

            var tasks: std.ArrayList(HostTask) = .empty;
            defer tasks.deinit(allocator);

            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                if (!config.matchesFilter(
                    entry.key_ptr.*,
                    args.filter,
                    args.exclude,
                )) continue;

                try tasks.append(allocator, .{
                    .gpa = allocator,
                    .io = init.io,
                    .out = &out,
                    .subcommand = subcommand,
                    .hostname = entry.key_ptr.*,
                    .host = entry.value_ptr.*,
                    .flake = args.flake,
                    .builders = cfg.value.builders,
                    .environ_map = init.environ_map,
                    .exec_args = args.exec_args,
                    .reboot = args.reboot,
                    .show_progress = args.sequential,
                });
            }

            if (args.sequential) {
                if (subcommand == .apply)
                    std.mem.sort(HostTask, tasks.items, {}, HostTask.higherNice);
                for (tasks.items) |*task| task.run();
            } else if (subcommand == .apply) {
                // build everything in parallel, then copy and activate in nice tiers
                try spawnJoin(HostTask.runBuildStore, allocator, tasks.items);

                // stable descending sort by nice groups the tiers into adjacent
                // runs while preserving insertion order within each tier
                std.mem.sort(HostTask, tasks.items, {}, HostTask.higherNice);
                var start: usize = 0;
                while (start < tasks.items.len) {
                    const nice = tasks.items[start].host.nice;
                    var end = start;
                    while (end < tasks.items.len and tasks.items[end].host.nice == nice) end += 1;
                    try spawnJoin(HostTask.runDeploy, allocator, tasks.items[start..end]);
                    start = end;
                }
            } else {
                try spawnJoin(HostTask.run, allocator, tasks.items);
            }
        },
    }
}

const EvalEntry = struct {
    name: []const u8,
    host: config.HostConfig,
    fn higherNice(_: void, a: EvalEntry, b: EvalEntry) bool {
        return a.host.nice > b.host.nice;
    }
};

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
