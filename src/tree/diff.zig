//! TreeDiff - Compute differences between two tree objects
//!
//! This module provides functionality to compute the differences
//! between two tree objects, similar to `git diff-tree`.

const std = @import("std");
const tree_mod = @import("../object/tree.zig");
const OID = @import("../object/oid.zig").OID;

pub const ChangeType = enum {
    added,
    deleted,
    modified,
    renamed,
    copied,
    type_changed,
    unmerged,
};

pub const TreeChange = struct {
    change_type: ChangeType,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    old_entry: ?tree_mod.TreeEntry,
    new_entry: ?tree_mod.TreeEntry,
};

pub const DiffResult = struct {
    changes: []const TreeChange,
    has_changes: bool,

    pub fn init(_allocator: std.mem.Allocator) DiffResult {
        _ = _allocator;
        return .{
            .changes = &.{},
            .has_changes = false,
        };
    }
};

pub const TreeDiff = struct {
    allocator: std.mem.Allocator,
    changes: std.ArrayList(TreeChange),

    pub fn init(allocator: std.mem.Allocator) TreeDiff {
        return .{
            .allocator = allocator,
            .changes = std.ArrayList(TreeChange).init(allocator),
        };
    }

    pub fn deinit(self: *TreeDiff) void {
        for (self.changes.items) |change| {
            if (change.old_path) |path| self.allocator.free(path);
            if (change.new_path) |path| self.allocator.free(path);
        }
        self.changes.deinit();
    }

    pub fn compute(self: *TreeDiff, old_tree: ?tree_mod.Tree, new_tree: ?tree_mod.Tree) !void {
        try self.diffTrees(old_tree, new_tree);
    }

    fn diffTrees(self: *TreeDiff, old_tree: ?tree_mod.Tree, new_tree: ?tree_mod.Tree) !void {
        const old_entries = if (old_tree) |t| t.entries else &.{};
        const new_entries = if (new_tree) |t| t.entries else &.{};

        var old_map = std.StringHashMap(tree_mod.TreeEntry).init(self.allocator);
        defer old_map.deinit();
        for (old_entries) |entry| {
            try old_map.put(entry.name, entry);
        }

        var new_map = std.StringHashMap(tree_mod.TreeEntry).init(self.allocator);
        defer new_map.deinit();
        for (new_entries) |entry| {
            try new_map.put(entry.name, entry);
        }

        for (old_entries) |old_entry| {
            if (new_map.get(old_entry.name)) |new_entry| {
                if (!oidsEqual(old_entry.oid, new_entry.oid)) {
                    if (old_entry.mode != new_entry.mode) {
                        try self.addChange(.type_changed, old_entry.name, old_entry, new_entry);
                    } else {
                        try self.addChange(.modified, old_entry.name, old_entry, new_entry);
                    }
                }
            } else {
                try self.addChange(.deleted, old_entry.name, old_entry, null);
            }
        }

        for (new_entries) |new_entry| {
            if (!old_map.contains(new_entry.name)) {
                try self.addChange(.added, new_entry.name, null, new_entry);
            }
        }
    }

    fn addChange(self: *TreeDiff, change_type: ChangeType, path: []const u8, old_entry: ?tree_mod.TreeEntry, new_entry: ?tree_mod.TreeEntry) !void {
        try self.changes.append(.{
            .change_type = change_type,
            .old_path = if (old_entry != null) try self.allocator.dupe(u8, path) else null,
            .new_path = if (new_entry != null) try self.allocator.dupe(u8, path) else null,
            .old_entry = old_entry,
            .new_entry = new_entry,
        });
    }

    pub fn getChanges(self: *TreeDiff) []const TreeChange {
        return self.changes.items;
    }

    pub fn hasChanges(self: *TreeDiff) bool {
        return self.changes.items.len > 0;
    }
};

fn oidsEqual(a: OID, b: OID) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

pub fn diffTrees(
    allocator: std.mem.Allocator,
    old_tree: ?tree_mod.Tree,
    new_tree: ?tree_mod.Tree,
) !DiffResult {
    var differ = TreeDiff.init(allocator);
    errdefer differ.deinit();

    try differ.compute(old_tree, new_tree);

    return .{
        .changes = try differ.changes.toOwnedSlice(),
        .has_changes = differ.hasChanges(),
    };
}

