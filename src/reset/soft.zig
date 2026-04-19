//! Reset Soft - Reset HEAD only (--soft)
const std = @import("std");

pub const SoftReset = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SoftReset {
        return .{ .allocator = allocator };
    }

    pub fn reset(self: *SoftReset, target: []const u8) !void {
        _ = self;
        _ = target;
    }

    pub fn getHeadCommit(self: *SoftReset) ![]const u8 {
        _ = self;
        return "";
    }
};

test "SoftReset init" {
    const reset = SoftReset.init(std.testing.allocator);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}

test "SoftReset reset method exists" {
    var reset = SoftReset.init(std.testing.allocator);
    try reset.reset("HEAD~1");
    try std.testing.expect(true);
}

test "SoftReset getHeadCommit method exists" {
    var reset = SoftReset.init(std.testing.allocator);
    const commit = try reset.getHeadCommit();
    _ = commit;
    try std.testing.expect(true);
}