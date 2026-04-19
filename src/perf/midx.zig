//! Multi-Pack Index - Index multiple packfiles for faster object lookup
const std = @import("std");

pub const MultiPackIndex = struct {
    allocator: std.mem.Allocator,
    objects: std.StringArrayHashMap(PackOffset),
    packs: std.ArrayList(PackInfo),

    pub const PackOffset = struct {
        pack_index: u32,
        offset: u64,
    };

    pub const PackInfo = struct {
        hash: []const u8,
        object_count: u32,
    },

    pub fn init(allocator: std.mem.Allocator) MultiPackIndex {
        return .{
            .allocator = allocator,
            .objects = std.StringArrayHashMap(PackOffset).init(allocator),
            .packs = std.ArrayList(PackInfo).init(allocator),
        };
    }

    pub fn deinit(self: *MultiPackIndex) void {
        self.objects.deinit();
        for (self.packs.items) |p| {
            self.allocator.free(p.hash);
        }
        self.packs.deinit();
    }

    pub fn addPack(self: *MultiPackIndex, hash: []const u8, object_count: u32) !void {
        const hash_copy = try self.allocator.dupe(u8, hash);
        try self.packs.append(.{ .hash = hash_copy, .object_count = object_count });
    }

    pub fn addObject(self: *MultiPackIndex, object_hash: []const u8, pack_index: u32, offset: u64) !void {
        try self.objects.put(object_hash, .{ .pack_index = pack_index, .offset = offset });
    }

    pub fn findObject(self: *MultiPackIndex, object_hash: []const u8) ?PackOffset {
        return self.objects.get(object_hash);
    }

    pub fn getPackCount(self: *MultiPackIndex) usize {
        return self.packs.items.len;
    }

    pub fn getObjectCount(self: *MultiPackIndex) usize {
        return self.objects.count();
    }
};

test "MultiPackIndex init" {
    const midx = MultiPackIndex.init(std.testing.allocator);
    try std.testing.expect(midx.getPackCount() == 0);
}

test "MultiPackIndex addPack" {
    var midx = MultiPackIndex.init(std.testing.allocator);
    defer midx.deinit();
    try midx.addPack("pack-abc123", 100);
    try std.testing.expect(midx.getPackCount() == 1);
}

test "MultiPackIndex addObject" {
    var midx = MultiPackIndex.init(std.testing.allocator);
    defer midx.deinit();
    try midx.addPack("pack-abc123", 100);
    try midx.addObject("object-hash", 0, 12345);
    try std.testing.expect(midx.getObjectCount() == 1);
}