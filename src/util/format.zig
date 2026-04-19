//! Output formatting for Hoz VCS
//!
//! Provides standardized terminal output formatting with consistent
//! color schemes, symbols, and styling across all commands.

const std = @import("std");
const Io = std.Io;

pub const Formatter = struct {
    writer: *Io.Writer,
    use_color: bool,

    pub const Color = struct {
        pub const reset = "\x1b[0m";
        pub const bold = "\x1b[1m";
        pub const dim = "\x1b[2m";

        pub const red = "\x1b[31m";
        pub const green = "\x1b[32m";
        pub const yellow = "\x1b[33m";
        pub const blue = "\x1b[34m";
        pub const magenta = "\x1b[35m";
        pub const cyan = "\x1b[36m";

        pub const bright_red = "\x1b[91m";
        pub const bright_green = "\x1b[92m";
        pub const bright_yellow = "\x1b[93m";
        pub const bright_blue = "\x1b[94m";
        pub const bright_magenta = "\x1b[95m";
        pub const bright_cyan = "\x1b[96m";
    };

    pub const Symbol = struct {
        pub const check = "\x1b[32m✓\x1b[0m";
        pub const cross = "\x1b[31m✗\x1b[0m";
        pub const info = "\x1b[34mℹ\x1b[0m";
        pub const warn = "\x1b[33m⚠\x1b[0m";
        pub const arrow = "\x1b[36m→\x1b[0m";
        pub const bullet = "\x1b[36m•\x1b[0m";
    };

    pub fn init(writer: *Io.Writer, use_color: bool) Formatter {
        return .{ .writer = writer, .use_color = use_color };
    }

    pub fn color(self: Formatter, code: []const u8) []const u8 {
        if (!self.use_color) return "";
        return code;
    }

    pub fn colored(self: Formatter, text: []const u8, color_code: []const u8) !void {
        try self.writer.print("{s}{s}{s}", .{
            self.color(color_code),
            text,
            self.color(Color.reset),
        });
    }

    pub fn header(self: Formatter, text: []const u8) !void {
        try self.writer.print("\n{s}{s}{s}\n", .{
            self.color(Color.bold),
            text,
            self.color(Color.reset),
        });
    }

    pub fn subheader(self: Formatter, text: []const u8) !void {
        try self.writer.print("\n{s}{s}{s}\n", .{
            self.color(Color.cyan),
            text,
            self.color(Color.reset),
        });
    }

    pub fn success(self: Formatter, message: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}\n", .{
            self.color(Color.green),
            Symbol.check,
            self.color(Color.reset),
            message,
        });
    }

    pub fn err(self: Formatter, message: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}\n", .{
            self.color(Color.red),
            Symbol.cross,
            self.color(Color.reset),
            message,
        });
    }

    pub fn warning(self: Formatter, message: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}\n", .{
            self.color(Color.yellow),
            Symbol.warn,
            self.color(Color.reset),
            message,
        });
    }

    pub fn info(self: Formatter, message: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}\n", .{
            self.color(Color.blue),
            Symbol.info,
            self.color(Color.reset),
            message,
        });
    }

    pub fn plain(self: Formatter, message: []const u8) !void {
        try self.writer.print("{s}\n", .{message});
    }

    pub fn keyValue(self: Formatter, key: []const u8, val: []const u8) !void {
        try self.writer.print("  {s}{s}{s}: {s}\n", .{
            self.color(Color.dim),
            key,
            self.color(Color.reset),
            val,
        });
    }

    pub fn branch(self: Formatter, name: []const u8, current: bool) !void {
        if (current) {
            try self.writer.print("{s} {s}{s}{s} (current)\n", .{
                self.color(Color.green),
                self.color(Color.bold),
                name,
                self.color(Color.reset),
            });
        } else {
            try self.writer.print("  {s}\n", .{name});
        }
    }

    pub fn statusLine(self: Formatter, index_status: []const u8, worktree_status: []const u8, path: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}{s}{s} {s}\n", .{
            self.color(Color.red),
            index_status,
            self.color(Color.reset),
            self.color(Color.green),
            worktree_status,
            self.color(Color.reset),
            path,
        });
    }

    pub fn commitHash(self: Formatter, hash: []const u8, message: []const u8) !void {
        try self.writer.print("{s}{s}{s} {s}\n", .{
            self.color(Color.yellow),
            hash,
            self.color(Color.reset),
            message,
        });
    }

    pub fn diffLine(self: Formatter, prefix: []const u8, content: []const u8) !void {
        const color_code: []const u8 = switch (prefix[0]) {
            '+' => Color.green,
            '-' => Color.red,
            '@' => Color.magenta,
            else => Color.reset,
        };
        try self.writer.print("{s}{s}{s}{s}\n", .{
            self.color(color_code),
            prefix,
            self.color(Color.reset),
            content,
        });
    }

    pub fn helpCommand(self: Formatter, cmd: []const u8, desc: []const u8) !void {
        try self.writer.print("  {s}{s}{s}", .{
            self.color(Color.cyan),
            cmd,
            self.color(Color.reset),
        });
        const spaces = 14 - cmd.len;
        var i: usize = 0;
        while (i < spaces) : (i += 1) {
            try self.writer.print(" ", .{});
        }
        try self.writer.print("{s}\n", .{desc});
    }

    pub fn label(self: Formatter, text: []const u8) !void {
        try self.writer.print("{s}[{s}{s}{s}]{s} ", .{
            self.color(Color.dim),
            self.color(Color.bold),
            text,
            self.color(Color.dim),
            self.color(Color.reset),
        });
    }

    pub fn value(self: Formatter, text: []const u8) !void {
        try self.writer.print("{s}\n", .{text});
    }
};

test "Formatter.header prints with bold" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream.init(&buf);
    const writer = fbs.writer();

    var formatter = Formatter.init(&writer.interface, true);
    try formatter.header("Test Header");

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Test Header") != null);
}

test "Formatter.success prints with symbol" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream.init(&buf);
    const writer = fbs.writer();

    var formatter = Formatter.init(&writer.interface, true);
    try formatter.success("Operation completed");

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Operation completed") != null);
}

test "Formatter.helpCommand aligns columns" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream.init(&buf);
    const writer = fbs.writer();

    var formatter = Formatter.init(&writer.interface, true);
    try formatter.helpCommand("status", "Show working tree status");

    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Show working tree status") != null);
}