pub fn countChanges(result: DiffResult) struct { added: usize, deleted: usize, modified: usize } {
    var counts = .{ .added = 0, .deleted = 0, .modified = 0 };
    for (result.changes) |change| {
        switch (change.change_type) {
            .added => counts.added += 1,
            .deleted => counts.deleted += 1,
            .modified, .type_changed => counts.modified += 1,
            else => {},
        }
    }
    return counts;
}

pub fn hasPathChange(result: DiffResult, path: []const u8) bool {
    for (result.changes) |change| {
        if (change.old_path) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        if (change.new_path) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
    }
    return false;
}

test "TreeDiff initializes correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var differ = TreeDiff.init(gpa.allocator());
    defer differ.deinit();

    try std.testing.expect(!differ.hasChanges());
}

test "diffTrees detects added files" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const old_tree = tree_mod.Tree.create(&.{});
    const new_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "new.txt" },
    });

    const result = try diffTrees(gpa.allocator(), old_tree, new_tree);
    defer {
        for (result.changes) |change| {
            if (change.old_path) |p| gpa.allocator().free(p);
            if (change.new_path) |p| gpa.allocator().free(p);
        }
        gpa.allocator().free(result.changes);
    }

    try std.testing.expect(result.has_changes);
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    try std.testing.expectEqual(ChangeType.added, result.changes[0].change_type);
}

test "diffTrees detects deleted files" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const old_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "deleted.txt" },
    });
    const new_tree = tree_mod.Tree.create(&.{});

    const result = try diffTrees(gpa.allocator(), old_tree, new_tree);
    defer {
        for (result.changes) |change| {
            if (change.old_path) |p| gpa.allocator().free(p);
            if (change.new_path) |p| gpa.allocator().free(p);
        }
        gpa.allocator().free(result.changes);
    }

    try std.testing.expect(result.has_changes);
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    try std.testing.expectEqual(ChangeType.deleted, result.changes[0].change_type);
}

test "diffTrees detects modified files" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const old_oid: [20]u8 = [_]u8{0} ** 20;
    const new_oid: [20]u8 = [_]u8{1} ** 20;
    const old_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = old_oid, .name = "modified.txt" },
    });
    const new_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = new_oid, .name = "modified.txt" },
    });

    const result = try diffTrees(gpa.allocator(), old_tree, new_tree);
    defer {
        for (result.changes) |change| {
            if (change.old_path) |p| gpa.allocator().free(p);
            if (change.new_path) |p| gpa.allocator().free(p);
        }
        gpa.allocator().free(result.changes);
    }

    try std.testing.expect(result.has_changes);
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
    try std.testing.expectEqual(ChangeType.modified, result.changes[0].change_type);
}

test "countChanges counts all change types" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const old_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "a.txt" },
        .{ .mode = .file, .oid = oid, .name = "b.txt" },
        .{ .mode = .file, .oid = oid, .name = "c.txt" },
    });
    const new_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "a.txt" },
        .{ .mode = .file, .oid = oid, .name = "d.txt" },
        .{ .mode = .file, .oid = oid, .name = "e.txt" },
    });

    const result = try diffTrees(gpa.allocator(), old_tree, new_tree);
    defer {
        for (result.changes) |change| {
            if (change.old_path) |p| gpa.allocator().free(p);
            if (change.new_path) |p| gpa.allocator().free(p);
        }
        gpa.allocator().free(result.changes);
    }

    const counts = countChanges(result);
    try std.testing.expectEqual(@as(usize, 2), counts.added);
    try std.testing.expectEqual(@as(usize, 2), counts.deleted);
    try std.testing.expectEqual(@as(usize, 0), counts.modified);
}

test "hasPathChange finds changed path" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const old_tree = tree_mod.Tree.create(&.{});
    const new_tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "new.txt" },
    });

    const result = try diffTrees(gpa.allocator(), old_tree, new_tree);
    defer {
        for (result.changes) |change| {
            if (change.old_path) |p| gpa.allocator().free(p);
            if (change.new_path) |p| gpa.allocator().free(p);
        }
        gpa.allocator().free(result.changes);
    }

    try std.testing.expect(hasPathChange(result, "new.txt"));
    try std.testing.expect(!hasPathChange(result, "nonexistent.txt"));
}
