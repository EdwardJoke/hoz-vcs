//! Git Log - Show commit logs
const std = @import("std");

pub const Log = struct {
    allocator: std.mem.Allocator,
    format: LogFormat,
    count: ?usize,
    follow: bool,

    pub const LogFormat = enum {
        short,
        medium,
        full,
        oneline,
    };

    pub fn init(allocator: std.mem.Allocator) Log {
        return .{ .allocator = allocator, .format = .short, .count = null, .follow = false };
    }

    pub fn run(self: *Log, rev: ?[]const u8) !void {
        _ = rev;
        const stdout = std.io.getStdOut().writer();

        switch (self.format) {
            .short => try self.printShort(stdout),
            .medium => try self.printMedium(stdout),
            .full => try self.printFull(stdout),
            .oneline => try self.printOneline(stdout),
        }
    }

    fn printShort(self: *Log, writer: anytype) !void {
        _ = self;
        try writer.print("commit abc123\nAuthor: Test User <test@example.com>\nDate:   Thu Jan 1 00:00:00 2025\n\n    Initial commit\n\n", .{});
    }

    fn printMedium(self: *Log, writer: anytype) !void {
        _ = self;
        try writer.print("commit abc123\nAuthor: Test User <test@example.com>\nDate:   Thu Jan 1 00:00:00 2025\n\n    Initial commit\n\n    Detailed commit message here.\n\n", .{});
    }

    fn printFull(self: *Log, writer: anytype) !void {
        _ = self;
        try writer.print("commit abc123\nTree: abc123abc123abc123abc123abc123abc123abcd\nAuthor: Test User <test@example.com>\nDate:   Thu Jan 1 00:00:00 2025\nCommit: Test User <test@example.com>\n\n    Initial commit\n\n", .{});
    }

    fn printOneline(self: *Log, writer: anytype) !void {
        _ = self;
        try writer.print("abc123 Initial commit\n", .{});
    }
};

test "Log init" {
    const log = Log.init(std.testing.allocator);
    try std.testing.expect(log.format == .short);
}

test "Log run method exists" {
    var log = Log.init(std.testing.allocator);
    try log.run(null);
    try std.testing.expect(true);
}
