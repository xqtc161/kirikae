const std = @import("std");
const output = @import("./output.zig");
const config = @import("./config.zig");
const Duration = std.Io.Duration;

/// Spawns an interactive SSH shell on the target, inheriting stdio.
pub fn shell(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: config.HostConfig,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{host.targetPort});
    defer gpa.free(port_str);

    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ host.targetUser, host.targetHost });
    defer gpa.free(user_host);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "ssh", "-p", port_str, user_host },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.SshFailed,
        else => return error.SshFailed,
    }
}

/// Shell-escapes args
fn escapeArg(gpa: std.mem.Allocator, arg: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(gpa, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try buf.appendSlice(gpa, "'\\''");
        } else {
            try buf.append(gpa, c);
        }
    }
    try buf.append(gpa, '\'');
    return buf.toOwnedSlice(gpa);
}

pub fn runRemoteCmd(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    host: config.HostConfig,
    hostname: []const u8,
    cmd: []const []const u8,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{host.targetPort});
    defer gpa.free(port_str);

    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ host.targetUser, host.targetHost });
    defer gpa.free(user_host);

    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (parts.items) |p| gpa.free(p);
        parts.deinit(gpa);
    }
    for (cmd) |arg| try parts.append(gpa, try escapeArg(gpa, arg));
    const remote_cmd = try std.mem.join(gpa, " ", parts.items);
    defer gpa.free(remote_cmd);

    var child = try std.process.spawn(io, .{
        .stdout = .pipe,
        .stderr = .inherit,
        .argv = &.{ "ssh", "-p", port_str, user_host, remote_cmd },
    });
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        out.print("[{s}] {s}\n", .{ hostname, line });
    }

    if (reader.interface.buffered().len > 0) {
        out.print("[{s}] {s}\n", .{ hostname, reader.interface.buffered() });
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| if (code != 0) return error.CmdFailed,
        else => return error.CmdFailed,
    }
}

pub fn activate(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    store_path: []const u8,
    host: config.HostConfig,
    reboot: bool,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{host.targetPort});
    defer gpa.free(port_str);
    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ host.targetUser, host.targetHost });
    defer gpa.free(user_host);

    const ssh = &.{ "ssh", "-tt", "-p", port_str, "-o", "StrictHostKeyChecking=accept-new", user_host };

    if (reboot) {
        // On containers there is no bootloader to activate the new profile on
        // next boot, so we run switch-to-configuration boot to set up the
        // systemd activation scripts that will do it instead.
        const set_cmd = try std.fmt.allocPrint(
            gpa,
            // ziglint-ignore: Z024
            "nix-env -p /nix/var/nix/profiles/system --set {s} && if systemd-detect-virt -c; then {s}/bin/switch-to-configuration boot; fi",
            .{ store_path, store_path },
        );
        defer gpa.free(set_cmd);
        const r1 = try std.process.run(gpa, io, .{ .argv = &(ssh.* ++ .{set_cmd}) });
        defer gpa.free(r1.stdout);
        defer gpa.free(r1.stderr);
        try out.checkExit(r1.term, "profile set failed:", r1.stdout, error.ActivationFailed);

        const r2 = try std.process.run(gpa, io, .{ .argv = &(ssh.* ++ .{"reboot"}) });
        gpa.free(r2.stdout);
        gpa.free(r2.stderr);
        switch (r2.term) {
            .exited => |code| if (code != 0 and code != 255) return error.ActivationFailed,
            else => {},
        }

        try waitForReboot(gpa, io, out, port_str, user_host);

        const check_cmd = "readlink /run/current-system";
        const r3 = try std.process.run(
            gpa,
            io,
            .{
                .argv = &.{
                    "ssh",
                    "-p",
                    port_str,
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    user_host,
                    check_cmd,
                },
            },
        );
        defer gpa.free(r3.stdout);
        defer gpa.free(r3.stderr);

        switch (r3.term) {
            .exited => |code| {
                if (code != 0) {
                    out.errPrint("listing current system path failed", .{});
                    return error.ActivationFailed;
                }
            },
            else => {},
        }

        switch (std.mem.eql(u8, std.mem.trimEnd(u8, r3.stdout, "\r\n"), store_path)) {
            true => {},
            false => {
                out.errPrint(
                    "store path mismatch:\n  deployed: {s}\n  booted:   {s}\n",
                    .{
                        store_path,
                        std.mem.trimEnd(u8, r3.stdout, "\r\n"),
                    },
                );
                return error.ActivationFailed;
            },
        }
    } else {
        // -tt: PTY so SSH exits when switch-to-configuration does, even if child procs hold FDs
        const cmd = try std.fmt.allocPrint(
            gpa,
            "nix-env -p /nix/var/nix/profiles/system --set {s} && {s}/bin/switch-to-configuration switch",
            .{ store_path, store_path },
        );
        defer gpa.free(cmd);
        const r = try std.process.run(gpa, io, .{ .argv = &(ssh.* ++ .{cmd}) });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try out.checkExit(r.term, "activation failed:", r.stdout, error.ActivationFailed);
    }
}

fn waitForReboot(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *output.Output,
    port_str: []const u8,
    user_host: []const u8,
) !void {
    out.print("waiting for host to come back online...\n", .{});
    try std.Io.sleep(io, Duration.fromSeconds(10), .real);
    while (true) {
        const r = try std.process.run(
            gpa,
            io,
            .{
                .argv = &.{
                    "ssh",
                    "-p",
                    port_str,
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    "-o",
                    "ConnectTimeout=5",
                    "-o",
                    "BatchMode=yes",
                    user_host,
                    "true",
                },
            },
        );
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        if (r.term == .exited and r.term.exited == 0) return;
        try std.Io.sleep(io, Duration.fromSeconds(3), .real);
    }
}
