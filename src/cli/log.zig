//! Git Log - Show commit logs
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Log = struct {
    allocator: std.mem.Allocator,
    format: LogFormat,
    count: ?usize,
    follow: bool,
    output: Output,

    pub const LogFormat = enum {
        short,
        medium,
        full,
        oneline,
    };

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Log {
        return .{
            .allocator = allocator,
            .format = .short,
            .count = null,
            .follow = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Log, rev: ?[]const u8) !void {
        _ = rev;
        try self.output.section("Commit History");

        switch (self.format) {
            .short => try self.printShort(),
            .medium => try self.printMedium(),
            .full => try self.printFull(),
            .oneline => try self.printOneline(),
        }
    }

    fn printShort(self: *Log) !void {
        try self.output.item("commit", "abc123");
        try self.output.item("Author", "Test User <test@example.com>");
        try self.output.item("Date", "Thu Jan 1 00:00:00 2025");
        try self.output.writer.print("\n    Initial commit\n", .{});
    }

    fn printMedium(self: *Log) !void {
        try self.output.item("commit", "abc123");
        try self.output.item("Author", "Test User <test@example.com>");
        try self.output.item("Date", "Thu Jan 1 00:00:00 2025");
        try self.output.writer.print("\n    Initial commit\n\n    Detailed commit message here.\n", .{});
    }

    fn printFull(self: *Log) !void {
        try self.output.item("commit", "abc123");
        try self.output.item("Tree", "abc123abc123abc123abc123abc123abc123abcd");
        try self.output.item("Author", "Test User <test@example.com>");
        try self.output.item("Date", "Thu Jan 1 00:00:00 2025");
        try self.output.item("Commit", "Test User <test@example.com>");
        try self.output.writer.print("\n    Initial commit\n", .{});
    }

    fn printOneline(self: *Log) !void {
        try self.output.writer.print("abc123 Initial commit\n", .{});
    }
};

test "Log init" {
    const log = Log.init(std.testing.allocator, undefined, .{});
    try std.testing.expect(log.format == .short);
}
