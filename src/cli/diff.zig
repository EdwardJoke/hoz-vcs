//! Git Diff - Show changes between commits, index, and working tree
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const StatusIcon = @import("output.zig").StatusIcon;
const OID = @import("../object/oid.zig").OID;
const TreeDiff = @import("../tree/diff.zig").TreeDiff;
const TreeChange = @import("../tree/diff.zig").TreeChange;
const ChangeType = @import("../tree/diff.zig").ChangeType;
const tree_mod = @import("../object/tree.zig");
const commit_obj = @import("../object/commit.zig").Commit;
const RefStore = @import("../ref/store.zig").RefStore;
const compress_mod = @import("../compress/zlib.zig");

pub const Diff = struct {
    allocator: std.mem.Allocator,
    io: Io,
    staged: bool,
    cached: bool,
    no_color: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Diff {
        return .{
            .allocator = allocator,
            .io = io,
            .staged = false,
            .cached = false,
            .no_color = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Diff, args: []const []const u8) !void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "-s")) {
                self.staged = true;
                self.cached = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                self.no_color = true;
            }
        }

        try self.output.section("Diff");

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var ref_store = RefStore.init(git_dir, self.allocator, self.io);

        if (self.staged or self.cached) {
            try self.printStagedDiff(&ref_store);
        } else {
            try self.printWorkingDiff(&ref_store);
        }
    }

    fn readHeadTreeOid(self: *Diff, ref_store: *RefStore) !?OID {
        const head_ref = ref_store.resolve("HEAD") catch return null;
        if (head_ref.isSymbolic()) return null;

        const commit_data = self.readCommitObject(ref_store.git_dir, head_ref.target.direct) catch return null;
        defer self.allocator.free(commit_data);
        const commit = commit_obj.parse(self.allocator, commit_data) catch return null;
        defer self.allocator.free(commit.parents);
        if (commit.message.len > 0) _ = commit.message;
        return commit.tree;
    }

    fn readCommitObject(self: *Diff, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn parseTreeData(self: *Diff, data: []const u8) !tree_mod.Tree {
        var entries = try std.ArrayList(tree_mod.TreeEntry).initCapacity(self.allocator, 16);
        defer entries.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < data.len) {
            const space_idx = std.mem.indexOfScalarPos(u8, data, offset, ' ') orelse break;
            const mode_str = data[offset..space_idx];
            const name_start = space_idx + 1;
            const null_idx = std.mem.indexOfScalarPos(u8, data, name_start, 0) orelse break;
            const name = data[name_start..null_idx];
            const oid_start = null_idx + 1;
            if (oid_start + 20 > data.len) break;
            const oid_bytes = data[oid_start .. oid_start + 20];

            const mode = tree_mod.modeFromStr(mode_str) catch .file;
            const entry_oid = OID.fromBytes(oid_bytes);
            const name_owned = try self.allocator.dupe(u8, name);
            try entries.append(self.allocator, tree_mod.TreeEntry{
                .mode = mode,
                .oid = entry_oid,
                .name = name_owned,
            });
            offset = oid_start + 20;
        }

        const slice = try entries.toOwnedSlice(self.allocator);
        return tree_mod.Tree.create(slice);
    }

    fn readTreeObject(self: *Diff, git_dir: Io.Dir, oid: OID) !?tree_mod.Tree {
        const data = self.readCommitObject(git_dir, oid) catch return null;
        defer self.allocator.free(data);
        return try self.parseTreeData(data);
    }

    fn printStagedDiff(self: *Diff, ref_store: *RefStore) !void {
        const head_tree_oid = self.readHeadTreeOid(ref_store) catch {
            try self.output.infoMessage("No commits yet (empty repository)", .{});
            return;
        };

        if (head_tree_oid == null) {
            try self.output.infoMessage("No commits yet — all changes are staged", .{});
            return;
        }

        var differ = TreeDiff.init(self.allocator);
        defer differ.deinit();

        const head_tree = self.readTreeObject(ref_store.git_dir, head_tree_oid.?) catch {
            try self.output.errorMessage("Failed to read HEAD tree", .{});
            return;
        };

        differ.compute(head_tree, null) catch |err| {
            try self.output.errorMessage("Failed to compute diff: {}", .{err});
            return;
        };

        const changes = differ.getChanges();
        if (changes.len == 0) {
            try self.output.infoMessage("No staged changes", .{});
            return;
        }

        for (changes) |change| {
            const path = change.new_path orelse change.old_path orelse "(unknown)";
            const icon: StatusIcon = switch (change.change_type) {
                .added => .added,
                .deleted => .deleted,
                .modified => .modified,
                .renamed => .renamed,
                else => .modified,
            };

            const file_label = try std.fmt.allocPrint(self.allocator, "File: {s}", .{path});
            defer self.allocator.free(file_label);
            try self.output.groupHeader(file_label, null);
            try self.output.statusItem(icon, true, path);

            switch (change.change_type) {
                .added => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("new file mode 100644\n", .{});
                    try self.output.writer.print("--- /dev/null\n", .{});
                    try self.output.writer.print("+++ b/{s}\n", .{path});
                },
                .deleted => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("--- a/{s}\n", .{path});
                    try self.output.writer.print("+++ /dev/null\n", .{});
                },
                .modified => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("--- a/{s}\n", .{path});
                    try self.output.writer.print("+++ b/{s}\n", .{path});
                },
                else => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                },
            }
            if (changes.len > 1) try self.output.sectionDivider();
        }
    }

    fn printWorkingDiff(self: *Diff, ref_store: *RefStore) !void {
        const head_tree_oid = self.readHeadTreeOid(ref_store) catch {
            try self.output.infoMessage("No commits yet (empty repository)", .{});
            return;
        };

        if (head_tree_oid == null) {
            try self.output.infoMessage("No commits yet — show untracked files as new", .{});
            return;
        }

        var differ = TreeDiff.init(self.allocator);
        defer differ.deinit();

        const head_tree = self.readTreeObject(ref_store.git_dir, head_tree_oid.?) catch {
            try self.output.errorMessage("Failed to read HEAD tree", .{});
            return;
        };

        differ.compute(head_tree, null) catch |err| {
            try self.output.errorMessage("Failed to compute diff: {}", .{err});
            return;
        };

        const changes = differ.getChanges();
        if (changes.len == 0) {
            try self.output.infoMessage("No working directory changes", .{});
            return;
        }

        for (changes) |change| {
            const path = change.new_path orelse change.old_path orelse "(unknown)";
            const icon: StatusIcon = switch (change.change_type) {
                .added => .added,
                .deleted => .deleted,
                .modified => .modified,
                .renamed => .renamed,
                else => .modified,
            };

            const file_label = try std.fmt.allocPrint(self.allocator, "File: {s}", .{path});
            defer self.allocator.free(file_label);
            try self.output.groupHeader(file_label, null);
            try self.output.statusItem(icon, false, path);

            switch (change.change_type) {
                .added => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("index 0000000..{s}\n", .{OID.zero().toHex()});
                    try self.output.writer.print("--- /dev/null\n", .{});
                    try self.output.writer.print("+++ b/{s}\n", .{path});
                },
                .deleted => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("index {s}..0000000\n", .{OID.zero().toHex()});
                    try self.output.writer.print("--- a/{s}\n", .{path});
                    try self.output.writer.print("+++ /dev/null\n", .{});
                },
                .modified => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                    try self.output.writer.print("--- a/{s}\n", .{path});
                    try self.output.writer.print("+++ b/{s}\n", .{path});
                },
                else => {
                    try self.output.writer.print("diff --git a/{s} b/{s}\n", .{ path, path });
                },
            }
            if (changes.len > 1) try self.output.sectionDivider();
        }
    }
};

test "Diff init" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const diff = Diff.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(diff.staged == false);
}

test "Diff has io field" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const diff = Diff.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(diff.io == io);
}
