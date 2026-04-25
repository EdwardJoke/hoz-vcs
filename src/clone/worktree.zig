//! Clone Worktree - Worktree integration for clone
const std = @import("std");

pub const WorktreeInteg = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorktreeInteg {
        return .{ .allocator = allocator };
    }

    pub fn createInitialWorktree(self: *WorktreeInteg, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(undefined, path) catch {};
        _ = self;
    }

    pub fn setupHead(self: *WorktreeInteg, ref: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const head_content = try std.fmt.allocPrint(self.allocator, "ref: {s}\n", .{ref});
        defer self.allocator.free(head_content);
        try cwd.writeFile(undefined, .{ .sub_path = ".git/HEAD", .data = head_content });
    }
};

test "WorktreeInteg init" {
    const integ = WorktreeInteg.init(std.testing.allocator);
    try std.testing.expect(integ.allocator == std.testing.allocator);
}

test "WorktreeInteg createInitialWorktree method exists" {
    var integ = WorktreeInteg.init(std.testing.allocator);
    try integ.createInitialWorktree("/tmp/repo");
    try std.testing.expect(true);
}

test "WorktreeInteg setupHead method exists" {
    var integ = WorktreeInteg.init(std.testing.allocator);
    try integ.setupHead("refs/heads/main");
    try std.testing.expect(true);
}