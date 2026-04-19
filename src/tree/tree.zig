//! Tree module - Working with Git tree objects
//!
//! This module provides the main entry point for tree operations,
//! re-exporting functionality from submodules.

const std = @import("std");
const tree_object = @import("../object/tree.zig");
const Mode = tree_object.Mode;
const TreeEntry = tree_object.TreeEntry;
const Tree = tree_object.Tree;
const modeToStr = tree_object.modeToStr;
const modeFromStr = tree_object.modeFromStr;

pub const builder = @import("builder.zig");
pub const parser = @import("parser.zig");
pub const diff = @import("diff.zig");
pub const sort = @import("sort.zig");
pub const ls_tree = @import("ls_tree.zig");

pub usingnamespace tree_object;

test "tree module exports" {
    try std.testing.expectEqual(@as(u16, 0o100644), @intFromEnum(Mode.file));
    try std.testing.expectEqual(@as(u16, 0o040000), @intFromEnum(Mode.directory));
}

test "tree module roundtrip" {
    const oid: [20]u8 = [_]u8{0} ** 20;
    const entry = TreeEntry{
        .mode = .file,
        .oid = oid,
        .name = "test.txt",
    };

    const tree = Tree.create(&.{entry});
    try std.testing.expectEqual(@as(usize, 1), tree.entries.len);
}