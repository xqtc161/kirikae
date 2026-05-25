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
