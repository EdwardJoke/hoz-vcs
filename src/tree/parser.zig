//! TreeParser - Parse tree objects from object database
//!
//! This module provides functionality to parse tree objects from
//! their binary representation in the object database.

const std = @import("std");
const Io = std.Io;
const tree_mod = @import("../object/tree.zig");
const OID = @import("../object/oid.zig").OID;
const Object = @import("../object/object.zig").Object;
const ODB = @import("../object/odb.zig").ODB;

pub const TreeParserError = error{
    InvalidTreeData,
    MalformedTreeEntry,
    IoError,
};

pub const TreeParser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) TreeParser {
        return .{
            .allocator = allocator,
            .data = data,
            .position = 0,
        };
    }

    pub fn parse(self: *TreeParser) !tree_mod.Tree {
        var entries = std.ArrayList(tree_mod.TreeEntry).init(self.allocator);
        errdefer entries.deinit();

        while (self.position < self.data.len) {
            const entry = try self.parseEntry();
            try entries.append(entry);
        }

        return tree_mod.Tree.create(try entries.toOwnedSlice());
    }

    fn parseEntry(self: *TreeParser) !tree_mod.TreeEntry {
        if (self.position >= self.data.len) {
            return error.MalformedTreeEntry;
        }

        const space_idx = std.mem.indexOfScalar(u8, self.data[self.position..], ' ') orelse {
            return error.MalformedTreeEntry;
        };
        const mode_str = self.data[self.position .. self.position + space_idx];
        self.position += space_idx + 1;

        if (self.position >= self.data.len) {
            return error.MalformedTreeEntry;
        }

        const null_idx = std.mem.indexOfScalar(u8, self.data[self.position..], 0) orelse {
            return error.MalformedTreeEntry;
        };
        const name = self.data[self.position .. self.position + null_idx];
        self.position += null_idx + 1;

        if (self.position + 20 > self.data.len) {
            return error.MalformedTreeEntry;
        }
        const oid_bytes = self.data[self.position .. self.position + 20];
        self.position += 20;

        const mode = try tree_mod.modeFromStr(mode_str);
        const oid = OID.fromBytes(oid_bytes);

        return .{
            .mode = mode,
            .oid = oid,
            .name = name,
        };
    }

    pub fn parseFromObject(self: *TreeParser, obj: Object) !tree_mod.Tree {
        if (obj.objType() != .tree) {
            return error.InvalidTreeData;
        }
        return try self.parse();
    }
};

pub fn parseTree(allocator: std.mem.Allocator, data: []const u8) !tree_mod.Tree {
    var parser = TreeParser.init(allocator, data);
    return try parser.parse();
}

pub fn parseTreeFromodb(allocator: std.mem.Allocator, io: *Io, odb: *ODB, oid: OID) !tree_mod.Tree {
    const obj = try odb.read(io, oid);
    var parser = TreeParser.init(allocator, obj.data);
    return try parser.parse();
}

pub fn treeToEntries(tree: tree_mod.Tree) []const tree_mod.TreeEntry {
    return tree.entries;
}

pub fn findEntry(tree: tree_mod.Tree, name: []const u8) ?tree_mod.TreeEntry {
    for (tree.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry;
        }
    }
    return null;
}

pub fn countEntries(tree: tree_mod.Tree) struct { files: usize, dirs: usize } {
    var counts = .{ .files = 0, .dirs = 0 };
    for (tree.entries) |entry| {
        switch (entry.mode) {
            .directory => counts.dirs += 1,
            else => counts.files += 1,
        }
    }
    return counts;
}

test "TreeParser initializes correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const data = "100644 README.txt\x00" ++ ([20]u8{0} ** 20);
    const parser = TreeParser.init(gpa.allocator(), data);

    try std.testing.expectEqual(@as(usize, 0), parser.position);
}

test "TreeParser parses single entry" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid_bytes: [20]u8 = .{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc };
    var data: [60]u8 = undefined;
    @memcpy(data[0..7], "100644");
    data[7] = ' ';
    @memcpy(data[8..18], "README.txt");
    data[18] = 0;
    @memcpy(data[19..39], &oid_bytes);

    var parser = TreeParser.init(gpa.allocator(), &data);
    const tree = try parser.parse();

    try std.testing.expectEqual(@as(usize, 1), tree.entries.len);
    try std.testing.expectEqualStrings("README.txt", tree.entries[0].name);
}

test "parseTree parses tree data correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid_bytes: [20]u8 = .{0x12} ** 20;
    var data: [60]u8 = undefined;
    @memcpy(data[0..7], "100644");
    data[7] = ' ';
    @memcpy(data[8..12], "a.txt");
    data[12] = 0;
    @memcpy(data[13..33], &oid_bytes);

    const tree = try parseTree(gpa.allocator(), &data);
    try std.testing.expectEqual(@as(usize, 1), tree.entries.len);
}

test "findEntry finds existing entry" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "test.txt" },
        .{ .mode = .directory, .oid = oid, .name = "src" },
    });

    const entry = findEntry(tree, "test.txt");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("test.txt", entry.?.name);
}

test "findEntry returns null for non-existent entry" {
    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "test.txt" },
    });

    const entry = findEntry(tree, "nonexistent");
    try std.testing.expect(entry == null);
}

test "countEntries counts files and directories" {
    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "a.txt" },
        .{ .mode = .file, .oid = oid, .name = "b.txt" },
        .{ .mode = .directory, .oid = oid, .name = "src" },
    });

    const counts = countEntries(tree);
    try std.testing.expectEqual(@as(usize, 2), counts.files);
    try std.testing.expectEqual(@as(usize, 1), counts.dirs);
}

test "treeToEntries returns entries slice" {
    const oid: [20]u8 = [_]u8{0} ** 20;
    const entries: []const tree_mod.TreeEntry = &.{
        .{ .mode = .file, .oid = oid, .name = "test.txt" },
    };
    const tree = tree_mod.Tree.create(entries);

    const result = treeToEntries(tree);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}
