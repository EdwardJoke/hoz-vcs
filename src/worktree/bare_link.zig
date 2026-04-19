//! Worktree Bare Link - Create bare repository linking
const std = @import("std");

pub const WorktreeBareLinker = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeBareLinker {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    pub fn link(self: *WorktreeBareLinker, worktree_path: []const u8) !void {
        const git_dir = try std.fs.openDirAbsolute(self.repo_path, .{});
        defer git_dir.close();

        const wt_dir = try std.fs.openDirAbsolute(worktree_path, .{});
        defer wt_dir.close();

        try self.createObjectLink(&wt_dir);
        try self.createRefLink(&wt_dir);
    }

    fn createObjectLink(self: *WorktreeBareLinker, wt_dir: *std.fs.Dir) !void {
        _ = self;
        const objects_path = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{self.repo_path});
        defer self.allocator.free(objects_path);
        try wt_dir.writeFile(".git/objects", objects_path);
    }

    fn createRefLink(self: *WorktreeBareLinker, wt_dir: *std.fs.Dir) !void {
        _ = self;
        const refs_path = try std.fmt.allocPrint(self.allocator, "{s}/refs", .{self.repo_path});
        defer self.allocator.free(refs_path);
        try wt_dir.writeFile(".git/refs", refs_path);
    }

    pub fn isLinked(self: *WorktreeBareLinker, worktree_path: []const u8) bool {
        const wt_dir = std.fs.openDirAbsolute(worktree_path, .{}) catch return false;
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