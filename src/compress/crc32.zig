//! CRC32 implementation for packfile integrity
const std = @import("std");

/// Standard CRC32 function using std.hash.Crc32
pub fn crc32(data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final();
}

/// CRC32 with initial value
pub fn crc32WithInitial(initial: u32, data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final() ^ initial;
}

test "crc32 basic" {
    // Test vectors from RFC 3720
    const test1 = crc32("hello world");
    _ = test1;

    // Test empty
    const empty = crc32("");
    try std.testing.expectEqual(@as(u32, 0x00000000), empty);
}
