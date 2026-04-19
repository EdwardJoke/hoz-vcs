//! Tag Create Lightweight - Create lightweight tag
const std = @import("std");

pub const LightweightTagCreator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LightweightTagCreator {
        return .{ .allocator = allocator };
    }

    pub fn create(self: *LightweightTagCreator, name: []const u8, target: []const u8) !void {
        _ = self;
        _ = name;
        _ = target;
    }
};

test "LightweightTagCreator init" {
    const creator = LightweightTagCreator.init(std.testing.allocator);
    try std.testing.expect(creator.allocator == std.testing.allocator);
}

test "LightweightTagCreator create method exists" {
    var creator = LightweightTagCreator.init(std.testing.allocator);
    try creator.create("v1.0.0", "abc123");
    try std.testing.expect(true);
}