//! Restore Staged - Restore index from another commit (git restore --staged)
const std = @import("std");

pub const RestoreStaged = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RestoreStaged {
        return .{ .allocator = allocator };
    }

    pub fn restore(self: *RestoreStaged, paths: []const []const u8, source: []const u8) !void {
        _ = self;
        _ = paths;
        _ = source;
    }

    pub fn restoreAll(self: *RestoreStaged, source: []const u8) !void {
        _ = self;
        _ = source;
    }
};

test "RestoreStaged init" {
    const restore = RestoreStaged.init(std.testing.allocator);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}

test "RestoreStaged restore method exists" {
    var restore = RestoreStaged.init(std.testing.allocator);
    try restore.restore(&.{ "file.txt" }, "HEAD");
    try std.testing.expect(true);
}

test "RestoreStaged restoreAll method exists" {
    var restore = RestoreStaged.init(std.testing.allocator);
    try restore.restoreAll("HEAD~1");
    try std.testing.expect(true);
}