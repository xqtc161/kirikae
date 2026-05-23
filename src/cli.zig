const std = @import("std");

pub const GlobalArgs = struct {
    flake: []const u8 = ".",
    filter: ?[]const u8,
    subcommand: ?Subcommand,
};

pub const Subcommand = enum {
    build,
    apply,
    eval,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !GlobalArgs {
    _ = allocator;
    var result = GlobalArgs{ .filter = null, .subcommand = null };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--flake")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.flake = args[i];
        } else if (std.mem.eql(u8, arg, "--on")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.filter = args[i];
        } else if (arg.len > 0 and arg[0] != '-') {
            if (result.subcommand != null) return error.UnexpectedArgument;
            const sub = std.meta.stringToEnum(Subcommand, arg) orelse {
                std.debug.print("error: unknown subcommand '{s}'\n", .{arg});
                return error.UnknownSubcommand;
            };
            result.subcommand = sub;
        } else {
            std.debug.print("error: unknown flag '{s}'\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return result;
}

pub fn printUsage() void {
    std.debug.print(
        \\Usage: kirikae [-f <flake>] [--on <nodes>] <subcommand>
        \\
        \\Subcommands:
        \\  build   Build system closures
        \\  apply   Build and deploy to hosts
        \\  eval    Evaluate the hive configuration
        \\
        \\Options:
        \\  -f, --flake <FLAKE>   Flake to deploy (default: ".")
        \\  --on <NODES>          Comma-separated host filter
        \\  -h, --help            Show this help
        \\
    , .{});
}
