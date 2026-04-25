//! Stash Pop - Apply and drop stash
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");
const stash_list = @import("list.zig");
const StashLister = stash_list.StashLister;

pub const PopOptions = struct {
    index: u32 = 0,
    force: bool = false,
};

pub const PopResult = struct {
    success: bool,
    conflict: bool,
    stash_dropped: bool,
    message: ?[]const u8 = null,
};

pub const StashPopper = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: PopOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: PopOptions) StashPopper {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn pop(self: *StashPopper) !PopResult {
        return try self.popIndex(self.options.index);
    }

    pub fn popIndex(self: *StashPopper, index: u32) !PopResult {
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
            return PopResult{
                .success = false,
                .conflict = false,
                .stash_dropped = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        const apply_result = try self.applyStash(target_entry.?);

        if (apply_result.success) {
            try self.dropStashIndex(index);
            return PopResult{
                .success = true,
                .conflict = apply_result.conflict,
                .stash_dropped = true,
                .message = try std.fmt.allocPrint(self.allocator, "Dropped stash@{d}", .{index}),
            };
        }

        return PopResult{
            .success = false,
            .conflict = apply_result.conflict,
            .stash_dropped = false,
            .message = apply_result.message,
        };
    }

    fn applyStash(self: *StashPopper, entry: StashEntry) !ApplyResult {
        const hex = entry.oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash object missing: {s}", .{obj_path}),
            };
        };
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash object corrupt: {s}", .{obj_path}),
            };
        };
        defer self.allocator.free(decompressed);

        const obj = object_mod.parse(decompressed) catch {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash object parse failed", .{}),
            };
        };

        if (obj.obj_type != .commit) {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} is not a commit", .{entry.index}),
            };
        }

        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        var tree_oid: ?OID = null;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hex = line[5..];
                if (tree_hex.len >= 40) {
                    tree_oid = OID.fromHex(tree_hex[0..40]) catch null;
                }
            }
            if (line.len == 0) break;
        }

        const target_oid = tree_oid orelse {
            return ApplyResult{
                .success = false,
                .conflict = false,
                .message = try std.fmt.allocPrint(self.allocator, "stash commit has no tree", .{}),
            };
        };

        self.applyTreeToWorkdir(target_oid) catch {
            return ApplyResult{
                .success = false,
                .conflict = true,
                .message = try std.fmt.allocPrint(self.allocator, "conflicts applying stash@{d}", .{entry.index}),
            };
        };

        return ApplyResult{
            .success = true,
            .conflict = false,
            .message = null,
        };
    }

    fn applyTreeToWorkdir(self: *StashPopper, tree_oid: OID) anyerror!void {
        const hex = tree_oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return;
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch return;
        defer self.allocator.free(decompressed);

        const obj = object_mod.parse(decompressed) catch return;
        if (obj.obj_type != .tree) return;

        const cwd = Io.Dir.cwd();
        try self.applyTreeEntries(cwd, obj.data, "");
    }

    fn applyTreeEntries(self: *StashPopper, cwd: Io.Dir, tree_data: []const u8, base_path: []const u8) anyerror!void {
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
            var mode: u32 = 0;
            for (mode_str) |c| {
                if (c < '0' or c > '7') break;
                mode = (mode << 3) | @as(u32, c - '0');
            }

            const full_path = if (base_path.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name })
            else
                try self.allocator.dupe(u8, name);
            defer self.allocator.free(full_path);

            if (mode == 0o040000) {
                cwd.createDirPath(self.io, full_path) catch {};
                self.applyTreeToSubdir(entry_oid, cwd, full_path) catch {};
            } else if (mode == 0o100644 or mode == 0o100755) {
                self.writeBlobToFile(entry_oid, full_path) catch {};
            }
        }
    }

    fn applyTreeToSubdir(self: *StashPopper, tree_oid: OID, parent_cwd: Io.Dir, sub_path: []const u8) anyerror!void {
        const hex = tree_oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return;
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch return;
        defer self.allocator.free(decompressed);

        const obj = object_mod.parse(decompressed) catch return;
        if (obj.obj_type != .tree) return;

        const subdir = parent_cwd.openDir(self.io, sub_path, .{}) catch return;
        defer subdir.close(self.io);
        try self.applyTreeEntries(subdir, obj.data, "");
    }

    fn writeBlobToFile(self: *StashPopper, blob_oid: OID, path: []const u8) anyerror!void {
        const hex = blob_oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return;
        defer self.allocator.free(compressed);

        const decompressed = compress_mod.Zlib.decompress(compressed, self.allocator) catch return;
        defer self.allocator.free(decompressed);

        const obj = object_mod.parse(decompressed) catch return;
        if (obj.obj_type != .blob) return;

        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = obj.data });
    }

    fn dropStashIndex(self: *StashPopper, index: u32) !void {
        const reflog_path = "logs/refs/stash";
        const content = self.git_dir.readFileAlloc(self.io, reflog_path, self.allocator, .limited(1024 * 1024)) catch {
            return;
        };
        defer self.allocator.free(content);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var logical_index: u32 = 0;
        var kept_lines: usize = 0;
        var latest_oid: ?OID = null;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (logical_index == index) {
                logical_index += 1;
                continue;
            }

            try out.appendSlice(self.allocator, line);
            try out.append(self.allocator, '\n');
            kept_lines += 1;
            latest_oid = parseNewOidFromReflogLine(line);
            logical_index += 1;
        }

        if (kept_lines == 0) {
            self.git_dir.deleteFile(self.io, reflog_path) catch {};
            self.git_dir.deleteFile(self.io, "refs/stash") catch {};
            return;
        }

        try self.git_dir.writeFile(self.io, .{ .sub_path = reflog_path, .data = out.items });
        if (latest_oid) |oid| {
            const hex = oid.toHex();
            const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
            defer self.allocator.free(ref_content);
            try self.git_dir.writeFile(self.io, .{ .sub_path = "refs/stash", .data = ref_content });
        }
    }
};

const StashEntry = stash_list.StashEntry;

const ApplyResult = struct {
    success: bool,
    conflict: bool,
    message: ?[]const u8,
};

fn parseNewOidFromReflogLine(line: []const u8) ?OID {
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next() orelse return null;
    const new_oid = parts.next() orelse return null;
    if (new_oid.len < 40) return null;
    return OID.fromHex(new_oid[0..40]) catch null;
}

test "PopOptions default values" {
    const options = PopOptions{};
    try std.testing.expect(options.index == 0);
    try std.testing.expect(options.force == false);
}

test "PopResult structure" {
    const result = PopResult{ .success = true, .conflict = false, .stash_dropped = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.conflict == false);
    try std.testing.expect(result.stash_dropped == true);
}
