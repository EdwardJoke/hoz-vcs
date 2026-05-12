//! DEFLATE compression/decompression for Git packfiles
//!
//! Supports stored blocks (btype=0) and fixed Huffman blocks (btype=1).
//! Dynamic Huffman (btype=2) is decompressed via the canonical Huffman path.
const std = @import("std");

pub const Compressor = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bit_buffer: u64,
    bit_count: u8,

    pub fn init(allocator: std.mem.Allocator) !Compressor {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(allocator, 256),
            .allocator = allocator,
            .bit_buffer = 0,
            .bit_count = 0,
        };
    }

    pub fn deinit(self: *Compressor) void {
        self.buf.deinit(self.allocator);
    }

    fn writeBits(self: *Compressor, value: u32, num_bits: u8) void {
        self.bit_buffer |= @as(u64, value) << @intCast(self.bit_count);
        self.bit_count += num_bits;
        while (self.bit_count >= 8) {
            self.buf.append(self.allocator, @truncate(self.bit_buffer)) catch unreachable;
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }

    fn flushBits(self: *Compressor) void {
        if (self.bit_count > 0) {
            self.buf.append(self.allocator, @truncate(self.bit_buffer)) catch unreachable;
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }

    fn reverseBits(value: u32, num_bits: u8) u32 {
        var result: u32 = 0;
        var v = value;
        var i: u8 = 0;
        while (i < num_bits) : (i += 1) {
            result = (result << 1) | (v & 1);
            v >>= 1;
        }
        return result;
    }

    fn writeHuffmanCode(self: *Compressor, code: u32, num_bits: u8) void {
        self.writeBits(reverseBits(code, num_bits), num_bits);
    }

    fn writeLiteral(self: *Compressor, byte: u8) void {
        if (byte <= 143) {
            self.writeHuffmanCode(0x30 + byte, 8);
        } else {
            self.writeHuffmanCode(@as(u32, 0x190) + byte - 144, 9);
        }
    }

    const length_codes_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const length_codes_extra = [_]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

    fn writeLength(self: *Compressor, length: u16) void {
        const capped_len = @min(length, 258);
        var code: u9 = 257;
        var extra_bits: u6 = 0;
        var extra_value: u16 = 0;

        for (length_codes_base, 0..) |base, i| {
            const next_base = if (i + 1 < length_codes_base.len) length_codes_base[i + 1] else base + 1;
            if (capped_len >= base and capped_len < next_base) {
                code = @intCast(257 + i);
                extra_bits = length_codes_extra[i];
                extra_value = capped_len - base;
                break;
            }
        }

        if (code >= 257 and code <= 279) {
            self.writeHuffmanCode(code - 256, 7);
        } else if (code >= 280 and code <= 285) {
            self.writeHuffmanCode(@as(u32, code - 88), 8);
        } else {
            unreachable;
        }
        if (extra_bits > 0) {
            self.writeBits(extra_value, extra_bits);
        }
    }

    fn writeDistance(self: *Compressor, dist: u16) void {
        const dist_codes_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
        const dist_codes_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

        const capped_dist = @min(dist, 24577);
        var code: u5 = 0;
        var extra_bits: u5 = 0;
        var extra_value: u16 = 0;

        for (dist_codes_base, 0..) |base, i| {
            if (capped_dist >= base and (i + 1 == dist_codes_base.len or capped_dist < dist_codes_base[i + 1])) {
                code = @intCast(i);
                extra_bits = dist_codes_extra[i];
                extra_value = capped_dist - base;
                break;
            }
        }

        self.writeHuffmanCode(code, 5);
        if (extra_bits > 0) {
            self.writeBits(extra_value, extra_bits);
        }
    }

    fn findMatch(data: []const u8, pos: usize, max_lookahead: usize) ?struct { length: usize, distance: usize } {
        const max_len = @min(max_lookahead, data.len - pos);
        const max_dist = @min(pos, 32768);
        var best_length: usize = 0;
        var best_distance: usize = 0;
        const min_match: usize = 3;

        if (max_len < min_match or max_dist < 1) return null;

        const search_start = if (pos > max_dist) pos - max_dist else 0;
        var search_pos: usize = search_start;

        while (search_pos < pos) : (search_pos += 1) {
            var match_len: usize = 0;
            const remaining = @min(max_len, data.len - search_pos);
            while (match_len < remaining and data[search_pos + match_len] == data[pos + match_len]) : (match_len += 1) {}
            if (match_len >= min_match and match_len > best_length) {
                best_length = match_len;
                best_distance = pos - search_pos;
                if (best_length >= 258) break;
            }
        }

        if (best_length >= min_match) {
            return .{ .length = best_length, .distance = best_distance };
        }
        return null;
    }

    pub fn compressFixed(self: *Compressor, data: []const u8) ![]u8 {
        self.bit_buffer = 0;
        self.bit_count = 0;
        self.buf.clearRetainingCapacity();

        self.writeBits(1, 1);
        self.writeBits(1, 2);

        var pos: usize = 0;
        while (pos < data.len) {
            if (findMatch(data, pos, 258)) |m| {
                self.writeLength(@intCast(m.length));
                self.writeDistance(@intCast(m.distance));
                pos += m.length;
            } else {
                self.writeLiteral(data[pos]);
                pos += 1;
            }
        }

        self.writeHuffmanCode(0, 7);
        self.flushBits();

        const result = try self.allocator.dupe(u8, self.buf.items);
        return result;
    }
};

/// Simple DEFLATE stored blocks (no compression) - fallback for small objects
pub fn store(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const maxusize = std.math.maxInt(usize);

    const blocks = @divTrunc(data.len, 65535) + 1;
    const overhead, const overflow1 = @mulWithOverflow(blocks, 5);
    if (overflow1 != 0) return error.InputTooLarge;

    const output_len, const overflow2 = @addWithOverflow(data.len, overhead);
    if (overflow2 != 0) return error.InputTooLarge;

    if (output_len > maxusize) return error.InputTooLarge;

    var output = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output);

    var offset: usize = 0;
    var out_offset: usize = 0;

    while (offset < data.len or out_offset == 0) {
        const remaining = data.len - offset;
        const block_size = @min(remaining, 65535);
        const is_last = (offset + block_size >= data.len);

        output[out_offset] = if (is_last) 0x01 else 0x00;
        out_offset += 1;

        const len: u16 = @truncate(block_size);
        const nlen: u16 = ~len;
        output[out_offset..][0..2].* = std.mem.asBytes(&len).*;
        out_offset += 2;
        output[out_offset..][0..2].* = std.mem.asBytes(&nlen).*;
        out_offset += 2;

        @memcpy(output[out_offset .. out_offset + block_size], data[offset .. offset + block_size]);
        out_offset += block_size;

        offset += block_size;
    }

    return output[0..out_offset];
}

