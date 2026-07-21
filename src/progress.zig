const output = @import("./output.zig");
const std = @import("std");

const max_msgs = 5;
const msg_width = 100;

/// Tracks the last MAX_MSGS log messages and renders a 6-line TUI block:
/// 5 scrolling message lines above a [done/running/expected] progress line.
/// The caller must have printed a trailing newline before the first `update`
/// call so the block has a clean line to expand into.
pub const Display = struct {
    out: *output.Output,
    msg_ring: [max_msgs][msg_width]u8 = undefined,
    msg_ring_len: [max_msgs]usize = .{0} ** max_msgs,
    msg_head: usize = 0,
    msg_full: bool = false,
    rendered: bool = false,

    pub fn push(self: *Display, text: []const u8) void {
        const src = text[0..@min(text.len, msg_width)];
        @memcpy(self.msg_ring[self.msg_head][0..src.len], src);
        self.msg_ring_len[self.msg_head] = src.len;
        self.msg_head = (self.msg_head + 1) % max_msgs;
        if (self.msg_head == 0) self.msg_full = true;
    }

    pub fn update(self: *Display, done: u64, running: u64, expected: u64) !void {
        if (self.rendered) self.out.errPrint("\x1b[{d}A\r", .{max_msgs});

        const display_start: usize = if (self.msg_full) self.msg_head else 0;
        const display_count: usize = if (self.msg_full) max_msgs else self.msg_head;
        for (0..max_msgs) |i| {
            if (i < display_count) {
                const slot = (display_start + i) % max_msgs;
                self.out.errPrint("\x1b[2K  {s}\x1b[0m\n", .{self.msg_ring[slot][0..self.msg_ring_len[slot]]});
            } else {
                self.out.errPrint("\x1b[2K\n", .{});
            }
        }
        var done_buf: [20]u8 = undefined;
        var running_buf: [20]u8 = undefined;
        var expected_buf: [20]u8 = undefined;

        self.out.errPrint(
            "\x1b[2K[{f}/{f}/{f}] building...",

            .{
                self.out.green(try std.fmt.bufPrint(&done_buf, "{d}", .{done})),
                self.out.yellow(try std.fmt.bufPrint(&running_buf, "{d}", .{running})),
                self.out.dim(try std.fmt.bufPrint(&expected_buf, "{d}", .{expected})),
            },
        );
        self.rendered = true;
    }

    /// Erase the TUI block, leaving the cursor at the top of where it was.
    pub fn clear(self: *Display) void {
        if (self.rendered) self.out.errPrint("\x1b[{d}A\r\x1b[J", .{max_msgs});
    }
};
