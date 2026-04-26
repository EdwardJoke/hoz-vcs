//! Tree Comparison Cache - Cache for tree comparison results
//!
//! Caches the results of comparing two trees to avoid repeated
//! traversal and diff computation.

const std = @import("std");
const tree_object = @import("../object/tree.zig");

pub const TreeCompareConfig = struct {
    max_entries: usize = 500,
    enabled: bool = true,
};

pub const TreeCompareStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    size: usize = 0,
    hit_rate: f64 = 0.0,
};

pub const TreeChangeType = enum(u8) {
    added,
    deleted,
    modified,
    renamed,
    copied,
    untracked,
};

pub const TreeChange = struct {
    change_type: TreeChangeType,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    old_oid: ?[20]u8,
    new_oid: ?[20]u8,
    old_mode: ?tree_object.Mode,
    new_mode: ?tree_object.Mode,
    similarity: ?f64,
};

pub const TreeCompareResult = struct {
    changes: []const TreeChange,
    added_count: usize = 0,
    deleted_count: usize = 0,
    modified_count: usize = 0,
    renamed_count: usize = 0,
};

pub const TreeCompareCache = struct {
    allocator: std.mem.Allocator,
    config: TreeCompareConfig,
    entries: std.StringArrayHashMapUnmanaged(TreeCompareEntry),
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    access_counter: u64 = 0,

    pub const TreeCompareEntry = struct {
        result: TreeCompareResult,
        access_time: u64,
    },

    pub fn init(allocator: std.mem.Allocator, config: TreeCompareConfig) TreeCompareCache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = .empty,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *TreeCompareCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.freeEntry(entry.value_ptr);
        }
        self.entries.deinit(self.allocator);
    }

    fn freeEntry(self: *TreeCompareCache, entry: *TreeCompareEntry) void {
        for (entry.result.changes) |change| {
            if (change.old_path) |p| self.allocator.free(p);
            if (change.new_path) |p| self.allocator.free(p);
        }
        self.allocator.free(entry.result.changes);
    }

    pub fn computeKey(old_tree_oid: [20]u8, new_tree_oid: [20]u8) [40]u8 {
        var key: [40]u8 = undefined;
        @memcpy(key[0..20], &old_tree_oid);
        @memcpy(key[20..40], &new_tree_oid);
        return key;
    }

    pub fn get(self: *TreeCompareCache, key: []const u8) ?*const TreeCompareResult {
        if (!self.config.enabled) return null;

        if (self.entries.get(key)) |*entry| {
            self.hits += 1;
            entry.access_time = self.access_counter;
            self.access_counter += 1;
            return &entry.result;
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *TreeCompareCache, key: []const u8, result: TreeCompareResult) !void {
        if (!self.config.enabled) return;

        if (self.entries.getEntry(key)) |entry| {
            self.freeEntry(entry.value_ptr);
            entry.value_ptr.* = .{
                .result = result,
                .access_time = self.access_counter,
            };
            self.access_counter += 1;
            return;
        }

        while (self.entries.count() >= self.config.max_entries) {
            try self.evictOldest();
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        try self.entries.put(self.allocator, key_copy, .{
            .result = result,
            .access_time = self.access_counter,
        });
        self.access_counter += 1;
    }

    fn evictOldest(self: *TreeCompareCache) !void {
        var oldest_key: []const u8 = "";
        var oldest_time: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.access_time < oldest_time) {
                oldest_time = entry.value_ptr.access_time;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key.len > 0) {
            if (self.entries.get(oldest_key)) |entry| {
                self.freeEntry(entry);
            }
            self.entries.remove(oldest_key);
            self.evictions += 1;
        }
    }

    pub fn invalidate(self: *TreeCompareCache, key: []const u8) void {
        if (self.entries.get(key)) |entry| {
            self.freeEntry(entry);
            self.entries.remove(key);
        }
    }

    pub fn clear(self: *TreeCompareCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.freeEntry(entry);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn hitRate(self: *const TreeCompareCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn getStats(self: *const TreeCompareCache) TreeCompareStats {
        return TreeCompareStats{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .size = self.entries.count(),
            .hit_rate = self.hitRate(),
        };
    }

    pub fn setEnabled(self: *TreeCompareCache, enabled: bool) void {
        self.config.enabled = enabled;
        if (!enabled) {
            self.clear();
        }
    }
};

test "TreeCompareCache init" {
    const cache = TreeCompareCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    try std.testing.expect(cache.config.enabled == true);
}

test "TreeCompareCache computeKey" {
    const old_oid: [20]u8 = .{1} ** 20;
    const new_oid: [20]u8 = .{2} ** 20;

    const key1 = TreeCompareCache.computeKey(old_oid, new_oid);
    const key2 = TreeCompareCache.computeKey(old_oid, new_oid);

    try std.testing.expectEqualSlices(u8, &key1, &key2);

    const key3 = TreeCompareCache.computeKey(new_oid, old_oid);
    try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "TreeCompareCache put and get" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const old_oid: [20]u8 = .{1} ** 20;
    const new_oid: [20]u8 = .{2} ** 20;
    const key = TreeCompareCache.computeKey(old_oid, new_oid);

    const changes = &[_]TreeChange{
        TreeChange{
            .change_type = .added,
            .old_path = null,
            .new_path = "new.txt",
            .old_oid = null,
            .new_oid = new_oid,
            .old_mode = null,
            .new_mode = .file,
            .similarity = null,
        },
    };
    const result = TreeCompareResult{
        .changes = changes,
        .added_count = 1,
    };

    try cache.put(&key, result);

    const cached = cache.get(&key);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(usize, 1), cached.?.added_count);
}

test "TreeCompareCache miss" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const old_oid: [20]u8 = .{1} ** 20;
    const new_oid: [20]u8 = .{2} ** 20;
    const key = TreeCompareCache.computeKey(old_oid, new_oid);

    const cached = cache.get(&key);
    try std.testing.expect(cached == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "TreeCompareCache hit increments counter" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const old_oid: [20]u8 = .{1} ** 20;
    const new_oid: [20]u8 = .{2} ** 20;
    const key = TreeCompareCache.computeKey(old_oid, new_oid);

    const changes = &[_]TreeChange{};
    const result = TreeCompareResult{ .changes = changes };
    try cache.put(&key, result);

    _ = cache.get(&key);
    _ = cache.get(&key);
    try std.testing.expectEqual(@as(u64, 2), cache.hits);
}

test "TreeCompareCache eviction" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .max_entries = 2 });
    defer cache.deinit();

    const oid1: [20]u8 = .{1} ** 20;
    const oid2: [20]u8 = .{2} ** 20;
    const oid3: [20]u8 = .{3} ** 20;

    const key1 = TreeCompareCache.computeKey(oid1, oid2);
    const key2 = TreeCompareCache.computeKey(oid2, oid3);
    const key3 = TreeCompareCache.computeKey(oid3, oid1);

    const changes = &[_]TreeChange{};
    const result = TreeCompareResult{ .changes = changes };

    try cache.put(&key1, result);
    try cache.put(&key2, result);
    try cache.put(&key3, result);

    try std.testing.expectEqual(@as(u64, 1), cache.evictions);
    try std.testing.expect(cache.get(&key1) == null);
}

test "TreeCompareCache clear" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const oid1: [20]u8 = .{1} ** 20;
    const oid2: [20]u8 = .{2} ** 20;
    const key = TreeCompareCache.computeKey(oid1, oid2);

    const changes = &[_]TreeChange{};
    const result = TreeCompareResult{ .changes = changes };
    try cache.put(&key, result);

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expect(cache.get(&key) == null);
}

test "TreeCompareCache disabled" {
    var cache = TreeCompareCache.init(std.testing.allocator, .{ .enabled = false });
    defer cache.deinit();

    const oid1: [20]u8 = .{1} ** 20;
    const oid2: [20]u8 = .{2} ** 20;
    const key = TreeCompareCache.computeKey(oid1, oid2);

    const changes = &[_]TreeChange{};
    const result = TreeCompareResult{ .changes = changes };
    try cache.put(&key, result);

    try std.testing.expect(cache.get(&key) == null);
}
