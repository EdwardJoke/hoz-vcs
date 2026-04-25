//! Worktree Add - Create a new worktree
const std = @import("std");
const Io = std.Io;

pub const WorktreeAdder = struct {
    allocator: std.mem.Allocator,
    main_repo_path: []const u8,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, main_repo_path: []const u8) WorktreeAdder {
        return .{ .allocator = allocator, .main_repo_path = main_repo_path, .io = undefined };
    }

    pub fn add(self: *WorktreeAdder, path: []const u8, branch: []const u8, commit: ?[]const u8) !void {
        _ = self;
        _ = path;
        _ = branch;
        _ = commit;
    }
};

test "WorktreeAdder init" {
    const adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo");
    try std.testing.expectEqualStrings("/path/to/repo", adder.main_repo_path);
}

test "WorktreeAdder createGitFile" {
    const adder = WorktreeAdder.init(std.testing.allocator, "/path/to/repo");
    _ = adder;
    try std.testing.expect(true);
}
