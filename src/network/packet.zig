//! Packet-line Encoding - Git's network packet format
const std = @import("std");

pub const MAX_PACKET_LINE_LENGTH: usize = 65520;
pub const MIN_PACKET_LINE_LENGTH: usize = 4;
pub const FLUSH_PACKET_LINE_LENGTH: usize = 0;
pub const DELIM_PACKET_LINE_LENGTH: usize = 1;

pub const SidebandChannel = enum(u8) {
    data = 1,
    progress = 2,
    err = 3,
};

pub const PacketLine = struct {
    data: []const u8,
    flush: bool,
};

pub const PacketDecodeError = error{
    PacketLineTooLong,
    PacketLineTooShort,
    InvalidLengthPrefix,
    BufferOverflow,
    MalformedPacket,
};

pub const PacketEncoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PacketEncoder {
        return .{ .allocator = allocator };
    }

    pub fn encode(self: *PacketEncoder, data: []const u8) ![]u8 {
        if (data.len > MAX_PACKET_LINE_LENGTH - MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        var result = try self.allocator.alloc(u8, MIN_PACKET_LINE_LENGTH + data.len);
        errdefer self.allocator.free(result);

        const total_len: u16 = @as(u16, @intCast(MIN_PACKET_LINE_LENGTH + data.len));
        const printed = try std.fmt.bufPrint(result[0..4], "{x:0>4}", .{total_len});
        _ = printed;
        @memcpy(result[MIN_PACKET_LINE_LENGTH..], data);
        return result;
    }

    pub fn encodeFlush(self: *PacketEncoder) []const u8 {
        _ = self;
        return &[0]u8{};
    }

    pub fn encodeDelim(self: *PacketEncoder) ![]u8 {
        return try self.encode(&[_]u8{0});
    }

    pub fn encodeSideband(self: *PacketEncoder, channel: SidebandChannel, data: []const u8) ![]u8 {
        if (data.len > MAX_PACKET_LINE_LENGTH - MIN_PACKET_LINE_LENGTH - 1) {
            return PacketDecodeError.PacketLineTooLong;
        }

        var result = try self.allocator.alloc(u8, MIN_PACKET_LINE_LENGTH + 1 + data.len);
        errdefer self.allocator.free(result);

        const total_len = MIN_PACKET_LINE_LENGTH + 1 + data.len;
        std.fmt.bufPrintSentinel(result[0..4], 0, "{x}", .{total_len});
        result[MIN_PACKET_LINE_LENGTH] = @intFromEnum(channel);
        @memcpy(result[MIN_PACKET_LINE_LENGTH + 1 ..], data);
        return result;
    }
};

