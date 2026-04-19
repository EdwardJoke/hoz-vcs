//! OID (Object ID) type - Git's 20-byte SHA-1 identifier
const std = @import("std");
const sha1 = @import("../crypto/sha1.zig");

/// OID size in bytes (160-bit SHA-1)
pub const OID_SIZE: usize = sha1.SHA1_SIZE;

/// Maximum hex string length (OID_SIZE * 2)
pub const OID_HEX_SIZE: usize = OID_SIZE * 2;

/// OID represents a Git object identifier (20-byte SHA-1 hash)
pub const OID = [OID_SIZE]u8;

/// Parse OID from hex string (40 characters)
pub fn oidFromHex(str: []const u8) !OID {
    if (str.len != OID_HEX_SIZE) {
        return error.InvalidHexLength;
    }
    var oid: OID = undefined;
    for (0..OID_SIZE) |i| {
        const byte_str = str[i * 2 .. i * 2 + 2];
        oid[i] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    return oid;
}

/// Convert OID to hex string (requires 40-byte buffer)
pub fn oidToHex(oid: OID, buf: *[OID_HEX_SIZE]u8) void {
    const hex_chars = "0123456789abcdef";
    for (oid, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0xf];
    }
}

/// Create OID from raw bytes
pub fn oidFromBytes(bytes: []const u8) OID {
    var oid: OID = undefined;
    @memcpy(&oid, bytes[0..OID_SIZE]);
    return oid;
}

/// Compute OID from content (the core Git operation)
pub fn oidFromContent(content: []const u8) OID {
    // Git format: "<type> <size>\0<content>"
    // We'll handle this in the object module
    return sha1.sha1(content);
}

/// Compare two OIDs
pub fn oidEqual(a: OID, b: OID) bool {
    return std.mem.eql(u8, &a, &b);
}

/// OID zero value (all zeros - used for null/unset)
pub fn oidZero() OID {
    return OID{};
}

/// Check if OID is zero (null)
pub fn oidIsZero(oid: OID) bool {
    for (oid) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "oid from hex" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid = try oidFromHex(hex_str);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid to hex" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid = try oidFromHex(hex_str);
    var buf: [OID_HEX_SIZE]u8 = undefined;
    oidToHex(oid, &buf);
    try std.testing.expectEqualSlices(u8, hex_str, &buf);
}

test "oid from content" {
    const content = "test content";
    const oid = oidFromContent(content);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid zero" {
    const zero = oidZero();
    try std.testing.expect(oidIsZero(zero));
}

test "oid equal" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid1 = try oidFromHex(hex_str);
    const oid2 = try oidFromHex(hex_str);
    try std.testing.expect(oidEqual(oid1, oid2));
}

test "oid from hex invalid length" {
    const short_hex = "abc";
    try std.testing.expectError(error.InvalidHexLength, oidFromHex(short_hex));
}

test "oid from bytes" {
    const bytes = "12345678901234567890";
    const oid = oidFromBytes(bytes);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid is zero returns false for non-zero" {
    const hex_str = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    const oid = try oidFromHex(hex_str);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid not equal" {
    const hex1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const hex2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const oid1 = try oidFromHex(hex1);
    const oid2 = try oidFromHex(hex2);
    try std.testing.expect(!oidEqual(oid1, oid2));
}
