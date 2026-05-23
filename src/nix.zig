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
