//! Zlib compression/decompression for Git objects
//!
//! Compression uses custom fixed Huffman; decompression uses
//! Zig's std.compress.flate.Decompress (supports all block types
//! including dynamic Huffman used by real git objects).
const std = @import("std");
const deflate_mod = @import("deflate.zig");

pub const ZlibError = error{
    InvalidHeader,
    TruncatedInput,
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

        var in: std.Io.Reader = .fixed(data);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        var decomp = std.compress.flate.Decompress.init(&in, .zlib, &.{});
        _ = try decomp.reader.streamRemaining(&aw.writer);

        return aw.toOwnedSlice();
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
