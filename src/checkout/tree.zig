//! Tree Checkout - Recursively checkout trees
const std = @import("std");
const OID = @Import("../object/oid.zig").OID;
const Tree = @import("../object/tree.zig").Tree;
const TreeEntry = @import("../object/tree.zig").TreeEntry;
const ODB = @import("../object/odb.zig").ODB;
const Mode = @import("../object/tree.zig").Mode;
const FileCheckout = @import("file.zig").FileCheckout;

pub const TreeCheckout = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    file_checkout: FileCheckout,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB) TreeCheckout {
        return .{
            .allocator = allocator,
            .odb = odb,
            .file_checkout = FileCheckout.init(allocator, odb),
        };
    }

    pub fn checkoutTree(
        self: *TreeCheckout,
        tree_oid: OID,
        base_path: []const u8,
        force: bool,
    ) !void {
        const tree_data = try self.odb.readObject(tree_oid);
        defer self.allocator.free(tree_data);

        const tree = try Tree.parse(tree_data);
        try self.checkoutEntries(&tree, base_path, force);
    }

    fn checkoutEntries(
        self: *TreeCheckout,
        tree: *const Tree,
        base_path: []const u8,
        force: bool,
    ) !void {
        for (tree.entries) |entry| {
            const full_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ base_path, entry.name },
            );
            defer self.allocator.free(full_path);

            switch (entry.mode) {
                .directory => {
                    try std.fs.cwd().makePath(full_path);
                    const subtree_data = try self.odb.readObject(entry.oid);
                    defer self.allocator.free(subtree_data);
                    const subtree = try Tree.parse(subtree_data);
                    try self.checkoutEntries(&subtree, full_path, force);
                },
                .file, .executable => {
                    try self.file_checkout.checkoutFile(entry.oid, full_path);
                },
                .symlink => {
                    try self.checkoutSymlink(entry, full_path);
                },
                .gitlink => {
                    try self.checkoutGitlink(entry, full_path);
                },
                else => {},
            }
        }
    }

    fn checkoutSymlink(self: *TreeCheckout, entry: TreeEntry, path: []const u8) !void {
        _ = self;
        _ = entry;
        _ = path;
    }

    fn checkoutGitlink(self: *TreeCheckout, entry: TreeEntry, path: []const u8) !void {
        _ = self;
        _ = entry;
        _ = path;
    }
};

test "TreeCheckout init" {
    var odb: ODB = undefined;
    var checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}

test "TreeCheckout init with odb" {
    var odb: ODB = undefined;
    var checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.odb == &odb);
}

test "TreeCheckout allocator access" {
    var odb: ODB = undefined;
    var checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expectEqual(std.testing.allocator, checkout.allocator);
}

test "TreeCheckout init sets allocator" {
    var odb: ODB = undefined;
    const checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator.ptr != null);
}

test "TreeCheckout init sets odb reference" {
    var odb: ODB = undefined;
    const checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.odb != null);
}

test "TreeCheckout file_checkout access" {
    var odb: ODB = undefined;
    var checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.file_checkout.allocator == std.testing.allocator);
}

test "TreeCheckout file_checkout odb reference" {
    var odb: ODB = undefined;
    var checkout = TreeCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.file_checkout.odb == &odb);
}