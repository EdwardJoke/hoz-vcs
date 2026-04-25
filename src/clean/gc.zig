//! Garbage Collection - Git gc implementation
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const compress_mod = @import("../compress/zlib.zig");

pub const GcOptions = struct {
    aggressive: bool = false,
    prune: bool = false,
    prune_expire: ?[]const u8 = null,
};

pub const GcResult = struct {
    packed_objects: usize,
    removed_objects: usize,
    freed_bytes: usize,
};

pub const GarbageCollector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: GcOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) GarbageCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = .{},
        };
    }

    pub fn run(self: *GarbageCollector) !GcResult {
        var result = GcResult{
            .packed_objects = 0,
            .removed_objects = 0,
            .freed_bytes = 0,
        };

        result.packed_objects = try self.packLooseObjects();
        result.removed_objects = try self.removeUnreachableObjects();

        return result;
    }

    pub fn packLooseObjects(self: *GarbageCollector) !usize {
        const objects_dir = self.git_dir.openDir(self.io, "objects", .{}) catch {
            return 0;
        };
        defer objects_dir.close(self.io);

        var object_list = std.ArrayList(OID).init(self.allocator);
        defer object_list.deinit(self.allocator);

        var dir_iter = objects_dir.iterate(self.io);
        while (try dir_iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;
            if (name.len != 2) continue;

            var is_hex = true;
            for (name) |c| {
                if (!std.ascii.isHex(c)) {
                    is_hex = false;
                    break;
                }
            }
            if (!is_hex) continue;

            const subdir = objects_dir.openDir(self.io, name, .{}) catch continue;
            defer subdir.close(self.io);

            var sub_iter = subdir.iterate(self.io);
            while (try sub_iter.next()) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                const filename = sub_entry.name;
                if (filename.len != 38) continue;

                var is_hex_file = true;
                for (filename) |c| {
                    if (!std.ascii.isHex(c)) {
                        is_hex_file = false;
                        break;
                    }
                }
                if (!is_hex_file) continue;

                const hex_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ name, filename });
                defer self.allocator.free(hex_str);

                const oid = OID.fromHex(hex_str) catch continue;
                try object_list.append(self.allocator, oid);
            }
        }

        if (object_list.items.len == 0) {
            return 0;
        }

        try self.createPackfile(object_list.items);

        for (object_list.items) |oid| {
            const hex = oid.toHex();
            const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
            defer self.allocator.free(obj_path);
            self.git_dir.deleteFile(self.io, obj_path) catch {};
        }

        return object_list.items.len;
    }

    pub fn removeUnreachableObjects(self: *GarbageCollector) !usize {
        var reachable = std.StringHashMap(bool).init(self.allocator);
        defer {
            var iter = reachable.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            reachable.deinit();
        }

        try self.markReachable(&reachable);

        var removed_count: usize = 0;

        const objects_dir = self.git_dir.openDir(self.io, "objects", .{}) catch {
            return 0;
        };
        defer objects_dir.close(self.io);

        var dir_iter = objects_dir.iterate(self.io);
        while (try dir_iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;
            if (name.len != 2) continue;

            var is_hex = true;
            for (name) |c| {
                if (!std.ascii.isHex(c)) {
                    is_hex = false;
                    break;
                }
            }
            if (!is_hex) continue;

            if (std.mem.eql(u8, name, "pack") or std.mem.eql(u8, name, "info")) continue;

            const subdir = objects_dir.openDir(self.io, name, .{}) catch continue;
            defer subdir.close(self.io);

            var sub_iter = subdir.iterate(self.io);
            while (try sub_iter.next()) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                const filename = sub_entry.name;
                if (filename.len != 38) continue;

                const hex_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ name, filename });
                defer self.allocator.free(hex_str);

                if (!reachable.contains(hex_str)) {
                    const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ name, filename });
                    defer self.allocator.free(obj_path);
                    self.git_dir.deleteFile(self.io, obj_path) catch {};
                    removed_count += 1;
                }
            }
        }

        return removed_count;
    }

    pub fn repack(self: *GarbageCollector) !usize {
        return try self.packLooseObjects();
    }

    fn markReachable(self: *GarbageCollector, reachable: *std.StringHashMap(bool)) !void {
        const refs_dir = self.git_dir.openDir(self.io, "refs", .{}) catch return;
        defer refs_dir.close(self.io);

        try self.markRefsReachable(refs_dir, reachable);

        const head_data = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch null;
        defer if (head_data) |buf| self.allocator.free(buf);
        if (head_data) |buf| {
            const trimmed = std.mem.trim(u8, buf, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                try self.markRefReachable(ref_path, reachable);
            } else if (trimmed.len >= 40) {
                const hex_str = try self.allocator.dupe(u8, trimmed[0..40]);
                try reachable.put(hex_str, true);
            }
        }
    }

    fn markRefsReachable(self: *GarbageCollector, dir: Io.Dir, reachable: *std.StringHashMap(bool)) !void {
        var dir_iter = dir.iterate(self.io);
        while (try dir_iter.next()) |entry| {
            if (entry.kind == .directory) {
                const subdir = dir.openDir(self.io, entry.name, .{}) catch continue;
                defer subdir.close(self.io);
                try self.markRefsReachable(subdir, reachable);
            } else if (entry.kind == .file) {
                const ref_content = dir.readFileAlloc(self.io, entry.name, self.allocator, .limited(256)) catch continue;
                defer self.allocator.free(ref_content);
                const trimmed = std.mem.trim(u8, ref_content, " \n\r");
                if (trimmed.len >= 40) {
                    const hex_str = try self.allocator.dupe(u8, trimmed[0..40]);
                    try reachable.put(hex_str, true);
                }
            }
        }
    }

    fn markRefReachable(self: *GarbageCollector, ref_path: []const u8, reachable: *std.StringHashMap(bool)) !void {
        const ref_content = self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return;
        defer self.allocator.free(ref_content);
        const trimmed = std.mem.trim(u8, ref_content, " \n\r");
        if (trimmed.len >= 40) {
            const hex_str = try self.allocator.dupe(u8, trimmed[0..40]);
            try reachable.put(hex_str, true);
        }
    }

    fn createPackfile(self: *GarbageCollector, oids: []const OID) !void {
        const pack_dir = try std.fmt.allocPrint(self.allocator, "objects/pack", .{});
        defer self.allocator.free(pack_dir);

        self.git_dir.createDirPath(self.io, pack_dir) catch {};

        const timestamp = std.time.timestamp();
        const pack_name = try std.fmt.allocPrint(self.allocator, "pack-{d}.pack", .{timestamp});
        defer self.allocator.free(pack_name);

        const pack_path = try std.fmt.allocPrint(self.allocator, "objects/pack/{s}", .{pack_name});
        defer self.allocator.free(pack_path);

        var pack_data = std.ArrayList(u8).init(self.allocator);
        defer pack_data.deinit(self.allocator);

        try pack_data.appendSlice(self.allocator, "PACK");
        try pack_data.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 2 });

        const num_objects: u32 = @intCast(oids.len);
        try pack_data.append(self.allocator, @truncate((num_objects >> 24) & 0xff));
        try pack_data.append(self.allocator, @truncate((num_objects >> 16) & 0xff));
        try pack_data.append(self.allocator, @truncate((num_objects >> 8) & 0xff));
        try pack_data.append(self.allocator, @truncate(num_objects & 0xff));

        for (oids) |oid| {
            const obj_data = self.readObject(oid) catch continue;
            defer self.allocator.free(obj_data);
            try pack_data.appendSlice(self.allocator, obj_data);
        }

        try self.git_dir.writeFile(self.io, .{ .sub_path = pack_path, .data = pack_data.items });
    }

    fn readObject(self: *GarbageCollector, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| {
            return err;
        };
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch |err| {
            return err;
        };

        return decompressed;
    }
};

test "GarbageCollector init" {
    const gc = GarbageCollector.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(gc.options.aggressive == false);
}
