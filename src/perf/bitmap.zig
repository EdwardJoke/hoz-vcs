//! Packfile Bitmap - Bitmap optimization for packfiles
const std = @import("std");

pub const PackfileBitmap = struct {
    allocator: std.mem.Allocator,
    bitmaps: std.StringArrayHashMap([]align(1) const u8),
    hashes: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) PackfileBitmap {
        return .{
            .allocator = allocator,
            .bitmaps = std.StringArrayHashMap([]align(1) const u8).init(allocator),
            .hashes = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PackfileBitmap) void {
        var iter = self.bitmaps.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.bitmaps.deinit();

        for (self.hashes.items) |h| {
            self.allocator.free(h);
        }
        self.hashes.deinit();
    }

    pub fn addBitmap(self: *PackfileBitmap, hash: []const u8, bitmap: []const u8) !void {
        const hash_copy = try self.allocator.dupe(u8, hash);
        const bitmap_copy = try self.allocator.dupe(u8, bitmap);
        try self.bitmaps.put(hash_copy, bitmap_copy);
        try self.hashes.append(hash_copy);
    }

    pub fn hasObject(self: *PackfileBitmap, hash: []const u8) bool {
        return self.bitmaps.contains(hash);
    }

    pub fn getBitmap(self: *PackfileBitmap, hash: []const u8) ?[]const u8 {
        return self.bitmaps.get(hash);
    }

    pub fn and(self: *PackfileBitmap, hash1: []const u8, hash2: []const u8, result: *std.ArrayList(u8)) !void {
        const b1 = self.bitmaps.get(hash1) orelse return;
        const b2 = self.bitmaps.get(hash2) orelse return;
        const min_len = @min(b1.len, b2.len);

        try result.resize(min_len);
        for (0..min_len) |i| {
            result.items[i] = b1[i] & b2[i];
        }
    }

    pub fn or(self: *PackfileBitmap, hash1: []const u8, hash2: []const u8, result: *std.ArrayList(u8)) !void {
        const b1 = self.bitmaps.get(hash1) orelse return;
        const b2 = self.bitmaps.get(hash2) orelse return;
        const max_len = @max(b1.len, b2.len);

        try result.resize(max_len);
        @memset(result.items, 0);

        @memcpy(result.items[0..b1.len], b1);
        for (0..b2.len) |i| {
            result.items[i] |= b2[i];
        }
    }
};

test "PackfileBitmap init" {
    const bitmap = PackfileBitmap.init(std.testing.allocator);
    try std.testing.expect(bitmap.bitmaps.count() == 0);
}

test "PackfileBitmap addBitmap" {
    var bitmap = PackfileBitmap.init(std.testing.allocator);
    defer bitmap.deinit();
    try bitmap.addBitmap("abc123", &.{ 0xFF, 0x00 });
    try std.testing.expect(bitmap.hasObject("abc123"));
}

test "PackfileBitmap and operation" {
    var bitmap = PackfileBitmap.init(std.testing.allocator);
    defer bitmap.deinit();
    try bitmap.addBitmap("abc123", &.{ 0xFF, 0x0F });
    try bitmap.addBitmap("def456", &.{ 0xF0, 0x0F });
    var result = std.ArrayList(u8).init(std.testing.allocator);
    defer result.deinit();
    try bitmap.and("abc123", "def456", &result);
    try std.testing.expect(result.items[0] == 0xF0);
}