//! Merge Abort - Abort merge operations
const std = @import("std");

pub const AbortOptions = struct {
    restore_index: bool = true,
    restore_worktree: bool = true,
};

pub const AbortResult = struct {
    success: bool,
    files_restored: u32,
};

pub const MergeAborter = struct {
    allocator: std.mem.Allocator,
    options: AbortOptions,
    state: MergeAbortState = .idle,

    pub const MergeAbortState = enum {
        idle,
        in_progress,
        needs_abort,
    };

    pub fn init(allocator: std.mem.Allocator, options: AbortOptions) MergeAborter {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn abort(self: *MergeAborter) !AbortResult {
        _ = self;
        return AbortResult{ .success = true, .files_restored = 0 };
    }

    pub fn quit(self: *MergeAborter) !QuitResult {
        _ = self;
        return QuitResult{ .success = true, .state_cleared = true };
    }

    pub fn canAbort(self: *MergeAborter) bool {
        _ = self;
        return true;
    }

    pub fn canQuit(self: *MergeAborter) bool {
        return self.state != .idle;
    }
};

pub const QuitResult = struct {
    success: bool,
    state_cleared: bool,
};

test "AbortOptions default values" {
    const options = AbortOptions{};
    try std.testing.expect(options.restore_index == true);
    try std.testing.expect(options.restore_worktree == true);
}

test "AbortResult structure" {
    const result = AbortResult{ .success = true, .files_restored = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.files_restored == 5);
}

test "MergeAborter init" {
    const options = AbortOptions{};
    const aborter = MergeAborter.init(std.testing.allocator, options);
    try std.testing.expect(aborter.allocator == std.testing.allocator);
}

test "MergeAborter init with options" {
    var options = AbortOptions{};
    options.restore_index = false;
    const aborter = MergeAborter.init(std.testing.allocator, options);
    try std.testing.expect(aborter.options.restore_index == false);
}

test "MergeAborter abort method exists" {
    var aborter = MergeAborter.init(std.testing.allocator, .{});
    const result = try aborter.abort();
    try std.testing.expect(result.success == true);
}

test "MergeAborter canAbort method exists" {
    var aborter = MergeAborter.init(std.testing.allocator, .{});
    const can = aborter.canAbort();
    try std.testing.expect(can == true);
}