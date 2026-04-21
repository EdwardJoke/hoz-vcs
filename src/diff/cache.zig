//! Diff Cache - LRU cache for diff results
//!
//! Caches diff results based on content hash to avoid recomputing
//! identical diffs when files haven't changed.

const std = @import("std");
const crypto = std.crypto;

pub const DiffCacheConfig = struct {
    max_entries: usize = 1000,
    max_memory_bytes: usize = 50 * 1024 * 1024,
    enabled: bool = true,
};

pub const DiffCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    size: usize = 0,
    max_size: usize = 0,
    hit_rate: f64 = 0.0,
};

pub const DiffCacheEntry = struct {
    result_data: []u8,
    old_content_hash: [20]u8,
    new_content_hash: [20]u8,
    options_hash: [16]u8,
    access_time: u64,
    size_bytes: usize,
};

pub const DiffCache = struct {
    allocator: std.mem.Allocator,
    config: DiffCacheConfig,
    entries: std.StringArrayHashMap(DiffCacheEntry),
    total_memory: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    access_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: DiffCacheConfig) DiffCache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.StringArrayHashMap(DiffCacheEntry).init(allocator),
            .total_memory = 0,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *DiffCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.result_data);
        }
        self.entries.deinit();
    }

    pub fn computeCacheKey(
        old_content: []const u8,
        new_content: []const u8,
        options: []const u8,
    ) [64]u8 {
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(old_content);
        hasher.update(new_content);
        const old_hash = hasher.final();

        hasher = crypto.hash.Sha1.init(.{});
        hasher.update(new_content);
        hasher.update(old_content);
        const new_hash = hasher.final();

        hasher = crypto.hash.Sha1.init(.{});
        hasher.update(options);
        const options_hash = hasher.final();

        var key: [64]u8 = undefined;
        @memcpy(key[0..20], &old_hash);
        @memcpy(key[20..40], &new_hash);
        @memcpy(key[40..60], &options_hash);
        @memcpy(key[60..64], &options_hash[0..4]);
        return key;
    }

    pub fn get(self: *DiffCache, key: []const u8) ?[]const u8 {
        if (!self.config.enabled) return null;

        if (self.entries.get(key)) |*entry| {
            self.hits += 1;
            entry.access_time = self.access_counter;
            self.access_counter += 1;
            return entry.result_data;
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *DiffCache, key: []const u8, data: []const u8) !void {
        if (!self.config.enabled) return;

        if (self.entries.getEntry(key)) |entry| {
            self.allocator.free(entry.value_ptr.result_data);
            self.total_memory -= entry.value_ptr.size_bytes;
            entry.value_ptr.result_data = try self.allocator.dupe(u8, data);
            entry.value_ptr.size_bytes = data.len;
            entry.value_ptr.access_time = self.access_counter;
            self.access_counter += 1;
            self.total_memory += data.len;
            return;
        }

        const entry_size = @sizeOf(DiffCacheEntry) + key.len + data.len;

        while (self.entries.count() >= self.config.max_entries or
            self.total_memory + data.len > self.config.max_memory_bytes) {
            try self.evictOldest();
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        try self.entries.put(key_copy, .{
            .result_data = data_copy,
            .old_content_hash = undefined,
            .new_content_hash = undefined,
            .options_hash = undefined,
            .access_time = self.access_counter,
            .size_bytes = data.len,
        });

        self.access_counter += 1;
        self.total_memory += entry_size;
    }

    fn evictOldest(self: *DiffCache) !void {
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
                self.total_memory -= entry.size_bytes;
                self.allocator.free(entry.result_data);
            }
            self.entries.remove(oldest_key);
            self.evictions += 1;
        }
    }

    pub fn invalidate(self: *DiffCache, path: []const u8) void {
        _ = path;
        self.clear();
    }

    pub fn clear(self: *DiffCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.result_data);
        }
        self.entries.clearRetainingCapacity();
        self.total_memory = 0;
    }

    pub fn hitRate(self: *const DiffCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn getStats(self: *const DiffCache) DiffCacheStats {
        return DiffCacheStats{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = self.evictions,
            .size = self.entries.count(),
            .max_size = self.config.max_entries,
            .hit_rate = self.hitRate(),
        };
    }

    pub fn setEnabled(self: *DiffCache, enabled: bool) void {
        self.config.enabled = enabled;
        if (!enabled) {
            self.clear();
        }
    }
};

test "DiffCache init" {
    const cache = DiffCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    try std.testing.expect(cache.config.enabled == true);
    try std.testing.expect(cache.entries.count() == 0);
}

test "DiffCache computeCacheKey" {
    const key1 = DiffCache.computeCacheKey("hello", "world", "options");
    const key2 = DiffCache.computeCacheKey("hello", "world", "options");
    try std.testing.expectEqual(key1, key2);

    const key3 = DiffCache.computeCacheKey("hello", "different", "options");
    try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "DiffCache put and get" {
    var cache = DiffCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const key = DiffCache.computeCacheKey("old", "new", "");
    try cache.put(&key, "diff result");

    const result = cache.get(&key);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("diff result", result.?);
}

test "DiffCache miss" {
    var cache = DiffCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const key = DiffCache.computeCacheKey("old", "new", "");
    const result = cache.get(&key);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "DiffCache hit increments counter" {
    var cache = DiffCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const key = DiffCache.computeCacheKey("old", "new", "");
    try cache.put(&key, "result");

    _ = cache.get(&key);
    _ = cache.get(&key);
    try std.testing.expectEqual(@as(u64, 2), cache.hits);
}

test "DiffCache eviction" {
    var cache = DiffCache.init(std.testing.allocator, .{ .max_entries = 2 });
    defer cache.deinit();

    const key1 = DiffCache.computeCacheKey("a", "b", "");
    const key2 = DiffCache.computeCacheKey("c", "d", "");
    const key3 = DiffCache.computeCacheKey("e", "f", "");

    try cache.put(&key1, "result1");
    try cache.put(&key2, "result2");
    try cache.put(&key3, "result3");

    try std.testing.expectEqual(@as(u64, 1), cache.evictions);
    try std.testing.expect(cache.get(&key1) == null);
    try std.testing.expect(cache.get(&key2) != null);
    try std.testing.expect(cache.get(&key3) != null);
}

test "DiffCache clear" {
    var cache = DiffCache.init(std.testing.allocator, .{ .max_entries = 10 });
    defer cache.deinit();

    const key = DiffCache.computeCacheKey("old", "new", "");
    try cache.put(&key, "result");

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expect(cache.get(&key) == null);
}

test "DiffCache disabled" {
    var cache = DiffCache.init(std.testing.allocator, .{ .enabled = false });
    defer cache.deinit();

    const key = DiffCache.computeCacheKey("old", "new", "");
    try cache.put(&key, "result");

    try std.testing.expect(cache.get(&key) == null);
}
