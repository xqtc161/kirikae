const std = @import("std");
const ansi = @import("./ansi.zig");
const progress = @import("./progress.zig");

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
            std.debug.print(ansi.red ++ "nix eval failed:" ++ ansi.reset ++ "\n{s}\n", .{result.stderr});
            return error.NixFailed;
        },
        else => {
            std.debug.print(ansi.red ++ "nix eval terminated unexpectedly" ++ ansi.reset ++ "\n", .{});
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
            std.debug.print(ansi.red ++ "nix copy failed:" ++ ansi.reset ++ "\n{s}\n", .{result.stderr});
            return error.NixFailed;
        },
        else => {
            std.debug.print(ansi.red ++ "nix copy terminated unexpectedly" ++ ansi.reset ++ "\n", .{});
            return error.NixFailed;
        },
    }
}

/// Reads nix's `--log-format internal-json` stderr stream, feeding messages
/// and progress updates into `disp` and accumulating raw lines into `stderr_log`.
fn streamBuildStderr(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    disp: *progress.Display,
    stderr_log: *std.ArrayList(u8),
) !void {
    const nix_prefix = "@nix ";
    var builds_id: i64 = -1;
    var done: u64 = 0;
    var expected: u64 = 0;
    var running: u64 = 0;

    while (true) {
        const line = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = reader.discard(.limited(65536)) catch {};
                continue;
            },
            error.ReadFailed => break,
        } orelse break;

        try stderr_log.appendSlice(gpa, line);
        try stderr_log.append(gpa, '\n');

        if (!std.mem.startsWith(u8, line, nix_prefix)) continue;
        const json_str = line[nix_prefix.len..];

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{ .allocate = .alloc_always }) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const action_str = switch (obj.get("action") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const Action = enum { msg, start, result };
        switch (std.meta.stringToEnum(Action, action_str) orelse continue) {
            .msg => {
                const v = obj.get("msg") orelse continue;
                if (v == .string) disp.push(v.string);
            },
            .start => {
                capture: {
                    const typ = obj.get("type") orelse break :capture;
                    if (typ != .integer or typ.integer != 104) break :capture;
                    const id = obj.get("id") orelse break :capture;
                    if (id == .integer) builds_id = id.integer;
                }
                // level <= 4: cache copies (3) and downloads/evaluations (4); 5+ is per-file noise
                const level = obj.get("level") orelse continue;
                if (level != .integer or level.integer > 4) continue;
                const text = obj.get("text") orelse continue;
                if (text == .string and text.string.len > 0) disp.push(text.string);
            },
            .result => {
                const typ = obj.get("type") orelse continue;
                if (typ != .integer or typ.integer != 105) continue;
                const id = obj.get("id") orelse continue;
                if (id != .integer or id.integer != builds_id) continue;
                const fields = obj.get("fields") orelse continue;
                if (fields != .array) continue;
                const arr = fields.array.items;
                if (arr.len < 3) continue;
                if (arr[0] == .integer and arr[0].integer >= 0) done = @intCast(arr[0].integer);
                if (arr[1] == .integer and arr[1].integer >= 0) expected = @intCast(arr[1].integer);
                if (arr[2] == .integer and arr[2].integer >= 0) running = @intCast(arr[2].integer);
                if (expected > 0) disp.update(done, running, expected);
            },
        }
    }
}

/// Runs `nix build <flake>#nixosConfigurations.<hostname>.config.system.build.toplevel`,
/// streaming a 6-line TUI (5 recent log messages + progress bar) to stderr,
/// and returns the resulting store path.
/// Caller owns the returned slice and must free it with `gpa`.
/// Expects the caller to have already printed a trailing newline so the TUI
/// can expand below the current line.
pub fn buildSystem(gpa: std.mem.Allocator, io: std.Io, flake_ref: []const u8, hostname: []const u8) ![]u8 {
    const installable = try std.fmt.allocPrint(
        gpa,
        "{s}#nixosConfigurations.{s}.config.system.build.toplevel",
        .{ flake_ref, hostname },
    );
    defer gpa.free(installable);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "nix", "build", installable, "--no-link", "--print-out-paths", "--log-format", "internal-json" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer {
        if (child.stderr) |f| f.close(io);
        child.stderr = null;
        if (child.stdout) |f| f.close(io);
        child.stdout = null;
        child.kill(io);
    }

    var stderr_buf: [65536]u8 = undefined;
    var stderr_reader = child.stderr.?.readerStreaming(io, &stderr_buf);
    var stderr_log: std.ArrayList(u8) = .empty;
    defer stderr_log.deinit(gpa);
    var disp: progress.Display = .{};

    try streamBuildStderr(gpa, &stderr_reader.interface, &disp, &stderr_log);
    disp.clear();

    child.stderr.?.close(io);
    child.stderr = null;

    // Read stdout (the store path)
    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buf);
    var store_path: std.ArrayList(u8) = .empty;
    errdefer store_path.deinit(gpa);
    try stdout_reader.interface.appendRemainingUnlimited(gpa, &store_path);

    child.stdout.?.close(io);
    child.stdout = null;

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print(ansi.red ++ "nix build failed" ++ ansi.reset ++ " for '{s}':\n{s}\n", .{ hostname, stderr_log.items });
            return error.NixFailed;
        },
        else => {
            std.debug.print(ansi.red ++ "nix build terminated unexpectedly" ++ ansi.reset ++ " for '{s}'\n", .{hostname});
            return error.NixFailed;
        },
    }

    return store_path.toOwnedSlice(gpa);
}
