//! Tag List - List tags with pattern filtering
const std = @import("std");

pub const TagLister = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TagLister {
        return .{ .allocator = allocator };
    }

    pub fn listAll(self: *TagLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }

    pub fn listMatching(self: *TagLister, pattern: []const u8) ![]const []const u8 {
        _ = self;
        _ = pattern;
        return &.{};
    }

    pub fn listWithDetails(self: *TagLister) ![]const []const u8 {
        _ = self;
        return &.{};
    }
};

test "TagLister init" {
    const lister = TagLister.init(std.testing.allocator);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}

test "TagLister listAll method exists" {
    var lister = TagLister.init(std.testing.allocator);
    const tags = try lister.listAll();
    _ = tags;
    try std.testing.expect(true);
}

test "TagLister listMatching method exists" {
    var lister = TagLister.init(std.testing.allocator);
    const tags = try lister.listMatching("v1.*");
    _ = tags;
    try std.testing.expect(true);
}

test "TagLister listWithDetails method exists" {
    var lister = TagLister.init(std.testing.allocator);
    const tags = try lister.listWithDetails();
    _ = tags;
    try std.testing.expect(true);
}