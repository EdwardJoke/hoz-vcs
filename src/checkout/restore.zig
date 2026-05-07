//! Restore - Restore working tree files
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const compress_mod = @import("../compress/zlib.zig");

pub const RestoreSource = enum {
    index,
    head,
    commit,
};

pub const RestoreOptions = struct {
    source: RestoreSource = .index,
    staged: bool = false,
    force: bool = false,
    paths: ?[]const []const u8 = null,
    source_oid: ?OID = null,
};

pub const Restorer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: RestoreOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: RestoreOptions) Restorer {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn restore(self: *Restorer, paths: []const []const u8) !void {
        switch (self.options.source) {
            .index => try self.restoreFromIndex(paths),
            .head => try self.restoreFromHead(paths),
            .commit => try self.restoreFromCommit(paths),
        }
    }

    pub fn restoreFromIndex(self: *Restorer, paths: []const []const u8) !void {
        var failures: usize = 0;
        for (paths) |path| {
            self.restoreFileFromIndex(path) catch {
                failures += 1;
            };
        }
        if (failures > 0) return error.RestoreFailed;
    }

    pub fn restoreFromHead(self: *Restorer, paths: []const []const u8) !void {
        const head_oid = self.resolveHeadOid() catch return error.NoHeadOid;
        const tree_data = self.readTreeData(head_oid) catch return error.NoTreeOid;
        defer self.allocator.free(tree_data);

        var failures: usize = 0;
        for (paths) |path| {
            self.restorePathFromTree(path, tree_data) catch {
                failures += 1;
            };
        }
        if (failures > 0) return error.RestoreFailed;
    }

    fn restoreFromCommit(self: *Restorer, paths: []const []const u8) !void {
        const commit_oid = self.options.source_oid orelse return error.NoSourceOid;
        const tree_data = self.readTreeData(commit_oid) catch return error.NoTreeOid;
        defer self.allocator.free(tree_data);

        var failures: usize = 0;
        for (paths) |path| {
            self.restorePathFromTree(path, tree_data) catch {
                failures += 1;
            };
        }
        if (failures > 0) return error.RestoreFailed;
    }

    fn restoreFileFromIndex(self: *Restorer, path: []const u8) !void {
        const blob_data = self.readBlobForPath(path) catch return;
        defer self.allocator.free(blob_data);

        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(self.io, getParentDir(path));
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = blob_data });
    }

    fn readBlobForPath(self: *Restorer, path: []const u8) ![]u8 {
        const index_data = self.git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(1024 * 1024)) catch {
            return error.IndexNotFound;
        };
        defer self.allocator.free(index_data);

        if (index_data.len < 12) return error.InvalidIndex;

        if (!std.mem.eql(u8, index_data[0..4], "DIRC")) return error.InvalidIndex;

        const version = std.mem.readInt(u32, index_data[4..8], .big);
        if (version < 2 or version > 4) return error.UnsupportedIndexVersion;

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

    fn readBlob(self: *Restorer, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(compressed);

        const raw = compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.InvalidObject;
        };

        if (raw.len < 5 or !std.mem.startsWith(u8, raw, "blob ")) {
            self.allocator.free(raw);
            return error.InvalidObject;
        }

        const null_idx = std.mem.indexOfScalar(u8, raw, 0) orelse {
            self.allocator.free(raw);
            return error.InvalidObject;
        };
        const result = try self.allocator.dupe(u8, raw[null_idx + 1 ..]);
        self.allocator.free(raw);
        return result;
    }

    fn resolveHeadOid(self: *Restorer) !OID {
        const head_data = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return error.HeadNotFound;
        };
        defer self.allocator.free(head_data);
        const trimmed = std.mem.trim(u8, head_data, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            const ref_content = self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
                return error.RefNotFound;
            };
            defer self.allocator.free(ref_content);
            const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (ref_trimmed.len >= 40) {
                return OID.fromHex(ref_trimmed[0..40]) catch error.InvalidOid;
            }
            return error.InvalidRef;
        }
        if (trimmed.len >= 40) {
            return OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
        }
        return error.InvalidHead;
    }

    fn resolveTreeOid(self: *Restorer, oid: OID) !OID {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(compressed);

        const raw = compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.InvalidObject;
        };
        defer self.allocator.free(raw);

        if (std.mem.startsWith(u8, raw, "tree ")) return oid;
        if (!std.mem.startsWith(u8, raw, "commit ")) return error.NotATree;

        const tree_prefix = "tree ";
        const tree_start = std.mem.indexOf(u8, raw, tree_prefix) orelse return error.InvalidObject;
        const tree_hex_start = tree_start + tree_prefix.len;
        if (tree_hex_start + 40 > raw.len) return error.InvalidObject;
        return OID.fromHex(raw[tree_hex_start .. tree_hex_start + 40]) catch error.InvalidOid;
    }

    fn readTreeData(self: *Restorer, commit_oid: OID) ![]u8 {
        const tree_oid = try self.resolveTreeOid(commit_oid);
        const hex = tree_oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(compressed);

        const raw = compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.InvalidObject;
        };

        if (raw.len < 5 or !std.mem.startsWith(u8, raw, "tree ")) {
            self.allocator.free(raw);
            return error.NotATree;
        }

        const null_idx = std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidObject;
        const result = try self.allocator.dupe(u8, raw[null_idx + 1 ..]);
        self.allocator.free(raw);
        return result;
    }

    fn restorePathFromTree(self: *Restorer, path: []const u8, tree_data: []const u8) !void {
        const first_sep = std.mem.indexOfScalar(u8, path, '/') orelse null;
        const target_name = if (first_sep) |sep| path[0..sep] else path;
        const remaining = if (first_sep) |sep| path[sep + 1 ..] else null;

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

            if (!std.mem.eql(u8, name, target_name)) continue;

            if (std.mem.eql(u8, mode_str, "40000")) {
                if (remaining) |rest| {
                    const subtree_data = self.readTreeData(oid) catch return;
                    defer self.allocator.free(subtree_data);
                    return self.restorePathFromTree(rest, subtree_data);
                }
                return;
            }

            if (remaining != null) continue;

            const blob = self.readBlob(oid) catch return;
            defer self.allocator.free(blob);

            const cwd = Io.Dir.cwd();
            try cwd.createDirPath(self.io, getParentDir(path));
            try cwd.writeFile(self.io, .{ .sub_path = path, .data = blob });
            return;
        }
    }

    fn getParentDir(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            return path[0..idx];
        }
        return ".";
    }
};

test "RestoreSource enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.index)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.head)) == 1);
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.commit)) == 2);
}

test "RestoreOptions default values" {
    const options = RestoreOptions{};
    try std.testing.expect(options.source == .index);
    try std.testing.expect(options.staged == false);
    try std.testing.expect(options.force == false);
}

test "Restorer init" {
    const options = RestoreOptions{};
    const restorer = Restorer.init(std.testing.allocator, undefined, undefined, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
}

test "Restorer init with options" {
    var options = RestoreOptions{};
    options.staged = true;
    options.force = true;
    const restorer = Restorer.init(std.testing.allocator, undefined, undefined, options);

    try std.testing.expect(restorer.options.staged == true);
    try std.testing.expect(restorer.options.force == true);
}

test "Restorer restore method exists" {
    const options = RestoreOptions{};
    const restorer = Restorer.init(std.testing.allocator, undefined, undefined, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
    const result = restorer.restore(&.{ "nonexistent.txt" });
    try std.testing.expectError(error.RestoreFailed, result);
}

test "getParentDir extracts parent" {
    try std.testing.expectEqualStrings("src/foo", Restorer.getParentDir("src/foo/bar.txt"));
    try std.testing.expectEqualStrings(".", Restorer.getParentDir("file.txt"));
}
