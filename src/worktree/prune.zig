//! Worktree Prune - Remove stale worktree references
const std = @import("std");

pub const WorktreePruner = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreePruner {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    pub fn prune(self: *WorktreePruner) !void {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const worktrees_dir = git_dir.openDir("worktrees", .{} catch |_| return);
        defer worktrees_dir.close();

        var iter = worktrees_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                try self.pruneWorktree(entry.name, &worktrees_dir);
            }
        }
    }

    fn pruneWorktree(self: *WorktreePruner, name: []const u8, dir: *std.fs.Dir) !void {
        _ = self;
        const wt_dir = dir.openDir(name, .{});
        if (wt_dir) |d| {
            defer d.close();
            const head = d.readFileAlloc(self.allocator, "head", 64) catch {
                try dir.deleteTree(name);
                return;
            };
            defer self.allocator.free(head);

            if (head.len == 0) {
                try dir.deleteTree(name);
            }
        } else |_| {
            try dir.deleteTree(name);
        }
    }

    pub fn isPrunable(self: *WorktreePruner, name: []const u8) !bool {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const wt_dir = try git_dir.openDir("worktrees", .{});
        defer wt_dir.close();

        const head = wt_dir.readFileAlloc(self.allocator, name ++ "/head", 64) catch return true;
        defer self.allocator.free(head);

        return head.len == 0;
    }
};

test "WorktreePruner init" {
    const pruner = WorktreePruner.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", pruner.repo_path);
}

test "WorktreePruner prune method exists" {
    var pruner = WorktreePruner.init(std.testing.allocator, "/path/to/repo");
    try pruner.prune();
    try std.testing.expect(true);
}