/// Compress data using DEFLATE with fixed Huffman coding.
/// Produces smaller output than store() for most inputs.
pub fn compressFixed(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var comp = try Compressor.init(allocator);
    defer comp.deinit();
    return comp.compressFixed(data);
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
    try std.testing.expect(compressed.len > original.len);
}

test "adler32" {
    const result = adler32("hello");
    const expected: u32 = 0x062C0215;
    try std.testing.expectEqual(expected, result);
}

test "deflate store empty" {
    const allocator = std.testing.allocator;
    const original = "";
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 3);
}

test "deflate store large" {
    const allocator = std.testing.allocator;
    const original = "x" ** 70000;
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len > 65535);
}

test "deflate store binary" {
    const allocator = std.testing.allocator;
    const original = "\x00\x01\x02\xff\xfe\xfd\x80\x81";
    const compressed = try store(original, allocator);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= original.len);
}

test "adler32 empty input" {
    const result = adler32("");
    const expected: u32 = 0x00000001;
    try std.testing.expectEqual(expected, result);
}

test "adler32 abc" {
    const result = adler32("abc");
    const expected: u32 = 0x024D0127;
    try std.testing.expectEqual(expected, result);
}

test "deflate fixed AAAA roundtrip" {
    const allocator = std.testing.allocator;
    const original = "AAAA";
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "deflate fixed git blob roundtrip" {
    const allocator = std.testing.allocator;
    const original = "blob 10\x00hello hoz\n";
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "deflate fixed repeat roundtrip" {
    const allocator = std.testing.allocator;
    const original = "ABCDEFGH" ** 100;
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(compressed, allocator);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

fn zlibDecompress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var decomp = std.compress.flate.Decompress.init(&in, .raw, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}
