//! Tree object - represents a directory structure with entries
const std = @import("std");
const object_mod = @import("object.zig");
const oid_mod = @import("oid.zig");

/// File mode constants for tree entries
pub const Mode = enum(u16) {
    /// 0644 - regular file
    file = 0o100644,
    /// 0755 - executable file
    executable = 0o100755,
    /// 040000 - directory
    directory = 0o040000,
    /// 0160000 - symlink
    symlink = 0o120000,
    /// 0120000 - gitlink (submodule)
    gitlink = 0o160000,
};

/// Convert mode to string representation
pub fn modeToStr(m: Mode) []const u8 {
    return switch (m) {
        .file => "100644",
        .executable => "100755",
        .directory => "040000",
        .symlink => "120000",
        .gitlink => "160000",
    };
}

/// Parse mode from string
pub fn modeFromStr(str: []const u8) !Mode {
    if (std.mem.eql(u8, str, "100644")) return .file;
    if (std.mem.eql(u8, str, "100755")) return .executable;
    if (std.mem.eql(u8, str, "040000")) return .directory;
    if (std.mem.eql(u8, str, "120000")) return .symlink;
    if (std.mem.eql(u8, str, "160000")) return .gitlink;
    return error.InvalidMode;
}

/// A single entry in a tree (file or directory)
pub const TreeEntry = struct {
    /// File mode (e.g., "100644", "040000")
    mode: Mode,
    /// OID of the object (blob for files, tree for directories)
    oid: oid_mod.OID,
    /// Filename (path component)
    name: []const u8,
};

/// Tree object - represents a directory
pub const Tree = struct {
    /// Sorted list of entries
    entries: []const TreeEntry,

    /// Create a new Tree with entries
    pub fn create(entries: []const TreeEntry) Tree {
        return Tree{ .entries = entries };
    }

    /// Get the object type for this tree
    pub fn objectType() object_mod.Type {
        return .tree;
    }

    /// Serialize tree to loose object format
    /// Format: "tree <size>\n<entry>\n<entry>..."
    /// Each entry: "<mode> <name>\x00<oid_bytes>"
    pub fn serialize(self: Tree, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);

        // Build entries
        for (self.entries) |entry| {
            // Write mode and name
            try buffer.appendSlice(modeToStr(entry.mode));
            try buffer.append(' ');
            try buffer.appendSlice(entry.name);
            try buffer.append(0);

            // Write OID (20 bytes)
            try buffer.appendSlice(&entry.oid.bytes);
        }

        // Now wrap with tree header
        const content = buffer.items;
        const size_str = try std.fmt.allocPrint(allocator, "{}", .{content.len});
        defer allocator.free(size_str);

        const header = try std.fmt.allocPrint(allocator, "tree {}\x00", .{size_str});
        defer allocator.free(header);

        var result = try allocator.alloc(u8, header.len + content.len);
        @memcpy(result[0..header.len], header);
        @memcpy(result[header.len..], content);

        return result;
    }

    /// Parse tree from loose object data
    pub fn parse(data: []const u8) !Tree {
        const obj = try object_mod.parse(data);
        if (obj.obj_type != .tree) {
            return error.NotATree;
        }

        // Parse tree entries from the binary format
        var entries = std.ArrayList(TreeEntry).init(std.testing.allocator);
        errdefer entries.deinit();

        var pos: usize = 0;
        while (pos < obj.data.len) {
            // Find space between mode and name
            const space_idx = std.mem.indexOf(u8, obj.data[pos..], " ") orelse break;
            const mode_str = obj.data[pos .. pos + space_idx];
            pos += space_idx + 1;

            // Find null byte between name and OID
            const null_idx = std.mem.indexOf(u8, obj.data[pos..], "\x00") orelse break;
            const name = obj.data[pos .. pos + null_idx];
            pos += null_idx + 1;

            // OID is exactly 20 bytes
            if (pos + 20 > obj.data.len) break;
            const oid_bytes = obj.data[pos .. pos + 20];
            pos += 20;

            const mode = try modeFromStr(mode_str);
            const oid = oid_mod.OID.fromBytes(oid_bytes);

            try entries.append(TreeEntry{
                .mode = mode,
                .oid = oid,
                .name = name,
            });
        }

        return Tree{ .entries = try entries.toOwnedSlice() };
    }
};

test "mode to string" {
    try std.testing.expectEqualSlices(u8, "100644", modeToStr(.file));
    try std.testing.expectEqualSlices(u8, "100755", modeToStr(.executable));
    try std.testing.expectEqualSlices(u8, "040000", modeToStr(.directory));
}

test "mode from string" {
    try std.testing.expectEqual(Mode.file, try modeFromStr("100644"));
    try std.testing.expectEqual(Mode.executable, try modeFromStr("100755"));
    try std.testing.expectEqual(Mode.directory, try modeFromStr("040000"));
}

test "tree create" {
    const entries = &[_]TreeEntry{
        TreeEntry{ .mode = .file, .oid = oid_mod.OID.zero(), .name = "README" },
        TreeEntry{ .mode = .directory, .oid = oid_mod.OID.zero(), .name = "src" },
    };
    const tree = Tree.create(entries);

    try std.testing.expectEqual(2, tree.entries.len);
    try std.testing.expectEqualSlices(u8, "README", tree.entries[0].name);
    try std.testing.expectEqualSlices(u8, "src", tree.entries[1].name);
}

test "tree serialize and parse roundtrip" {
    const entries = &[_]TreeEntry{
        TreeEntry{ .mode = .file, .oid = oid_mod.OID.zero(), .name = "foo.txt" },
        TreeEntry{ .mode = .directory, .oid = oid_mod.OID.zero(), .name = "dir" },
        TreeEntry{ .mode = .executable, .oid = oid_mod.OID.zero(), .name = "script.sh" },
    };
    const tree = Tree.create(entries);

    const serialized = try tree.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const parsed = try Tree.parse(serialized);
    try std.testing.expectEqual(3, parsed.entries.len);
    try std.testing.expectEqualSlices(u8, "foo.txt", parsed.entries[0].name);
    try std.testing.expectEqual(Mode.file, parsed.entries[0].mode);
    try std.testing.expectEqualSlices(u8, "dir", parsed.entries[1].name);
    try std.testing.expectEqual(Mode.directory, parsed.entries[1].mode);
}

test "tree symlink and gitlink modes" {
    try std.testing.expectEqual(Mode.symlink, try modeFromStr("120000"));
    try std.testing.expectEqual(Mode.gitlink, try modeFromStr("160000"));
    try std.testing.expectEqualSlices(u8, "120000", modeToStr(.symlink));
    try std.testing.expectEqualSlices(u8, "160000", modeToStr(.gitlink));
}

test "tree parse rejects non-tree" {
    const blob_data = "blob 5\x00hello";
    try std.testing.expectError(error.NotATree, Tree.parse(blob_data));
}

test "tree empty entries" {
    const entries = &[_]TreeEntry{};
    const tree = Tree.create(entries);
    try std.testing.expectEqual(0, tree.entries.len);
    try std.testing.expectEqual(object_mod.Type.tree, tree.objectType());
}
