//! Tree object - represents a directory structure with entries
const std = @import("std");
const object_mod = @import("object.zig");
const oid_mod = @import("oid.zig");

/// File mode constants for tree entries
pub const Mode = enum(u16) {
    file = 0o100644,
    executable = 0o100755,
    directory = 0o040000,
    symlink = 0o120000,
    gitlink = 0o160000,
};

pub const ModeError = error{
    InvalidModeFormat,
    UnsupportedMode,
};

fn modeToInt(m: Mode) u16 {
    return @as(u16, @intFromEnum(m));
}

fn intToMode(val: u16) Mode {
    return @as(Mode, @enumFromInt(val));
}

pub fn modeToStr(m: Mode) [6]u8 {
    return switch (m) {
        .file => .{ '1', '0', '0', '6', '4', '4' },
        .executable => .{ '1', '0', '0', '7', '5', '5' },
        .directory => .{ '0', '4', '0', '0', '0', '0' },
        .symlink => .{ '1', '2', '0', '0', '0', '0' },
        .gitlink => .{ '1', '6', '0', '0', '0', '0' },
    };
}

pub fn modeFromStr(str: []const u8) !Mode {
    if (str.len != 6) return error.InvalidModeFormat;

    var mode_val: u16 = 0;
    for (str) |c| {
        if (c < '0' or c > '7') return error.InvalidModeFormat;
        mode_val = (mode_val << 3) | @as(u16, c - '0');
    }

    if (mode_val == 0o100644) return .file;
    if (mode_val == 0o100755) return .executable;
    if (mode_val == 0o040000) return .directory;
    if (mode_val == 0o120000) return .symlink;
    if (mode_val == 0o160000) return .gitlink;

    return error.UnsupportedMode;
}

pub fn modeFromInt(val: u16) !Mode {
    if (val == 0o100644) return .file;
    if (val == 0o100755) return .executable;
    if (val == 0o040000) return .directory;
    if (val == 0o120000) return .symlink;
    if (val == 0o160000) return .gitlink;
    if (val & 0o170000 == 0o100000) return .file;
    return error.UnsupportedMode;
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
        var buffer = std.ArrayList(u8).initCapacity(allocator, 256);
        defer buffer.deinit(allocator);

        // Build entries
        for (self.entries) |entry| {
            // Write mode and name
            try buffer.appendSlice(&modeToStr(entry.mode));
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
    try std.testing.expectEqualSlices(u8, "100644", &modeToStr(.file));
    try std.testing.expectEqualSlices(u8, "100755", &modeToStr(.executable));
    try std.testing.expectEqualSlices(u8, "040000", &modeToStr(.directory));
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
    try std.testing.expectEqualSlices(u8, "120000", &modeToStr(.symlink));
    try std.testing.expectEqualSlices(u8, "160000", &modeToStr(.gitlink));
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

test "mode from int" {
    try std.testing.expectEqual(Mode.file, modeFromInt(0o100644));
    try std.testing.expectEqual(Mode.executable, modeFromInt(0o100755));
    try std.testing.expectEqual(Mode.directory, modeFromInt(0o040000));
    try std.testing.expectEqual(Mode.symlink, modeFromInt(0o120000));
    try std.testing.expectEqual(Mode.gitlink, modeFromInt(0o160000));
}

test "mode invalid format" {
    try std.testing.expectError(error.InvalidModeFormat, modeFromStr(""));
    try std.testing.expectError(error.InvalidModeFormat, modeFromStr("10064"));
    try std.testing.expectError(error.InvalidModeFormat, modeFromStr("1006444"));
    try std.testing.expectError(error.InvalidModeFormat, modeFromStr("abcdef"));
}

test "mode unsupported mode" {
    try std.testing.expectError(error.UnsupportedMode, modeFromStr("100000"));
    try std.testing.expectError(error.UnsupportedMode, modeFromStr("000000"));
}
