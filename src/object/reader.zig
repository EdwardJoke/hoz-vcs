//! ObjectReader - streaming reads for large objects
const std = @import("std");
const object_mod = @import("object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const StreamConfig = struct {
    buffer_size: usize = 64 * 1024,
    max_object_size: usize = 100 * 1024 * 1024,
};

/// Buffered reader for streaming object reads
pub const ObjectReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    read_buffer: []u8,
    position: u64 = 0,
    config: StreamConfig,

    /// Initialize from a file with streaming support
    pub fn fromFile(allocator: std.mem.Allocator, file: std.fs.File, config: StreamConfig) !ObjectReader {
        const buffer = try allocator.alloc(u8, config.buffer_size);
        errdefer allocator.free(buffer);

        return ObjectReader{
            .allocator = allocator,
            .file = file,
            .read_buffer = buffer,
            .config = config,
        };
    }

    /// Read next object from stream using chunked I/O
    pub fn readObject(self: *ObjectReader) !?object_mod.Object {
        var header_buffer = std.ArrayList(u8).init(self.allocator);
        defer header_buffer.deinit();

        var data_buffer = std.ArrayList(u8).init(self.allocator);
        errdefer data_buffer.deinit();

        var state: enum { header, size, null_byte, data } = .header;
        var bytes_read: usize = 0;

        while (true) {
            const bytes = self.file.read(self.read_buffer) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (bytes == 0) break;

            for (self.read_buffer[0..bytes]) |byte| {
                if (bytes_read >= self.config.max_object_size) {
                    return error.ObjectTooLarge;
                }

                switch (state) {
                    .header => {
                        if (byte == ' ') {
                            state = .size;
                        } else {
                            try header_buffer.append(byte);
                        }
                    },
                    .size => {
                        if (byte == 0) {
                            state = .data;
                        } else {
                            try header_buffer.append(byte);
                        }
                    },
                    .null_byte => unreachable,
                    .data => {
                        try data_buffer.append(byte);
                    },
                }
                bytes_read += 1;
            }
            self.position += bytes;
        }

        if (header_buffer.items.len == 0) return null;

        const full_data = try data_buffer.toOwnedSlice();
        return try object_mod.Object.parseFromParts(
            self.allocator,
            header_buffer.items,
            full_data,
        );
    }

    /// Read object by OID with size limit
    pub fn readObjectBySize(self: *ObjectReader, expected_size: usize) !?[]u8 {
        if (expected_size > self.config.max_object_size) {
            return error.ObjectTooLarge;
        }

        const data = try self.allocator.alloc(u8, expected_size);
        errdefer self.allocator.free(data);

        var offset: usize = 0;
        while (offset < expected_size) {
            const to_read = @min(self.config.buffer_size, expected_size - offset);
            const bytes = try self.file.read(data[offset..][0..to_read]);
            if (bytes == 0) break;
            offset += bytes;
        }

        self.position += offset;
        return data[0..offset];
    }

    /// Get current file position
    pub fn getPosition(self: *const ObjectReader) u64 {
        return self.position;
    }

    /// Release resources
    pub fn deinit(self: *ObjectReader) void {
        self.allocator.free(self.read_buffer);
    }
};

test "object reader streaming" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.obj", .{});
    defer file.close();

    try file.writeAll("blob 6\x00Hello\n");

    var reader = try ObjectReader.fromFile(allocator, file, .{});
    defer reader.deinit();

    const obj = try reader.readObject();
    try std.testing.expect(obj != null);
    if (obj) |o| {
        try std.testing.expectEqual(object_mod.Type.blob, o.obj_type);
        allocator.free(o.data);
    }
}
