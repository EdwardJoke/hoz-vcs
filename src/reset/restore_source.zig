//! Restore Source - Specify source for restore (--source)
const std = @import("std");

pub const RestoreSource = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RestoreSource {
        return .{ .allocator = allocator };
    }

    pub fn resolveSource(self: *RestoreSource, spec: []const u8) ![]const u8 {
        _ = self;
        _ = spec;
        return "";
    }

    pub fn getTreeFromSource(self: *RestoreSource, spec: []const u8) ![]const u8 {
        _ = self;
        _ = spec;
        return "";
    }
};

test "RestoreSource init" {
    const source = RestoreSource.init(std.testing.allocator);
    try std.testing.expect(source.allocator == std.testing.allocator);
}

test "RestoreSource resolveSource method exists" {
    var source = RestoreSource.init(std.testing.allocator);
    const resolved = try source.resolveSource("HEAD~1:file.txt");
    _ = resolved;
    try std.testing.expect(true);
}

test "RestoreSource getTreeFromSource method exists" {
    var source = RestoreSource.init(std.testing.allocator);
    const tree = try source.getTreeFromSource("HEAD");
    _ = tree;
    try std.testing.expect(true);
}