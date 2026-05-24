const std = @import("std");

const MAX_MSGS = 5;
const MSG_WIDTH = 100;

/// Tracks the last MAX_MSGS log messages and renders a 6-line TUI block:
/// 5 scrolling message lines above a [done/running/expected] progress line.
/// The caller must have printed a trailing newline before the first `update`
/// call so the block has a clean line to expand into.
pub const Display = struct {
    msg_ring: [MAX_MSGS][MSG_WIDTH]u8 = undefined,
    msg_ring_len: [MAX_MSGS]usize = .{0} ** MAX_MSGS,
    msg_head: usize = 0,
    msg_full: bool = false,
    rendered: bool = false,

    pub fn push(self: *Display, text: []const u8) void {
        const src = text[0..@min(text.len, MSG_WIDTH)];
        @memcpy(self.msg_ring[self.msg_head][0..src.len], src);
        self.msg_ring_len[self.msg_head] = src.len;
        self.msg_head = (self.msg_head + 1) % MAX_MSGS;
        if (self.msg_head == 0) self.msg_full = true;
    }

    pub fn update(self: *Display, done: u64, running: u64, expected: u64) void {
        if (self.rendered) std.debug.print("\x1b[{d}A\r", .{MAX_MSGS});

        const display_start: usize = if (self.msg_full) self.msg_head else 0;
        const display_count: usize = if (self.msg_full) MAX_MSGS else self.msg_head;
        for (0..MAX_MSGS) |i| {
            if (i < display_count) {
                const slot = (display_start + i) % MAX_MSGS;
                std.debug.print("\x1b[2K  {s}\x1b[0m\n", .{self.msg_ring[slot][0..self.msg_ring_len[slot]]});
            } else {
                std.debug.print("\x1b[2K\n", .{});
            }
        }
        std.debug.print("\x1b[2K[{d}/{d}/{d}] building...", .{ done, running, expected });
        self.rendered = true;
    }

    /// Erase the TUI block, leaving the cursor at the top of where it was.
    pub fn clear(self: *Display) void {
        if (self.rendered) std.debug.print("\x1b[{d}A\r\x1b[J", .{MAX_MSGS});
    }
};
