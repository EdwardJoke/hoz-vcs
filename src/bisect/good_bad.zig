//! Bisect Good/Bad - Mark commits as good or bad
const std = @import("std");

pub const BisectGoodBad = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator) BisectGoodBad {
        return .{ .allocator = allocator, .path = ".git" };
    }

    pub fn markGood(self: *BisectGoodBad, ref: []const u8) !void {
        try self.writeStatus("good", ref);
    }

    pub fn markBad(self: *BisectGoodBad, ref: []const u8) !void {
        try self.writeStatus("bad", ref);
    }

    fn writeStatus(self: *BisectGoodBad, status: []const u8, ref: []const u8) !void {
        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();

        const bisect_dir = try git_dir.makeOpenPath("bisect", .{});
        defer bisect_dir.close();

        const fname = try std.fmt.allocPrint(self.allocator, "{s}", .{status});
        defer self.allocator.free(fname);
        try bisect_dir.writeFile(fname, ref);
    }

    pub fn getStatus(self: *BisectGoodBad, status: []const u8) !?[]const u8 {
        const git_dir = try std.fs.openDirAbsolute(self.path, .{});
        defer git_dir.close();

        const bisect_dir = try git_dir.makeOpenPath("bisect", .{});
        defer bisect_dir.close();

        const fname = try std.fmt.allocPrint(self.allocator, "{s}", .{status});
        defer self.allocator.free(fname);

        const content = bisect_dir.readFileAlloc(self.allocator, fname, 1024) catch return null;
        return content;
    }
};

test "BisectGoodBad init" {
    const bisect = BisectGoodBad.init(std.testing.allocator);
    try std.testing.expectEqualStrings(".git", bisect.path);
}

test "BisectGoodBad markGood method exists" {
    var bisect = BisectGoodBad.init(std.testing.allocator);
    try bisect.markGood("HEAD~1");
    try std.testing.expect(true);
}

test "BisectGoodBad markBad method exists" {
    var bisect = BisectGoodBad.init(std.testing.allocator);
    try bisect.markBad("HEAD");
    try std.testing.expect(true);
}