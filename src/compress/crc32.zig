//! CRC32 implementation for packfile integrity
const std = @import("std");

pub const Crc32Error = error{
    ChecksumMismatch,
    TruncatedPackfile,
};

/// Standard CRC32 function using std.hash.Crc32
pub fn crc32(data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final();
}

/// CRC32 continuing from a previous checksum (for streaming/concatenation).
/// `initial` is the running CRC state from prior data (not finalized).
pub fn crc32WithInitial(initial: u32, data: []const u8) u32 {
    var state = initial;
    for (data) |byte| {
        state ^= byte;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if (state & 1 != 0) {
                state = (state >> 1) ^ 0xEDB88320;
            } else {
                state >>= 1;
            }
        }
    }
    return state;
}

/// Verify CRC32 checksum matches expected value
pub fn verifyCrc32(data: []const u8, expected: u32) Crc32Error!void {
    const computed = crc32(data);
    if (computed != expected) {
        return Crc32Error.ChecksumMismatch;
    }
}

/// Compute CRC32 of packfile data (excluding 20-byte trailing checksum).
/// Returns an owned copy of the verified data slice.
pub fn crc32Packfile(data: []const u8, expected_crc: u32, allocator: std.mem.Allocator) Crc32Error![]u8 {
    if (data.len < 20) return error.TruncatedPackfile;
    const obj_data = data[0 .. data.len - 20];
    try verifyCrc32(obj_data, expected_crc);
    const copy = try allocator.dupe(u8, obj_data);
    return copy;
}

/// Incremental CRC32 calculator for streaming
pub const Crc32Calculator = struct {
    hasher: std.hash.Crc32,

    pub fn init() Crc32Calculator {
        return .{ .hasher = std.hash.Crc32.init() };
    }

    pub fn update(self: *Crc32Calculator, data: []const u8) void {
        self.hasher.update(data);
    }

    pub fn final(self: *Crc32Calculator) u32 {
        return self.hasher.final();
    }
};

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

test "crc32 verify mismatch" {
    const data = "hello world";
    const wrong: u32 = 0x12345678;
    const result = verifyCrc32(data, wrong);
    try std.testing.expectError(Crc32Error.ChecksumMismatch, result);
}

test "crc32 incremental" {
    var calc = Crc32Calculator.init();
    calc.update("hello ");
    calc.update("world");
    const result = calc.final();
    const combined = crc32("hello world");
    try std.testing.expectEqual(combined, result);
}
