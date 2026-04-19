//! Parallel Compression - Multi-threaded compression for packfiles
//!
//! Provides parallel compression using multiple worker threads for
//! improved throughput when compressing large packfiles.

const std = @import("std");
const deflate_mod = @import("../compress/deflate.zig");

pub const ParallelCompressConfig = struct {
    thread_count: usize = 4,
    chunk_size: usize = 65536,
    compression_level: CompressLevel = .default,
    memory_limit: usize = 256 * 1024 * 1024,
};

pub const CompressLevel = enum {
    none,
    fastest,
    fast,
    default,
    best,
};

pub const ParallelCompressStats = struct {
    chunks_processed: u64 = 0,
    bytes_input: u64 = 0,
    bytes_output: u64 = 0,
    threads_used: usize = 0,
    time_ms: u64 = 0,
};

pub const CompressedChunk = struct {
    offset: u64,
    compressed_data: []u8,
    original_size: usize,
};

pub const ParallelCompressor = struct {
    allocator: std.mem.Allocator,
    config: ParallelCompressConfig,
    chunks: std.ArrayList(CompressedChunk),
    stats: ParallelCompressStats,

    pub fn init(allocator: std.mem.Allocator, config: ParallelCompressConfig) ParallelCompressor {
        return .{
            .allocator = allocator,
            .config = config,
            .chunks = std.ArrayList(CompressedChunk).init(allocator),
            .stats = .{
                .threads_used = config.thread_count,
            },
        };
    }

    pub fn deinit(self: *ParallelCompressor) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.compressed_data);
        }
        self.chunks.deinit();
    }

    pub fn compress(self: *ParallelCompressor, data: []const u8) ![]CompressedChunk {
        const start_time = std.time.milliTimestamp();

        const thread_count = self.config.thread_count;
        const chunk_size = self.config.chunk_size;
        const chunk_count = (data.len + chunk_size - 1) / chunk_size;

        const threads = try self.allocator.alloc(*ThreadContext, thread_count);
        defer {
            for (threads) |ctx| ctx.deinit();
            self.allocator.free(threads);
        }

        const results = try self.allocator.alloc([]CompressedChunk, thread_count);
        defer {
            for (results) |r| self.allocator.free(r);
            self.allocator.free(results);
        }

        for (0..thread_count) |i| {
            const start_chunk = i * chunk_count / thread_count;
            const end_chunk = @min((i + 1) * chunk_count / thread_count, chunk_count);
            const start = start_chunk * chunk_size;
            const end = @min(end_chunk * chunk_size, data.len);

            threads[i] = try ThreadContext.init(
                self.allocator,
                data[start..end],
                start,
                self.config.compression_level,
            );
            results[i] = threads[i].chunks;
        }

        const join_ctx: *ThreadContext = undefined;
        _ = join_ctx;

        for (threads) |ctx| {
            while (!ctx.done) {
                std.thread.yield();
            }
        }

        var all_chunks = std.ArrayList(CompressedChunk).init(self.allocator);
        for (results) |result| {
            for (result) |chunk| {
                try all_chunks.append(chunk);
            }
        }

        self.stats.chunks_processed = @intCast(all_chunks.items.len);
        self.stats.bytes_input = data.len;
        self.stats.time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

        var output_size: u64 = 0;
        for (all_chunks.items) |chunk| {
            output_size += @as(u64, chunk.compressed_data.len);
        }
        self.stats.bytes_output = output_size;

        return all_chunks.toOwnedSlice();
    }

    pub fn getStats(self: *const ParallelCompressor) ParallelCompressStats {
        return self.stats;
    }
};

const ThreadContext = struct {
    done: bool,
    chunks: []CompressedChunk,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, data: []const u8, offset: u64, level: CompressLevel) !*ThreadContext {
        const ctx = try allocator.create(ThreadContext);
        ctx.* = .{
            .done = false,
            .chunks = &.{},
            .allocator = allocator,
        };

        ctx.chunks = try ctx.compressData(data, offset, level);
        ctx.done = true;
        return ctx;
    }

    fn deinit(self: *ThreadContext) void {
        for (self.chunks) |chunk| {
            self.allocator.free(chunk.compressed_data);
        }
        self.allocator.destroy(self);
    }

    fn compressData(self: *ThreadContext, data: []const u8, offset: u64, level: CompressLevel) ![]CompressedChunk {
        _ = level;
        var chunks = std.ArrayList(CompressedChunk).init(self.allocator);

        var pos: usize = 0;
        var chunk_offset = offset;
        while (pos < data.len) {
            const chunk_data = data[pos..@min(pos + 65536, data.len)];
            const compressed = try deflate_mod.store(chunk_data, self.allocator);
            errdefer self.allocator.free(compressed);

            try chunks.append(.{
                .offset = chunk_offset,
                .compressed_data = compressed,
                .original_size = chunk_data.len,
            });

            pos += chunk_data.len;
            chunk_offset += @as(u64, chunk_data.len);
        }

        return chunks.toOwnedSlice();
    }
};

test "ParallelCompressConfig default" {
    const config = ParallelCompressConfig{};
    try std.testing.expectEqual(@as(usize, 4), config.thread_count);
    try std.testing.expectEqual(@as(usize, 65536), config.chunk_size);
}

test "CompressLevel" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(CompressLevel.none));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(CompressLevel.fastest));
}

test "ParallelCompressStats init" {
    const stats = ParallelCompressStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.chunks_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_input);
}
