const std = @import("std");

const cli = @import("./cli.zig");
const config = @import("./config.zig");
const runner = @import("./runner.zig");
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
            const hosts = try config.selectHosts(allocator, &cfg.value, args.filter, args.exclude);
            defer allocator.free(hosts);

            std.mem.sort(config.SelectedHost, hosts, {}, config.SelectedHost.higherNice);

            for (hosts) |host| {
                out.print("{f}: {s}@{s}:{d} (nice {d})\n", .{
                    out.bold(host.name),
                    host.config.targetUser,
                    host.config.targetHost,
                    host.config.targetPort,
                    host.config.nice,
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

            const hosts = try config.selectHosts(
                allocator,
                &cfg.value,
                args.filter,
                args.exclude,
            );
            defer allocator.free(hosts);

            try runner.run(
                allocator,
                init.io,
                &out,
                init.environ_map,
                hosts,
                .{
                    .subcommand = subcommand,
                    .flake = args.flake,
                    .builders = cfg.value.builders,
                    .exec_args = args.exec_args,
                    .reboot = args.reboot,
                    .sequential = args.sequential,
                },
            );
        },
    }
}
