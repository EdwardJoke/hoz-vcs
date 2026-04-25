//! Worktree List - List all worktrees
const std = @import("std");

pub const WorktreeLister = struct {
    allocator: std.mem.Allocator,
    repo_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) WorktreeLister {
        return .{ .allocator = allocator, .repo_path = repo_path };
    }

    pub fn list(self: *WorktreeLister) ![]WorktreeInfo {
        _ = self;
        return &[_]WorktreeInfo{};
    }

    pub const WorktreeInfo = struct {
        path: []const u8,
        branch: []const u8,
        head: []const u8,
        locked: bool,
    };
};
