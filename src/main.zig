const std = @import("std");
const Io = std.Io;

const cli = @import("./cli.zig");

// const kirikae = @import("kirikae");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect argv into a slice, skipping argv[0] (program name).
    // On POSIX the iterator returns slices into the static argv array.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = iter.next(); // skip program name
    while (iter.next()) |arg| try argv.append(allocator, arg);

    const args = cli.parseArgs(allocator, argv.items) catch |err| {
        std.debug.print("try 'kirikae --help' for usage\n", .{});
        return err;
    };

    switch (args.subcommand orelse {
        cli.printUsage();
        return;
    }) {
        .build => std.debug.print("build: not yet implemented\n", .{}),
        .apply => std.debug.print("apply: not yet implemented\n", .{}),
        .eval  => std.debug.print("eval: not yet implemented\n", .{}),
    }
}
