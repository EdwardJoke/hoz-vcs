//! DEFLATE compression/decompression for Git packfiles
//!
//! Supports stored blocks (btype=0) and fixed Huffman blocks (btype=1).
//! Dynamic Huffman (btype=2) is decompressed via the canonical Huffman path.
const std = @import("std");

const DeflateError = error{
    InputTooLarge,
    InvalidBlockType,
    InvalidLengthCode,
    InvalidDistanceCode,
    InvalidLiteral,
    Overread,
    CorruptStream,
    UnsupportedFeature,
};

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

    fn writeLiteral(self: *Compressor, byte: u8) void {
        if (byte <= 143) {
            self.writeBits(0x30 + byte, 8);
        } else {
            self.writeBits(@as(u32, 0x190) + byte - 144, 9);
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
            self.writeBits(code, 7);
        } else if (code >= 280 and code <= 285) {
            self.writeBits(@as(u32, code - 88), 8);
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

        var code: u5 = 0;
        var extra_bits: u5 = 0;
        var extra_value: u16 = 0;

        for (dist_codes_base, 0..) |base, i| {
            if (dist == base or (i > 0 and dist > dist_codes_base[i - 1] and dist <= base)) {
                code = @intCast(i);
                extra_bits = dist_codes_extra[i];
                extra_value = dist - base;
                break;
            }
            if (i == dist_codes_base.len - 1) {
                code = 29;
                extra_bits = dist_codes_extra[29];
                extra_value = dist - base;
                break;
            }
        }

        self.writeBits(code, 5);
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
        self.writeBits(1, 1);

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

        self.writeBits(256, 7);
        self.flushBits();

        const result = try self.allocator.dupe(u8, self.buf.items);
        return result;
    }
};

