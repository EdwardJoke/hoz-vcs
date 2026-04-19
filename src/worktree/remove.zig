//! Worktree Remove - Remove a worktree
const std = @import("std");

pub const WorktreeRemover = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeRemover {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    pub fn remove(self: *WorktreeRemover, name: []const u8, force: bool) !void {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const wt_dir = try git_dir.openDir("worktrees", .{});
        defer wt_dir.close();

        if (!force) {
            const locked_file = try std.fmt.allocPrint(self.allocator, "{s}/locked", .{name});
            defer self.allocator.free(locked_file);
            if (wt_dir.access(locked_file, .{}) == null) {
                return error.WorktreeLocked;
            }
        }

        try wt_dir.deleteTree(name);
    }

    pub fn cleanupRefs(self: *WorktreeRemover, name: []const u8) !void {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const head = try std.fmt.allocPrint(self.allocator, "refs/remotes/origin/{s}", .{name});
        defer self.allocator.free(head);

        git_dir.deleteTree(head) catch {};
    }
};

test "WorktreeRemover init" {
    const remover = WorktreeRemover.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", remover.repo_path);
}

test "WorktreeRemover remove method exists" {
    var remover = WorktreeRemover.init(std.testing.allocator, "/path/to/repo");
    try remover.remove("feature-branch", false);
    try std.testing.expect(true);
}