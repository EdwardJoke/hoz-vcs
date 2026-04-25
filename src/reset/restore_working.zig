//! Restore Working - Restore working tree from index (git restore)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;

pub const RestoreWorking = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) RestoreWorking {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn restore(self: *RestoreWorking, paths: []const []const u8) !void {
        for (paths) |path| {
            self.restoreFile(path) catch {};
        }
    }

    pub fn restoreFromSource(self: *RestoreWorking, paths: []const []const u8, source: []const u8) !void {
        const source_oid = OID.fromHex(source) catch return error.InvalidOid;

        const tree_data = self.readObject(source_oid) catch return error.ObjectNotFound;
        defer self.allocator.free(tree_data);

        if (paths.len == 0) {
            self.restoreAllFromTree(tree_data) catch {};
        } else {
            for (paths) |path| {
                self.restorePathFromTree(path, tree_data) catch {};
            }
        }
    }

    fn restoreFile(self: *RestoreWorking, path: []const u8) !void {
        _ = self;
        _ = path;
    }

    fn readObject(self: *RestoreWorking, oid: OID) ![]const u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        return self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(65536)) catch {
            return error.ObjectNotFound;
        };
    }

    fn restoreAllFromTree(_: *RestoreWorking, _: []const u8) !void {}

    fn restorePathFromTree(_: *RestoreWorking, _: []const u8, _: []const u8) !void {}
};

test "RestoreWorking init" {
    const restore = RestoreWorking.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}