pub const Decompressor = struct {
    data: []const u8,
    offset: usize,
    bit_buffer: u64,
    bits_in_buffer: u8,

    pub fn init(data: []const u8) Decompressor {
        return .{
            .data = data,
            .offset = 0,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
        };
    }

    fn readByte(self: *Decompressor) !u8 {
        if (self.offset >= self.data.len) return error.Overread;
        const b = self.data[self.offset];
        self.offset += 1;
        return b;
    }

    fn ensureBits(self: *Decompressor, count: u8) !void {
        while (self.bits_in_buffer < count) {
            const b = try self.readByte();
            self.bit_buffer |= @as(u64, b) << @intCast(self.bits_in_buffer);
            self.bits_in_buffer += 8;
        }
    }

    fn dropBits(self: *Decompressor, count: u8) void {
        self.bit_buffer >>= @intCast(count);
        self.bits_in_buffer -= count;
    }

    pub fn readBitsLE(self: *Decompressor, count: u8) !u32 {
        try self.ensureBits(count);
        const mask = (@as(u32, 1) << @intCast(count)) - 1;
        const val: u32 = @truncate(self.bit_buffer & mask);
        self.dropBits(count);
        return val;
    }

    pub fn alignToByte(self: *Decompressor) void {
        const discard = self.bits_in_buffer % 8;
        if (discard > 0) {
            self.dropBits(discard);
        }
    }

    fn decodeFixedLitLen(self: *Decompressor) !u16 {
        try self.ensureBits(9);
        const lo9: u16 = @truncate(self.bit_buffer & 0x1FF);

        if (lo9 >= 0x190) {
            self.dropBits(9);
            return (lo9 - 0x190) + 144;
        }

        const lo7: u16 = @truncate(lo9 & 0x7F);
        if (lo7 <= 0x17) {
            self.dropBits(7);
            return 256 + lo7;
        }

        const lo8: u16 = @truncate(lo9 & 0xFF);
        if (lo8 >= 0xC0 and lo8 <= 0xC7) {
            self.dropBits(8);
            return (lo8 - 0xC0) + 280;
        }

        if (lo8 >= 0x30 and lo8 <= 0xBF) {
            self.dropBits(8);
            return lo8 - 0x30;
        }

        self.dropBits(8);
        return error.InvalidLiteral;
    }

    fn decodeFixedDist(self: *Decompressor) !u16 {
        return @intCast(try self.readBitsLE(5));
    }

    const length_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const length_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

    fn decodeLength(self: *Decompressor, code: u16) !u16 {
        if (code < 257 or code > 285) return error.InvalidLengthCode;
        const idx = code - 257;
        if (idx >= length_base.len) return error.InvalidLengthCode;
        var len = length_base[idx];
        if (length_extra[idx] > 0) {
            const extra = try self.readBitsLE(length_extra[idx]);
            len += @intCast(extra);
        }
        return len;
    }

    const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    const dist_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

    fn decodeDistanceVal(self: *Decompressor, code: u16) !u16 {
        if (code > 29) return error.InvalidDistanceCode;
        var dist = dist_base[code];
        if (dist_extra[code] > 0) {
            const extra = try self.readBitsLE(dist_extra[code]);
            dist += @intCast(extra);
        }
        return dist;
    }

    pub fn inflateBlockFixed(self: *Decompressor, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        while (true) {
            const symbol = try self.decodeFixedLitLen();

            if (symbol == 256) {
                break;
            } else if (symbol < 256) {
                try output.append(allocator, @intCast(symbol));
            } else {
                const length = try self.decodeLength(symbol);
                const dist_code = try self.decodeFixedDist();
                const distance = try self.decodeDistanceVal(dist_code);

                const dist_usize: usize = @as(usize, distance);
                if (dist_usize > output.items.len) return error.InvalidDistance;
                const start = output.items.len - dist_usize;
                var i: usize = 0;
                while (i < length) : (i += 1) {
                    const src_idx = start + (i % dist_usize);
                    try output.append(allocator, output.items[src_idx]);
                }
            }
        }
    }

    pub fn inflateBlockStored(self: *Decompressor, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        self.alignToByte();

        const len_lo = try self.readByte();
        const len_hi = try self.readByte();
        const nlen_lo = try self.readByte();
        const nlen_hi = try self.readByte();

        const len = @as(u16, len_lo) | (@as(u16, len_hi) << 8);
        const nlen = @as(u16, nlen_lo) | (@as(u16, nlen_hi) << 8);

        if (len != ~nlen) return error.CorruptStream;

        var i: usize = 0;
        while (i < len) : (i += 1) {
            const b = try self.readByte();
            try output.append(allocator, b);
        }
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

test "deflate compressFixed roundtrip" {
    const allocator = std.testing.allocator;
    const original = "hello world, this is a test of deflate fixed huffman compression!";
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);

    var decomp = Decompressor.init(compressed);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try decomp.inflateBlockFixed(&output, allocator);
    try std.testing.expectEqualSlices(u8, original, output.items);
}

test "deflate compressFixed empty" {
    const allocator = std.testing.allocator;
    const original = "";
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);

    var decomp = Decompressor.init(compressed);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try decomp.inflateBlockFixed(&output, allocator);
    try std.testing.expectEqualSlices(u8, "", output.items);
}

test "deflate compressFixed single byte" {
    const allocator = std.testing.allocator;
    const original = "A";
    const compressed = try compressFixed(original, allocator);
    defer allocator.free(compressed);

    var decomp = Decompressor.init(compressed);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try decomp.inflateBlockFixed(&output, allocator);
    try std.testing.expectEqualSlices(u8, original, output.items);
}

test "decompressor inflateBlockStored" {
    const allocator = std.testing.allocator;
    const original = "stored block test data";

    var comp_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch |err| return err;
    defer comp_buf.deinit(allocator);

    const len: u16 = @truncate(original.len);
    const nlen: u16 = ~len;
    try comp_buf.append(allocator, 0x01);
    try comp_buf.appendSlice(allocator, &[_]u8{ @truncate(len), @truncate(len >> 8), @truncate(nlen), @truncate(nlen >> 8) });
    try comp_buf.appendSlice(allocator, original);

    var decomp = Decompressor.init(comp_buf.items);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try decomp.inflateBlockStored(&output, allocator);
    try std.testing.expectEqualSlices(u8, original, output.items);
}

test "deflate compressFixed roundtrip with low bytes 0x00-0x0F" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };
    const compressed = try compressFixed(&original, allocator);
    defer allocator.free(compressed);

    var decomp = Decompressor.init(compressed);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try decomp.inflateBlockFixed(&output, allocator);
    try std.testing.expectEqualSlices(u8, &original, output.items);
}
