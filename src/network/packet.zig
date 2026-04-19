//! Packet-line Encoding - Git's network packet format
const std = @import("std");

pub const MAX_PACKET_LINE_LENGTH: usize = 65520;
pub const MIN_PACKET_LINE_LENGTH: usize = 4;
pub const FLUSH_PACKET_LINE_LENGTH: usize = 0;

pub const PacketLine = struct {
    data: []const u8,
    flush: bool,
};

pub const PacketDecodeError = error{
    PacketLineTooLong,
    PacketLineTooShort,
    InvalidLengthPrefix,
    BufferOverflow,
};

pub const PacketEncoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PacketEncoder {
        return .{ .allocator = allocator };
    }

    pub fn encode(self: *PacketEncoder, data: []const u8) ![]const u8 {
        if (data.len > MAX_PACKET_LINE_LENGTH - MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        var result = try self.allocator.alloc(u8, MIN_PACKET_LINE_LENGTH + data.len);
        errdefer self.allocator.free(result);

        const len = MIN_PACKET_LINE_LENGTH + data.len;
        const len_hex = std.fmt.hexInt(len);
        @memcpy(result[0..4], &[_]u8{ '0', '0', '0', '0' });

        const hex_chars = len_hex.len;
        if (hex_chars <= 4) {
            @memcpy(result[4 - hex_chars .. 4], len_hex);
        }

        @memcpy(result[MIN_PACKET_LINE_LENGTH..], data);
        return result;
    }

    pub fn encodeWithLength(self: *PacketEncoder, data: []const u8) ![]const u8 {
        if (data.len > MAX_PACKET_LINE_LENGTH - MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        const total_len = MIN_PACKET_LINE_LENGTH + data.len;
        var result = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(result);

        try formatLengthPrefix(result[0..4], total_len);
        @memcpy(result[MIN_PACKET_LINE_LENGTH..], data);
        return result;
    }

    pub fn flush(self: *PacketEncoder) []const u8 {
        _ = self;
        return "";
    }

    fn formatLengthPrefix(buf: *[4]u8, length: usize) !void {
        if (length > MAX_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        const hex_len = std.fmt.hexInt(length);
        @memcpy(buf[0..4], &[_]u8{ '0', '0', '0', '0' });

        const start = 4 - hex_len.len;
        @memcpy(buf[start..4], hex_len);
    }
};

pub const PacketDecoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PacketDecoder {
        return .{ .allocator = allocator };
    }

    pub fn decode(self: *PacketDecoder, data: []const u8) !PacketLine {
        _ = self;
        if (data.len == 0) {
            return PacketLine{ .data = &.{}, .flush = true };
        }

        if (data.len < MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooShort;
        }

        const len_bytes = data[0..4];
        const parsed_len = try parseLengthPrefix(len_bytes);

        if (parsed_len == FLUSH_PACKET_LINE_LENGTH) {
            return PacketLine{ .data = &.{}, .flush = true };
        }

        if (parsed_len > MAX_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        if (data.len < parsed_len) {
            return PacketDecodeError.BufferOverflow;
        }

        const payload = data[MIN_PACKET_LINE_LENGTH..parsed_len];
        return PacketLine{ .data = payload, .flush = false };
    }

    pub fn decodeMultiple(self: *PacketDecoder, data: []const u8) ![]const PacketLine {
        var lines = std.ArrayList(PacketLine).init(self.allocator);
        errdefer lines.deinit();

        var offset: usize = 0;
        while (offset < data.len) {
            const remaining = data[offset..];
            if (remaining.len == 0) break;

            const line = try self.decode(remaining);
            try lines.append(line);

            if (line.flush) break;

            const consumed = if (line.data.len > 0)
                MIN_PACKET_LINE_LENGTH + line.data.len
            else
                MIN_PACKET_LINE_LENGTH;

            if (consumed == 0 or offset + consumed > data.len) break;
            offset += consumed;
        }

        return lines.toOwnedSlice();
    }

    pub fn isFlush(self: *PacketDecoder, data: []const u8) bool {
        _ = self;
        return data.len == 0;
    }

    fn parseLengthPrefix(prefix: []const u8) !usize {
        if (prefix.len < MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.InvalidLengthPrefix;
        }

        var result: usize = 0;
        for (0..MIN_PACKET_LINE_LENGTH) |i| {
            const byte = prefix[i];
            const nibble = try parseHexNibble(byte);
            result = (result << 4) | nibble;
        }

        return result;
    }

    fn parseHexNibble(byte: u8) !u4 {
        return switch (byte) {
            '0'...'9' => @as(u4, byte - '0'),
            'a'...'f' => @as(u4, byte - 'a' + 10),
            'A'...'F' => @as(u4, byte - 'A' + 10),
            else => PacketDecodeError.InvalidLengthPrefix,
        };
    }
};

test "PacketLine structure" {
    const line = PacketLine{ .data = "hello", .flush = false };
    try std.testing.expectEqualStrings("hello", line.data);
    try std.testing.expect(line.flush == false);
}

test "PacketEncoder init" {
    const encoder = PacketEncoder.init(std.testing.allocator);
    try std.testing.expect(encoder.allocator == std.testing.allocator);
}

test "PacketEncoder encode method exists" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const encoded = try encoder.encode("test data");
    try std.testing.expectEqualStrings("test data", encoded);
}

test "PacketEncoder encodeWithLength method exists" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const encoded = try encoder.encodeWithLength("test");
    try std.testing.expectEqualStrings("test", encoded);
}

test "PacketEncoder flush method exists" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const flushed = encoder.flush();
    try std.testing.expect(flushed.len == 0);
}

test "PacketDecoder init" {
    const decoder = PacketDecoder.init(std.testing.allocator);
    try std.testing.expect(decoder.allocator == std.testing.allocator);
}

test "PacketDecoder decode method exists" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const line = try decoder.decode("test");
    try std.testing.expectEqualStrings("test", line.data);
}

test "PacketDecoder decodeMultiple method exists" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const lines = try decoder.decodeMultiple("test data");
    try std.testing.expect(lines.len == 0);
}

test "PacketDecoder isFlush method exists" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const is_flush = decoder.isFlush("");
    try std.testing.expect(is_flush == true);
}
