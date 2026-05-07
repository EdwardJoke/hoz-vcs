//! Git Protocol Service - Service handler for Git network protocol
const std = @import("std");
const Io = std.Io;
const packet = @import("packet.zig");

pub const ServiceType = enum {
    upload_pack,
    receive_pack,
};

pub const ServiceHandler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    service_type: ServiceType,
    running: bool = false,
    server: ?std.Io.net.Server = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, service_type: ServiceType) ServiceHandler {
        return .{ .allocator = allocator, .io = io, .service_type = service_type };
    }

    pub fn deinit(self: *ServiceHandler) void {
        self.stop();
    }

    pub fn start(self: *ServiceHandler, host: []const u8) !void {
        const port: u16 = switch (self.service_type) {
            .upload_pack => 9418,
            .receive_pack => 9418,
        };

        const address = try std.Io.net.IpAddress.resolve(self.io, host, port);
        self.server = try address.listen(self.io, .{ .reuse_address = true });
        self.running = true;
    }

    pub fn stop(self: *ServiceHandler) void {
        if (self.server) |*srv| {
            srv.deinit(self.io);
            self.server = null;
        }
        self.running = false;
    }

    pub fn isRunning(self: *ServiceHandler) bool {
        return self.running;
    }

    pub fn accept(self: *ServiceHandler) !std.Io.net.Stream {
        const srv = self.server orelse return error.NotListening;
        return try srv.accept(self.io);
    }
};

pub const V2ServiceCommand = enum {
    ls_refs,
    fetch,
    push,
};

pub const V2ProtocolHandler = struct {
    allocator: std.mem.Allocator,
    command: V2ServiceCommand,
    refs: std.array_hash_map.String([]const u8),
    caps: std.array_hash_map.String(void),

    pub fn init(allocator: std.mem.Allocator) V2ProtocolHandler {
        return .{
            .allocator = allocator,
            .command = .ls_refs,
            .refs = std.array_hash_map.String([]const u8).empty,
            .caps = std.array_hash_map.String(void).empty,
        };
    }

    pub fn deinit(self: *V2ProtocolHandler) void {
        self.refs.deinit(self.allocator);
        self.caps.deinit(self.allocator);
    }

    pub fn parseCommand(self: *V2ProtocolHandler, data: []const u8) !void {
        if (std.mem.eql(u8, data, "ls-refs")) {
            self.command = .ls_refs;
        } else if (std.mem.eql(u8, data, "fetch")) {
            self.command = .fetch;
        } else if (std.mem.eql(u8, data, "push")) {
            self.command = .push;
        } else {
            return error.UnknownCommand;
        }
    }

    pub fn parseRefLine(self: *V2ProtocolHandler, line: []const u8) !void {
        var iter = std.mem.splitScalar(u8, line, ' ');
        const oid = iter.next() orelse return error.MalformedRefLine;
        const ref_name = iter.rest();
        if (ref_name.len > 0 and ref_name[0] == ' ') {
            try self.refs.put(self.allocator, ref_name[1..], oid);
        }
    }

    pub fn parseRefsResponse(self: *V2ProtocolHandler, lines: []const packet.PacketLine) !void {
        for (lines) |line| {
            if (line.flush) continue;
            try self.parseRefLine(line.data);
        }
    }
};

test "ServiceType enum values" {
    try std.testing.expect(@as(u1, @intFromEnum(ServiceType.upload_pack)) == 0);
    try std.testing.expect(@as(u1, @intFromEnum(ServiceType.receive_pack)) == 1);
}

test "ServiceHandler init" {
    const io = std.Io.Threaded.new(.{}).?;
    const handler = ServiceHandler.init(std.testing.allocator, io, .upload_pack);
    try std.testing.expect(handler.allocator == std.testing.allocator);
}

test "ServiceHandler init with receive_pack" {
    const io = std.Io.Threaded.new(.{}).?;
    const handler = ServiceHandler.init(std.testing.allocator, io, .receive_pack);
    try std.testing.expect(handler.service_type == .receive_pack);
}

test "ServiceHandler stop method exists" {
    const io = std.Io.Threaded.new(.{}).?;
    var handler = ServiceHandler.init(std.testing.allocator, io, .upload_pack);
    handler.stop();
    try std.testing.expect(true);
}

test "ServiceHandler isRunning method exists" {
    const io = std.Io.Threaded.new(.{}).?;
    var handler = ServiceHandler.init(std.testing.allocator, io, .upload_pack);
    const running = handler.isRunning();
    try std.testing.expect(running == false);
}

test "V2ProtocolHandler init" {
    var handler = V2ProtocolHandler.init(std.testing.allocator);
    defer handler.deinit();
    try std.testing.expect(handler.command == .ls_refs);
}

test "V2ProtocolHandler parseCommand ls-refs" {
    var handler = V2ProtocolHandler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.parseCommand("ls-refs");
    try std.testing.expect(handler.command == .ls_refs);
}

test "V2ProtocolHandler parseCommand fetch" {
    var handler = V2ProtocolHandler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.parseCommand("fetch");
    try std.testing.expect(handler.command == .fetch);
}

test "V2ProtocolHandler parseRefLine" {
    var handler = V2ProtocolHandler.init(std.testing.allocator);
    defer handler.deinit();
    try handler.parseRefLine("abc123def456789012345678901234567890abcd refs/heads/main");
    const oid = handler.refs.get("refs/heads/main");
    try std.testing.expect(oid != null);
    try std.testing.expectEqualStrings("abc123def456789012345678901234567890abcd", oid.?);
}
