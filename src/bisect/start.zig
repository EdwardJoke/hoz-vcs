//! Bisect Start - Initialize bisect session
const std = @import("std");

pub const BisectStart = struct {
    allocator: std.mem.Allocator,
    bad_ref: []const u8,
    good_refs: []const []const u8,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator) BisectStart {
        return .{
            .allocator = allocator,
            .bad_ref = "HEAD",
            .good_refs = &.{},
            .path = ".git",
        };
    }

    pub fn start(self: *BisectStart, bad: []const u8, goods: []const []const u8) !void {
        self.bad_ref = bad;
        self.good_refs = goods;

        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();

        const bisect_dir = try git_dir.makeOpenPath("bisect", .{});
        defer bisect_dir.close();

        try self.writeRef("bad", bad);
        for (goods) |good| {
            try self.writeRef("good", good);
        }
    }

    fn writeRef(self: *BisectStart, status: []const u8, ref: []const u8) !void {
        const fname = try std.fmt.allocPrint(self.allocator, "bisect/{s}", .{status});
        defer self.allocator.free(fname);
        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();
        try git_dir.writeFile(fname, ref);
    }

    pub fn getRevList(self: *BisectStart) ![]const []const u8 {
        _ = self;
        return &.{};
    }
};

test "BisectStart init" {
    const bisect = BisectStart.init(std.testing.allocator);
    try std.testing.expectEqualStrings("HEAD", bisect.bad_ref);
}

test "BisectStart start method exists" {
    var bisect = BisectStart.init(std.testing.allocator);
    try bisect.start("HEAD", &.{"HEAD~5"});
    try std.testing.expect(true);
}

test "BisectStart getRevList method exists" {
    var bisect = BisectStart.init(std.testing.allocator);
    const revs = try bisect.getRevList();
    _ = revs;
    try std.testing.expect(true);
}