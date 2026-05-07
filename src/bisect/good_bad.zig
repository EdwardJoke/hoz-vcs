//! Bisect Good/Bad - Mark commits as good or bad
const std = @import("std");
const Io = std.Io;

pub const BisectGoodBad = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) BisectGoodBad {
        return .{ .allocator = allocator, .io = io, .path = ".git" };
    }

    pub fn markGood(self: *BisectGoodBad, ref: []const u8) !void {
        try self.writeStatus("good", ref);
    }

    pub fn markBad(self: *BisectGoodBad, ref: []const u8) !void {
        try self.writeStatus("bad", ref);
    }

    fn writeStatus(self: *BisectGoodBad, status: []const u8, ref: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        _ = git_dir.createDir(self.io, "bisect", @enumFromInt(0o755)) catch {};
        const bisect_dir = git_dir.openDir(self.io, "bisect", .{}) catch return;
        defer bisect_dir.close(self.io);

        try bisect_dir.writeFile(self.io, .{ .sub_path = status, .data = ref });
    }

    pub fn getStatus(self: *BisectGoodBad, status: []const u8) !?[]const u8 {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch return null;
        defer git_dir.close(self.io);

        const bisect_dir = git_dir.openDir(self.io, "bisect", .{}) catch return null;
        defer bisect_dir.close(self.io);

        const content = bisect_dir.readFileAlloc(self.io, status, self.allocator, .limited(1024)) catch return null;
        return content;
    }
};

test "BisectGoodBad init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectGoodBad.init(std.testing.allocator, io);
    try std.testing.expectEqualStrings(".git", bisect.path);
}

test "BisectGoodBad markGood method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectGoodBad.init(std.testing.allocator, io);
    if (bisect.markGood("HEAD~1")) |_| {} else |err| {
        try std.testing.expect(err == error.NotAGitRepository);
    }
}

test "BisectGoodBad markBad method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectGoodBad.init(std.testing.allocator, io);
    if (bisect.markBad("HEAD")) |_| {} else |err| {
        try std.testing.expect(err == error.NotAGitRepository);
    }
}
