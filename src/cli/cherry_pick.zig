//! Git Cherry-Pick - Apply the changes introduced by some existing commits
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");
const OID = oid_mod.OID;
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");

pub const CherryPickOptions = struct {
    no_commit: bool = false,
    edit: bool = false,
    reference_original: bool = false,
    mainline: ?u32 = null,
};

pub const CherryPick = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    git_dir: Io.Dir,
    options: CherryPickOptions,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: *Io, git_dir: Io.Dir, writer: *std.Io.Writer, style: OutputStyle) CherryPick {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = .{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *CherryPick, commits: []const []const u8) !void {
        if (commits.len == 0) {
            try self.output.errorMessage("No commits specified to cherry-pick", .{});
            return;
        }

        for (commits, 0..) |commit_str, i| {
            const commit_oid = try self.resolveCommitOid(commit_str);

            const commit_data = self.readObject(commit_oid) catch {
                try self.output.errorMessage("Could not read commit {s}", .{commit_str});
                return;
            };
            defer self.allocator.free(commit_data);

            const obj = object_mod.parse(commit_data) catch {
                try self.output.errorMessage("Invalid commit object {s}", .{commit_str});
                return;
            };

            if (obj.obj_type != .commit) {
                try self.output.errorMessage("{s} is not a commit", .{commit_str});
                return;
            }

            const parent_oid = try extractParent(obj.data);
            if (!parent_oid.isZero()) {
                const parent_data = self.readObject(parent_oid) catch {
                    try self.output.errorMessage("Could not read parent commit", .{});
                    return;
                };
                defer self.allocator.free(parent_data);

                const parent_obj = object_mod.parse(parent_data) catch continue;

                const parent_tree = self.extractTreeHex(parent_obj.data) catch "";
                defer if (parent_tree.len > 0) self.allocator.free(parent_tree);

                const our_tree = self.extractTreeHex(obj.data) catch "";
                defer if (our_tree.len > 0) self.allocator.free(our_tree);

                if (parent_tree.len > 0 and our_tree.len > 0) {
                    try self.applyTreeDiff(parent_tree, our_tree);
                }
            } else {
                const tree_hex = self.extractTreeHex(obj.data) catch "";
                defer if (tree_hex.len > 0) self.allocator.free(tree_hex);
                if (tree_hex.len > 0) {
                    try self.applyTreeToWorkdir(tree_hex);
                }
            }

            try self.writeCherryPickHead(commit_oid);

            if (!self.options.no_commit) {
                try self.output.infoMessage("Cherry-picked {s} ({d}/{d})", .{ commit_str, i + 1, commits.len });
            }
        }

        try self.output.successMessage("Successfully cherry-picked {d} commit(s)", .{commits.len});
    }

    fn resolveCommitOid(self: *CherryPick, spec: []const u8) !OID {
        if (spec.len >= 40) {
            return OID.fromHex(spec[0..40]) catch OID{ .bytes = .{0} ** 20 };
        }

        if (std.mem.startsWith(u8, spec, "refs/")) {
            const ref_content = self.git_dir.readFileAlloc(self.io.*, spec, self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(ref_content);
            const trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
            }
        }

        if (std.mem.eql(u8, spec, "HEAD")) {
            const head_data = self.git_dir.readFileAlloc(self.io.*, "HEAD", self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(head_data);
            const trimmed = std.mem.trim(u8, head_data, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                const ref_content = self.git_dir.readFileAlloc(self.io.*, ref_path, self.allocator, .limited(256)) catch {
                    return OID{ .bytes = .{0} ** 20 };
                };
                defer self.allocator.free(ref_content);
                const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
                if (ref_trimmed.len >= 40) {
                    return OID.fromHex(ref_trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
                }
            }
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
            }
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn extractParent(data: []const u8) !OID {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                if (hex.len >= 40) {
                    return OID.fromHex(hex[0..40]) catch OID{ .bytes = .{0} ** 20 };
                }
            }
            if (line.len == 0) break;
        }
        return OID{ .bytes = .{0} ** 20 };
    }

    fn extractTreeHex(self: *CherryPick, data: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const hex = line[5..];
                if (hex.len >= 40) {
                    return try self.allocator.dupe(u8, hex[0..40]);
                }
            }
            if (line.len == 0) break;
        }
        return "";
    }

    fn applyTreeDiff(self: *CherryPick, parent_tree_hex: []const u8, our_tree_hex: []const u8) !void {
        _ = parent_tree_hex;
        const tree_oid = try OID.fromHex(our_tree_hex);
        try self.applyTreeToWorkdirRaw(tree_oid);
    }

    fn applyTreeToWorkdir(self: *CherryPick, tree_hex: []const u8) !void {
        const tree_oid = try OID.fromHex(tree_hex);
        try self.applyTreeToWorkdirRaw(tree_oid);
    }

    fn applyTreeToWorkdirRaw(self: *CherryPick, tree_oid: OID) !void {
        if (tree_oid.isZero()) return;

        const tree_data = self.readObject(tree_oid) catch return;
        defer self.allocator.free(tree_data);

        const obj = object_mod.parse(tree_data) catch return;
        if (obj.obj_type != .tree) return;

        try self.applyTreeEntries(obj.data, "");
    }

    fn applyTreeEntries(self: *CherryPick, tree_data: []const u8, base_path: []const u8) anyerror!void {
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
            const mode = parseModeU32(mode_str) catch continue;

            const full_path = if (base_path.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name })
            else
                try self.allocator.dupe(u8, name);
            defer self.allocator.free(full_path);

            try self.applyEntry(full_path, entry_oid, mode);
        }
    }

    fn applyEntry(self: *CherryPick, path: []const u8, oid: OID, mode: u32) anyerror!void {
        const cwd = Io.Dir.cwd();

        if (mode == 0o040000) {
            cwd.createDirPath(self.io.*, path) catch {};
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
                try cwd.writeFile(self.io.*, .{ .sub_path = path, .data = obj.data });
            }
        }
    }

    fn writeCherryPickHead(self: *CherryPick, commit_oid: OID) !void {
        const hex = commit_oid.toHex();
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
        defer self.allocator.free(content);
        try self.git_dir.writeFile(self.io.*, .{ .sub_path = "CHERRY_PICK_HEAD", .data = content });
    }

    fn readObject(self: *CherryPick, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const object_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(object_path);

        const compressed = try self.git_dir.readFileAlloc(self.io.*, object_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }
};

fn parseModeU32(mode_str: []const u8) !u32 {
    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') return error.InvalidMode;
        mode = (mode << 3) | @as(u32, c - '0');
    }
    return mode;
}

test "CherryPick init" {
    const cp = CherryPick.init(std.testing.allocator, undefined, undefined, undefined, .{});
    try std.testing.expect(cp.options.no_commit == false);
}
