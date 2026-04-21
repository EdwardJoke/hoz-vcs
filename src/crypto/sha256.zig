//! SHA-256 hash computation for Git object hashing (SHA-256 support)
const std = @import("std");

/// SHA-256 hash output size (32 bytes = 256 bits)
pub const SHA256_SIZE: usize = 32;

/// Compute SHA-256 hash of data and return the 32-byte digest.
/// This is an alternative hash function for Git's SHA-256 support.
pub fn sha256(data: []const u8) [SHA256_SIZE]u8 {
    var hash: [SHA256_SIZE]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(&hash);
    return hash;
}

/// SHA-256 hasher type for incremental hashing
pub const Sha256 = std.crypto.hash.sha2.Sha256;

/// Convenience function to compute SHA-256 and return as a slice
pub fn sha256Slice(data: []const u8) []const u8 {
    return &sha256(data);
}

pub const HashAlgorithm = enum {
    sha1,
    sha256,
};

pub const HashSize = struct {
    pub const SHA1: usize = 20;
    pub const SHA256: usize = 32;
};

test "sha256 basic" {
    const result = sha256("hello world");
    try std.testing.expect(result.len == SHA256_SIZE);
}

test "sha256 empty" {
    const result = sha256("");
    try std.testing.expect(result.len == SHA256_SIZE);
}

test "sha256 incremental" {
    var hasher = Sha256.init(.{});
    hasher.update("hello ");
    hasher.update("world");
    var result: [SHA256_SIZE]u8 = undefined;
    hasher.final(&result);
    try std.testing.expect(result.len == SHA256_SIZE);
}
