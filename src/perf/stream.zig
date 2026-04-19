//! Streaming I/O - High-performance streaming for large files
//!
//! Provides buffered, chunked I/O operations for handling large files
//! without loading them entirely into memory.

const std = @import("std");

pub const StreamingConfig = struct {
    chunk_size: usize = 65536,
    buffer_count: usize = 4,
    max_memory: usize = 1024 * 1024 * 1024,
    prefetch_ahead: usize = 2,
};

pub const StreamingStats = struct {
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    chunks_read: u64 = 0,
    chunks_written: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
};

pub const Chunk = struct {
    data: []u8,
    offset: u64,
    consumed: bool,
};

pub const StreamingReader = struct {
    allocator: std.mem.Allocator,
    config: StreamingConfig,
    file: std.fs.File,
    file_size: u64,
    position: u64,
    buffer: std.fifo.LinearFifo(Chunk, .Dynamic),
    stats: StreamingStats,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, config: StreamingConfig) !StreamingReader {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        const stat = try file.stat();
        const file_size = @as(u64, stat.size);

        var reader = StreamingReader{
            .allocator = allocator,
            .config = config,
            .file = file,
            .file_size = file_size,
            .position = 0,
            .buffer = std.fifo.LinearFifo(Chunk, .Dynamic).init(allocator),
            .stats = .{},
        };

        try reader.fillBuffer();
        return reader;
    }

    pub fn close(self: *StreamingReader) void {
        self.file.close();
        while (self.buffer.readItem()) |chunk| {
            self.allocator.free(chunk.data);
        }
        self.buffer.deinit();
    }

    fn fillBuffer(self: *StreamingReader) !void {
        while (self.buffer.count < self.config.buffer_count) {
            if (self.position >= self.file_size) break;

            const remaining = self.file_size - self.position;
            const to_read = @min(@as(u64, self.config.chunk_size), remaining);
            const data = try self.allocator.alignedAlloc(u8, 8, @as(usize, to_read));
            errdefer self.allocator.free(data);

            const bytes_read = try self.file.preadAll(data, self.position);
            if (bytes_read == 0) {
                self.allocator.free(data);
                break;
            }

            self.position += @as(u64, bytes_read);
            self.stats.bytes_read += @as(u64, bytes_read);
            self.stats.chunks_read += 1;

            try self.buffer.writeItem(.{ .data = data[0..bytes_read], .offset = self.position - @as(u64, bytes_read), .consumed = false });
        }
    }

    pub fn read(self: *StreamingReader, dest: []u8) !usize {
        if (self.buffer.count == 0 and self.position >= self.file_size) {
            return 0;
        }

        var offset: usize = 0;
        while (offset < dest.len and self.buffer.count > 0) {
            const chunk = self.buffer.readItem().?;
            const to_copy = @min(dest.len - offset, chunk.data.len);
            @memcpy(dest[offset..][0..to_copy], chunk.data[0..to_copy]);
            offset += to_copy;

            if (to_copy < chunk.data.len) {
                chunk.data = chunk.data[to_copy..];
                chunk.offset += @as(u64, to_copy);
                self.buffer.prepend(chunk);
            } else {
                self.allocator.free(chunk.data);
            }
        }

        return offset;
    }

    pub fn readChunk(self: *StreamingReader) !?[]u8 {
        if (self.buffer.count == 0 and self.position >= self.file_size) {
            return null;
        }

        try self.fillBuffer();

        if (self.buffer.count == 0) {
            return null;
        }

        const chunk = self.buffer.readItem().?;
        return chunk.data;
    }

    pub fn skip(self: *StreamingReader, count: u64) !u64 {
        if (self.position >= self.file_size) return @as(u64, 0);

        self.position = @min(self.position + count, self.file_size);
        while (self.buffer.count > 0) {
            const chunk = self.buffer.readItem().?;
            if (chunk.offset + @as(u64, chunk.data.len) <= self.position) {
                self.allocator.free(chunk.data);
            } else {
                self.buffer.prepend(chunk);
                break;
            }
        }

        return count;
    }

    pub fn getStats(self: *const StreamingReader) StreamingStats {
        return self.stats;
    }

    pub fn tell(self: *const StreamingReader) u64 {
        return self.position;
    }
};

pub const StreamingWriter = struct {
    allocator: std.mem.Allocator,
    config: StreamingConfig,
    file: std.fs.File,
    position: u64,
    buffer: std.fifo.LinearFifo([]u8, .Dynamic),
    stats: StreamingStats,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, config: StreamingConfig) !StreamingWriter {
        const file = try std.fs.createFileAbsolute(path, .{});
        errdefer file.close();

        var writer = StreamingWriter{
            .allocator = allocator,
            .config = config,
            .file = file,
            .position = 0,
            .buffer = std.fifo.LinearFifo([]u8, .Dynamic).init(allocator),
            .stats = .{},
        };

        return writer;
    }

    pub fn close(self: *StreamingWriter) !void {
        try self.flush();
        self.file.close();
        while (self.buffer.readItem()) |chunk| {
            self.allocator.free(chunk);
        }
        self.buffer.deinit();
    }

    pub fn write(self: *StreamingWriter, data: []const u8) !usize {
        var offset: usize = 0;
        while (offset < data.len) {
            const space = self.config.chunk_size;
            const to_write = @min(data.len - offset, space);
            const chunk = try self.allocator.alignedAlloc(u8, 8, to_write);
            @memcpy(chunk, data[offset..][0..to_write]);
            try self.buffer.writeItem(chunk);
            offset += to_write;
        }
        return offset;
    }

    pub fn flush(self: *StreamingWriter) !void {
        while (self.buffer.count > 0) {
            const chunk = self.buffer.readItem().?;
            try self.file.writeAll(chunk);
            self.allocator.free(chunk);
            self.stats.chunks_written += 1;
        }
    }

    pub fn getStats(self: *const StreamingWriter) StreamingStats {
        return self.stats;
    }

    pub fn tell(self: *const StreamingWriter) u64 {
        return self.position;
    }
};

pub fn copyStream(allocator: std.mem.Allocator, reader: *StreamingReader, writer: *StreamingWriter, buffer_size: usize) !u64 {
    var buffer = try allocator.alignedAlloc(u8, 8, buffer_size);
    defer allocator.free(buffer);

    var total: u64 = 0;
    while (true) {
        const n = try reader.read(buffer);
        if (n == 0) break;
        _ = try writer.write(buffer[0..n]);
        total += @as(u64, n);
    }
    return total;
}

test "StreamingConfig default" {
    const config = StreamingConfig{};
    try std.testing.expectEqual(@as(usize, 65536), config.chunk_size);
    try std.testing.expectEqual(@as(usize, 4), config.buffer_count);
}
