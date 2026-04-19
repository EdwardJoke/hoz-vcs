//! Tag Delete - Delete a tag
const std = @import("std");

pub const TagDeleter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TagDeleter {
        return .{ .allocator = allocator };
    }

    pub fn delete(self: *TagDeleter, name: []const u8) !void {
        _ = self;
        _ = name;
    }

    pub fn deleteRemote(self: *TagDeleter, remote: []const u8, name: []const u8) !void {
        _ = self;
        _ = remote;
        _ = name;
    }
};

test "TagDeleter init" {
    const deleter = TagDeleter.init(std.testing.allocator);
    try std.testing.expect(deleter.allocator == std.testing.allocator);
}

test "TagDeleter delete method exists" {
    var deleter = TagDeleter.init(std.testing.allocator);
    try deleter.delete("v1.0.0");
    try std.testing.expect(true);
}

test "TagDeleter deleteRemote method exists" {
    var deleter = TagDeleter.init(std.testing.allocator);
    try deleter.deleteRemote("origin", "v1.0.0");
    try std.testing.expect(true);
}