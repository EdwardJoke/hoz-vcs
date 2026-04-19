//! ObjectReader - streaming reads for large objects
const std = @import("std");
const object_mod = @import("object.zig");
const compress_mod = @import("../compress/zlib.zig");

/// Buffered reader for streaming object reads
pub const ObjectReader = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    position: usize = 0,

    /// Initialize from a file
    pub fn fromFile(allocator: std.mem.Allocator, file: std.fs.File) !ObjectReader {
        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        return ObjectReader{
            .allocator = allocator,
            .buffer = content,
        };
    }

    /// Read next object from stream
    pub fn readObject(self: *ObjectReader) !?object_mod.Object {
        if (self.position >= self.buffer.len) return null;

        // Find object header
        const start = self.position;
        const header_end = std.mem.indexOfScalar(u8, self.buffer[start..], '\n') orelse {
            return error.InvalidObject;
        };

        const header = self.buffer[start .. start + header_end];
        self.position = start + header_end + 1;

        // Decompress and parse
        const remaining = self.buffer[self.position..];
        const decompressed = try compress_mod.Zlib.decompress(self.allocator, remaining);
        defer self.allocator.free(decompressed);

        return try object_mod.Object.parse(decompressed);
    }

    /// Get remaining bytes without parsing
    pub fn readRemaining(self: *ObjectReader) []u8 {
        const result = self.buffer[self.position..];
        self.position = self.buffer.len;
        return result;
    }

    /// Release resources
    pub fn deinit(self: *ObjectReader) void {
        self.allocator.free(self.buffer);
    }
};

test "object reader basic" {
    // Basic test - would need actual file setup
    const allocator = std.testing.allocator;
    _ = allocator;
}
