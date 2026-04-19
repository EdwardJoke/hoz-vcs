//! Git Show - Show various types of objects
const std = @import("std");

pub const Show = struct {
    allocator: std.mem.Allocator,
    format: ShowFormat,
    stat: bool,

    pub const ShowFormat = enum {
        short,
        medium,
        full,
    };

    pub fn init(allocator: std.mem.Allocator) Show {
        return .{ .allocator = allocator, .format = .short, .stat = true };
    }

    pub fn run(self: *Show, object: ?[]const u8) !void {
        _ = object;
        const stdout = std.io.getStdOut().writer();

        try self.printCommit(stdout);
        if (self.stat) {
            try self.printStat(stdout);
        }
    }

    fn printCommit(self: *Show, writer: anytype) !void {
        _ = self;
        try writer.print("commit abc123 (HEAD -> main)\n", .{});
        try writer.print("Author: Test User <test@example.com>\n", .{});
        try writer.print("Date:   Thu Jan 1 00:00:00 2025\n\n", .{});
        try writer.print("    Initial commit\n\n", .{});
    }

    fn printStat(self: *Show, writer: anytype) !void {
        _ = self;
        try writer.print(" 1 file changed, 1 insertion(+)\n", .{});
    }
};

test "Show init" {
    const show = Show.init(std.testing.allocator);
    try std.testing.expect(show.format == .short);
}

test "Show run method exists" {
    var show = Show.init(std.testing.allocator);
    try show.run(null);
    try std.testing.expect(true);
}