pub const PacketDecoder = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,
    offset: usize,

    pub fn init(allocator: std.mem.Allocator) PacketDecoder {
        return .{
            .allocator = allocator,
            .buffer = &.{},
            .offset = 0,
        };
    }

    pub fn setBuffer(self: *PacketDecoder, data: []const u8) void {
        self.buffer = data;
        self.offset = 0;
    }

    pub fn next(self: *PacketDecoder) !?PacketLine {
        if (self.offset >= self.buffer.len) {
            return null;
        }

        const remaining = self.buffer[self.offset..];
        if (remaining.len < MIN_PACKET_LINE_LENGTH) {
            if (remaining.len == 0) return null;
            return PacketDecodeError.PacketLineTooShort;
        }

        const len = try parseLengthPrefix(remaining[0..MIN_PACKET_LINE_LENGTH]);

        if (len == FLUSH_PACKET_LINE_LENGTH) {
            self.offset += MIN_PACKET_LINE_LENGTH;
            return PacketLine{ .data = &.{}, .flush = true };
        }

        if (len > MAX_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        if (remaining.len < len) {
            return PacketDecodeError.BufferOverflow;
        }

        self.offset += len;
        const payload = remaining[MIN_PACKET_LINE_LENGTH..len];
        return PacketLine{ .data = payload, .flush = false };
    }

    pub fn decode(_: *PacketDecoder, data: []const u8) !PacketLine {
        if (data.len == 0) {
            return PacketLine{ .data = &.{}, .flush = true };
        }

        if (data.len < MIN_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooShort;
        }

        const len = try parseLengthPrefix(data[0..MIN_PACKET_LINE_LENGTH]);

        if (len == FLUSH_PACKET_LINE_LENGTH) {
            return PacketLine{ .data = &.{}, .flush = true };
        }

        if (len > MAX_PACKET_LINE_LENGTH) {
            return PacketDecodeError.PacketLineTooLong;
        }

        if (data.len < len) {
            return PacketDecodeError.BufferOverflow;
        }

        const payload = data[MIN_PACKET_LINE_LENGTH..len];
        return PacketLine{ .data = payload, .flush = false };
    }

    pub fn decodeSideband(_: *PacketDecoder, line: PacketLine) !?struct { channel: SidebandChannel, data: []const u8 } {
        if (line.data.len == 0 or line.flush) {
            return null;
        }

        const channel_val = line.data[0];
        const channel: SidebandChannel = @enumFromInt(channel_val);
        const payload = line.data[1..];

        return .{
            .channel = channel,
            .data = payload,
        };
    }

    pub fn isFlush(data: []const u8) bool {
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
            '0'...'9' => @as(u4, @intCast(byte - '0')),
            'a'...'f' => @as(u4, @intCast(byte - 'a' + 10)),
            'A'...'F' => @as(u4, @intCast(byte - 'A' + 10)),
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

test "PacketEncoder encode" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const encoded = try encoder.encode("test");
    try std.testing.expect(encoded.len == 8);
    try std.testing.expect(std.mem.eql(u8, encoded[4..], "test"));
}

test "PacketEncoder encode with 0032 prefix" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const encoded = try encoder.encode("test");
    try std.testing.expect(std.mem.eql(u8, encoded[0..4], "0032"));
}

test "PacketEncoder encodeFlush" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const flushed = encoder.encodeFlush();
    try std.testing.expect(flushed.len == 0);
}

test "PacketEncoder encodeSideband" {
    var encoder = PacketEncoder.init(std.testing.allocator);
    const encoded = try encoder.encodeSideband(.data, "progress info");
    try std.testing.expect(encoded[4] == 1);
    try std.testing.expect(std.mem.eql(u8, encoded[5..], "progress info"));
}

test "PacketDecoder init" {
    const decoder = PacketDecoder.init(std.testing.allocator);
    try std.testing.expect(decoder.allocator == std.testing.allocator);
}

test "PacketDecoder decode flush" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const line = try decoder.decode("");
    try std.testing.expect(line.flush == true);
    try std.testing.expect(line.data.len == 0);
}

test "PacketDecoder decode packet" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const line = try decoder.decode("0032test");
    try std.testing.expect(line.flush == false);
    try std.testing.expectEqualStrings("test", line.data);
}

test "PacketDecoder decodeSideband" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    const line = PacketLine{ .data = "\x01progress data", .flush = false };
    const result = try decoder.decodeSideband(line);
    try std.testing.expect(result.?.channel == .data);
    try std.testing.expectEqualStrings("progress data", result.?.data);
}

test "PacketDecoder next" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    decoder.setBuffer("0032test0031hi!!");
    const line1 = try decoder.next();
    try std.testing.expect(line1.?.flush == false);
    try std.testing.expectEqualStrings("test", line1.?.data);
    const line2 = try decoder.next();
    try std.testing.expect(line2.?.flush == false);
    try std.testing.expectEqualStrings("hi!!", line2.?.data);
}

test "PacketDecoder next with flush" {
    var decoder = PacketDecoder.init(std.testing.allocator);
    decoder.setBuffer("0032test0000");
    const line1 = try decoder.next();
    try std.testing.expectEqualStrings("test", line1.?.data);
    const line2 = try decoder.next();
    try std.testing.expect(line2.?.flush == true);
}
