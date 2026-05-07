//! Bisect Log - Visualize bisect progress
const std = @import("std");
const Io = std.Io;

pub const BisectLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(BisectLogEntry),

    pub const BisectLogEntry = struct {
        commit: []const u8,
        status: []const u8,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) BisectLog {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *BisectLog) void {
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *BisectLog, commit: []const u8, status: []const u8, msg: []const u8) !void {
        try self.entries.append(self.allocator, BisectLogEntry{
            .commit = commit,
            .status = status,
            .message = msg,
        });
    }

    pub fn getEntries(self: *BisectLog) []const BisectLogEntry {
        return self.entries.items;
    }

    pub fn formatLog(self: *BisectLog, writer: anytype) !void {
        for (self.entries.items) |entry| {
            try writer.print("{s} {s}: {s}\n", .{ entry.status, entry.commit, entry.message });
        }
    }
};

test "BisectLog init" {
    const log = BisectLog.init(std.testing.allocator);
    try std.testing.expect(log.entries.items.len == 0);
}

test "BisectLog addEntry" {
    var log = BisectLog.init(std.testing.allocator);
    defer log.deinit();
    try log.addEntry("abc123", "good", "test passed");
    try std.testing.expect(log.entries.items.len == 1);
}

test "BisectLog formatLog" {
    var log = BisectLog.init(std.testing.allocator);
    defer log.deinit();
    try log.addEntry("abc123", "good", "test passed");
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try log.formatLog(&writer.interface);
    const written = writer.interface.getWritten();
    try std.testing.expectEqualStrings("good abc123: test passed\n", written);
}
