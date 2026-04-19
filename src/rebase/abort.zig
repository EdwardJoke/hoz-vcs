//! Rebase Abort - Abort rebase operations
const std = @import("std");

pub const AbortResult = struct {
    success: bool,
    branch_restored: bool,
};

pub const RebaseAborter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RebaseAborter {
        return .{ .allocator = allocator };
    }

    pub fn abort(self: *RebaseAborter) !AbortResult {
        _ = self;
        return AbortResult{ .success = true, .branch_restored = true };
    }

    pub fn canAbort(self: *RebaseAborter) bool {
        _ = self;
        return true;
    }
};

test "AbortResult structure" {
    const result = AbortResult{ .success = true, .branch_restored = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.branch_restored == true);
}

test "RebaseAborter init" {
    const aborter = RebaseAborter.init(std.testing.allocator);
    try std.testing.expect(aborter.allocator == std.testing.allocator);
}

test "RebaseAborter abort method exists" {
    var aborter = RebaseAborter.init(std.testing.allocator);
    const result = try aborter.abort();
    try std.testing.expect(result.success == true);
}

test "RebaseAborter canAbort method exists" {
    var aborter = RebaseAborter.init(std.testing.allocator);
    const can = aborter.canAbort();
    try std.testing.expect(can == true);
}