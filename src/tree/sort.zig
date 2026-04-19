//! TreeSort - Sort tree entries by name and type
//!
//! This module provides sorting utilities for tree entries,
//! following Git's sorting conventions (directories first, then by name).

const std = @import("std");
const tree_mod = @import("../object/tree.zig");
const OID = @import("../object/oid.zig").OID;

pub const SortOrder = enum {
    name_asc,
    name_desc,
    type_first,
};

pub const SortOptions = struct {
    order: SortOrder = .type_first,
    case_sensitive: bool = true,
};

pub fn sortTreeEntries(entries: []tree_mod.TreeEntry, options: SortOptions) void {
    std.mem.sort(tree_mod.TreeEntry, entries, options, compareTreeEntryByOptions);
}

pub fn compareTreeEntryByOptions(ctx: SortOptions, a: tree_mod.TreeEntry, b: tree_mod.TreeEntry) bool {
    switch (ctx.order) {
        .name_asc => {
            if (ctx.case_sensitive) {
                return std.mem.lessThan(u8, a.name, b.name);
            }
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        },
        .name_desc => {
            if (ctx.case_sensitive) {
                return std.mem.lessThan(u8, b.name, a.name);
            }
            return std.ascii.lessThanIgnoreCase(b.name, a.name);
        },
        .type_first => {
            const a_is_dir = a.mode == .directory;
            const b_is_dir = b.mode == .directory;
            if (a_is_dir != b_is_dir) {
                return a_is_dir;
            }
            if (ctx.case_sensitive) {
                return std.mem.lessThan(u8, a.name, b.name);
            }
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        },
    }
}

pub fn sortedTree(allocator: std.mem.Allocator, tree: tree_mod.Tree, options: SortOptions) !tree_mod.Tree {
    const entries_copy = try allocator.alloc(tree_mod.TreeEntry, tree.entries.len);
    @memcpy(entries_copy, tree.entries);
    sortTreeEntries(entries_copy, options);
    return tree_mod.Tree.create(entries_copy);
}

pub fn groupEntriesByType(entries: []tree_mod.TreeEntry) struct { dirs: []tree_mod.TreeEntry, files: []tree_mod.TreeEntry } {
    var dir_count: usize = 0;
    var file_count: usize = 0;

    for (entries) |entry| {
        if (entry.mode == .directory) {
            dir_count += 1;
        } else {
            file_count += 1;
        }
    }

    var dirs_slice = try std.ArrayList(tree_mod.TreeEntry).initCapacity(std.testing.allocator, dir_count);
    var files_slice = try std.ArrayList(tree_mod.TreeEntry).initCapacity(std.testing.allocator, file_count);

    for (entries) |entry| {
        if (entry.mode == .directory) {
            dirs_slice.appendAssumeCapacity(entry);
        } else {
            files_slice.appendAssumeCapacity(entry);
        }
    }

    return .{ .dirs = dirs_slice.items, .files = files_slice.items };
}

pub fn isSorted(tree: tree_mod.Tree, options: SortOptions) bool {
    if (tree.entries.len <= 1) return true;

    for (tree.entries[0 .. tree.entries.len - 1], 0..) |entry, i| {
        const next = tree.entries[i + 1];
        if (!compareTreeEntryByOptions(options, entry, next)) {
            if (compareTreeEntryByOptions(options, next, entry)) {
                return false;
            }
        }
    }
    return true;
}

test "sortTreeEntries sorts by name ascending" {
    var entries: [3]tree_mod.TreeEntry = .{
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "c.txt" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "a.txt" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "b.txt" },
    };

    sortTreeEntries(&entries, .{ .order = .name_asc });

    try std.testing.expectEqualStrings("a.txt", entries[0].name);
    try std.testing.expectEqualStrings("b.txt", entries[1].name);
    try std.testing.expectEqualStrings("c.txt", entries[2].name);
}

test "sortTreeEntries sorts directories first" {
    var entries: [3]tree_mod.TreeEntry = .{
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "a.txt" },
        .{ .mode = .directory, .oid = [20]u8{0} ** 20, .name = "src" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "b.txt" },
    };

    sortTreeEntries(&entries, .{ .order = .type_first });

    try std.testing.expectEqual(.directory, entries[0].mode);
    try std.testing.expectEqualStrings("a.txt", entries[1].name);
}

test "compareTreeEntryByOptions handles case insensitive" {
    const entries: [2]tree_mod.TreeEntry = .{
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "B.txt" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "a.txt" },
    };

    const result = compareTreeEntryByOptions(.{ .order = .name_asc, .case_sensitive = false }, entries[0], entries[1]);
    try std.testing.expect(result);
}

test "isSorted returns true for already sorted tree" {
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .directory, .oid = [20]u8{0} ** 20, .name = "src" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "a.txt" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "b.txt" },
    });

    try std.testing.expect(isSorted(tree, .{ .order = .type_first }));
}

test "isSorted returns false for unsorted tree" {
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "b.txt" },
        .{ .mode = .file, .oid = [20]u8{0} ** 20, .name = "a.txt" },
    });

    try std.testing.expect(!isSorted(tree, .{ .order = .name_asc }));
}
