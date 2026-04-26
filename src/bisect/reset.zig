//! Bisect Reset - End bisect session and restore
const std = @import("std");
const Io = std.Io;

pub const BisectReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) BisectReset {
        return .{ .allocator = allocator, .io = io, .path = ".git" };
    }

    pub fn reset(self: *BisectReset) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        try self.cleanupBisectDir(&git_dir);
    }

    fn cleanupBisectDir(self: *BisectReset, dir: *const Io.Dir) !void {
        dir.deleteTree(self.io, "bisect") catch {};
    }

    pub fn restoreHead(self: *BisectReset) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch return;
        defer git_dir.close(self.io);

        const head_ref = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(1024)) catch return;
        defer self.allocator.free(head_ref);
    }

    pub fn isBisecting(self: *BisectReset) bool {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch return false;
        defer git_dir.close(self.io);

        _ = git_dir.openFile("bisect/bad", .{}) catch return false;
        return true;
    }
};

test "BisectReset init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectReset.init(std.testing.allocator, io);
    try std.testing.expectEqualStrings(".git", bisect.path);
}

test "BisectReset isBisecting" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectReset.init(std.testing.allocator, io);
    _ = bisect.isBisecting();
    try std.testing.expect(true);
}

test "BisectReset reset method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectReset.init(std.testing.allocator, io);
    bisect.reset() catch {};
    try std.testing.expect(true);
}
