//! Blob object - stores file content and computes SHA
const std = @import("std");
const object_mod = @import("object.zig");
const oid_mod = @import("oid.zig");

/// Blob type - stores raw file content
pub const Blob = struct {
    /// Raw file content (the actual bytes stored in the blob)
    data: []const u8,

    /// Create a new Blob from raw file content
    pub fn create(content: []const u8) Blob {
        return Blob{ .data = content };
    }

    /// Get the object type for this blob
    pub fn objectType() object_mod.Type {
        return .blob;
    }

    /// Compute the OID (SHA) for this blob
    /// Git blob format: "blob <size>\0<content>"
    pub fn oid(self: Blob) oid_mod.OID {
        // Build header: "blob <size>\0"
        const size_str = std.fmt.comptimePrint("{}", .{self.data.len});
        const header = std.fmt.comptimePrint("blob {}\x00", .{size_str});

        // For content up to 1000 bytes, use inline computation
        var content_with_header: [1024]u8 = undefined;
        @memcpy(content_with_header[0..header.len], header);
        @memcpy(content_with_header[header.len .. header.len + self.data.len], self.data);
        const full_content = content_with_header[0 .. header.len + self.data.len];

        return oid_mod.oidFromContent(full_content);
    }

    /// Serialize blob to loose object format
    /// Format: "blob <size>\0<content>"
    pub fn serialize(self: Blob, allocator: std.mem.Allocator) ![]u8 {
        const size_str = try std.fmt.allocPrint(allocator, "{}", .{self.data.len});
        defer allocator.free(size_str);

        const header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{size_str});
        defer allocator.free(header);

        var result = try allocator.alloc(u8, header.len + self.data.len);
        @memcpy(result[0..header.len], header);
        @memcpy(result[header.len..], self.data);

        return result;
    }

    /// Parse blob from loose object data
    pub fn parse(data: []const u8) !Blob {
        const obj = try object_mod.parse(data);
        if (obj.obj_type != .blob) {
            return error.NotABlob;
        }
        return Blob{ .data = obj.data };
    }
};

test "blob create and oid" {
    const content = "Hello, World!";
    const blob = Blob.create(content);

    // Verify content is stored
    try std.testing.expectEqualSlices(u8, content, blob.data);

    // Verify object type
    try std.testing.expectEqual(object_mod.Type.blob, blob.objectType());
}

test "blob serialize and parse roundtrip" {
    const content = "Test content for blob";
    const blob = Blob.create(content);

    // Serialize
    const serialized = try blob.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    // Parse back
    const parsed = try Blob.parse(serialized);

    // Verify content matches
    try std.testing.expectEqualSlices(u8, content, parsed.data);
}

test "blob oid consistency" {
    // Verify that the same content produces the same OID
    const content = "Hello, World!";
    const blob1 = Blob.create(content);
    const blob2 = Blob.create(content);

    try std.testing.expectEqualSlices(u8, &blob1.oid().bytes, &blob2.oid().bytes);
}

test "blob empty content" {
    const blob = Blob.create("");
    try std.testing.expectEqual(0, blob.data.len);
    try std.testing.expectEqual(object_mod.Type.blob, blob.objectType());
}

test "blob large content" {
    const content = "x" ** 10000;
    const blob = Blob.create(content);
    try std.testing.expectEqual(10000, blob.data.len);
    try std.testing.expect(!oid_mod.oidIsZero(blob.oid()));
}

test "blob parse rejects non-blob" {
    const tree_data = "tree 0\x00";
    try std.testing.expectError(error.NotABlob, Blob.parse(tree_data));
}

test "blob binary content" {
    const binary_data = "\x00\x01\x02\xff\xfe\xfd";
    const blob = Blob.create(binary_data);
    try std.testing.expectEqualSlices(u8, binary_data, blob.data);
}

test "blob newline content" {
    const content = "line1\nline2\nline3\n";
    const blob = Blob.create(content);
    const serialized = try blob.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "line1\n") != null);
}
