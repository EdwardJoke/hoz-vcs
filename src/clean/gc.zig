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
        const removal = try self.removeUnreachableObjects();
        result.removed_objects = removal.count;
        result.freed_bytes = removal.bytes;

        return result;
    }

    pub fn packLooseObjects(self: *GarbageCollector) !usize {
        const objects_dir = self.git_dir.openDir(self.io, "objects", .{}) catch {
            return 0;
        };
        defer objects_dir.close(self.io);

        var object_list = try std.ArrayList(OID).initCapacity(self.allocator, 0);
        defer object_list.deinit(self.allocator);

        var dir_iter = objects_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
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

            var sub_iter = subdir.iterate();
            while (sub_iter.next(self.io) catch null) |sub_entry| {
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

    pub fn removeUnreachableObjects(self: *GarbageCollector) !struct { count: usize, bytes: usize } {
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
        var removed_bytes: usize = 0;

        const objects_dir = self.git_dir.openDir(self.io, "objects", .{}) catch {
            return .{ .count = 0, .bytes = 0 };
        };
        defer objects_dir.close(self.io);

        var dir_iter = objects_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
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

            var sub_iter = subdir.iterate();
            while (sub_iter.next(self.io) catch null) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                const filename = sub_entry.name;
                if (filename.len != 38) continue;

                const hex_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ name, filename });
                defer self.allocator.free(hex_str);

                if (!reachable.contains(hex_str)) {
                    const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ name, filename });
                    defer self.allocator.free(obj_path);
                    const file_stat = self.git_dir.statFile(self.io, obj_path) catch 0;
                    removed_bytes += @as(usize, @intCast(file_stat.size));
                    self.git_dir.deleteFile(self.io, obj_path) catch {};
                    removed_count += 1;
                }
            }
        }

        return .{ .count = removed_count, .bytes = removed_bytes };
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

        var worklist = std.ArrayList([]const u8).initCapacity(self.allocator, 64);
        defer {
            for (worklist.items) |oid| self.allocator.free(oid);
            worklist.deinit(self.allocator);
        }

        var iter = reachable.keyIterator();
        while (iter.next()) |oid_hex| {
            const owned = try self.allocator.dupe(u8, oid_hex.*);
            try worklist.append(self.allocator, owned);
        }

        while (worklist.popOrNull()) |oid_hex| {
            defer self.allocator.free(oid_hex);

            var oid_bytes: [OID.hex_length]u8 = undefined;
            @memcpy(&oid_bytes, oid_hex);

            const raw = self.readObject(OID{ .bytes = oid_bytes }) catch continue;
            defer self.allocator.free(raw);

            if (std.mem.startsWith(u8, raw, "commit ")) {
                try self.walkCommit(raw, &worklist, reachable);
            } else if (std.mem.startsWith(u8, raw, "tree ")) {
                try self.walkTree(raw, reachable);
            } else if (std.mem.startsWith(u8, raw, "tag ")) {
                try self.walkTag(raw, &worklist, reachable);
            }
        }
    }

    fn walkCommit(self: *GarbageCollector, commit_data: []const u8, worklist: *std.ArrayList([]const u8), reachable: *std.StringHashMap(bool)) !void {
        var pos: usize = "commit ".len;
        while (pos < commit_data.len) {
            const end_of_value = std.mem.indexOfPos(u8, commit_data, pos, "\n") orelse break;
            const line = commit_data[pos..end_of_value];

            const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const field = line[0..space_idx];
            const value = line[space_idx + 1 ..];

            if (value.len < OID.hex_length) {
                pos = end_of_value + 1;
                continue;
            }

            if (std.mem.eql(u8, field, "tree") or std.mem.eql(u8, field, "parent")) {
                const hex = value[0..OID.hex_length];
                const gop = try reachable.getOrPut(hex);
                if (!gop.found_existing) {
                    gop.value_ptr.* = true;
                    const owned = try self.allocator.dupe(u8, hex);
                    try worklist.append(self.allocator, owned);
                }
            }

            pos = end_of_value + 1;
            if (pos < commit_data.len and commit_data[pos] == '\n') break;
        }
    }

    fn walkTree(_: *GarbageCollector, tree_data: []const u8, reachable: *std.StringHashMap(bool)) !void {
        var pos: usize = "tree ".len;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOfPos(u8, tree_data, pos, ' ') orelse break;
            pos = space_idx + 1;

            const null_idx = std.mem.indexOfPos(u8, tree_data, pos, 0) orelse break;
            pos = null_idx + 1;

            if (pos + 20 > tree_data.len) break;

            var raw_oid: [20]u8 = undefined;
            @memcpy(&raw_oid, tree_data[pos..][0..20]);

            const oid_obj = OID{ .bytes = raw_oid };
            const hex_buf = oid_obj.toHex();
            const hex = &hex_buf;
            const gop = try reachable.getOrPut(hex);
            if (!gop.found_existing) {
                gop.value_ptr.* = true;
            }
            pos += 20;
        }
    }

    fn walkTag(self: *GarbageCollector, tag_data: []const u8, worklist: *std.ArrayList([]const u8), reachable: *std.StringHashMap(bool)) !void {
        var pos: usize = "tag ".len;
        while (pos < tag_data.len) {
            const end_of_value = std.mem.indexOfPos(u8, tag_data, pos, "\n") orelse break;
            const line = tag_data[pos..end_of_value];

            const space_idx = std.mem.indexOfScalar(u8, line, ' ') orelse {
                pos = end_of_value + 1;
                continue;
            };
            const field = line[0..space_idx];
            const value = line[space_idx + 1 ..];

            if (value.len >= OID.hex_length and std.mem.eql(u8, field, "object")) {
                const hex = value[0..OID.hex_length];
                const gop = try reachable.getOrPut(hex);
                if (!gop.found_existing) {
                    gop.value_ptr.* = true;
                    const owned = try self.allocator.dupe(u8, hex);
                    try worklist.append(self.allocator, owned);
                }
            }

            pos = end_of_value + 1;
            if (pos < tag_data.len and tag_data[pos] == '\n') break;
        }
    }

    fn markRefsReachable(self: *GarbageCollector, dir: Io.Dir, reachable: *std.StringHashMap(bool)) !void {
        var dir_iter = dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
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

        var pack_data = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
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

            const obj_type = objectTypeFromRaw(obj_data);
            const null_idx = std.mem.indexOfScalar(u8, obj_data, 0) orelse obj_data.len;
            const content = if (null_idx < obj_data.len) obj_data[null_idx + 1 ..] else obj_data;
            const size = @as(u32, @intCast(content.len));
            var byte: u8 = @truncate((obj_type << 4) | (size & 0xf));
            var remaining = size >> 4;
            try pack_data.append(self.allocator, byte);
            while (remaining > 0) {
                byte = @as(u8, @intCast(remaining & 0x7f)) | 0x80;
                remaining >>= 7;
                try pack_data.append(self.allocator, byte);
            }

            const compressed = self.zlibCompress(content) catch continue;
            defer self.allocator.free(compressed);
            try pack_data.appendSlice(self.allocator, compressed);
        }

        try self.git_dir.writeFile(self.io, .{ .sub_path = pack_path, .data = pack_data.items });

        const idx_name = try std.fmt.allocPrint(self.allocator, "pack-{d}.idx", .{timestamp});
        defer self.allocator.free(idx_name);
        const idx_path = try std.fmt.allocPrint(self.allocator, "objects/pack/{s}", .{idx_name});
        defer self.allocator.free(idx_path);

        var idx_data = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer idx_data.deinit(self.allocator);

        const idx_magic = "\xff\x74\x4f\x63";
        try idx_data.appendSlice(self.allocator, idx_magic);
        std.mem.writeInt(u32, try idx_data.addManyAsArray(self.allocator, 4), 2, .little);

        var fanout: [256]u32 = [_]u32{0} ** 256;
        for (oids) |oid| {
            const fb = oid.bytes[0];
            fanout[fb] += 1;
        }
        var cumulative: u32 = 0;
        for (&fanout) |*count| {
            cumulative += count.*;
            count.* = cumulative;
        }
        for (fanout) |f| {
            std.mem.writeInt(u32, try idx_data.addManyAsArray(self.allocator, 4), f, .big);
        }

        const sorted_oids = try self.allocator.alloc(OID, oids.len);
        defer self.allocator.free(sorted_oids);
        @memcpy(sorted_oids, oids);
        std.mem.sort(OID, sorted_oids, {}, OID.lessThan);

        for (sorted_oids) |oid| {
            try idx_data.appendSlice(self.allocator, &oid.bytes);
        }
        for (sorted_oids) |_| {
            std.mem.writeInt(u32, try idx_data.addManyAsArray(self.allocator, 4), 0, .big);
        }
        for (sorted_oids) |_| {
            std.mem.writeInt(u32, try idx_data.addManyAsArray(self.allocator, 4), 0, .big);
        }

        try idx_data.appendSlice(self.allocator, &[_]u8{0} ** 20);
        try idx_data.appendSlice(self.allocator, &[_]u8{0} ** 20);

        self.git_dir.writeFile(self.io, .{ .sub_path = idx_path, .data = idx_data.items }) catch {};
    }

    fn objectTypeFromRaw(raw: []const u8) u8 {
        if (raw.len < 4) return 1;
        if (std.mem.startsWith(u8, raw, "blob ")) return 3;
        if (std.mem.startsWith(u8, raw, "tree ")) return 2;
        if (std.mem.startsWith(u8, raw, "commit ")) return 1;
        if (std.mem.startsWith(u8, raw, "tag ")) return 4;
        return 1;
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

    fn zlibCompress(self: *GarbageCollector, data: []const u8) ![]u8 {
        return compress_mod.Zlib.compress(data, self.allocator);
    }
};

test "GarbageCollector init" {
    const gc = GarbageCollector.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(gc.options.aggressive == false);
}

test "GcResult fields initialized" {
    const result = GcResult{ .packed_objects = 0, .removed_objects = 0, .freed_bytes = 0 };
    try std.testing.expect(result.packed_objects == 0);
    try std.testing.expect(result.removed_objects == 0);
    try std.testing.expect(result.freed_bytes == 0);
}
