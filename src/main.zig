const std = @import("std");
const Io = std.Io;

const cli = @import("./cli.zig");
const config = @import("./config.zig");
const nix = @import("./nix.zig");
const ssh = @import("./ssh.zig");
const output = @import("./output.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var out: output.Output = undefined;
    out.init(init.io, true);

    // Collect argv into a slice, skipping argv[0] (program name).
    // On POSIX the iterator returns slices into the static argv array.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = iter.next();
    while (iter.next()) |arg| try argv.append(allocator, arg);

    const args = cli.parseArgs(
        allocator,
        &out,
        argv.items,
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
            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                if (!config.matchesFilter(
                    entry.key_ptr.*,
                    args.filter,
                    args.exclude,
                )) continue;

                const h = entry.value_ptr.*;
                out.print("{f}: {s}@{s}:{d}\n", .{
                    out.bold(entry.key_ptr.*),
                    h.targetUser,
                    h.targetHost,
                    h.targetPort,
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

            if (args.sequential) {
                var it = cfg.value.hosts.map.iterator();
                while (it.next()) |entry| {
                    if (!config.matchesFilter(
                        entry.key_ptr.*,
                        args.filter,
                        args.exclude,
                    )) continue;

                    const task: HostTask = .{
                        .gpa = allocator,
                        .io = init.io,
                        .out = &out,
                        .subcommand = subcommand,
                        .hostname = entry.key_ptr.*,
                        .host = entry.value_ptr.*,
                        .flake = args.flake,
                        .environ_map = init.environ_map,
                        .exec_args = args.exec_args,
                        .reboot = args.reboot,
                        .show_progress = true,
                    };
                    task.run();
                }
            } else {
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
                        .environ_map = init.environ_map,
                        .exec_args = args.exec_args,
                        .reboot = args.reboot,
                        .show_progress = false,
                    });
                }

                // Finalise the slice before spawning so realloc can't invalidate pointers.
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(allocator);
                for (tasks.items) |*task| {
                    try threads.append(allocator, try std.Thread.spawn(
                        .{},
                        HostTask.run,
                        .{task},
                    ));
                }
                for (threads.items) |thread| thread.join();
            }
        },
    }
}

const HostTask = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    subcommand: cli.Subcommand,
    hostname: []const u8,
    host: config.HostConfig,
    flake: []const u8,
    environ_map: *const std.process.Environ.Map,
    exec_args: []const []const u8,
    reboot: bool,
    show_progress: bool,

    fn run(self: *const HostTask) void {
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

    fn runBuild(self: *const HostTask) void {
        self.out.print("[{f}] building...\n", .{
            self.out.bold(self.hostname),
        });
        const path = nix.buildSystem(
            self.gpa,
            self.io,
            self.out,
            self.flake,
            self.hostname,
            self.show_progress,
        ) catch return;
        defer self.gpa.free(path);

        self.out.print("[{f}] => {f}\n", .{
            self.out.bold(self.hostname),
            self.out.dim(
                std.mem.trimEnd(u8, path, "\n"),
            ),
        });
    }

    fn runApply(self: *const HostTask) void {
        self.out.print("[{f}] building...\n", .{self.out.bold(self.hostname)});
        const path = nix.buildSystem(
            self.gpa,
            self.io,
            self.out,
            self.flake,
            self.hostname,
            self.show_progress,
        ) catch return;
        defer self.gpa.free(path);
        const store_path = std.mem.trimEnd(u8, path, "\n");
        self.out.print("[{f}] => {f}\n", .{
            self.out.bold(self.hostname),
            self.out.dim(store_path),
        });

        self.out.print("[{f}] copying...\n", .{self.out.bold(self.hostname)});
        nix.copyToHost(
            self.gpa,
            self.io,
            self.out,
            self.environ_map,
            store_path,
            self.host,
        ) catch return;
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
        ) catch return;
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
