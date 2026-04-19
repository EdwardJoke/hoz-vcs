//! ObjectWriter - streaming writes for large objects
const std = @import("std");
const object_mod = @import("object.zig");
const compress_mod = @import("../compress/zlib.zig");

/// Buffered writer for streaming object writes
pub const ObjectWriter = struct {
    allocator: std.mem.Allocator,
    vector: std.ArrayList(u8),

    /// Initialize with allocator
    pub fn init(allocator: std.mem.Allocator) ObjectWriter {
        return ObjectWriter{
            .allocator = allocator,
            .vector = std.ArrayList(u8).init(allocator),
        };
    }

    /// Write an object to the stream
    pub fn writeObject(self: *ObjectWriter, obj: *const object_mod.Object) !void {
        // Serialize object
        const serialized = try obj.serialize(self.allocator);
        defer self.allocator.free(serialized);

        // Compress
        const compressed = try compress_mod.Zlib.compress(self.allocator, serialized);
        defer self.allocator.free(compressed);

        // Append to vector
        try self.vector.appendSlice(compressed);
    }

    /// Write raw bytes
    pub fn writeBytes(self: *ObjectWriter, bytes: []const u8) !void {
        try self.vector.appendSlice(bytes);
    }

    /// Get the written data
    pub fn toSlice(self: *const ObjectWriter) []u8 {
        return self.vector.items;
    }

    /// Get written data as BytesOwned (takes ownership)
    pub fn toOwned(self: *ObjectWriter) []u8 {
        const result = self.vector.items;
        self.vector.items = &.{};
        return result;
    }

    /// Release resources
    pub fn deinit(self: *ObjectWriter) void {
        self.vector.deinit();
    }
};

test "object writer basic" {
    const allocator = std.testing.allocator;
    var writer = ObjectWriter.init(allocator);
    defer writer.deinit();
    _ = writer;
}
