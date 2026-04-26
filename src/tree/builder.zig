//! TreeBuilder - Build tree objects from index entries
//!
//! This module provides functionality to convert index entries into
//! tree objects that can be stored in the object database.

const std = @import("std");
const Io = std.Io;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const Index = @import("../index/index.zig").Index;
const tree_mod = @import("../object/tree.zig");
const OID = @import("../object/oid.zig").OID;

pub const TreeBuilderError = error{
    InvalidPath,
    IoError,
    OutOfMemory,
};

pub const TreeBuilder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(tree_mod.TreeEntry),
    subtrees: std.AutoHashMap([]const u8, *TreeBuilder),

    pub fn init(allocator: std.mem.Allocator) !TreeBuilder {
        return .{
            .allocator = allocator,
            .entries = try std.ArrayList(tree_mod.TreeEntry).initCapacity(allocator, 0),
            .subtrees = std.AutoHashMap([]const u8, *TreeBuilder).init(allocator),
        };
    }

    pub fn deinit(self: *TreeBuilder) void {
        self.entries.deinit(self.allocator);
        var it = self.subtrees.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.subtrees.deinit();
    }

    pub fn addIndexEntry(self: *TreeBuilder, entry: IndexEntry, name: []const u8) !void {
        const mode = self.modeFromIndexEntry(entry);
        try self.entries.append(self.allocator, .{
            .mode = mode,
            .oid = entry.oid,
            .name = try self.allocator.dupe(u8, name),
        });
    }

    pub fn addEntry(self: *TreeBuilder, mode: tree_mod.Mode, oid: OID, name: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .mode = mode,
            .oid = oid,
            .name = try self.allocator.dupe(u8, name),
        });
    }

    fn modeFromIndexEntry(self: *TreeBuilder, entry: IndexEntry) tree_mod.Mode {
        _ = self;
        const mode_val = entry.mode;
        if (mode_val & 0o100000 != 0) {
            if (mode_val & 0o100 != 0) {
                return .executable;
            }
            return .file;
        }
        if (mode_val & 0o40000 != 0) {
            return .directory;
        }
        if (mode_val & 0o120000 != 0) {
            return .symlink;
        }
        return .file;
    }

    pub fn build(self: *TreeBuilder) !tree_mod.Tree {
        const sorted_entries = try self.sortEntries(self.entries.items);
        return tree_mod.Tree.create(sorted_entries);
    }

    fn sortEntries(self: *TreeBuilder, entries: []tree_mod.TreeEntry) ![]const tree_mod.TreeEntry {
        _ = self;
        std.mem.sort(tree_mod.TreeEntry, @constCast(entries), {}, compareTreeEntries);
        return entries;
    }

    pub fn buildAll(self: *TreeBuilder) ![]const tree_mod.Tree {
        if (self.entries.items.len == 0) {
            const trees = try self.allocator.alloc(tree_mod.Tree, 1);
            trees[0] = try tree_mod.Tree.create(&.{});
            return trees;
        }

        var dir_map = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(tree_mod.TreeEntry)).empty;
        defer {
            var it = dir_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }
            dir_map.deinit(self.allocator);
        }

        for (self.entries.items) |entry| {
            const slash_idx = std.mem.indexOf(u8, entry.name, "/") orelse entry.name.len;
            const dir = if (slash_idx > 0)
                entry.name[0..slash_idx]
            else
                ".";

            const gop = try dir_map.getOrPut(self.allocator, dir);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.ensureTotalCapacity(self.allocator, 4);
            try gop.value_ptr.append(self.allocator, entry);
        }

        var trees = std.ArrayListUnmanaged(tree_mod.Tree).empty;
        errdefer trees.deinit(self.allocator);

        var it = dir_map.iterator();
        while (it.next()) |entry| {
            const sub_entries = try entry.value_ptr.*.toOwnedSlice(self.allocator);
            defer self.allocator.free(sub_entries);
            const sorted = try self.sortEntries(sub_entries);
            const tree = tree_mod.Tree.create(sorted);
            try trees.append(self.allocator, tree);
        }

        return trees.toOwnedSlice(self.allocator);
    }
};

pub fn compareTreeEntries(_: void, a: tree_mod.TreeEntry, b: tree_mod.TreeEntry) bool {
    if (std.mem.eql(u8, a.name, b.name)) {
        return @intFromEnum(a.mode) < @intFromEnum(b.mode);
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn buildTreeFromIndex(
    allocator: std.mem.Allocator,
    index: Index,
) !tree_mod.Tree {
    var builder = try TreeBuilder.init(allocator);
    errdefer builder.deinit();

    for (index.entries.items, index.entry_names.items) |entry, name| {
        try builder.addIndexEntry(entry, name);
    }

    return try builder.build();
}

pub fn buildSubtree(
    allocator: std.mem.Allocator,
    entries: []const tree_mod.TreeEntry,
    prefix: []const u8,
) !tree_mod.Tree {
    var builder = try TreeBuilder.init(allocator);
    errdefer builder.deinit();

    for (entries) |entry| {
        const full_path = try std.mem.concat(allocator, u8, &.{ prefix, "/", entry.name });
        defer allocator.free(full_path);

        if (std.mem.startsWith(u8, entry.name, prefix)) {
            try builder.addEntry(entry.mode, entry.oid, full_path);
        }
    }

    return try builder.build();
}

test "TreeBuilder initializes correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var builder = try TreeBuilder.init(gpa.allocator());
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, 0), builder.entries.items.len);
}

test "TreeBuilder adds entry correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var builder = try TreeBuilder.init(gpa.allocator());
    defer builder.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    try builder.addEntry(.file, oid, "test.txt");

    try std.testing.expectEqual(@as(usize, 1), builder.entries.items.len);
}

test "TreeBuilder build creates tree" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var builder = try TreeBuilder.init(gpa.allocator());
    defer builder.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    try builder.addEntry(.file, oid, "a.txt");
    try builder.addEntry(.file, oid, "b.txt");

    const tree = try builder.build();
    try std.testing.expectEqual(@as(usize, 2), tree.entries.len);
}

test "TreeBuilder addIndexEntry works" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var builder = try TreeBuilder.init(gpa.allocator());
    defer builder.deinit();

    const entry = IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .file_size = 10,
        .oid = [_]u8{0} ** 20,
        .flags = 0,
    };

    try builder.addIndexEntry(entry, "indexed.txt");
    try std.testing.expectEqual(@as(usize, 1), builder.entries.items.len);
    try std.testing.expectEqualStrings("indexed.txt", builder.entries.items[0].name);
}

test "compareTreeEntries sorts by name then mode" {
    const a = tree_mod.TreeEntry{
        .mode = .file,
        .oid = [_]u8{0} ** 20,
        .name = "a.txt",
    };
    const b = tree_mod.TreeEntry{
        .mode = .file,
        .oid = [_]u8{0} ** 20,
        .name = "b.txt",
    };

    try std.testing.expect(compareTreeEntries({}, a, b));
}

test "buildTreeFromIndex creates tree from index" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var index = Index.init(gpa.allocator());
    defer index.deinit();

    const oid: [20]u8 = [_]u8{1} ** 20;
    try index.entries.append(gpa.allocator(), .{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .file_size = 0,
        .oid = oid,
        .flags = 0,
    });
    try index.entry_names.append(gpa.allocator(), "test.txt");

    const tree = try buildTreeFromIndex(gpa.allocator(), index);
    try std.testing.expectEqual(@as(usize, 1), tree.entries.len);
    try std.testing.expectEqualStrings("test.txt", tree.entries[0].name);
}
