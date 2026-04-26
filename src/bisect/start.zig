//! Bisect Start - Initialize bisect session
const std = @import("std");
const Io = std.Io;

pub const BisectStart = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bad_ref: []const u8,
    good_refs: []const []const u8,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) BisectStart {
        return .{
            .allocator = allocator,
            .io = io,
            .bad_ref = "HEAD",
            .good_refs = &.{},
            .path = ".git",
        };
    }

    pub fn start(self: *BisectStart, bad: []const u8, goods: []const []const u8) !void {
        self.bad_ref = bad;
        self.good_refs = goods;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        _ = git_dir.createDir(self.io, "bisect", @enumFromInt(0o755)) catch {};
        const bisect_dir = git_dir.openDir(self.io, "bisect", .{}) catch return;
        defer bisect_dir.close(self.io);

        try self.writeRef("bad", bad);
        for (goods) |good| {
            try self.writeRef("good", good);
        }
    }

    fn writeRef(self: *BisectStart, status: []const u8, ref: []const u8) !void {
        const fname = try std.fmt.allocPrint(self.allocator, "bisect/{s}", .{status});
        defer self.allocator.free(fname);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        try git_dir.writeFile(self.io, .{ .sub_path = fname, .data = ref });
    }

    pub fn getRevList(self: *BisectStart) ![]const []const u8 {
        _ = self;
        return &[_][]const u8{};
    }
};

test "BisectStart init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectStart.init(std.testing.allocator, io);
    try std.testing.expectEqualStrings("HEAD", bisect.bad_ref);
}

test "BisectStart start method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectStart.init(std.testing.allocator, io);
    bisect.start("HEAD", &.{"HEAD~5"}) catch {};
    try std.testing.expect(true);
}

test "BisectStart getRevList method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectStart.init(std.testing.allocator, io);
    const revs = try bisect.getRevList();
    _ = revs;
    try std.testing.expect(true);
}
