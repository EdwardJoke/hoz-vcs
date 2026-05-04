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

        const head_original = git_dir.readFileAlloc(self.io, "bisect/head-original", self.allocator, .limited(256)) catch return;
        defer self.allocator.free(head_original);
        const trimmed = std.mem.trim(u8, head_original, " \t\r\n");

        if (trimmed.len == 0) return;

        try git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = trimmed });
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

test "BisectReset isBisecting returns false outside git repo" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectReset.init(std.testing.allocator, io);
    try std.testing.expect(bisect.isBisecting() == false);
}

test "BisectReset reset method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectReset.init(std.testing.allocator, io);
    if (bisect.reset()) |_| {} else |err| {
        try std.testing.expect(err == error.NotAGitRepository);
    }
}
