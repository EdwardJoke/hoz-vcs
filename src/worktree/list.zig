//! Worktree List - List all worktrees
const std = @import("std");

pub const WorktreeLister = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeLister {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    pub fn list(self: *WorktreeLister) ![]WorktreeInfo {
        var worktrees = std.ArrayList(WorktreeInfo).init(self.allocator);
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const worktrees_dir = git_dir.openDir("worktrees", .{} catch |_| return worktrees.items);
        defer worktrees_dir.close();

        var iter = worktrees_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                const wt_info = try self.getWorktreeInfo(entry.name);
                try worktrees.append(wt_info);
            }
        }
        return worktrees.items;
    }

    pub const WorktreeInfo = struct {
        path: []const u8,
        branch: []const u8,
        head: []const u8,
        locked: bool,
    };

    fn getWorktreeInfo(self: *WorktreeLister, name: []const u8) !WorktreeInfo {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const wt_dir = try git_dir.openDir("worktrees", .{});
        defer wt_dir.close();

        const wt_path_dir = try wt_dir.openDir(name, .{});
        defer wt_path_dir.close();

        var info = WorktreeInfo{
            .path = try std.fmt.allocPrint(self.allocator, "{s}/worktrees/{s}", .{ self.repo_path, name }),
            .branch = try wt_path_dir.readFileAlloc(self.allocator, "head", 1024) catch "",
            .head = "",
            .locked = wt_path_dir.access("locked", .{}) == null,
        };
        return info;
    }
};

test "WorktreeLister init" {
    const lister = WorktreeLister.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", lister.repo_path);
}

test "WorktreeLister list method exists" {
    var lister = WorktreeLister.init(std.testing.allocator, "/path/to/repo");
    const wts = try lister.list();
    _ = wts;
    try std.testing.expect(true);
}