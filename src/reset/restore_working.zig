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
        const cwd = Io.Dir.cwd();
        const blob_data = self.readBlobForPath(path) catch return;
        defer self.allocator.free(blob_data);

        cwd.createDirPath(self.io, getParentDir(path)) catch {};
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = blob_data });
    }

    fn readBlobForPath(self: *RestoreWorking, path: []const u8) ![]u8 {
        const index_data = self.git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(1024 * 1024)) catch {
            return error.IndexNotFound;
        };
        defer self.allocator.free(index_data);

        var pos: usize = 12;
        while (pos + 62 < index_data.len) {
            const flags = std.mem.readInt(u16, index_data[pos + 60 ..][0..2], .big);
            const name_len = flags & 0xFFF;
            if (name_len == 0 or name_len > path.len) {
                pos += 62 + ((name_len + 8) & ~@as(usize, 7));
                continue;
            }
            const entry_name = index_data[pos + 62 .. pos + 62 + name_len];
            if (std.mem.eql(u8, entry_name, path)) {
                var oid_bytes: [20]u8 = undefined;
                @memcpy(&oid_bytes, index_data[pos + 40 ..][0..20]);
                const oid = OID{ .bytes = oid_bytes };
                return self.readBlob(oid);
            }
            pos += 62 + ((name_len + 8) & ~@as(usize, 7));
        }
        return error.PathNotInIndex;
    }

    fn readBlob(self: *RestoreWorking, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const raw = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(raw);

        if (raw.len < 5 or !std.mem.startsWith(u8, raw, "blob ")) return error.InvalidObject;

        const null_idx = std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidObject;
        return self.allocator.dupe(u8, raw[null_idx + 1 ..]);
    }

    fn readObject(self: *RestoreWorking, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const raw = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };

        if (raw.len < 5) return error.InvalidObject;

        const null_idx = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        return self.allocator.dupe(u8, raw[null_idx + 1 ..]);
    }

    fn restoreAllFromTree(self: *RestoreWorking, tree_data: []const u8) !void {
        var pos: usize = 0;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_data[pos..], ' ') orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            pos += space_idx + 1;

            const null_idx = std.mem.indexOfScalar(u8, tree_data[pos..], 0) orelse break;
            const name = tree_data[pos .. pos + null_idx];
            pos += null_idx + 1;

            if (pos + 20 > tree_data.len) break;
            var oid_bytes: [20]u8 = undefined;
            @memcpy(&oid_bytes, tree_data[pos .. pos + 20]);
            const oid = OID{ .bytes = oid_bytes };
            pos += 20;

            if (!std.mem.eql(u8, mode_str, "40000")) {
                const blob = self.readBlob(oid) catch continue;
                defer self.allocator.free(blob);

                const cwd = Io.Dir.cwd();
                cwd.createDirPath(self.io, name) catch {};
                cwd.writeFile(self.io, .{ .sub_path = name, .data = blob }) catch {};
            } else {
                Io.Dir.cwd().createDirPath(self.io, name) catch {};
            }
        }
    }

    fn restorePathFromTree(self: *RestoreWorking, path: []const u8, tree_data: []const u8) !void {
        var pos: usize = 0;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_data[pos..], ' ') orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            pos += space_idx + 1;

            const null_idx = std.mem.indexOfScalar(u8, tree_data[pos..], 0) orelse break;
            const name = tree_data[pos .. pos + null_idx];
            pos += null_idx + 1;

            if (pos + 20 > tree_data.len) break;
            var oid_bytes2: [20]u8 = undefined;
            @memcpy(&oid_bytes2, tree_data[pos .. pos + 20]);
            const oid = OID{ .bytes = oid_bytes2 };
            pos += 20;

            if (std.mem.eql(u8, name, path) and !std.mem.eql(u8, mode_str, "40000")) {
                const blob = self.readBlob(oid) catch return;
                defer self.allocator.free(blob);

                const cwd = Io.Dir.cwd();
                cwd.createDirPath(self.io, getParentDir(name)) catch {};
                try cwd.writeFile(self.io, .{ .sub_path = name, .data = blob });
                return;
            }
        }
    }

    fn getParentDir(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            return path[0..idx];
        }
        return ".";
    }
};

test "RestoreWorking init" {
    const restore = RestoreWorking.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(restore.allocator == std.testing.allocator);
}
