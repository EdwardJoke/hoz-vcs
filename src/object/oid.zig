//! OID (Object ID) type - Git's 20-byte SHA-1 identifier
const std = @import("std");
const sha1 = @import("../crypto/sha1.zig");

/// OID size in bytes (160-bit SHA-1)
pub const OID_SIZE: usize = sha1.SHA1_SIZE;

/// Maximum hex string length (OID_SIZE * 2)
pub const OID_HEX_SIZE: usize = OID_SIZE * 2;

/// Minimum short OID length (7 characters = 28 bits, Git default)
pub const OID_MIN_SHORT_LENGTH: usize = 7;

/// OID error types
pub const OidError = error{
    InvalidHexLength,
    InvalidHexCharacter,
    OddLengthHexString,
} || std.fmt.ParseIntError;

/// OID represents a Git object identifier (20-byte SHA-1 hash)
pub const OID = struct {
    bytes: [OID_SIZE]u8,

    /// Parse OID from hex string (40 characters or short form)
    /// Supports full OIDs (40 chars) and short OIDs (7-39 chars)
    pub fn fromHex(str: []const u8) !OID {
        if (str.len == 0) return error.InvalidHexLength;
        if (str.len % 2 != 0) return error.OddLengthHexString;
        if (str.len > OID_HEX_SIZE) return error.InvalidHexLength;

        var oid: OID = undefined;
        @memset(&oid.bytes, 0);

        const start_offset = OID_HEX_SIZE - str.len;
        var i: usize = 0;
        while (i < str.len) : (i += 2) {
            const byte_str = str[i .. i + 2];
            const byte_val = try std.fmt.parseInt(u8, byte_str, 16);
            const target_idx = start_offset + (i / 2);
            if (target_idx < OID_SIZE) {
                oid.bytes[target_idx] = byte_val;
            }
        }

        return oid;
    }

    /// Convert OID to hex string
    pub fn toHex(self: OID) [OID_HEX_SIZE]u8 {
        var buf: [OID_HEX_SIZE]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (self.bytes, 0..) |byte, i| {
            buf[i * 2] = hex_chars[byte >> 4];
            buf[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        return buf;
    }

    /// Convert OID to hex string with custom length (for short OIDs)
    pub fn toHexLen(self: OID, len: usize) ![OID_HEX_SIZE]u8 {
        if (len < OID_MIN_SHORT_LENGTH or len > OID_HEX_SIZE) {
            return error.InvalidHexLength;
        }
        const full_hex = self.toHex();
        var result: [OID_HEX_SIZE]u8 = undefined;
        @memcpy(&result, &full_hex);
        return result;
    }

    /// Get short OID (abbreviated to specified length)
    pub fn short(self: OID, len: usize) [OID_HEX_SIZE]u8 {
        const hex = self.toHex();
        var result: [OID_HEX_SIZE]u8 = undefined;
        @memset(&result, 0);
        const safe_len = @max(len, OID_MIN_SHORT_LENGTH);
        @memcpy(&result, hex[0..safe_len]);
        return result;
    }

    /// Compare two OIDs
    pub fn eql(self: OID, other: OID) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Check if OID is zero (null)
    pub fn isZero(self: OID) bool {
        for (self.bytes) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }
};

/// Create OID from raw bytes
pub fn oidFromBytes(bytes: []const u8) OID {
    var oid: OID = undefined;
    @memcpy(&oid.bytes, bytes[0..OID_SIZE]);
    return oid;
}

/// Compute OID from content (the core Git operation)
pub fn oidFromContent(content: []const u8) OID {
    const hash = sha1.sha1(content);
    return oidFromBytes(&hash);
}

/// Compare two OIDs
pub fn oidEqual(a: OID, b: OID) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

/// OID zero value (all zeros - used for null/unset)
pub fn oidZero() OID {
    return OID{ .bytes = .{} };
}

/// Check if OID is zero (null)
pub fn oidIsZero(oid: OID) bool {
    for (oid.bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "oid from hex" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid = try OID.fromHex(hex_str);
    try std.testing.expect(!oid.isZero());
}

test "oid to hex" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid = try OID.fromHex(hex_str);
    const result = oid.toHex();
    try std.testing.expectEqualSlices(u8, hex_str, &result);
}

test "oid from content" {
    const content = "test content";
    const oid = oidFromContent(content);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid zero" {
    const zero = oidZero();
    try std.testing.expect(zero.isZero());
}

test "oid equal" {
    const hex_str = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid1 = try OID.fromHex(hex_str);
    const oid2 = try OID.fromHex(hex_str);
    try std.testing.expect(oid1.eql(oid2));
}

test "oid from hex invalid length" {
    const short_hex = "abc";
    try std.testing.expectError(error.InvalidHexLength, OID.fromHex(short_hex));
}

test "oid from bytes" {
    const bytes = "12345678901234567890";
    const oid = oidFromBytes(bytes);
    try std.testing.expect(!oidIsZero(oid));
}

test "oid is zero returns false for non-zero" {
    const hex_str = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    const oid = try OID.fromHex(hex_str);
    try std.testing.expect(!oid.isZero());
}

test "oid not equal" {
    const hex1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const hex2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const oid1 = try OID.fromHex(hex1);
    const oid2 = try OID.fromHex(hex2);
    try std.testing.expect(!oid1.eql(oid2));
}

test "oid short forms" {
    const full_hex = "2aae6c8f6f948c5af23c4a08f91c7a4d903c1e";
    const oid = try OID.fromHex(full_hex);

    const short7 = oid.short(7);
    try std.testing.expectEqualSlices(u8, "2aae6c8", &short7);

    const short40 = oid.toHex();
    try std.testing.expectEqualSlices(u8, full_hex, &short40);
}

test "oid short from hex" {
    const short7 = "2aae6c8";
    const oid = try OID.fromHex(short7);
    try std.testing.expect(!oid.isZero());
}

test "oid zero from short" {
    const zero = oidZero();
    try std.testing.expect(zero.isZero());

    const zero_hex = try OID.fromHex("0000000");
    try std.testing.expect(zero_hex.isZero());
}

test "oid odd length error" {
    const odd_hex = "abc";
    try std.testing.expectError(error.OddLengthHexString, OID.fromHex(odd_hex));
}
