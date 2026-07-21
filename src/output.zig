const std = @import("std");
const ansi = @import("ansi.zig");

pub const Output = struct {
    out_fw: std.Io.File.Writer = undefined,
    out_buf: [4096]u8 = undefined,

    err_fw: std.Io.File.Writer = undefined,
    err_buf: [4096]u8 = undefined,

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    use_color: bool,

    pub fn init(
        self: *Output,
        io: std.Io,
        use_color: bool,
    ) void {
        self.io = io;
        self.use_color = use_color;
        self.mutex = .init;
        self.out_fw = std.Io.File.stdout().writer(io, &self.out_buf);
        self.err_fw = std.Io.File.stderr().writer(io, &self.err_buf);
    }

    pub fn print(
        self: *Output,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.out_fw.interface.print(fmt, args) catch return;
    }

    pub fn errPrint(
        self: *Output,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.err_fw.interface.print(fmt, args) catch return;
        self.err_fw.interface.flush() catch return;
    }

    pub const Style = enum {
        bold,
        dim,
        red,
        green,
        yellow,
        fn code(s: Style) []const u8 {
            return switch (s) {
                .bold => ansi.bold,
                .dim => ansi.dim,
                .red => ansi.red,
                .green => ansi.green,
                .yellow => ansi.yellow,
            };
        }
    };

    pub const Styled = struct {
        text: []const u8,
        styles: []const Style,
        color: bool,
        // ziglint-ignore: Z012
        pub fn format(self: Styled, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.color) for (self.styles) |s| try w.writeAll(s.code());
            try w.writeAll(self.text);
            if (self.color) try w.writeAll(ansi.reset);
        }
    };

    fn styled(
        self: *const Output,
        styles: []const Style,
        text: []const u8,
    ) Styled {
        return .{ .text = text, .styles = styles, .color = self.use_color };
    }

    pub fn bold(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{.bold}, t);
    }

    pub fn dim(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{.dim}, t);
    }

    pub fn red(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{.red}, t);
    }

    pub fn green(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{.green}, t);
    }

    pub fn yellow(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{.yellow}, t);
    }

    pub fn boldRed(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{ .bold, .red }, t);
    }

    pub fn boldGreen(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{ .bold, .green }, t);
    }

    pub fn boldYellow(
        self: *const Output,
        t: []const u8,
    ) Styled {
        return self.styled(&.{ .bold, .yellow }, t);
    }
};
