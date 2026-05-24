const std = @import("std");

/// Runs `nix eval <flake_ref>#<attr> --json` and returns the captured stdout.
/// Caller owns the returned slice and must free it with `gpa`.
/// On non-zero exit, prints nix's stderr and returns `error.NixFailed`.
pub fn evalJson(gpa: std.mem.Allocator, io: std.Io, flake_ref: []const u8, attr: []const u8) ![]u8 {
    const installable = try std.fmt.allocPrint(gpa, "{s}#{s}", .{ flake_ref, attr });
    defer gpa.free(installable);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "nix", "eval", installable, "--json" },
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("nix eval failed:\n{s}\n", .{result.stderr});
            return error.NixFailed;
        },
        else => {
            std.debug.print("nix eval terminated unexpectedly\n", .{});
            return error.NixFailed;
        },
    }

    return result.stdout;
}

/// Copies a store path to a remote host via `nix copy`.
/// Port is passed via NIX_SSHOPTS rather than embedded in the URL, because
/// nix does not parse the port from ssh:// URIs, it passes the host string
/// verbatim to SSH, which rejects "host:port" as a hostname.
pub fn copyToHost(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent_env: *const std.process.Environ.Map,
    store_path: []const u8,
    target_user: []const u8,
    target_host: []const u8,
    target_port: u16,
) !void {
    const target = try std.fmt.allocPrint(gpa, "ssh://{s}@{s}", .{ target_user, target_host });
    defer gpa.free(target);

    var env = try parent_env.clone(gpa);
    defer env.deinit();
    const ssh_opts = try std.fmt.allocPrint(gpa, "-p {d}", .{target_port});
    defer gpa.free(ssh_opts);
    try env.put("NIX_SSHOPTS", ssh_opts);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "nix", "copy", "--to", target, "--substitute-on-destination", store_path },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("nix copy failed:\n{s}\n", .{result.stderr});
            return error.NixFailed;
        },
        else => {
            std.debug.print("nix copy terminated unexpectedly\n", .{});
            return error.NixFailed;
        },
    }
}

/// Runs `nix build <flake>#nixosConfigurations.<hostname>.config.system.build.toplevel`
/// and returns the resulting store path
/// Caller owns the returned slice and must free it with `gpa`.
pub fn buildSystem(gpa: std.mem.Allocator, io: std.Io, flake_ref: []const u8, hostname: []const u8) ![]u8 {
    const installable = try std.fmt.allocPrint(
        gpa,
        "{s}#nixosConfigurations.{s}.config.system.build.toplevel",
        .{ flake_ref, hostname },
    );
    defer gpa.free(installable);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "nix", "build", installable, "--no-link", "--print-out-paths" },
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("nix build failed for '{s}':\n{s}\n", .{ hostname, result.stderr });
            return error.NixFailed;
        },
        else => {
            std.debug.print("nix build terminated unexpectedly for '{s}'\n", .{hostname});
            return error.NixFailed;
        },
    }

    return result.stdout;
}
