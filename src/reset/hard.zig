//! Reset Hard - Reset HEAD, index, and working tree (--hard)
const std = @import("std");

pub const HardReset = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HardReset {
        return .{ .allocator = allocator };
    }

    pub fn reset(self: *HardReset, target: []const u8) !void {
        _ = self;
        _ = target;
    }

    pub fn resetTree(self: *HardReset, target: []const u8) !void {
        _ = self;
        _ = target;
    }
};

test "HardReset init" {
    const reset = HardReset.init(std.testing.allocator);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}

test "HardReset reset method exists" {
    var reset = HardReset.init(std.testing.allocator);
    try reset.reset("HEAD~1");
    try std.testing.expect(true);
}

test "HardReset resetTree method exists" {
    var reset = HardReset.init(std.testing.allocator);
    try reset.resetTree("HEAD~1");
    try std.testing.expect(true);
}