//! Tree Checkout - Recursively checkout trees
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Tree = @import("../object/tree.zig").Tree;
const TreeEntry = @import("../object/tree.zig").TreeEntry;
const ODB = @import("../object/odb.zig").ODB;
const Mode = @import("../object/tree.zig").Mode;
const FileCheckout = @import("file.zig").FileCheckout;

pub const TreeCheckout = struct {
    allocator: std.mem.Allocator,
    io: Io,
    odb: *ODB,
    file_checkout: FileCheckout,

    pub fn init(allocator: std.mem.Allocator, io: Io, odb: *ODB) TreeCheckout {
        return .{
            .allocator = allocator,
            .io = io,
            .odb = odb,
            .file_checkout = FileCheckout.init(allocator, io, odb),
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

        const tree = try Tree.parse(self.allocator, tree_data);
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
                    Io.Dir.cwd().makePath(self.io, full_path) catch {};
                    const subtree_data = try self.odb.readObject(entry.oid);
                    defer self.allocator.free(subtree_data);
                    const subtree = try Tree.parse(self.allocator, subtree_data);
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
        const link_target = try self.odb.readObject(entry.oid);
        defer self.allocator.free(link_target);

        const cwd = Io.Dir.cwd();
        cwd.symLink(self.io, link_target, path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                cwd.deleteFile(self.io, path) catch {};
                try cwd.symLink(self.io, link_target, path, .{});
            },
            else => return err,
        };
    }

    fn checkoutGitlink(self: *TreeCheckout, entry: TreeEntry, path: []const u8) !void {
        const cwd = Io.Dir.cwd();
        cwd.makePath(self.io, path) catch {};

        const git_file = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{path});
        defer self.allocator.free(git_file);

        const gitlink_content = try std.fmt.allocPrint(
            self.allocator,
            "gitdir: ../.git/modules/{s}\n",
            .{entry.oid.toHex()},
        );
        defer self.allocator.free(gitlink_content);

        var file = cwd.createFile(self.io, git_file, .{}) catch return;
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(gitlink_content);
    }
};

test "TreeCheckout init" {
    var odb: ODB = undefined;
    const checkout = TreeCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}

test "TreeCheckout init with odb" {
    var odb: ODB = undefined;
    const checkout = TreeCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.odb == &odb);
}

test "TreeCheckout file_checkout shares odb" {
    var odb: ODB = undefined;
    const checkout = TreeCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.file_checkout.odb == checkout.odb);
}
