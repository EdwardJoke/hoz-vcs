//! Reference Advertisement - Parse and manage remote refs
const std = @import("std");
const Io = std.Io;
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
        if (self.getBranchesFiltered(self.allocator)) |filtered| return filtered;
        return &[_]RemoteRef{};
    }

    pub fn getTags(self: *RefAdvertisement) []const RemoteRef {
        if (self.getTagsFiltered(self.allocator)) |filtered| return filtered;
        return &[_]RemoteRef{};
    }

    pub fn loadLocalPackedRefs(self: *RefAdvertisement, allocator: std.mem.Allocator, io: Io) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(io, ".git", .{}) catch return;

        const content = git_dir.readFileAlloc(io, "packed-refs", allocator, .limited(1024 * 1024)) catch {
            git_dir.close(io);
            return;
        };
        defer {
            allocator.free(content);
            git_dir.close(io);
        }

        var lines = std.mem.tokenizeAny(u8, content, "\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.endsWith(u8, line, "^")) continue;

            var parts = std.mem.tokenizeAny(u8, line, " ");
            const oid_hex = parts.next() orelse continue;
            const ref_name = parts.rest();
            if (ref_name.len == 0) continue;

            if (self.refs.contains(ref_name)) continue;
            try self.refs.put(allocator, ref_name, .{
                .name = ref_name,
                .oid = oid_hex,
                .peeled = null,
            });
        }
    }

    pub fn getBranchesFiltered(self: *RefAdvertisement, allocator: std.mem.Allocator) ![]const RemoteRef {
        var result = std.ArrayList(RemoteRef).empty;
        errdefer result.deinit(allocator);

        for (self.refs.values()) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/") or std.mem.startsWith(u8, ref.name, "refs/remotes/")) {
                try result.append(allocator, ref);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getTagsFiltered(self: *RefAdvertisement, allocator: std.mem.Allocator) ![]const RemoteRef {
        var result = std.ArrayList(RemoteRef).empty;
        errdefer result.deinit(allocator);

        for (self.refs.values()) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
                try result.append(allocator, ref);
            }
        }
        return result.toOwnedSlice(allocator);
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
