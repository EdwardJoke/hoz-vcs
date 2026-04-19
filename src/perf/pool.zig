//! Memory Pool - Pooled memory allocator for objects
//!
//! Provides a memory pool for frequently allocated/deallocated objects,
//! reducing allocation overhead and fragmentation.

const std = @import("std");

pub const MemoryPoolConfig = struct {
    block_size: usize = 4096,
    max_blocks: usize = 1000,
    object_size: usize = 64,
    alignment: usize = 8,
};

pub const MemoryPoolStats = struct {
    allocated_objects: u64 = 0,
    freed_objects: u64 = 0,
    pooled_objects: u64 = 0,
    blocks_used: usize = 0,
    peak_objects: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
};

pub const MemoryPool = struct {
    allocator: std.mem.Allocator,
    config: MemoryPoolConfig,
    free_list: std.SinglyLinkedList(void),
    blocks: std.ArrayList([]u8),
    stats: MemoryPoolStats,

    pub fn init(allocator: std.mem.Allocator, config: MemoryPoolConfig) MemoryPool {
        return .{
            .allocator = allocator,
            .config = config,
            .free_list = .{},
            .blocks = std.ArrayList([]u8).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *MemoryPool) void {
        self.reset();
        self.blocks.deinit();
    }

    pub fn reset(self: *MemoryPool) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block);
        }
        self.blocks.clearRetainingCapacity();
        self.free_list.len = 0;
        self.stats.blocks_used = 0;
        self.stats.pooled_objects = 0;
    }

    pub fn acquire(self: *MemoryPool) ![]u8 {
        self.stats.allocated_objects += 1;
        self.stats.peak_objects = @max(self.stats.peak_objects, self.stats.allocated_objects);

        if (self.free_list.len > 0) {
            self.stats.hits += 1;
            self.stats.pooled_objects -= 1;
            const node = self.free_list.popFirst();
            return @as([*]u8, @ptrFromInt(@intFromPtr(node)))[0..self.config.object_size];
        }

        self.stats.misses += 1;

        if (self.blocks.items.len == 0 or self.currentBlockRemaining() < self.config.object_size) {
            try self.allocateBlock();
        }

        const block = self.blocks.items[self.blocks.items.len - 1];
        const offset = block.len - self.currentBlockRemaining();
        const obj_ptr = block[offset .. offset + self.config.object_size];
        self.stats.blocks_used = self.blocks.items.len;

        return obj_ptr;
    }

    pub fn release(self: *MemoryPool, obj: []u8) void {
        if (obj.len != self.config.object_size) {
            return;
        }

        self.stats.freed_objects += 1;
        self.stats.pooled_objects += 1;

        const node_ptr = @as(*std.SinglyLinkedList(void).Node, @ptrFromInt(@intFromPtr(obj.ptr)));
        self.free_list.prepend(node_ptr);
    }

    fn currentBlockRemaining(self: *const MemoryPool) usize {
        if (self.blocks.items.len == 0) return 0;
        const block = self.blocks.items[self.blocks.items.len - 1];
        const used = (self.stats.pooled_objects * self.config.object_size) % self.config.block_size;
        return self.config.block_size - used;
    }

    fn allocateBlock(self: *MemoryPool) !void {
        if (self.blocks.items.len >= self.config.max_blocks) {
            return error.TooManyBlocks;
        }

        const block = try self.allocator.alignedAlloc(u8, self.config.alignment, self.config.block_size);
        errdefer self.allocator.free(block);

        try self.blocks.append(block);
        self.stats.blocks_used = self.blocks.items.len;
    }

    pub fn getStats(self: *const MemoryPool) MemoryPoolStats {
        return self.stats;
    }

    pub fn poolSize(self: *const MemoryPool) usize {
        return self.free_list.len * self.config.object_size;
    }

    pub fn totalMemory(self: *const MemoryPool) usize {
        return self.blocks.items.len * self.config.block_size;
    }
};

pub fn ObjectPool(comptime T: type) type {
    return struct {
        pool: MemoryPool,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .pool = MemoryPool.init(allocator, .{
                    .object_size = @sizeOf(T),
                    .alignment = @alignOf(T),
                }),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.pool.deinit();
        }

        pub fn create(self: *@This()) !*T {
            const obj = try self.pool.acquire();
            return @as(*T, @ptrCast(@alignCast(obj.ptr)));
        }

        pub fn destroy(self: *@This(), obj: *T) void {
            const bytes = @as([*]u8, @ptrCast(obj))[0..@sizeOf(T)];
            self.pool.release(bytes);
        }
    };
}

test "MemoryPool init" {
    const pool = MemoryPool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try std.testing.expectEqual(@as(u64, 0), pool.stats.allocated_objects);
}

test "MemoryPool acquire release" {
    var pool = MemoryPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    const obj = try pool.acquire();
    try std.testing.expectEqual(@as(u64, 1), pool.stats.allocated_objects);

    pool.release(obj);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.freed_objects);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.pooled_objects);
}

test "MemoryPool reuse from pool" {
    var pool = MemoryPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    const obj1 = try pool.acquire();
    pool.release(obj1);

    const obj2 = try pool.acquire();
    try std.testing.expectEqual(@as(u64, 2), pool.stats.allocated_objects);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.hits);
}

test "MemoryPool getStats" {
    var pool = MemoryPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    _ = try pool.acquire();
    _ = try pool.acquire();
    pool.release(try pool.acquire());

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.allocated_objects);
    try std.testing.expectEqual(@as(u64, 2), stats.freed_objects);
    try std.testing.expectEqual(@as(u64, 1), stats.pooled_objects);
}

test "MemoryPool reset" {
    var pool = MemoryPool.init(std.testing.allocator, .{});
    defer pool.deinit();

    _ = try pool.acquire();
    _ = try pool.acquire();

    pool.reset();

    try std.testing.expectEqual(@as(u64, 0), pool.stats.pooled_objects);
    try std.testing.expectEqual(@as(usize, 0), pool.stats.blocks_used);
}

test "MemoryPool totalMemory" {
    var pool = MemoryPool.init(std.testing.allocator, .{ .block_size = 1024 });
    defer pool.deinit();

    _ = try pool.acquire();
    _ = try pool.acquire();
    _ = try pool.acquire();

    try std.testing.expect(totalMemory() > 0);
}

test "ObjectPool" {
    const Pool = ObjectPool(u32);
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const obj = try pool.create();
    obj.* = 42;

    try std.testing.expectEqual(@as(u32, 42), obj.*);

    pool.destroy(obj);
}

test "ObjectPool multiple objects" {
    const Pool = ObjectPool(u64);
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();

    const obj1 = try pool.create();
    obj1.* = 100;
    const obj2 = try pool.create();
    obj2.* = 200;

    try std.testing.expectEqual(@as(u64, 100), obj1.*);
    try std.testing.expectEqual(@as(u64, 200), obj2.*);
}
