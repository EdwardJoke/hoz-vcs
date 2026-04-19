//! Arena Allocator - Arena memory management for operations
//!
//! Provides arena allocation strategy for temporary allocations within
//! a defined scope, automatically freeing all memory at once.

const std = @import("std");

pub const ArenaAllocatorConfig = struct {
    chunk_size: usize = 4096,
    max_chunks: usize = 100,
    memory_limit: usize = 1024 * 1024 * 1024,
};

pub const ArenaAllocatorStats = struct {
    allocated_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    chunks_used: usize = 0,
    peak_bytes: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
};

pub const ArenaAllocator = struct {
    allocator: std.mem.Allocator,
    config: ArenaAllocatorConfig,
    chunks: std.ArrayList([]u8),
    current_chunk: []u8,
    current_offset: usize,
    stats: ArenaAllocatorStats,

    pub fn init(allocator: std.mem.Allocator, config: ArenaAllocatorConfig) ArenaAllocator {
        return .{
            .allocator = allocator,
            .config = config,
            .chunks = std.ArrayList([]u8).init(allocator),
            .current_chunk = &.{},
            .current_offset = 0,
            .stats = .{},
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        self.reset();
        self.chunks.deinit();
    }

    pub fn reset(self: *ArenaAllocator) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk);
        }
        self.chunks.clearRetainingCapacity();
        self.current_chunk = &.{};
        self.current_offset = 0;
        self.stats.freed_bytes = self.stats.allocated_bytes;
        self.stats.chunks_used = 0;
    }

    fn allocateChunk(self: *ArenaAllocator) !void {
        if (self.chunks.items.len >= self.config.max_chunks) {
            return error.TooManyChunks;
        }

        const size = self.config.chunk_size;
        const chunk = try self.allocator.alignedAlloc(u8, 8, size);
        errdefer self.allocator.free(chunk);

        try self.chunks.append(chunk);
        self.current_chunk = chunk;
        self.current_offset = 0;
        self.stats.chunks_used = self.chunks.items.len;
    }

    pub fn alloc(self: *ArenaAllocator, comptime T: type, count: usize) ![]T {
        const size = @sizeOf(T) * count;
        const alignment = @alignOf(T);

        if (self.current_offset + size <= self.current_chunk.len) {
            const ptr = @ptrCast([*]T, @alignCast(alignment, @as(*[1]u8, @alignCast(alignment, self.current_chunk.ptr + self.current_offset))));
            self.current_offset += size;
            self.stats.allocated_bytes += size;
            self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.allocated_bytes);
            self.stats.allocations += 1;
            return ptr[0..count];
        }

        if (size > self.config.chunk_size) {
            const large = try self.allocator.alignedAlloc(u8, alignment, size);
            errdefer self.allocator.free(large);
            try self.chunks.append(large);
            self.stats.allocated_bytes += size;
            self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.allocated_bytes);
            self.stats.allocations += 1;
            return @ptrCast([*]T, @alignCast(alignment, large.ptr))[0..count];
        }

        try self.allocateChunk();
        return self.alloc(T, count);
    }

    pub fn create(self: *ArenaAllocator, comptime T: type) !*T {
        const slice = try self.alloc(T, 1);
        return &slice[0];
    }

    pub fn dupe(self: *ArenaAllocator, data: []const u8) ![]u8 {
        const result = try self.alloc(u8, data.len);
        @memcpy(result, data);
        return result;
    }

    pub fn print(self: *ArenaAllocator, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(str);
        _ = try self.dupe(str);
        self.allocator.free(str);
    }

    pub fn getStats(self: *const ArenaAllocator) ArenaAllocatorStats {
        return self.stats;
    }

    pub fn remainingCapacity(self: *const ArenaAllocator) usize {
        if (self.current_chunk.len == 0) return 0;
        return self.current_chunk.len - self.current_offset;
    }

    pub fn allocatedBytes(self: *const ArenaAllocator) u64 {
        return self.stats.allocated_bytes;
    }
};

test "ArenaAllocator init" {
    const arena = ArenaAllocator.init(std.testing.allocator, .{});
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), arena.stats.allocations);
}

test "ArenaAllocator alloc" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{ .chunk_size = 1024 });
    defer arena.deinit();

    const arr = try arena.alloc(u32, 10);
    try std.testing.expectEqual(@as(usize, 10), arr.len);
    try std.testing.expectEqual(@as(u64, 40), arena.stats.allocated_bytes);
}

test "ArenaAllocator reset" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{ .chunk_size = 1024 });
    defer arena.deinit();

    _ = try arena.alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), arena.stats.allocated_bytes);

    arena.reset();
    try std.testing.expectEqual(@as(u64, 0), arena.stats.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), arena.stats.chunks_used);
}

test "ArenaAllocator dupe" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{ .chunk_size = 1024 });
    defer arena.deinit();

    const original = "hello world";
    const duped = try arena.dupe(original);

    try std.testing.expectEqualSlices(u8, original, duped);
}

test "ArenaAllocator remainingCapacity" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{ .chunk_size = 100 });
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 100), arena.remainingCapacity());

    _ = try arena.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), arena.remainingCapacity());
}

test "ArenaAllocator create" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{ .chunk_size = 1024 });
    defer arena.deinit();

    const ptr = try arena.create(u32);
    ptr.* = 42;

    try std.testing.expectEqual(@as(u32, 42), ptr.*);
}

test "ArenaAllocator getStats" {
    var arena = ArenaAllocator.init(std.testing.allocator, .{});
    defer arena.deinit();

    _ = try arena.alloc(u8, 100);
    const stats = arena.getStats();

    try std.testing.expectEqual(@as(u64, 100), stats.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 1), stats.allocations);
}
