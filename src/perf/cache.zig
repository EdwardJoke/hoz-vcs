//! Object Cache - LRU cache for Git objects
const std = @import("std");
const Io = std.Io;

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
    cache: std.StringArrayHashMapUnmanaged(CacheEntry),
    max_size: usize,
    hits: u64,
    misses: u64,
    evictions: u64,
    eviction_policy: EvictionPolicy,
    lfu_counts: std.AutoHashMapUnmanaged(u64, u32),

    pub const CacheEntry = struct {
        data: []const u8,
        size: usize,
        access_time: u64,
        insert_order: u64,
    },

    pub fn init(allocator: std.mem.Allocator, max_size: usize) ObjectCache {
        return .{
            .allocator = allocator,
            .cache = .empty,
            .max_size = max_size,
            .hits = 0,
            .misses = 0,
            .evictions = 0,
            .eviction_policy = .lru,
            .lfu_counts = .empty,
        };
    }

    pub fn deinit(self: *ObjectCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
        }
        self.cache.deinit(self.allocator);
        self.lfu_counts.deinit(self.allocator);
    }

    pub fn get(self: *ObjectCache, key: []const u8) ?[]const u8 {
        if (self.cache.get(key)) |entry| {
            self.hits += 1;
            entry.access_time = @as(u64, @intCast(std.time.timestamp()));
            if (self.eviction_policy == .lfu) {
                if (self.lfu_counts.getPtr(entry.access_time)) |count| {
                    count.* += 1;
                }
            }
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
            try self.evictOne();
        }

        const now: u64 = @intCast(std.time.timestamp());
        const data_copy = try self.allocator.dupe(u8, data);
        try self.cache.put(self.allocator, key, .{
            .data = data_copy,
            .size = data.len,
            .access_time = now,
            .insert_order = self.evictions,
        });

        if (self.eviction_policy == .lfu) {
            try self.lfu_counts.put(self.allocator, now, 1);
        }
    }

    fn evictOne(self: *ObjectCache) !void {
        var victim_key: ?[]const u8 = null;

        switch (self.eviction_policy) {
            .lru => {
                var oldest_time: u64 = std.math.maxInt(u64);
                var iter = self.cache.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.access_time < oldest_time) {
                        oldest_time = entry.value_ptr.access_time;
                        victim_key = entry.key_ptr.*;
                    }
                }
            },
            .fifo => {
                var oldest_order: u64 = std.math.maxInt(u64);
                var iter = self.cache.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.insert_order < oldest_order) {
                        oldest_order = entry.value_ptr.insert_order;
                        victim_key = entry.key_ptr.*;
                    }
                }
            },
            .lfu => {
                var min_count: u32 = std.math.maxInt(u32);
                var iter = self.cache.iterator();
                while (iter.next()) |entry| {
                    const count = self.lfu_counts.get(entry.value_ptr.access_time) orelse 0;
                    if (count < min_count) {
                        min_count = count;
                        victim_key = entry.key_ptr.*;
                    }
                }
            },
        }

        if (victim_key) |vk| {
            if (self.cache.get(vk)) |entry| {
                self.allocator.free(entry.data);
            }
            self.cache.remove(vk);
            self.evictions += 1;
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
            .evictions = self.evictions,
            .size = self.cache.count(),
            .max_size = self.max_size,
            .hit_rate = self.hitRate(),
            .total_memory = total_memory,
        };
    }

    pub fn warmCache(self: *ObjectCache, io: Io, options: CacheWarmingOptions) !void {
        if (!options.enabled) return;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(io, ".git", .{}) catch return;
        defer git_dir.close(io);

        if (options.priority_refs) {
            const head_content = git_dir.readFileAlloc(io, "HEAD", self.allocator, .limited(256)) catch return;
            defer self.allocator.free(head_content);

            const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                _ = git_dir.readFileAlloc(io, ref_path, self.allocator, .limited(64)) catch return;
            }

            const packed_refs = git_dir.readFileAlloc(io, "packed-refs", self.allocator, .limited(4096)) catch return;
            defer self.allocator.free(packed_refs);
        }

        const info_refs = git_dir.readFileAlloc(io, "info/refs", self.allocator, .limited(4096)) catch return;
        defer self.allocator.free(info_refs);
    }

    pub fn setEvictionPolicy(self: *ObjectCache, policy: EvictionPolicy) void {
        self.eviction_policy = policy;
        if (policy != .lfu) {
            var iter = self.lfu_counts.iterator();
            while (iter.next()) |_| {}
            self.lfu_counts.clearAndFree(self.allocator);
        } else {
            if (self.lfu_counts.count() == 0) {
                self.lfu_counts = .empty;
            }
        }
    }
};

test "ObjectCache init" {
    const cache = ObjectCache.init(std.testing.allocator, 100);
    try std.testing.expect(cache.max_size == 100);
    try std.testing.expect(cache.eviction_policy == .lru);
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

test "ObjectCache setEvictionPolicy" {
    var cache = ObjectCache.init(std.testing.allocator, 10);
    defer cache.deinit();

    cache.setEvictionPolicy(.fifo);
    try std.testing.expect(cache.eviction_policy == .fifo);

    cache.setEvictionPolicy(.lfu);
    try std.testing.expect(cache.eviction_policy == .lfu);
}

test "ObjectCache eviction with lru" {
    var cache = ObjectCache.init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("key1", "data1");
    try cache.put("key2", "data2");
    try cache.put("key3", "data3");

    _ = cache.get("key1");

    try cache.put("key4", "data4");

    try std.testing.expect(cache.get("key1") != null);
    try std.testing.expect(cache.get("key4") != null);
}

test "ObjectCache stats include evictions" {
    var cache = ObjectCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try cache.put("a", "x");
    try cache.put("b", "y");
    try cache.put("c", "z");

    const stats = cache.getStats();
    try std.testing.expect(stats.evictions >= 1);
}
