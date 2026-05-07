//! Reset Hard - Reset HEAD, index, and working tree (--hard)
const std = @import("std");
const Io = std.Io;
const SoftReset = @import("soft.zig").SoftReset;
const MixedReset = @import("mixed.zig").MixedReset;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const HardReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) HardReset {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn reset(self: *HardReset, target: []const u8) !void {
        var soft = SoftReset.init(self.allocator, self.io, self.git_dir);
        try soft.reset(target);

        const target_oid = try self.resolveTarget(target);
        const tree_oid = try self.getTreeFromCommit(target_oid);

        try self.resetTreeToOid(tree_oid);
        try self.clearIndex();
        try self.clearStateFiles();
    }

    fn resolveTarget(self: *HardReset, spec: []const u8) !OID {
        if (std.mem.startsWith(u8, spec, "refs/")) {
            const ref_content = self.git_dir.readFileAlloc(self.io, spec, self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(ref_content);
            const trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]);
            }
        }

        if (spec.len == 40) {
            return OID.fromHex(spec);
        }

        if (std.mem.eql(u8, spec, "HEAD")) {
            const head_data = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(head_data);
            const trimmed = std.mem.trim(u8, head_data, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                return self.resolveTarget(ref_path);
            }
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]);
            }
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn getTreeFromCommit(self: *HardReset, commit_oid: OID) !OID {
        const commit_data = self.readObject(commit_oid) catch {
            return OID{ .bytes = .{0} ** 20 };
        };
        defer self.allocator.free(commit_data);

        const obj = object_mod.parse(commit_data) catch {
            return OID{ .bytes = .{0} ** 20 };
        };

        if (obj.obj_type != .commit) {
            return OID{ .bytes = .{0} ** 20 };
        }

        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hex = line[5..];
                if (tree_hex.len >= 40) {
                    return OID.fromHex(tree_hex[0..40]) catch {
                        return OID{ .bytes = .{0} ** 20 };
                    };
                }
            }
            if (line.len == 0) break;
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn readObject(self: *HardReset, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const object_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(object_path);

        const compressed = self.git_dir.readFileAlloc(self.io, object_path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| {
            return err;
        };
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch |err| {
            return err;
        };

        return decompressed;
    }

    fn resetTreeToOid(self: *HardReset, tree_oid: OID) !void {
        if (tree_oid.isZero()) return;

        const tree_data = self.readObject(tree_oid) catch return;
        defer self.allocator.free(tree_data);

        const obj = object_mod.parse(tree_data) catch return;
        if (obj.obj_type != .tree) return;

        try self.applyTreeEntries(obj.data, "");
    }

    fn applyTreeEntries(self: *HardReset, tree_data: []const u8, base_path: []const u8) anyerror!void {
        var pos: usize = 0;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOf(u8, tree_data[pos..], " ") orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            pos += space_idx + 1;

            const null_idx = std.mem.indexOf(u8, tree_data[pos..], "\x00") orelse break;
            const name = tree_data[pos .. pos + null_idx];
            pos += null_idx + 1;

            if (pos + 20 > tree_data.len) break;
            const oid_bytes = tree_data[pos .. pos + 20];
            pos += 20;

            const entry_oid = oid_mod.oidFromBytes(oid_bytes);
            const mode = parseMode(mode_str) catch continue;

            const full_path = if (base_path.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name })
            else
                try self.allocator.dupe(u8, name);
            defer self.allocator.free(full_path);

            try self.applyTreeEntry(full_path, entry_oid, mode);
        }
    }

    fn applyTreeEntry(self: *HardReset, path: []const u8, oid: OID, mode: u32) anyerror!void {
        const cwd = Io.Dir.cwd();

        if (mode == 0o040000) {
            cwd.createDirPath(self.io, path) catch {};
            const tree_data = self.readObject(oid) catch return;
            defer self.allocator.free(tree_data);
            const obj = object_mod.parse(tree_data) catch return;
            if (obj.obj_type == .tree) {
                try self.applyTreeEntries(obj.data, path);
            }
        } else if (mode == 0o100644 or mode == 0o100755) {
            const blob_data = self.readObject(oid) catch return;
            defer self.allocator.free(blob_data);
            const obj = object_mod.parse(blob_data) catch return;
            if (obj.obj_type == .blob) {
                try cwd.writeFile(self.io, .{ .sub_path = path, .data = obj.data });
            }
        }
    }

    fn parseMode(mode_str: []const u8) !u32 {
        var mode: u32 = 0;
        for (mode_str) |c| {
            if (c < '0' or c > '7') return error.InvalidMode;
            mode = (mode << 3) | @as(u32, c - '0');
        }
        return mode;
    }

    fn clearIndex(self: *HardReset) !void {
        self.git_dir.deleteFile(self.io, "index") catch {};
        try self.git_dir.writeFile(self.io, .{ .sub_path = "index", .data = "" });
    }

    fn clearStateFiles(self: *HardReset) !void {
        const state_files = [_][]const u8{
            "MERGE_HEAD",
            "MERGE_MSG",
            "REBASE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
        };
        for (state_files) |path| {
            self.git_dir.deleteFile(self.io, path) catch {};
        }
    }
};

test "HardReset init" {
    const reset = HardReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
