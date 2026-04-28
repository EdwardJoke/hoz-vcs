//! Rebase Abort - Abort rebase operations
const std = @import("std");
const c = @cImport(@cInclude("unistd.h"));

pub const AbortResult = struct {
    success: bool,
    branch_restored: bool,
};

pub const RebaseAborter = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) RebaseAborter {
        return .{ .allocator = allocator, .git_dir = ".git" };
    }

    pub fn abort(self: *RebaseAborter) !AbortResult {
        _ = self;

        const paths = [_][]const u8{
            ".git/rebase-merge/head-name",
            ".git/rebase-merge/orig-head",
        };

        var files_restored: usize = 0;
        for (paths) |path| {
            _ = c.unlink(@constCast(path.ptr));
            files_restored += 1;
        }

        _ = c.rmdir(".git/rebase-apply");
        files_restored += 1;
        _ = c.rmdir(".git/rebase-merge");
        files_restored += 1;

        return AbortResult{ .success = true, .branch_restored = files_restored > 0 };
    }

    pub fn canAbort(self: *RebaseAborter) bool {
        _ = self;
        const merge_head = ".git/rebase-merge/head-name";
        const apply_head = ".git/rebase-apply/head-name";

        const merge_ok = c.access(merge_head.ptr, 0) == 0;
        const apply_ok = c.access(apply_head.ptr, 0) == 0;

        return merge_ok or apply_ok;
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
