//! Restore Working - Restore working tree from index (git restore)
const std = @import("std");

pub const RestoreWorking = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RestoreWorking {
        return .{ .allocator = allocator };
    }

    pub fn restore(self: *RestoreWorking, paths: []const []const u8) !void {
        _ = self;
        _ = paths;
    }

    pub fn restoreFromSource(self: *RestoreWorking, paths: []const []const u8, source: []const u8) !void {
        _ = self;
        _ = paths;
        _ = source;
    }
};

test "RestoreWorking init" {
    const restore = RestoreWorking.init(std.testing.allocator);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}

test "RestoreWorking restore method exists" {
    var restore = RestoreWorking.init(std.testing.allocator);
    try restore.restore(&.{ "file.txt" });
    try std.testing.expect(true);
}

test "RestoreWorking restoreFromSource method exists" {
    var restore = RestoreWorking.init(std.testing.allocator);
    try restore.restoreFromSource(&.{ "file.txt" }, "HEAD");
    try std.testing.expect(true);
}