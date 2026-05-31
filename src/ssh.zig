const std = @import("std");

/// Spawns an interactive SSH shell on the target, inheriting stdio.
pub fn shell(
    gpa: std.mem.Allocator,
    io: std.Io,
    target_user: []const u8,
    target_host: []const u8,
    target_port: u16,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{target_port});
    defer gpa.free(port_str);

    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ target_user, target_host });
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
    target_user: []const u8,
    target_host: []const u8,
    target_port: u16,
    cmd: []const []const u8,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{target_port});
    defer gpa.free(port_str);

    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ target_user, target_host });
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
        std.debug.print("[{s}] {s}\n", .{ target_host, line });
    }

    if (reader.interface.buffered().len > 0) {
        std.debug.print("[{s}] {s}\n", .{ target_host, reader.interface.buffered() });
    }

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| if (code != 0) return error.CmdFailed,
        else => return error.CmdFailed,
    }
}

/// SSHs into the target and runs the NixOS activation sequence:
///   nix-env -p /nix/var/nix/profiles/system --set <store_path>
///   <store_path>/bin/switch-to-configuration switch
pub fn activate(
    gpa: std.mem.Allocator,
    io: std.Io,
    store_path: []const u8,
    target_user: []const u8,
    target_host: []const u8,
    target_port: u16,
) !void {
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{target_port});
    defer gpa.free(port_str);

    const user_host = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ target_user, target_host });
    defer gpa.free(user_host);

    const cmd = try std.fmt.allocPrint(
        gpa,
        "nix-env -p /nix/var/nix/profiles/system --set {s} && {s}/bin/switch-to-configuration switch",
        .{ store_path, store_path },
    );
    defer gpa.free(cmd);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "ssh", "-p", port_str, "-o", "StrictHostKeyChecking=accept-new", user_host, cmd },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("activation failed:\n{s}\n", .{result.stderr});
            return error.ActivationFailed;
        },
        else => {
            std.debug.print("ssh terminated unexpectedly\n", .{});
            return error.ActivationFailed;
        },
    }
}
