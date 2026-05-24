const std = @import("std");
const Io = std.Io;

const cli = @import("./cli.zig");
const config = @import("./config.zig");
const nix = @import("./nix.zig");
const ssh = @import("./ssh.zig");

// const kirikae = @import("kirikae");

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

    const cfg = try config.load(allocator, init.io, args.flake);
    defer cfg.deinit();

    switch (args.subcommand orelse {
        cli.printUsage();
        return;
    }) {
        .build => {
            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                const hostname = entry.key_ptr.*;
                if (!config.matchesFilter(hostname, args.filter)) continue;
                std.debug.print("building {s}... ", .{hostname});
                const path = nix.buildSystem(allocator, init.io, args.flake, hostname) catch {
                    // error already printed by buildSystem
                    continue;
                };
                defer allocator.free(path);
                std.debug.print("{s}\n", .{std.mem.trimEnd(u8, path, "\n")});
            }
        },
        .apply => {
            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                const hostname = entry.key_ptr.*;
                const host = entry.value_ptr.*;
                if (!config.matchesFilter(hostname, args.filter)) continue;

                std.debug.print("[{s}] building... ", .{hostname});
                const path = nix.buildSystem(allocator, init.io, args.flake, hostname) catch continue;
                defer allocator.free(path);
                const store_path = std.mem.trimEnd(u8, path, "\n");
                std.debug.print("{s}\n", .{store_path});

                std.debug.print("[{s}] copying... ", .{hostname});
                nix.copyToHost(allocator, init.io, init.environ_map, store_path, host.targetUser, host.targetHost, host.targetPort) catch continue;
                std.debug.print("done\n", .{});

                std.debug.print("[{s}] activating... ", .{hostname});
                ssh.activate(allocator, init.io, store_path, host.targetUser, host.targetHost, host.targetPort) catch continue;
                std.debug.print("done\n", .{});
            }
        },
        .eval => {
            var it = cfg.value.hosts.map.iterator();
            while (it.next()) |entry| {
                if (!config.matchesFilter(entry.key_ptr.*, args.filter)) continue;
                const h = entry.value_ptr.*;
                std.debug.print("{s}: {s}@{s}:{d}\n", .{
                    entry.key_ptr.*, h.targetUser, h.targetHost, h.targetPort,
                });
            }
        },
    }
}
