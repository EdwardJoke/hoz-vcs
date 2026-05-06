//! Zlib compression/decompression for Git objects
//!
//! Supports zlib format (RFC 1950) wrapping DEFLATE (RFC 1951).
//! Compression uses fixed Huffman coding; decompression handles
//! both stored blocks and fixed Huffman blocks.
const std = @import("std");
const deflate_mod = @import("deflate.zig");

pub const ZlibError = error{
    InvalidHeader,
    InvalidChecksum,
    TruncatedInput,
    BadBlockType,
    CorruptData,
};

pub const Zlib = struct {
    pub fn compress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const deflated = try deflate_mod.compressFixed(data, allocator);
        defer allocator.free(deflated);

        const adler = deflate_mod.adler32(data);

        var output = try allocator.alloc(u8, 2 + deflated.len + 4);
        errdefer allocator.free(output);

        output[0] = 0x78;
        output[1] = 0x01;
        @memcpy(output[2 .. 2 + deflated.len], deflated);
        std.mem.writeInt(u32, output[2 + deflated.len ..][0..4], adler, .big);

        return output;
    }

    pub fn decompress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (data.len < 6) return ZlibError.TruncatedInput;

        if (data[0] != 0x78) return ZlibError.InvalidHeader;

        if ((@as(u32, data[0]) * 256 + data[1]) % 31 != 0) return ZlibError.InvalidHeader;

        var decomp = deflate_mod.Decompressor.init(data[2..]);

        var result = std.ArrayList(u8).initCapacity(allocator, data.len * 3) catch |err| return err;
        errdefer result.deinit(allocator);

        var bfinal: bool = false;

        while (!bfinal) {
            if (decomp.offset >= data.len - 4) break;

            const bfinal_btype = try decomp.readBitsLE(3);
            bfinal = (bfinal_btype & 1) != 0;
            const btype: u2 = @truncate((bfinal_btype >> 1) & 3);

            switch (btype) {
                0x00 => {
                    decomp.alignToByte();
                    if (decomp.offset + 4 > data.len - 4) return ZlibError.CorruptData;
                    const len = std.mem.readInt(u16, data[decomp.offset..][0..2], .little);
                    decomp.offset += 2;
                    const nlen = std.mem.readInt(u16, data[decomp.offset..][0..2], .little);
                    decomp.offset += 2;
                    if (len != ~nlen) return ZlibError.CorruptData;
                    if (decomp.offset + @as(usize, len) > data.len - 4) return ZlibError.TruncatedInput;
                    try result.appendSlice(allocator, data[decomp.offset .. decomp.offset + len]);
                    decomp.offset += len;
                },
                0x01 => {
                    try decomp.inflateBlockFixed(&result, allocator);
                },
                0x02 => {
                    return ZlibError.BadBlockType;
                },
                0x03 => {
                    return ZlibError.BadBlockType;
                },
            }
        }

        if (decomp.offset + 4 > data.len) return ZlibError.TruncatedInput;

        const stored_adler = std.mem.readInt(u32, data[decomp.offset..][0..4], .big);
        const computed_adler = deflate_mod.adler32(result.items);
        if (stored_adler != computed_adler) return ZlibError.InvalidChecksum;

        return result.toOwnedSlice(allocator);
    }
};

test "zlib compress decompress roundtrip" {
    const allocator = std.testing.allocator;
    const original = "hello world";
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try Zlib.decompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "zlib compress produces smaller output than store" {
    const allocator = std.testing.allocator;
    const original = "hello world hello world hello world hello world";
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len < original.len + 6);
}

test "zlib decompress empty" {
    const allocator = std.testing.allocator;
    const compressed = "";
    const result = Zlib.decompress(compressed, allocator);
    try std.testing.expectError(ZlibError.TruncatedInput, result);
}

test "zlib invalid header" {
    const allocator = std.testing.allocator;
    const bad = &[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00 };
    const result = Zlib.decompress(bad, allocator);
    try std.testing.expectError(ZlibError.InvalidHeader, result);
}

test "zlib compress decompress large" {
    const allocator = std.testing.allocator;
    const original = "x" ** 70000;
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
    try std.testing.expect(compressed[0] == 0x78);
    const decompressed = try Zlib.decompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "zlib compress decompress binary" {
    const allocator = std.testing.allocator;
    const original = "\x00\x01\x02\xff\xfe\xfd\x80\x81";
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try Zlib.decompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "zlib compress decompress with repeated patterns" {
    const allocator = std.testing.allocator;
    const original = "ABCDEFGH" ** 100;
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try Zlib.decompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}
