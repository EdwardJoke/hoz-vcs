//! CRC32 implementation for packfile integrity
const std = @import("std");

pub const Crc32Error = error{
    ChecksumMismatch,
};

/// Standard CRC32 function using std.hash.Crc32
pub fn crc32(data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final();
}

/// CRC32 with initial value (for incremental calculation)
pub fn crc32WithInitial(initial: u32, data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    return hasher.final() ^ initial;
}

/// Verify CRC32 checksum matches expected value
pub fn verifyCrc32(data: []const u8, expected: u32) Crc32Error!void {
    const computed = crc32(data);
    if (computed != expected) {
        return Crc32Error.ChecksumMismatch;
    }
}

/// Compute CRC32 of packfile data (excluding 20-byte trailing checksum)
pub fn crc32Packfile(data: []const u8, checksum: [20]u8) Crc32Error![]const u8 {
    if (data.len < 20) return error.TruncatedPackfile;
    const obj_data = data[0..data.len - 20];
    const stored_checksum = std.mem.readInt(u32, checksum[16..20], .big);
    try verifyCrc32(obj_data, stored_checksum);
    return obj_data;
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
    _ = test1;

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
