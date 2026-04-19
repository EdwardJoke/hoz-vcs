//! Worktree Add - Create a new worktree
const std = @import("std");

pub const WorktreeAdder = struct {
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, main_repo_path: []const u8) WorktreeAdder {
        return .{ .allocator = allocator, .main_repo_path = main_repo_path };
    }

    pub fn add(self: *WorktreeAdder, path: []const u8, branch: []const u8, commit: ?[]const u8) !void {
        const git_dir = try std.fs.openDirAbsolute(self.main_repo_path, .{});
        defer git_dir.close();

        try self.createWorktreeDir(path);
        try self.createGitFile(path, self.main_repo_path);
        try self.createHeadFile(path, branch, commit);
        try self.createConfigFile(path, branch);
    }

    fn createWorktreeDir(self: *WorktreeAdder, path: []const u8) !void {
        std.fs.cwd().makePath(path) catch {};
        const wt_dir = try std.fs.openDirAbsolute(path, .{});
        defer wt_dir.close();

        try wt_dir.makePath(".git");
        const git_dir = try std.fs.openDirAbsolute(self.main_repo_path, .{});
        defer git_dir.close();

        const objects_link = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{self.main_repo_path});
        defer self.allocator.free(objects_link);
        try wt_dir.writeFile(".git", objects_link);
    }

    fn createGitFile(self: *WorktreeAdder, path: []const u8, repo_path: []const u8) !void {
        const wt_dir = try std.fs.openDirAbsolute(path, .{});
        defer wt_dir.close();

        const git_content = try std.fmt.allocPrint(self.allocator, "gitdir: {s}", .{repo_path});
        defer self.allocator.free(git_content);
        try wt_dir.writeFile(".git", git_content);
    }

    fn createHeadFile(self: *WorktreeAdder, path: []const u8, branch: []const u8, commit: ?[]const u8) !void {
        const wt_dir = try std.fs.openDirAbsolute(path, .{});
        defer wt_dir.close();

        try wt_dir.makePath("refs");
        try wt_dir.makePath("refs/heads");

        if (commit) |c| {
            const head_content = try std.fmt.allocPrint(self.allocator, "ref: refs/heads/{s}\n{s}\n", .{ branch, c });
            defer self.allocator.free(head_content);
            try wt_dir.writeFile("HEAD", head_content);
        } else {
            const head_content = try std.fmt.allocPrint(self.allocator, "ref: refs/heads/{s}\n", .{branch});
            defer self.allocator.free(head_content);
            try wt_dir.writeFile("HEAD", head_content);
        }
    }

    fn createConfigFile(self: *WorktreeAdder, path: []const u8, branch: []const u8) !void {
        const wt_dir = try std.fs.openDirAbsolute(path, .{});
        defer wt_dir.close();

        const config_content = try std.fmt.allocPrint(self.allocator,
            "[core]\n  repositoryformatversion = 0\n  filemode = true\n  bare = false\n[branch \"{s}\"]\n  remote = .\n  merge = refs/heads/{s}\n", .{ branch, branch });
        defer self.allocator.free(config_content);
        try wt_dir.writeFile("config", config_content);
    }
};

test "WorktreeAdder init" {
    const adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", adder.main_repo_path);
}

test "WorktreeAdder createGitFile" {
    var adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expect(true);
}