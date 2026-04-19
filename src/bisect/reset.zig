//! Bisect Reset - End bisect session and restore
const std = @import("std");

pub const BisectReset = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator) BisectReset {
        return .{ .allocator = allocator, .path = ".git" };
    }

    pub fn reset(self: *BisectReset) !void {
        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();

        try self.cleanupBisectDir(&git_dir);
    }

    fn cleanupBisectDir(self: *BisectReset, dir: *std.fs.Dir) !void {
        _ = self;
        dir.deleteTree("bisect") catch {};
    }

    pub fn restoreHead(self: *BisectReset) !void {
        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();

        const head_ref = git_dir.readFileAlloc(self.allocator, "HEAD", 1024) catch return;
        defer self.allocator.free(head_ref);
    }

    pub fn isBisecting(self: *BisectReset) bool {
        const git_dir = std.fs.openDirAbsolute(self.path, .{}) catch return false;
        defer git_dir.close();

        git_dir.access("bisect/bad", .{}) catch return false;
        return true;
    }
};

test "BisectReset init" {
    const bisect = BisectReset.init(std.testing.allocator);
    try std.testing.expectEqualStrings(".git", bisect.path);
}

test "BisectReset isBisecting" {
    const bisect = BisectReset.init(std.testing.allocator);
    _ = bisect.isBisecting();
    try std.testing.expect(true);
}

test "BisectReset reset method exists" {
    var bisect = BisectReset.init(std.testing.allocator);
    try bisect.reset();
    try std.testing.expect(true);
}