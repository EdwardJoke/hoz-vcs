//! Stash Apply - Apply stash changes
const std = @import("std");
const Io = std.Io;
const stash_list = @import("list.zig");
const StashLister = stash_list.StashLister;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const ApplyOptions = struct {
    index: u32 = 0,
    restore_index: bool = false,
    force: bool = false,
};

pub const ApplyResult = struct {
    success: bool,
    conflict: bool,
    stash_retained: bool,
    message: ?[]const u8 = null,
};

pub const ApplyError = error{
    InvalidMode,
    OutOfMemory,
    IoError,
    InvalidObject,
    NotATree,
};

pub const StashApplier = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: ApplyOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: ApplyOptions) StashApplier {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn apply(self: *StashApplier) !ApplyResult {
        return try self.applyIndex(self.options.index);
    }

    pub fn applyIndex(self: *StashApplier, index: u32) !ApplyResult {
        var lister = StashLister.init(self.allocator, self.io, self.git_dir);
        const entries = try lister.list();
        defer self.allocator.free(entries);

        var target_entry: ?StashEntry = null;
        for (entries) |entry| {
            if (entry.index == index) {
                target_entry = entry;
                break;
            }
        }

        if (target_entry == null) {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        const entry = target_entry.?;
        const object_data = self.readObject(entry.oid) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = true,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} object is missing", .{index}),
            };
        };
        defer self.allocator.free(object_data);

        const obj = object_mod.parse(object_data) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = true,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} object is corrupt", .{index}),
            };
        };

        if (obj.obj_type != .commit) {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = true,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} is not a commit", .{index}),
            };
        }

        const tree_oid = self.parseTreeFromCommit(obj.data) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .stash_retained = true,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} has no tree", .{index}),
            };
        };

        const apply_result = self.applyTree(tree_oid) catch |err| {
            return ApplyResult{
                .success = false,
                .conflict = true,
                .stash_retained = true,
                .message = try std.fmt.allocPrint(self.allocator, "Failed to apply stash@{d}: {}", .{ index, err }),
            };
        };

        if (self.options.restore_index) {
            try self.restoreIndex();
        }

        return ApplyResult{
            .success = apply_result,
            .conflict = false,
            .stash_retained = true,
            .message = try std.fmt.allocPrint(self.allocator, "Applied stash@{d}", .{index}),
        };
    }

    fn readObject(self: *StashApplier, oid: OID) ![]u8 {
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

    fn parseTreeFromCommit(_: *StashApplier, commit_data: []const u8) !OID {
        var lines = std.mem.splitScalar(u8, commit_data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hex = line[5..];
                if (tree_hex.len >= 40) {
                    return OID.fromHex(tree_hex[0..40]) catch error.InvalidTreeOid;
                }
            }
            if (line.len == 0) break;
        }
        return error.NoTreeInCommit;
    }

    fn applyTree(self: *StashApplier, tree_oid: OID) anyerror!bool {
        const tree_data = try self.readObject(tree_oid);
        defer self.allocator.free(tree_data);

        const obj = try object_mod.parse(tree_data);
        if (obj.obj_type != .tree) {
            return error.NotATree;
        }

        try self.applyTreeEntries(obj.data);

        return true;
    }

    fn applyTreeEntries(self: *StashApplier, tree_data: []const u8) anyerror!void {
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
            const mode = try parseMode(mode_str);

            self.applyTreeEntry(name, entry_oid, mode) catch {};
        }
    }

    fn applyTreeEntry(self: *StashApplier, name: []const u8, oid: OID, mode: u32) anyerror!void {
        const cwd = Io.Dir.cwd();

        if (mode == 0o040000) {
            cwd.createDirPath(self.io, name) catch {};
            const subtree_data = self.readObject(oid) catch return;
            defer self.allocator.free(subtree_data);
            const obj = object_mod.parse(subtree_data) catch return;
            if (obj.obj_type == .tree) {
                const old_cwd = cwd;
                const subdir = cwd.openDir(self.io, name, .{}) catch return;
                defer subdir.close(self.io);
                self.git_dir = subdir;
                try self.applyTreeEntries(obj.data);
                self.git_dir = old_cwd;
            }
        } else if (mode == 0o100644 or mode == 0o100755) {
            const blob_data = self.readObject(oid) catch return;
            defer self.allocator.free(blob_data);
            const obj = object_mod.parse(blob_data) catch return;
            if (obj.obj_type == .blob) {
                try cwd.writeFile(self.io, .{ .sub_path = name, .data = obj.data });
            }
        }
    }

    fn parseMode(mode_str: []const u8) anyerror!u32 {
        var mode: u32 = 0;
        for (mode_str) |c| {
            if (c < '0' or c > '7') return error.InvalidMode;
            mode = (mode << 3) | @as(u32, c - '0');
        }
        return mode;
    }

    fn restoreIndex(self: *StashApplier) !void {
        const stash_index_path = "stash_index_backup";
        const backup = self.git_dir.readFileAlloc(self.io, stash_index_path, self.allocator, .limited(16 * 1024 * 1024)) catch null;
        defer if (backup) |buf| self.allocator.free(buf);
        if (backup) |buf| {
            try self.git_dir.writeFile(self.io, .{ .sub_path = "index", .data = buf });
        }
    }
};

const StashEntry = stash_list.StashEntry;

test "ApplyOptions default values" {
    const options = ApplyOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.restore_index == false);
    try std.testing.expect(options.force == false);
}

test "ApplyResult structure" {
    const result = ApplyResult{ .success = true, .conflict = false, .stash_retained = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.conflict == false);
    try std.testing.expect(result.stash_retained == true);
}
