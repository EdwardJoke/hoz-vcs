//! Zlib compression/decompression for Git objects
const std = @import("std");
const deflate_mod = @import("deflate.zig");

pub const Zlib = struct {
    pub fn compress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return deflate_mod.store(data, allocator);
    }

    pub fn decompress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        if (data.len == 0) return error.CompressionFailed;

        var offset: usize = 0;

        if (data[0] & 0x0F == 0x08) {
            offset += 1;
            if (offset >= data.len) return error.CompressionFailed;

            while (offset < data.len) {
                _ = data[offset];
                offset += 1;

                if (offset + 1 >= data.len) return error.CompressionFailed;

                const len = (@as(u16, data[offset]) << 0) | (@as(u16, data[offset + 1]) << 8);
                offset += 2;

                if (offset + len > data.len) return error.CompressionFailed;
                offset += len;

                if (offset >= data.len) break;
            }
        } else if (data[0] == 0x78) {
            offset += 2;

            var result = std.ArrayList(u8).init(allocator);
            errdefer result.deinit();

            while (offset < data.len) {
                const byte = data[offset];
                offset += 1;

                if (byte == 0xFF) {
                    if (offset + 2 >= data.len) return error.CompressionFailed;
                    const len = (@as(u16, data[offset]) << 0) | (@as(u16, data[offset + 1]) << 8);
                    offset += 2;

                    if (offset + len > data.len) return error.CompressionFailed;
                    try result.appendSlice(data[offset .. offset + len]);
                    offset += len;
                } else {
                    const block_type = (byte >> 0) & 0x03;

                    if (block_type == 0x00) {
                        offset += 1;
                        if (offset + 1 >= data.len) return error.CompressionFailed;
                        const len = (@as(u16, data[offset]) << 0) | (@as(u16, data[offset + 1]) << 8);
                        offset += 2;

                        if (offset + len > data.len) return error.CompressionFailed;
                        try result.appendSlice(data[offset .. offset + len]);
                        offset += len;
                    } else if (block_type == 0x01 or block_type == 0x02) {
                        return error.UnsupportedCompression;
                    } else if (block_type == 0x03) {
                        break;
                    }
                }

                if (offset >= data.len) break;
            }

            return result.toOwnedSlice();
        }

        return error.UnsupportedCompression;
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

test "zlib decompress empty" {
    const allocator = std.testing.allocator;
    const compressed = "";
    const result = Zlib.decompress(compressed, allocator);
    try std.testing.expectError(error.CompressionFailed, result);
}

test "zlib compress decompress large" {
    const allocator = std.testing.allocator;
    const original = "x" ** 70000;
    const compressed = try Zlib.compress(original, allocator);
    defer allocator.free(compressed);
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
