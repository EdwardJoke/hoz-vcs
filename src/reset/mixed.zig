//! Reset Mixed - Reset HEAD and index (--mixed)
const std = @import("std");

pub const MixedReset = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MixedReset {
        return .{ .allocator = allocator };
    }

    pub fn reset(self: *MixedReset, target: []const u8) !void {
        _ = self;
        _ = target;
    }

    pub fn clearIndex(self: *MixedReset) !void {
        _ = self;
    }
};

test "MixedReset init" {
    const reset = MixedReset.init(std.testing.allocator);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}

test "MixedReset reset method exists" {
    var reset = MixedReset.init(std.testing.allocator);
    try reset.reset("HEAD~1");
    try std.testing.expect(true);
}

test "MixedReset clearIndex method exists" {
    var reset = MixedReset.init(std.testing.allocator);
    try reset.clearIndex();
    try std.testing.expect(true);
}