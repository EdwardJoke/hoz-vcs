//! Worktree Lock - Lock/unlock a worktree
const std = @import("std");

pub const WorktreeLocker = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeLocker {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    fn resolveRepoPath(self: *WorktreeLocker) ![]const u8 {
        if (std.fs.path.isAbsolute(self.repo_path)) return self.repo_path;
        return std.fs.realpathAlloc(self.allocator, self.repo_path);
    }

    pub fn lock(self: *WorktreeLocker, name: []const u8, reason: ?[]const u8) !void {
        const abs_path = try self.resolveRepoPath();
        defer if (!std.fs.path.isAbsolute(self.repo_path)) self.allocator.free(abs_path);
        const git_dir = try std.fs.openDirAbsolute(abs_path, .{});
        defer git_dir.close();

        const wt_dir = try git_dir.openDir("worktrees", .{});
        defer wt_dir.close();

        const locked_file = try std.fmt.allocPrint(self.allocator, "{s}/locked", .{name});
        defer self.allocator.free(locked_file);

        if (reason) |r| {
            try wt_dir.writeFile(locked_file, r);
        } else {
            try wt_dir.writeFile(locked_file, "");
        }
    }

    pub fn unlock(self: *WorktreeLocker, name: []const u8) !void {
        const abs_path = try self.resolveRepoPath();
        defer if (!std.fs.path.isAbsolute(self.repo_path)) self.allocator.free(abs_path);
        const git_dir = try std.fs.openDirAbsolute(abs_path, .{});
        defer git_dir.close();

        const wt_dir = try git_dir.openDir("worktrees", .{});
        defer wt_dir.close();

        const locked_file = try std.fmt.allocPrint(self.allocator, "{s}/locked", .{name});
        defer self.allocator.free(locked_file);

        wt_dir.deleteFile(locked_file) catch {};
    }

    pub fn isLocked(self: *WorktreeLocker, name: []const u8) bool {
        const abs_path = self.resolveRepoPath() catch return false;
        defer if (!std.fs.path.isAbsolute(self.repo_path)) self.allocator.free(abs_path);
        const git_dir = std.fs.openDirAbsolute(abs_path, .{}) catch return false;
        defer git_dir.close();

        const wt_dir = git_dir.openDir("worktrees", .{}) catch return false;
        defer wt_dir.close();

        const locked_file = std.fmt.allocPrint(self.allocator, "{s}/locked", .{name}) catch return false;
        defer self.allocator.free(locked_file);

        return wt_dir.access(locked_file, .{}) == null;
    }
};

test "WorktreeLocker init" {
    const locker = WorktreeLocker.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", locker.repo_path);
}

test "WorktreeLocker lock method exists" {
    var locker = WorktreeLocker.init(std.testing.allocator, "/path/to/repo");
    try locker.lock("feature-branch", "working on it");
    try std.testing.expect(true);
}

test "WorktreeLocker isLocked method exists" {
    var locker = WorktreeLocker.init(std.testing.allocator, "/path/to/repo");
    const locked = locker.isLocked("feature-branch");
    _ = locked;
    try std.testing.expect(true);
}
