//! Reference Advertisement - Parse and manage remote refs
const std = @import("std");
const packet = @import("packet.zig");
const protocol = @import("protocol.zig");

pub const RemoteRef = struct {
    name: []const u8,
    oid: []const u8,
    peeled: ?[]const u8 = null,
};

pub const RefAdvertisement = struct {
    allocator: std.mem.Allocator,
    refs: std.array_hash_map.String(RemoteRef),
    caps: protocol.ProtocolCapabilities,

    pub fn init(allocator: std.mem.Allocator) RefAdvertisement {
        return .{
            .allocator = allocator,
            .refs = std.array_hash_map.String(RemoteRef).empty,
            .caps = protocol.ProtocolCapabilities{},
        };
    }

    pub fn deinit(self: *RefAdvertisement) void {
        self.refs.deinit(self.allocator);
    }

    pub fn parse(self: *RefAdvertisement, lines: []const packet.PacketLine) !void {
        for (lines) |line| {
            if (line.flush) continue;
            try self.parseRefLine(line.data);
        }
    }

    pub fn parseRefLine(self: *RefAdvertisement, line: []const u8) !void {
        if (line.len < 41 or line[40] != ' ') {
            return error.MalformedRefLine;
        }

        const oid = line[0..40];
        const ref_name = line[41..];

        if (std.mem.endsWith(u8, ref_name, "^{}")) {
            const base_name = ref_name[0 .. ref_name.len - 3];
            if (self.refs.get(base_name)) |existing| {
                var updated = existing;
                updated.peeled = oid;
                try self.refs.put(self.allocator, base_name, updated);
            }
        } else {
            try self.refs.put(self.allocator, ref_name, .{
                .name = ref_name,
                .oid = oid,
                .peeled = null,
            });
        }
    }

    pub fn parseV2RefsResponse(self: *RefAdvertisement, lines: []const packet.PacketLine) !void {
        for (lines) |line| {
            if (line.flush) continue;
            if (line.data.len > 0) {
                try self.parseRefLine(line.data);
            }
        }
    }

    pub fn get(self: *RefAdvertisement, name: []const u8) ?RemoteRef {
        return self.refs.get(name);
    }

    pub fn getAll(self: *RefAdvertisement) []const RemoteRef {
        return self.refs.values();
    }

    pub fn getBranches(self: *RefAdvertisement) []const RemoteRef {
        return self.refs.values();
    }

    pub fn getTags(self: *RefAdvertisement) []const RemoteRef {
        return self.refs.values();
    }
};

pub const RefCache = struct {
    allocator: std.mem.Allocator,
    advertisements: std.array_hash_map.String(RefAdvertisement),
    last_update: i64,

    pub fn init(allocator: std.mem.Allocator) RefCache {
        return .{
            .allocator = allocator,
            .advertisements = std.array_hash_map.String(RefAdvertisement).empty,
            .last_update = 0,
        };
    }

    pub fn deinit(self: *RefCache) void {
        var it = self.advertisements.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.advertisements.deinit(self.allocator);
    }

    pub fn update(self: *RefCache, remote: []const u8, adv: RefAdvertisement) !void {
        if (self.advertisements.get(remote)) |existing| {
            existing.deinit();
        }
        try self.advertisements.put(self.allocator, remote, adv);
        self.last_update = std.time.timestamp();
    }

    pub fn get(self: *RefCache, remote: []const u8) ?RefAdvertisement {
        return self.advertisements.get(remote);
    }
};

test "RefAdvertisement init" {
    var adv = RefAdvertisement.init(std.testing.allocator);
    defer adv.deinit();
    try std.testing.expect(adv.refs.count() == 0);
}

test "RefAdvertisement parseRefLine" {
    var adv = RefAdvertisement.init(std.testing.allocator);
    defer adv.deinit();
    try adv.parseRefLine("abc123def456789012345678901234567890abcd refs/heads/main");
    const ref = adv.get("refs/heads/main");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("abc123def456789012345678901234567890abcd", ref.?.oid);
}

test "RefAdvertisement parseRefLine with peeled" {
    var adv = RefAdvertisement.init(std.testing.allocator);
    defer adv.deinit();
    try adv.parseRefLine("abc123def456789012345678901234567890abcd refs/tags/v1.0^{}");
    const ref = adv.get("refs/tags/v1.0");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("abc123def456789012345678901234567890abcd", ref.?.oid);
}

test "RefAdvertisement parse multiple lines" {
    var adv = RefAdvertisement.init(std.testing.allocator);
    defer adv.deinit();
    const lines = &[_]packet.PacketLine{
        .{ .data = "abc123def456789012345678901234567890abcd refs/heads/main", .flush = false },
        .{ .data = "def456789012345678901234567890abcdef123456 refs/heads/devel", .flush = false },
        .{ .flush = true },
    };
    try adv.parse(lines);
    try std.testing.expect(adv.refs.count() == 2);
}

test "RefCache init" {
    var cache = RefCache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expect(cache.last_update == 0);
}
