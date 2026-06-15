const std = @import("std");
const Io = std.Io;

const ansi = @import("./ansi.zig");
const cli = @import("./cli.zig");
const config = @import("./config.zig");
const nix = @import("./nix.zig");
const ssh = @import("./ssh.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect argv into a slice, skipping argv[0] (program name).
    // On POSIX the iterator returns slices into the static argv array.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = iter.next();
    while (iter.next()) |arg| try argv.append(allocator, arg);

    const args = cli.parseArgs(allocator, argv.items) catch |err| {
        std.debug.print("try 'kirikae --help' for usage\n", .{});
        return err;
    };

    const subcommand = args.subcommand orelse {
        cli.printUsage();
        return;
    };

    const cfg = try config.load(allocator, init.io, args.flake);
    defer cfg.deinit();

    switch (subcommand) {
        .eval => {
            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                if (!config.matchesFilter(entry.key_ptr.*, args.filter, args.exclude)) continue;
                const h = entry.value_ptr.*;
                std.debug.print(ansi.bold ++ "{s}" ++ ansi.reset ++ ": {s}@{s}:{d}\n", .{
                    entry.key_ptr.*, h.targetUser, h.targetHost, h.targetPort,
                });
            }
        },
        .shell => {
            const hostname = args.filter orelse {
                std.debug.print("error: 'shell' requires a hostname\n", .{});
                return error.MissingHostname;
            };
            const host = cfg.value.hosts.map.get(hostname) orelse {
                std.debug.print("error: unknown host '{s}'\n", .{hostname});
                return error.UnknownHost;
            };
            try ssh.shell(allocator, init.io, host.targetUser, host.targetHost, host.targetPort);
        },
        .build, .apply, .exec => {
            if (subcommand == .exec and args.exec_args.len == 0) {
                std.debug.print("error: no command supplied.\n", .{});
                return error.NoCommand;
            }

            if (args.sequential) {
                var it = cfg.value.hosts.map.iterator();
                while (it.next()) |entry| {
                    const hostname = entry.key_ptr.*;
                    const host = entry.value_ptr.*;
                    if (!config.matchesFilter(hostname, args.filter, args.exclude)) continue;
                    switch (subcommand) {
                        .build => {
                            std.debug.print("building " ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "...\n", .{hostname});
                            std.debug.print("evaluating...", .{});
                            const path = nix.buildSystem(allocator, init.io, args.flake, hostname, true) catch continue;
                            defer allocator.free(path);
                            std.debug.print("  =>" ++ ansi.dim ++ "{s}" ++ ansi.reset ++ "\n", .{std.mem.trimEnd(u8, path, "\n")});
                        },
                        .apply => {
                            std.debug.print("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] building...\n", .{hostname});
                            std.debug.print("evaluating...", .{});
                            const path = nix.buildSystem(allocator, init.io, args.flake, hostname, true) catch continue;
                            defer allocator.free(path);
                            const store_path = std.mem.trimEnd(u8, path, "\n");
                            std.debug.print("  =>" ++ ansi.dim ++ "{s}" ++ ansi.reset ++ "\n", .{store_path});
                            std.debug.print("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] copying... ", .{hostname});
                            nix.copyToHost(allocator, init.io, init.environ_map, store_path, host.targetUser, host.targetHost, host.targetPort) catch continue;
                            std.debug.print(ansi.green ++ "done" ++ ansi.reset ++ "\n", .{});
                            std.debug.print("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] activating... ", .{hostname});
                            ssh.activate(allocator, init.io, store_path, host.targetUser, host.targetHost, host.targetPort) catch continue;
                            std.debug.print(ansi.green ++ "done" ++ ansi.reset ++ "\n", .{});
                        },
                        .exec => {
                            try ssh.runRemoteCmd(allocator, init.io, host.targetUser, host.targetHost, host.targetPort, args.exec_args);
                        },
                        else => unreachable,
                    }
                }
            } else {
                var mutex: std.Io.Mutex = std.Io.Mutex.init;

                var tasks: std.ArrayList(HostTask) = .empty;
                defer tasks.deinit(allocator);

                var it = cfg.value.hosts.map.iterator();
                while (it.next()) |entry| {
                    if (!config.matchesFilter(entry.key_ptr.*, args.filter, args.exclude)) continue;
                    try tasks.append(allocator, .{
                        .gpa = allocator,
                        .io = init.io,
                        .mutex = &mutex,
                        .subcommand = subcommand,
                        .hostname = entry.key_ptr.*,
                        .host = entry.value_ptr.*,
                        .flake = args.flake,
                        .environ_map = init.environ_map,
                        .exec_args = args.exec_args,
                    });
                }

                // Finalise the slice before spawning so realloc can't invalidate pointers.
                var threads: std.ArrayList(std.Thread) = .empty;
                defer threads.deinit(allocator);
                for (tasks.items) |*task| {
                    try threads.append(allocator, try std.Thread.spawn(.{}, HostTask.run, .{task}));
                }
                for (threads.items) |thread| thread.join();
            }
        },
    }
}

const HostTask = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: *std.Io.Mutex,
    subcommand: cli.Subcommand,
    hostname: []const u8,
    host: config.HostConfig,
    flake: []const u8,
    environ_map: *const std.process.Environ.Map,
    exec_args: []const []const u8,

    fn log(self: *const HostTask, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.print(fmt, args);
    }

    fn run(self: *const HostTask) void {
        switch (self.subcommand) {
            .build => self.runBuild(),
            .apply => self.runApply(),
            .exec => self.runExec() catch |err| {
                self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] exec failed: {s}\n", .{ self.hostname, @errorName(err) });
            },
            else => unreachable,
        }
    }

    fn runBuild(self: *const HostTask) void {
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] building...\n", .{self.hostname});
        const path = nix.buildSystem(self.gpa, self.io, self.flake, self.hostname, false) catch return;
        defer self.gpa.free(path);
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] => " ++ ansi.dim ++ "{s}" ++ ansi.reset ++ "\n", .{ self.hostname, std.mem.trimEnd(u8, path, "\n") });
    }

    fn runApply(self: *const HostTask) void {
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] building...\n", .{self.hostname});
        const path = nix.buildSystem(self.gpa, self.io, self.flake, self.hostname, false) catch return;
        defer self.gpa.free(path);
        const store_path = std.mem.trimEnd(u8, path, "\n");
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] => " ++ ansi.dim ++ "{s}" ++ ansi.reset ++ "\n", .{ self.hostname, store_path });

        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] copying...\n", .{self.hostname});
        nix.copyToHost(self.gpa, self.io, self.environ_map, store_path, self.host.targetUser, self.host.targetHost, self.host.targetPort) catch return;
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] copying " ++ ansi.green ++ "done" ++ ansi.reset ++ "\n", .{self.hostname});

        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] activating...\n", .{self.hostname});
        ssh.activate(self.gpa, self.io, store_path, self.host.targetUser, self.host.targetHost, self.host.targetPort) catch return;
        self.log("[" ++ ansi.bold ++ "{s}" ++ ansi.reset ++ "] " ++ ansi.green ++ "done" ++ ansi.reset ++ "\n", .{self.hostname});
    }

    fn runExec(self: *const HostTask) !void {
        try ssh.runRemoteCmd(self.gpa, self.io, self.host.targetUser, self.host.targetHost, self.host.targetPort, self.exec_args);
    }
};
