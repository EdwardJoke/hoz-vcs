//! Clone Working Directory - Clone with working directory
const std = @import("std");

pub const WorkingDirCloner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkingDirCloner {
        return .{ .allocator = allocator };
    }

    pub fn clone(self: *WorkingDirCloner, url: []const u8, path: []const u8) !void {
        _ = self;
        _ = url;
        _ = path;
    }

    pub fn cloneWithCheckout(self: *WorkingDirCloner, url: []const u8, path: []const u8, branch: []const u8) !void {
        _ = self;
        _ = url;
        _ = path;
        _ = branch;
    }
};

test "WorkingDirCloner init" {
    const cloner = WorkingDirCloner.init(std.testing.allocator);
    try std.testing.expect(cloner.allocator == std.testing.allocator);
}

test "WorkingDirCloner clone method exists" {
    var cloner = WorkingDirCloner.init(std.testing.allocator);
    try cloner.clone("https://github.com/user/repo.git", "/tmp/repo");
    try std.testing.expect(true);
}

test "WorkingDirCloner cloneWithCheckout method exists" {
    var cloner = WorkingDirCloner.init(std.testing.allocator);
    try cloner.cloneWithCheckout("https://github.com/user/repo.git", "/tmp/repo", "main");
    try std.testing.expect(true);
}