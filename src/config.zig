const std = @import("std");
const nix = @import("./nix.zig");

pub const HostConfig = struct {
    targetHost: []const u8,
    targetUser: []const u8 = "root",
    targetPort: u16 = 22,
};

pub const Config = struct {
    hosts: std.json.ArrayHashMap(HostConfig),
};

/// Evaluates `<flake_ref>#kirikae` and parses the result into a `Config`.
/// Call `.deinit()` on the returned value to free all memory.
pub fn load(gpa: std.mem.Allocator, io: std.Io, flake_ref: []const u8) !std.json.Parsed(Config) {
    const json = try nix.evalJson(gpa, io, flake_ref, "kirikae");
    defer gpa.free(json);

    return std.json.parseFromSlice(Config, gpa, json, .{
        .ignore_unknown_fields = true,
        // alloc_always copies all strings into the arena so we can safely
        // free the raw json slice above before returning.
        .allocate = .alloc_always,
    });
}

/// Returns true if `host_name` should be included given `filter` and `exclude`.
/// Both are comma-separated glob pattern lists; `*` is the only wildcard.
/// A null `filter` matches all hosts. A null `exclude` excludes none.
/// `exclude` takes precedence: a host matching both is excluded.
pub fn matchesFilter(host_name: []const u8, filter: ?[]const u8, exclude: ?[]const u8) bool {
    if (exclude) |ex| {
        var it = std.mem.splitScalar(u8, ex, ',');
        while (it.next()) |pattern| {
            if (globMatch(std.mem.trim(u8, pattern, " "), host_name)) return false;
        }
    }
    const f = filter orelse return true;
    var it = std.mem.splitScalar(u8, f, ',');
    while (it.next()) |pattern| {
        if (globMatch(std.mem.trim(u8, pattern, " "), host_name)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, str: []const u8) bool {
    const star = std.mem.indexOf(u8, pattern, "*") orelse {
        return std.mem.eql(u8, pattern, str);
    };
    const prefix = pattern[0..star];
    const rest = pattern[star + 1 ..];
    if (!std.mem.startsWith(u8, str, prefix)) return false;
    // recurse to handle multiple wildcards
    if (rest.len == 0) return true;
    var i = prefix.len;
    while (i <= str.len) : (i += 1) {
        if (globMatch(rest, str[i..])) return true;
    }
    return false;
}

test "matchesFilter" {
    try std.testing.expect(matchesFilter("webserver", null, null));
    try std.testing.expect(matchesFilter("webserver", "webserver", null));
    try std.testing.expect(!matchesFilter("webserver", "database", null));
    try std.testing.expect(matchesFilter("webserver", "web*", null));
    try std.testing.expect(matchesFilter("webserver", "*server", null));
    try std.testing.expect(matchesFilter("webserver", "*", null));
    try std.testing.expect(matchesFilter("database", "webserver,database", null));
    try std.testing.expect(!matchesFilter("bastion", "webserver,database", null));
    try std.testing.expect(matchesFilter("web-01", "web-*,db-*", null));
    // exclude takes precedence
    try std.testing.expect(!matchesFilter("webserver", null, "webserver"));
    try std.testing.expect(!matchesFilter("webserver", "*", "web*"));
    try std.testing.expect(matchesFilter("database", "*", "web*"));
    try std.testing.expect(!matchesFilter("web-01", "web-*", "web-01"));
}
