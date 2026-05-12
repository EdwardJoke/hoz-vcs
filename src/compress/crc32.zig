//! CRC32 implementation for packfile integrity
const std = @import("std");

pub const Crc32Error = error{
    ChecksumMismatch,
    TruncatedPackfile,
};

pub fn crc32(data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final();
}

test "crc32 basic" {
    const test1 = crc32("hello world");
    const expected: u32 = 0x2D7C6199;
    try std.testing.expectEqual(expected, test1);

    const empty = crc32("");
    try std.testing.expectEqual(@as(u32, 0x00000000), empty);
}

test "crc32 verify" {
    const data = "hello world";
    const expected = crc32(data);
    try verifyCrc32(data, expected);
}

fn verifyCrc32(data: []const u8, expected: u32) Crc32Error!void {
    const computed = crc32(data);
    if (computed != expected) {
        return Crc32Error.ChecksumMismatch;
    }
}
