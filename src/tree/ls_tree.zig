//! LsTree - Implementation of git ls-tree command
//!
//! This module provides the ls-tree functionality to list
//! tree entries in a formatted output similar to `git ls-tree`.

const std = @import("std");
const Io = std.Io;
const tree_mod = @import("../object/tree.zig");
const OID = @import("../object/oid.zig").OID;
const ODB = @import("../object/odb.zig").ODB;
const Object = @import("../object/object.zig").Object;

pub const LsTreeOptions = struct {
    recursive: bool = false,
    long_format: bool = false,
    name_only: bool = false,
    full_oid: bool = false,
    stage: bool = false,
};

pub const LsTreeError = error{
    NotATree,
    InvalidTree,
    IoError,
    ObjectNotFound,
};

pub const LsTree = struct {
    allocator: std.mem.Allocator,
    options: LsTreeOptions,
    entries: std.ArrayList(LsTreeEntry),

    pub const LsTreeEntry = struct {
        mode: tree_mod.Mode,
        oid: OID,
        name: []const u8,
        size: ?u64,
    };

    pub fn init(allocator: std.mem.Allocator, options: LsTreeOptions) LsTree {
        return .{
            .allocator = allocator,
            .options = options,
            .entries = std.ArrayList(LsTreeEntry).init(allocator),
        };
    }

    pub fn deinit(self: *LsTree) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
    }

    pub fn run(self: *LsTree, io: *Io, odb: *ODB, tree_oid: OID) !void {
        const obj = try odb.read(io, tree_oid);
        if (obj.objType() != .tree) {
            return error.NotATree;
        }

        const tree = try tree_mod.Tree.parse(self.allocator, obj.data);
        try self.listTree(io, odb, tree, "");
    }

    fn listTree(self: *LsTree, io: *Io, odb: *ODB, tree: tree_mod.Tree, prefix: []const u8) !void {
        for (tree.entries) |entry| {
            const full_name = if (prefix.len > 0)
                try std.mem.concat(self.allocator, u8, &.{ prefix, "/", entry.name })
            else
                try self.allocator.dupe(u8, entry.name);

            if (self.options.recursive and entry.mode == .directory) {
                try self.listDirectoryTree(io, odb, entry.oid, full_name);
            } else {
                try self.addEntry(entry, full_name);
            }

            if (prefix.len > 0) {
                self.allocator.free(full_name);
            }
        }
    }

    fn listDirectoryTree(self: *LsTree, io: *Io, odb: *ODB, oid: OID, prefix: []const u8) !void {
        const obj = try odb.read(io, oid);
        if (obj.objType() != .tree) return;

        const tree = try tree_mod.Tree.parse(self.allocator, obj.data);
        try self.listTree(io, odb, tree, prefix);
    }

    fn addEntry(self: *LsTree, entry: tree_mod.TreeEntry, name: []const u8) !void {
        try self.entries.append(.{
            .mode = entry.mode,
            .oid = entry.oid,
            .name = name,
            .size = null,
        });
    }

    pub fn formatEntry(self: *LsTree, entry: LsTreeEntry, writer: *std.Io.Writer, depth: usize) !void {
        const is_dir = entry.mode == .directory;
        const kind_sym = if (is_dir) "├──" else "├─ ";
        var indent_buf: [128]u8 = undefined;
        var indent_len: usize = 0;
        for (0..depth) |_| {
            @memcpy(indent_buf[indent_len..][0..2], "│ ");
            indent_len += 2;
        }

        if (self.options.name_only) {
            try writer.writeAll(indent_buf[0..indent_len]);
            try writer.print("{s}{s}", .{ kind_sym, entry.name });
            return;
        }

        try writer.writeAll(indent_buf[0..indent_len]);
        try writer.print("{s}{s} {s} {s}\t{s}", .{
            kind_sym,
            tree_mod.modeToStr(entry.mode),
            entry.oid.formatShort(),
            if (self.options.stage) "0" else "",
            entry.name,
        });
    }
};

pub fn formatTreeEntries(allocator: std.mem.Allocator, tree: tree_mod.Tree, options: LsTreeOptions) ![][]u8 {
    var lines = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit();
    }

    for (tree.entries) |entry| {
        var line = std.ArrayList(u8).init(allocator);
        errdefer line.deinit();

        if (options.name_only) {
            try line.appendSlice(entry.name);
        } else {
            try std.fmt.format(line.writer(), "{s} {s} {s}", .{
                tree_mod.modeToStr(entry.mode),
                entry.oid.formatShort(),
                entry.name,
            });
        }

        try lines.append(try line.toOwnedSlice());
    }

    return try lines.toOwnedSlice();
}

pub fn lsTree(allocator: std.mem.Allocator, io: *Io, odb: *ODB, tree_oid: OID, options: LsTreeOptions) !LsTree {
    var lister = LsTree.init(allocator, options);
    try lister.run(io, odb, tree_oid);
    return lister;
}

pub fn getTreeOid(io: *Io, odb: *ODB, ref: []const u8) !OID {
    return try ODB.resolveRef(io, odb, ref);
}

test "LsTree initializes correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var lister = LsTree.init(gpa.allocator(), .{});
    defer lister.deinit();

    try std.testing.expectEqual(@as(usize, 0), lister.entries.items.len);
}

test "LsTree with name_only option" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var lister = LsTree.init(gpa.allocator(), .{ .name_only = true });
    defer lister.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "test.txt" },
    });

    try lister.addEntry(tree.entries[0], "test.txt");
    try std.testing.expectEqual(@as(usize, 1), lister.entries.items.len);
    try std.testing.expectEqualStrings("test.txt", lister.entries.items[0].name);
}

test "formatTreeEntries creates formatted output" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "a.txt" },
        .{ .mode = .directory, .oid = oid, .name = "src" },
    });

    const lines = try formatTreeEntries(gpa.allocator(), tree, .{});
    defer {
        for (lines) |line| gpa.allocator().free(line);
        gpa.allocator().free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "a.txt") != null);
}

test "formatTreeEntries with name_only option" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    const oid: [20]u8 = [_]u8{0} ** 20;
    const tree = tree_mod.Tree.create(&.{
        .{ .mode = .file, .oid = oid, .name = "test.txt" },
    });

    const lines = try formatTreeEntries(gpa.allocator(), tree, .{ .name_only = true });
    defer {
        for (lines) |line| gpa.allocator().free(line);
        gpa.allocator().free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("test.txt", lines[0]);
}
