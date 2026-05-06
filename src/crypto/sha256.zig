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

pub const HashAlgorithm = enum {
    sha1,
    sha256,
};

test "sha256 basic" {
    const result = sha256("hello world");
    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "sha256 empty" {
    const result = sha256("");
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "sha256 incremental" {
    var hasher = Sha256.init(.{});
    hasher.update("hello ");
    hasher.update("world");
    var result: [SHA256_SIZE]u8 = undefined;
    hasher.final(&result);
    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}
