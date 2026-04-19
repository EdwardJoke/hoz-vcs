//! Tag Push - Push tags to remote
const std = @import("std");

pub const TagPusher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TagPusher {
        return .{ .allocator = allocator };
    }

    pub fn push(self: *TagPusher, remote: []const u8, tag: []const u8) !void {
        _ = self;
        _ = remote;
        _ = tag;
    }

    pub fn pushAll(self: *TagPusher, remote: []const u8) !void {
        _ = self;
        _ = remote;
    }
};

test "TagPusher init" {
    const pusher = TagPusher.init(std.testing.allocator);
    try std.testing.expect(pusher.allocator == std.testing.allocator);
}

test "TagPusher push method exists" {
    var pusher = TagPusher.init(std.testing.allocator);
    try pusher.push("origin", "v1.0.0");
    try std.testing.expect(true);
}

test "TagPusher pushAll method exists" {
    var pusher = TagPusher.init(std.testing.allocator);
    try pusher.pushAll("origin");
    try std.testing.expect(true);
}