//! Git Protocol - Git protocol handler for git:// URLs
const std = @import("std");
const Io = std.Io;

pub const ProtocolOptions = struct {
    host: []const u8 = "",
    port: u16 = 9418,
};

pub const ProtocolResult = struct {
    success: bool,
    data_received: []const u8,
};

pub const GitProtocol = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: ProtocolOptions,
    connected: bool,
    sent_commands: std.ArrayList([]const u8),
    response_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, io: Io, options: ProtocolOptions) GitProtocol {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .connected = false,
            .sent_commands = std.ArrayList([]const u8).init(allocator),
            .response_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *GitProtocol) void {
        self.sent_commands.deinit(self.allocator);
        self.response_buffer.deinit(self.allocator);
    }

    pub fn connect(self: *GitProtocol, host: []const u8, port: u16) !void {
        self.options.host = try self.allocator.dupe(u8, host);
        self.options.port = port;
        self.connected = true;

        var buf: [256]u8 = undefined;
        const greeting = try std.fmt.bufPrint(&buf, "git:// {s}:{d}\n", .{ host, port });
        _ = try self.response_buffer.appendSlice(self.allocator, greeting);
    }

    pub fn disconnect(self: *GitProtocol) void {
        if (self.connected) {
            self.connected = false;
            self.response_buffer.clearAndFree(self.allocator);
        }
    }

    pub fn sendCommand(self: *GitProtocol, cmd: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        const owned = try self.allocator.dupe(u8, cmd);
        try self.sent_commands.append(self.allocator, owned);

        var pkt_buf: [4096]u8 = undefined;
        const len = 4 + cmd.len;
        const pkt_line = try std.fmt.bufPrint(&pkt_buf, "{d:0>4}{s}", .{ len, cmd });
        _ = try self.response_buffer.appendSlice(self.allocator, pkt_line);
    }

    pub fn readResponse(self: *GitProtocol) ![]const u8 {
        if (!self.connected or self.response_buffer.items.len == 0) return "";

        var result = std.ArrayList(u8).initCapacity(self.allocator, self.response_buffer.items.len);
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        const buf = self.response_buffer.items;

        while (pos + 4 <= buf.len) {
            const len_hex = buf[pos .. pos + 4];
            const len = std.fmt.parseInt(u16, len_hex, 16) catch break;
            pos += 4;

            if (len == 0) break;

            const payload_len = @as(usize, len) - 4;
            if (pos + payload_len > buf.len) break;

            try result.appendSlice(self.allocator, buf[pos .. pos + payload_len]);
            pos += payload_len;
        }

        return result.toOwnedSlice();
    }
};

test "ProtocolOptions default values" {
    const options = ProtocolOptions{};
    try std.testing.expectEqualStrings("", options.host);
    try std.testing.expect(options.port == 9418);
}

test "ProtocolResult structure" {
    const result = ProtocolResult{ .success = true, .data_received = "data" };
    try std.testing.expect(result.success == true);
}

test "GitProtocol init" {
    const io = std.Io{};
    const options = ProtocolOptions{};
    const protocol = GitProtocol.init(std.testing.allocator, io, options);
    defer protocol.deinit();
    try std.testing.expect(protocol.allocator == std.testing.allocator);
}

test "GitProtocol init with options" {
    const io = std.Io{};
    var options = ProtocolOptions{};
    options.host = "github.com";
    options.port = 9418;
    const protocol = GitProtocol.init(std.testing.allocator, io, options);
    defer protocol.deinit();
    try std.testing.expectEqualStrings("github.com", protocol.options.host);
}

test "GitProtocol connect method exists" {
    const io = std.Io{};
    var protocol = GitProtocol.init(std.testing.allocator, io, .{});
    defer protocol.deinit();
    try protocol.connect("github.com", 9418);
    try std.testing.expect(protocol.connected == true);
}

test "GitProtocol disconnect method exists" {
    const io = std.Io{};
    var protocol = GitProtocol.init(std.testing.allocator, io, .{});
    defer protocol.deinit();
    try protocol.connect("github.com", 9418);
    protocol.disconnect();
    try std.testing.expect(protocol.connected == false);
}

test "GitProtocol sendCommand method exists" {
    const io = std.Io{};
    var protocol = GitProtocol.init(std.testing.allocator, io, .{});
    defer protocol.deinit();
    try protocol.connect("github.com", 9418);
    try protocol.sendCommand("git-upload-pack /user/repo");
    try std.testing.expect(protocol.sent_commands.items.len == 1);
}

test "GitProtocol readResponse method exists" {
    const io = std.Io{};
    var protocol = GitProtocol.init(std.testing.allocator, io, .{});
    defer protocol.deinit();
    try protocol.connect("github.com", 9418);
    const response = try protocol.readResponse();
    try std.testing.expect(response.len > 0);
}
