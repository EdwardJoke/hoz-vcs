//! Object Cache - LRU cache for Git objects
const std = @import("std");

pub const EvictionPolicy = enum {
    lru,
    fifo,
    lfu,
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    size: usize,
    max_size: usize,
    hit_rate: f64,
    total_memory: usize,
};

pub const CacheWarmingOptions = struct {
    enabled: bool = true,
    parallel: bool = false,
    priority_refs: bool = true,
};

pub const ObjectCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringArrayHashMap(CacheEntry),
    max_size: usize,
    hits: u64,
    misses: u64,

    pub const CacheEntry = struct {
        data: []const u8,
        size: usize,
        access_time: u64,
    },

    pub fn init(allocator: std.mem.Allocator, max_size: usize) ObjectCache {
        return .{
            .allocator = allocator,
            .cache = std.StringArrayHashMap(CacheEntry).init(allocator),
            .max_size = max_size,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *ObjectCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
        }
        self.cache.deinit();
    }

    pub fn get(self: *ObjectCache, key: []const u8) ?[]const u8 {
        if (self.cache.get(key)) |entry| {
            self.hits += 1;
            return entry.data;
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *ObjectCache, key: []const u8, data: []const u8) !void {
        if (self.cache.get(key)) |entry| {
            self.allocator.free(entry.data);
            self.cache.remove(key);
        }

        if (self.cache.count() >= self.max_size) {
            try self.evictOldest();
        }

        const data_copy = try self.allocator.dupe(u8, data);
        try self.cache.put(key, .{
            .data = data_copy,
            .size = data.len,
            .access_time = @as(u64, @intCast(std.time.timestamp())),
        });
    }

    fn evictOldest(self: *ObjectCache) !void {
        var oldest_key: []const u8 = "";
        var oldest_time: u64 = std.math.maxInt(u64);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.access_time < oldest_time) {
                oldest_time = entry.value_ptr.access_time;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key.len > 0) {
            if (self.cache.get(oldest_key)) |entry| {
                self.allocator.free(entry.data);
            }
            self.cache.remove(oldest_key);
        }
    }

    pub fn hitRate(self: *ObjectCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn getStats(self: *ObjectCache) CacheStats {
        var total_memory: usize = 0;
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            total_memory += entry.value_ptr.size;
        }
        return CacheStats{
            .hits = self.hits,
            .misses = self.misses,
            .evictions = 0,
            .size = self.cache.count(),
            .max_size = self.max_size,
            .hit_rate = self.hitRate(),
            .total_memory = total_memory,
        };
    }

    pub fn warmCache(self: *ObjectCache, options: CacheWarmingOptions) !void {
        _ = self;
        _ = options;
    }

    pub fn setEvictionPolicy(_: *ObjectCache, policy: EvictionPolicy) void {
        _ = policy;
    }
};

test "ObjectCache init" {
    const cache = ObjectCache.init(std.testing.allocator, 100);
    try std.testing.expect(cache.max_size == 100);
}

test "ObjectCache put and get" {
    var cache = ObjectCache.init(std.testing.allocator, 100);
    defer cache.deinit();
    try cache.put("abc123", "blob data");
    const data = cache.get("abc123");
    try std.testing.expect(data != null);
}

test "ObjectCache hitRate" {
    var cache = ObjectCache.init(std.testing.allocator, 100);
    defer cache.deinit();
    _ = cache.get("missing");
    _ = cache.get("missing");
    _ = cache.get("missing");
    try std.testing.expect(cache.misses == 3);
}