//! Worktree Bare Link - Create bare repository linking
const std = @import("std");

pub const WorktreeBareLinker = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeBareLinker {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    fn resolvePath(self: *WorktreeBareLinker, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        return std.fs.realpathAlloc(self.allocator, path);
    }

    pub fn link(self: *WorktreeBareLinker, worktree_path: []const u8) !void {
        const abs_repo = try self.resolvePath(self.repo_path);
        defer if (!std.fs.path.isAbsolute(self.repo_path)) self.allocator.free(abs_repo);
        const git_dir = try std.fs.openDirAbsolute(abs_repo, .{});
        defer git_dir.close();

        const abs_wt = try self.resolvePath(worktree_path);
        defer if (!std.fs.path.isAbsolute(worktree_path)) self.allocator.free(abs_wt);
        const wt_dir = try std.fs.openDirAbsolute(abs_wt, .{});
        defer wt_dir.close();

        try self.createObjectLink(&wt_dir);
        try self.createRefLink(&wt_dir);
    }

    fn createObjectLink(self: *WorktreeBareLinker, wt_dir: *std.fs.Dir) !void {
        const objects_path = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{self.repo_path});
        defer self.allocator.free(objects_path);
        try wt_dir.writeFile(".git/objects", objects_path);
    }

    fn createRefLink(self: *WorktreeBareLinker, wt_dir: *std.fs.Dir) !void {
        const refs_path = try std.fmt.allocPrint(self.allocator, "{s}/refs", .{self.repo_path});
        defer self.allocator.free(refs_path);
        try wt_dir.writeFile(".git/refs", refs_path);
    }

    pub fn isLinked(self: *WorktreeBareLinker, worktree_path: []const u8) bool {
        const abs_wt = self.resolvePath(worktree_path) catch return false;
        defer if (!std.fs.path.isAbsolute(worktree_path)) self.allocator.free(abs_wt);
        const wt_dir = std.fs.openDirAbsolute(abs_wt, .{}) catch return false;
        defer wt_dir.close();

        wt_dir.access(".git", .{}) catch return false;
        return true;
    }
};

test "WorktreeBareLinker init" {
    const linker = WorktreeBareLinker.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", linker.repo_path);
}

test "WorktreeBareLinker link method exists" {
    var linker = WorktreeBareLinker.init(std.testing.allocator, "/path/to/repo");
    try linker.link("/path/to/worktree");
    try std.testing.expect(true);
}
