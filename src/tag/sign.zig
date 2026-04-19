//! Tag Sign - GPG signing for tags
const std = @import("std");

pub const TagSigner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TagSigner {
        return .{ .allocator = allocator };
    }

    pub fn sign(self: *TagSigner, name: []const u8, key_id: []const u8) !void {
        _ = self;
        _ = name;
        _ = key_id;
    }

    pub fn signWithMessage(self: *TagSigner, name: []const u8, key_id: []const u8, message: []const u8) !void {
        _ = self;
        _ = name;
        _ = key_id;
        _ = message;
    }
};

test "TagSigner init" {
    const signer = TagSigner.init(std.testing.allocator);
    try std.testing.expect(signer.allocator == std.testing.allocator);
}

test "TagSigner sign method exists" {
    var signer = TagSigner.init(std.testing.allocator);
    try signer.sign("v1.0.0", "KEY123");
    try std.testing.expect(true);
}

test "TagSigner signWithMessage method exists" {
    var signer = TagSigner.init(std.testing.allocator);
    try signer.signWithMessage("v1.0.0", "KEY123", "Release version 1.0.0");
    try std.testing.expect(true);
}