//! Git Object type - base type for all Git objects
const std = @import("std");
const oid = @import("oid.zig");

/// Git object types
/// - blob: File content
/// - tree: Directory structure
/// - commit: Commit snapshot
/// - tag: Annotated tag
pub const Type = enum(u2) {
    blob,
    tree,
    commit,
    tag,
};

pub const TypeIterator = struct {
    current: Type,

    pub fn next(self: *TypeIterator) ?Type {
        const idx = @intFromEnum(self.current);
        if (idx >= @intFromEnum(Type.tag)) return null;
        self.current = @as(Type, @enumFromInt(idx + 1));
        return self.current;
    }
};

pub const ObjectType = struct {
    obj_type: Type,

    pub fn isBlob(self: ObjectType) bool {
        return self.obj_type == .blob;
    }

    pub fn isTree(self: ObjectType) bool {
        return self.obj_type == .tree;
    }

    pub fn isCommit(self: ObjectType) bool {
        return self.obj_type == .commit;
    }

    pub fn isTag(self: ObjectType) bool {
        return self.obj_type == .tag;
    }

    pub fn isCommitOrTag(self: ObjectType) bool {
        return self.obj_type == .commit or self.obj_type == .tag;
    }

    pub fn isTreeish(self: ObjectType) bool {
        return self.obj_type == .tree or self.obj_type == .blob;
    }

    pub fn requiresBody(self: ObjectType) bool {
        return self.obj_type == .commit or self.obj_type == .tag;
    }

    pub fn canHaveChildren(self: ObjectType) bool {
        return self.obj_type == .tree or self.obj_type == .commit;
    }
};

/// Convert object type to Git type string (used in serialization)
pub fn typeToStr(t: Type) []const u8 {
    return switch (t) {
        .blob => "blob",
        .tree => "tree",
        .commit => "commit",
        .tag => "tag",
    };
}

/// Parse object type from string
pub fn typeFromStr(str: []const u8) !Type {
    if (std.mem.eql(u8, str, "blob")) return .blob;
    if (std.mem.eql(u8, str, "tree")) return .tree;
    if (std.mem.eql(u8, str, "commit")) return .commit;
    if (std.mem.eql(u8, str, "tag")) return .tag;
    return error.InvalidObjectType;
}

/// Object header format: "<type> <size>\0"
pub fn computeHeaderSize(t: Type, size: usize) usize {
    _ = size;
    const type_str = typeToStr(t);
    // Format: "<type> <size>\0" -> length of type + 1 (space) + max digits of size + 1 (null)
    return type_str.len + 1 + 10 + 1; // 10 = max digits for 32-bit size
}

/// Generic object container - the specific object data is stored in the union
pub const Object = struct {
    oid: oid.OID,
    obj_type: Type,
    data: []const u8,
};

/// Parse object from raw data (Git loose object format)
pub fn parse(data: []const u8) !Object {
    // Git loose format: "<type> <size>\0<content>"
    // Find null byte separating header from content
    const null_idx = std.mem.indexOf(u8, data, "\x00") orelse return error.InvalidObjectFormat;

    const header = data[0..null_idx];
    const content = data[null_idx + 1 ..];

    // Parse header: "<type> <size>"
    var iter = std.mem.splitScalar(u8, header, ' ');
    const type_str = iter.next() orelse return error.InvalidObjectFormat;
    const size_str = iter.next() orelse return error.InvalidObjectFormat;

    const obj_type = try typeFromStr(type_str);
    const size = try std.fmt.parseInt(usize, size_str, 10);

    // Verify size matches
    if (content.len != size) {
        return error.InvalidObjectSize;
    }

    // Compute OID: SHA1("<type> <size>\0<content>")
    const full_content = data[0 .. null_idx + 1 + content.len];
    const computed_oid = oid.oidFromContent(full_content);

    return Object{
        .oid = computed_oid,
        .obj_type = obj_type,
        .data = content,
    };
}

/// Serialize object to loose object format
pub fn serialize(obj: Object, allocator: std.mem.Allocator) ![]u8 {
    const type_str = typeToStr(obj.obj_type);
    const size_str = try std.fmt.allocPrint(allocator, "{d}", .{obj.data.len});
    defer allocator.free(size_str);

    const header = try std.fmt.allocPrint(allocator, "{s} {s}\x00", .{ type_str, size_str });
    defer allocator.free(header);

    var result = try allocator.alloc(u8, header.len + obj.data.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], obj.data);

    return result;
}

test "object type to string" {
    try std.testing.expectEqualSlices(u8, "blob", typeToStr(.blob));
    try std.testing.expectEqualSlices(u8, "tree", typeToStr(.tree));
    try std.testing.expectEqualSlices(u8, "commit", typeToStr(.commit));
    try std.testing.expectEqualSlices(u8, "tag", typeToStr(.tag));
}

test "object type from string" {
    try std.testing.expectEqual(.blob, try typeFromStr("blob"));
    try std.testing.expectEqual(.tree, try typeFromStr("tree"));
    try std.testing.expectEqual(.commit, try typeFromStr("commit"));
    try std.testing.expectEqual(.tag, try typeFromStr("tag"));
}

test "object parse and serialize roundtrip" {
    const original_data = "Hello, World!";
    const size_str = try std.fmt.allocPrint(std.testing.allocator, "{}", .{original_data.len});
    defer std.testing.allocator.free(size_str);

    const raw = try std.mem.concat(std.testing.allocator, u8, &.{ "blob ", size_str, "\x00", original_data });
    defer std.testing.allocator.free(raw);

    const obj = try parse(raw);
    defer std.testing.allocator.free(obj.data);

    try std.testing.expectEqual(.blob, obj.obj_type);
    try std.testing.expectEqualSlices(u8, original_data, obj.data);
}

test "object parse invalid type" {
    const invalid_data = "invalid 5\x00hello";
    try std.testing.expectError(error.InvalidObjectType, parse(invalid_data));
}

test "object parse missing null" {
    const no_null = "blob 5hello";
    try std.testing.expectError(error.InvalidObjectFormat, parse(no_null));
}

test "object parse size mismatch" {
    const wrong_size = "blob 100\x00hello";
    try std.testing.expectError(error.InvalidObjectSize, parse(wrong_size));
}

test "object compute header size" {
    try std.testing.expectEqual(@as(usize, 16), computeHeaderSize(.blob, 0)); // "blob " (5) + max_digits (10) + "\0" (1)
    try std.testing.expectEqual(@as(usize, 16), computeHeaderSize(.blob, 9));
    try std.testing.expectEqual(@as(usize, 16), computeHeaderSize(.blob, 99));
    try std.testing.expectEqual(@as(usize, 16), computeHeaderSize(.blob, 999));
}
