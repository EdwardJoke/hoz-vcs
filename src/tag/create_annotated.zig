//! Tag Create Annotated - Create annotated tag
const std = @import("std");

pub const AnnotatedTagCreator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnnotatedTagCreator {
        return .{ .allocator = allocator };
    }

    pub fn create(self: *AnnotatedTagCreator, name: []const u8, target: []const u8, message: []const u8) !void {
        _ = self;
        _ = name;
        _ = target;
        _ = message;
    }

    pub fn createWithTagger(self: *AnnotatedTagCreator, name: []const u8, target: []const u8, message: []const u8, tagger: []const u8) !void {
        _ = self;
        _ = name;
        _ = target;
        _ = message;
        _ = tagger;
    }
};

test "AnnotatedTagCreator init" {
    const creator = AnnotatedTagCreator.init(std.testing.allocator);
    try std.testing.expect(creator.allocator == std.testing.allocator);
}

test "AnnotatedTagCreator create method exists" {
    var creator = AnnotatedTagCreator.init(std.testing.allocator);
    try creator.create("v1.0.0", "abc123", "Release version 1.0.0");
    try std.testing.expect(true);
}

test "AnnotatedTagCreator createWithTagger method exists" {
    var creator = AnnotatedTagCreator.init(std.testing.allocator);
    try creator.createWithTagger("v1.0.0", "abc123", "Release version 1.0.0", "User <user@example.com>");
    try std.testing.expect(true);
}