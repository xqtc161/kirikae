const std = @import("std");
const output = @import("./output.zig");

pub const GlobalArgs = struct {
    flake: []const u8 = ".",
    filter: ?[]const u8,
    exclude: ?[]const u8,
    subcommand: ?Subcommand,
    exec_args: []const []const u8 = &.{},
    sequential: bool = false,
    reboot: bool = false,
};

pub const Subcommand = enum {
    build,
    apply,
    eval,
    shell,
    exec,
};

pub fn parseArgs(
    out: *output.Output,
    args: []const []const u8,
) !GlobalArgs {
    var result: GlobalArgs = .{ .filter = null, .exclude = null, .subcommand = null };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.subcommand = null;
            break;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--flake")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.flake = args[i];
        } else if (std.mem.eql(u8, arg, "--on")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--not-on")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            result.exclude = args[i];
        } else if (std.mem.eql(u8, arg, "--sequential")) {
            result.sequential = true;
        } else if (std.mem.eql(u8, arg, "--reboot")) {
            result.reboot = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            result.exec_args = args[i + 1 ..];
            break;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (result.subcommand == .shell and result.filter == null) {
                result.filter = arg;
            } else if (result.subcommand != null) {
                return error.UnexpectedArgument;
            } else {
                const sub = std.meta.stringToEnum(Subcommand, arg) orelse {
                    out.errPrint("error: unknown subcommand '{s}'\n", .{arg});
                    return error.UnknownSubcommand;
                };
                result.subcommand = sub;
            }
        } else {
            out.errPrint("error: unknown flag '{s}'\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return result;
}

pub fn printUsage(out: *output.Output) void {
    out.print(
        \\Usage: kirikae [-f <flake>] [--on <nodes>] [--not-on <nodes>] <subcommand>
        \\
        \\Subcommands:
        \\  build          Build system closures
        \\  apply          Build and deploy to hosts
        \\  eval           Evaluate the hive configuration
        \\  shell <host>   Open an interactive shell on a host
        \\  exec -- <cmd>  Runs command on all hosts matching supplied filters 
        \\
        \\Options:
        \\  -f, --flake <FLAKE>   Flake to deploy (default: ".")
        \\  --on <NODES>          Comma-separated host filter
        \\  --not-on <NODES>      Comma-separated host exclusion filter
        \\  --sequential          Run hosts one at a time instead of in parallel
        \\  --reboot              Reboot host(s) before activating the new config
        \\  -h, --help            Show this help
        \\
    , .{});
}
