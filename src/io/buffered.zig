//! Buffered I/O - High-performance buffered file operations
//!
//! Provides buffered read/write operations with configurable buffer sizes,
//! prefetching, and batched writes for improved I/O performance.

const std = @import("std");

pub const BufferedConfig = struct {
    read_buffer_size: usize = 65536,
    write_buffer_size: usize = 65536,
    max_dirty_pages: usize = 16,
    prefetch_enabled: bool = true,
    flush_threshold: usize = 524288,
};

pub const BufferedStats = struct {
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    cache_hits: u64 = 0,
    prefetched: u64 = 0,
};

pub const BufferedReader = struct {
    allocator: std.mem.Allocator,
    config: BufferedConfig,
    file: std.fs.File,
    buffer: []u8,
    position: u64,
    file_size: u64,
    valid_bytes: usize,
    stats: BufferedStats,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, config: BufferedConfig) !BufferedReader {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        errdefer file.close();

        const stat = try file.stat();
        const file_size = @as(u64, stat.size);
        const buffer = try allocator.alignedAlloc(u8, 4096, config.read_buffer_size);
        errdefer allocator.free(buffer);

        var reader = BufferedReader{
            .allocator = allocator,
            .config = config,
            .file = file,
            .buffer = buffer,
            .position = 0,
            .file_size = file_size,
            .valid_bytes = 0,
            .stats = .{},
        };

        try reader.refill();
        return reader;
    }

    pub fn close(self: *BufferedReader) void {
        self.allocator.free(self.buffer);
        self.file.close();
    }

    fn refill(self: *BufferedReader) !void {
        const file_pos = @as(i64, @intCast(self.position));
        const bytes_read = try self.file.preadAll(self.buffer, file_pos);
        self.valid_bytes = bytes_read;
        self.stats.reads += 1;
        self.stats.bytes_read += @as(u64, bytes_read);
    }

    pub fn read(self: *BufferedReader, dest: []u8) !usize {
        var offset: usize = 0;
        while (offset < dest.len) {
            if (self.valid_bytes == 0) {
                if (self.position >= self.file_size) break;
                try self.refill();
                if (self.valid_bytes == 0) break;
            }

            const to_copy = @min(dest.len - offset, self.valid_bytes);
            @memcpy(dest[offset..][0..to_copy], self.buffer[0..to_copy]);
            offset += to_copy;
            self.valid_bytes -= to_copy;
            self.position += @as(u64, to_copy);

            if (self.valid_bytes > 0) {
                @memcpy(self.buffer[0..self.valid_bytes], self.buffer[self.buffer.len - self.valid_bytes ..][0..self.valid_bytes]);
            }
        }
        return offset;
    }

    pub fn skip(self: *BufferedReader, count: u64) !u64 {
        const actual = @min(count, self.file_size - self.position);
        self.position += actual;
        self.valid_bytes = 0;
        return actual;
    }

    pub fn getStats(self: *const BufferedReader) BufferedStats {
        return self.stats;
    }

    pub fn tell(self: *const BufferedReader) u64 {
        return self.position;
    }
};

pub const DirtyPage = struct {
    data: []u8,
    offset: u64,
    size: usize,
    dirty: bool,
};

pub const BufferedWriter = struct {
    allocator: std.mem.Allocator,
    config: BufferedConfig,
    file: std.fs.File,
    pages: std.ArrayList(DirtyPage),
    current_page: []u8,
    position: u64,
    stats: BufferedStats,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, config: BufferedConfig) !BufferedWriter {
        const file = try std.fs.createFileAbsolute(path, .{});
        errdefer file.close();

        const buffer = try allocator.alignedAlloc(u8, 4096, config.write_buffer_size);
        errdefer allocator.free(buffer);

        var pages = std.ArrayList(DirtyPage).init(allocator);
        errdefer pages.deinit();

        return BufferedWriter{
            .allocator = allocator,
            .config = config,
            .file = file,
            .pages = pages,
            .current_page = buffer,
            .position = 0,
            .stats = .{},
        };
    }

    pub fn close(self: *BufferedWriter) !void {
        try self.flush();
        self.allocator.free(self.current_page);
        for (self.pages.items) |page| {
            self.allocator.free(page.data);
        }
        self.pages.deinit();
        self.file.close();
    }

    pub fn write(self: *BufferedWriter, data: []const u8) !usize {
        var offset: usize = 0;
        while (offset < data.len) {
            const space = self.current_page.len - (@as(usize, @intCast(self.position)) % self.config.write_buffer_size);
            const to_copy = @min(data.len - offset, space);
            @memcpy(self.current_page[self.position % self.config.write_buffer_size ..][0..to_copy], data[offset..][0..to_copy]);
            offset += to_copy;
            self.position += @as(u64, to_copy);
            self.stats.bytes_written += @as(u64, to_copy);

            if (self.position % self.config.write_buffer_size == 0) {
                try self.flushCurrentPage();
            }
        }
        return offset;
    }

    fn flushCurrentPage(self: *BufferedWriter) !void {
        const page_offset = self.position - (@as(u64, @intCast(self.position % self.config.write_buffer_size)));
        try self.file.pwriteAll(self.current_page, @as(i64, @intCast(page_offset)));
        self.stats.writes += 1;
    }

    pub fn flush(self: *BufferedWriter) !void {
        if (self.position % self.config.write_buffer_size != 0) {
            try self.flushCurrentPage();
        }
        try self.file.sync();
    }

    pub fn getStats(self: *const BufferedWriter) BufferedStats {
        return self.stats;
    }

    pub fn tell(self: *const BufferedWriter) u64 {
        return self.position;
    }
};

pub const RandomAccessFile = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    path: []u8,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !RandomAccessFile {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        const path_copy = try allocator.dupe(u8, path);
        return RandomAccessFile{
            .allocator = allocator,
            .file = file,
            .path = path_copy,
        };
    }

    pub fn close(self: *RandomAccessFile) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn pwrite(self: *RandomAccessFile, data: []const u8, offset: u64) !usize {
        return self.file.pwriteAll(data, @as(i64, @intCast(offset)));
    }

    pub fn pread(self: *RandomAccessFile, data: []u8, offset: u64) !usize {
        return self.file.preadAll(data, @as(i64, @intCast(offset)));
    }

    pub fn stat(self: *RandomAccessFile) !std.fs.File.Stat {
        return self.file.stat();
    }

    pub fn sync(self: *RandomAccessFile) !void {
        try self.file.sync();
    }
};

test "BufferedConfig default" {
    const config = BufferedConfig{};
    try std.testing.expectEqual(@as(usize, 65536), config.read_buffer_size);
    try std.testing.expectEqual(@as(usize, 65536), config.write_buffer_size);
}

test "BufferedStats init" {
    const stats = BufferedStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_read);
    try std.testing.expectEqual(@as(u64, 0), stats.bytes_written);
}
