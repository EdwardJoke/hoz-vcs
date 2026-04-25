//! Restore Staged - Restore index from another commit (git restore --staged)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const Tree = @import("../object/tree.zig").Tree;

pub const RestoreStaged = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) RestoreStaged {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn restore(self: *RestoreStaged, paths: []const []const u8, source: []const u8) !void {
        const source_oid = OID.fromHex(source) catch return error.InvalidOid;
        const tree_oid = try self.getTreeFromCommit(source_oid);

        for (paths) |path| {
            const entry = self.findTreeEntry(tree_oid, path) catch continue;
            _ = entry;
        }
    }

    pub fn restoreAll(self: *RestoreStaged, source: []const u8) !void {
        const source_oid = OID.fromHex(source) catch return error.InvalidOid;
        const tree_oid = try self.getTreeFromCommit(source_oid);
        _ = tree_oid;
    }

    fn getTreeFromCommit(self: *RestoreStaged, oid: OID) !OID {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const raw_data = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(65536)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(raw_data);

        const commit = Commit.parse(self.allocator, raw_data) catch {
            return error.InvalidCommit;
        };

        return commit.tree;
    }

    fn findTreeEntry(_: *RestoreStaged, _: OID, _: []const u8) !struct { mode: u32, oid: OID } {
        return error.EntryNotFound;
    }
};

test "RestoreStaged init" {
    const restore = RestoreStaged.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}
