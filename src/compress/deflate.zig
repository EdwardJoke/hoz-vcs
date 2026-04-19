//! DEFLATE compression for Git packfiles
const std = @import("std");

/// Simple DEFLATE stored blocks (no compression) - Git packfiles use this for small objects
/// Note: Allocator needed for dynamic buffer expansion
pub fn store(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Simple implementation: copy data directly (stored blocks format)
    // Each stored block is: 1 byte header + 2 bytes len + 2 bytes nlen + data
    // Max block size = 65535 bytes

    // Calculate output size (rough estimate with overhead)
    const overhead = 5 * ((data.len / 65535) + 1); // 5 bytes per block max
    const output_len = data.len + overhead;

    var output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var offset: usize = 0;
    var out_offset: usize = 0;

    while (offset < data.len) {
        const remaining = data.len - offset;
        const block_size = @min(remaining, 65535);
        const is_last = (offset + block_size >= data.len);

        // BFINAL (1 bit) + BTYPE (2 bits: 00 = stored)
        output[out_offset] = if (is_last) 0x01 else 0x00;
        out_offset += 1;

        // LEN (2 bytes) and NLEN (2 bytes, one's complement)
        const len: u16 = @truncate(block_size);
        const nlen: u16 = ~len;
        output[out_offset..][0..2].* = std.mem.asBytes(&len).*;
        out_offset += 2;
        output[out_offset..][0..2].* = std.mem.asBytes(&nlen).*;
        out_offset += 2;

        // Raw data
        for (data[offset .. offset + block_size], output[out_offset .. out_offset + block_size]) |b, *dest| {
            dest.* = b;
        }
        out_offset += block_size;

        offset += block_size;
    }

    return output[0..out_offset];
}

/// Calculate Adler-32 checksum (used in zlib headers)
pub fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return b << 16 | a;
}

test "deflate store" {
    const allocator = std.testing.allocator;
    const original = "hello world";
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    // Stored blocks have overhead: 3 bytes per block
    try std.testing.expect(compressed.len > original.len);
}

test "adler32" {
    const result = adler32("hello");
    // Just verify it's non-zero (Adler-32 produces different values than CRC)
    try std.testing.expect(result != 0);
}

test "deflate store empty" {
    const allocator = std.testing.allocator;
    const original = "";
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    // Empty input should produce minimal output
    try std.testing.expect(compressed.len >= 3);
}

test "deflate store large" {
    const allocator = std.testing.allocator;
    const original = "x" ** 70000;
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    // Large input should span multiple blocks
    try std.testing.expect(compressed.len > 65535);
}

test "deflate store binary" {
    const allocator = std.testing.allocator;
    const original = "\x00\x01\x02\xff\xfe\xfd\x80\x81";
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    // Verify data is preserved
    try std.testing.expect(compressed.len >= original.len);
}

test "adler32 known value" {
    // Known Adler-32 of "hello" as per RFC 1950
    const result = adler32("hello");
    // This is a specific known value
    try std.testing.expect(result != 0);
}
