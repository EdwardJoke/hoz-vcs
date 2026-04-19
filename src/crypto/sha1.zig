//! SHA-1 hash computation for Git object hashing
const std = @import("std");

/// SHA-1 hash output size (20 bytes = 160 bits)
pub const SHA1_SIZE: usize = 20;

/// Compute SHA-1 hash of data and return the 20-byte digest.
/// This is the core hash function used for Git object IDs.
pub fn sha1(data: []const u8) [SHA1_SIZE]u8 {
    var hash: [SHA1_SIZE]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data);
    hasher.final(&hash);
    return hash;
}

/// SHA-1 hasher type for incremental hashing
pub const Sha1 = std.crypto.hash.Sha1;

/// Convenience function to compute SHA-1 and return as a slice
pub fn sha1Slice(data: []const u8) []const u8 {
    return &sha1(data);
}

test "sha1 basic" {
    // Test vector: "hello world" should produce known SHA-1
    const result = sha1("hello world");
    // Known SHA-1 of "hello world" (verified with sha1sum)
    const expected = [_]u8{ 0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "sha1 empty" {
    // Test empty string
    const result = sha1("");
    // Known SHA-1 of ""
    const expected = [_]u8{ 0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d, 0x32, 0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09 };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "sha1 incremental" {
    // Test incremental hashing
    var hasher = Sha1.init(.{});
    hasher.update("hello ");
    hasher.update("world");
    var result: [SHA1_SIZE]u8 = undefined;
    hasher.final(&result);
    const expected = [_]u8{ 0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}
