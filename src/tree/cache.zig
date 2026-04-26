//! Tree Cache - LRU cache for tree entry lookups
//!
//! Caches tree entries by OID to avoid repeated parsing of the same trees.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const tree_object = @import("../object/tree.zig");

pub const TreeCacheConfig = struct {
    max_entries: usize = 500,
    max_memory_bytes: usize = 10 * 1024 * 1024,
    enabled: bool = true,
};

pub const TreeCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    size: usize = 0,
    max_size: usize = 0,
    hit_rate: f64 = 0.0,
};

pub const TreeCacheEntry = struct {
    tree: tree_object.Tree,
    access_time: u64,
    size_bytes: usize,
};

pub const TreeCache = struct {
    allocator: std.mem.Allocator,
    config: TreeCacheConfig,
    entries: std.StringArrayHashMapUnmanaged(TreeCacheEntry),
    total_memory: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    access_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: TreeCacheConfig) TreeCache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = .empty,
            .total_memory = 0,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *TreeCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.freeTree(entry.value_ptr);
        }
        self.entries.deinit(self.allocator);
    }

    fn freeTree(self: *TreeCache, entry: *TreeCacheEntry) void {
        for (entry.tree.entries) |e| {
            self.allocator.free(e.name);
        }
        self.allocator.free(entry.tree.entries);
        self.total_memory -= entry.size_bytes;
    }

    pub fn get(self: *TreeCache, oid: oid_mod.OID) ?*const tree_object.Tree {
        if (!self.config.enabled) return null;

        const key = oid.toHex();
        if (self.entries.get(key)) |*entry| {
            self.hits += 1;
            entry.access_time = self.access_counter;
            self.access_counter += 1;
            return &entry.tree;
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *TreeCache, oid: oid_mod.OID, tree: tree_object.Tree) !void {
        if (!self.config.enabled) return;

        const key = oid.toHex();

        if (self.entries.getEntry(&key)) |entry| {
            self.freeTree(entry.value_ptr);
            entry.value_ptr.* = .{
                .tree = tree,
                .access_time = self.access_counter,
                .size_bytes = self.estimateSize(tree),
            };
            self.access_counter += 1;
            return;
        }

        while (self.entries.count() >= self.config.max_entries or
            self.total_memory + self.estimateSize(tree) > self.config.max_memory_bytes)
        {
            try self.evictOldest();
        }

        const entry_size = @sizeOf(TreeCacheEntry) + key.len;
        try self.entries.put(self.allocator, key, .{
            .tree = tree,
            .access_time = self.access_counter,
            .size_bytes = self.estimateSize(tree),
        });
        self.total_memory += entry_size + self.estimateSize(tree);
        self.access_counter += 1;
    }

    fn evictOldest(self: *TreeCache) !void {
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
                self.freeTree(entry);
            }
            self.entries.remove(oldest_key);
            self.evictions += 1;
        }
    }

    fn estimateSize(self: *TreeCache, tree: tree_object.Tree) usize {
        var size: usize = @sizeOf(tree_object.Tree);
        for (tree.entries) |entry| {
            size += @sizeOf(tree_object.TreeEntry) + entry.name.len + @sizeOf(oid_mod.OID);
        }
        return size;
    }

    pub fn invalidate(self: *TreeCache, oid: oid_mod.OID) void {
        const key = oid.toHex();
        if (self.entries.get(&key)) |entry| {
            self.freeTree(entry);
            self.entries.remove(key);
        }
    }

    pub fn clear(self: *TreeCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.freeTree(entry);
        }
        self.entries.clearRetainingCapacity();
        self.total_memory = 0;
    }

    pub fn hitRate(self: *const TreeCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn getStats(self: *const TreeCache) TreeCacheStats {
        return TreeCacheStats{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .size = self.entries.count(),
            .max_size = self.config.max_entries,
            .hit_rate = self.hitRate(),
        };
    }

    pub fn setEnabled(self: *TreeCache, enabled: bool) void {
        self.config.enabled = enabled;
        if (!enabled) {
            self.clear();
        }
    }
};

test "TreeCache init" {
    const cache = TreeCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    try std.testing.expect(cache.config.enabled == true);
    try std.testing.expect(cache.entries.count() == 0);
}

test "TreeCache put and get" {
    var cache = TreeCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const oid = oid_mod.OID.zero();
    const entries = &[_]tree_object.TreeEntry{
        tree_object.TreeEntry{ .mode = .file, .oid = oid, .name = "test.txt" },
    };
    const tree = tree_object.Tree.create(entries);

    try cache.put(oid, tree);
    const result = cache.get(oid);
    try std.testing.expect(result != null);
}

test "TreeCache miss" {
    var cache = TreeCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const oid = oid_mod.OID.zero();
    const result = cache.get(oid);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "TreeCache hit increments counter" {
    var cache = TreeCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const oid = oid_mod.OID.zero();
    const entries = &[_]tree_object.TreeEntry{
        tree_object.TreeEntry{ .mode = .file, .oid = oid, .name = "test.txt" },
    };
    const tree = tree_object.Tree.create(entries);
    try cache.put(oid, tree);

    _ = cache.get(oid);
    _ = cache.get(oid);
    try std.testing.expectEqual(@as(u64, 2), cache.hits);
}

test "TreeCache eviction" {
    var cache = TreeCache.init(std.testing.allocator, .{ .max_entries = 2 });
    defer cache.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    const entries = &[_]tree_object.TreeEntry{
        tree_object.TreeEntry{ .mode = .file, .oid = oid1, .name = "a.txt" },
    };

    try cache.put(oid1, tree_object.Tree.create(entries));
    try cache.put(oid2, tree_object.Tree.create(entries));
    try cache.put(oid3, tree_object.Tree.create(entries));

    try std.testing.expectEqual(@as(u64, 1), cache.evictions);
    try std.testing.expect(cache.get(oid1) == null);
    try std.testing.expect(cache.get(oid2) != null);
}

test "TreeCache clear" {
    var cache = TreeCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const oid = oid_mod.OID.zero();
    const entries = &[_]tree_object.TreeEntry{
        tree_object.TreeEntry{ .mode = .file, .oid = oid, .name = "test.txt" },
    };
    try cache.put(oid, tree_object.Tree.create(entries));

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expect(cache.get(oid) == null);
}

test "TreeCache disabled" {
    var cache = TreeCache.init(std.testing.allocator, .{ .enabled = false });
    defer cache.deinit();

    const oid = oid_mod.OID.zero();
    const entries = &[_]tree_object.TreeEntry{
        tree_object.TreeEntry{ .mode = .file, .oid = oid, .name = "test.txt" },
    };
    try cache.put(oid, tree_object.Tree.create(entries));

    try std.testing.expect(cache.get(oid) == null);
}
