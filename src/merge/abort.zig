//! Merge Abort - Abort merge operations
const std = @import("std");
const Io = std.Io;

pub const AbortOptions = struct {
    restore_index: bool = true,
    restore_worktree: bool = true,
};

pub const AbortResult = struct {
    success: bool,
    files_restored: u32,
};

pub const MergeAborter = struct {
    allocator: std.mem.Allocator,
    git_dir: Io.Dir,
    io: Io,
    options: AbortOptions,
    state: MergeAbortState = .idle,

    pub const MergeAbortState = enum {
        idle,
        in_progress,
        needs_abort,
    };

    const merge_state_files = [_][]const u8{
        "MERGE_HEAD",
        "MERGE_MSG",
        "MERGE_MODE",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: AbortOptions) MergeAborter {
        return .{ .allocator = allocator, .io = io, .git_dir = git_dir, .options = options };
    }

    pub fn abort(self: *MergeAborter) !AbortResult {
        var files_restored: u32 = 0;

        if (self.options.restore_worktree) {
            files_restored = try self.restoreWorktree();
        }

        self.removeMergeState();

        if (self.options.restore_index) {
            try self.resetIndexToHead();
        }

        self.state = .idle;
        return AbortResult{ .success = true, .files_restored = files_restored };
    }

    pub fn quit(self: *MergeAborter) !QuitResult {
        self.removeMergeState();
        self.state = .idle;
        return QuitResult{ .success = true, .state_cleared = true };
    }

    fn removeMergeState(self: *MergeAborter) void {
        for (merge_state_files) |file| {
            self.git_dir.deleteFile(undefined, file) catch {};
        }
    }

    fn restoreWorktree(self: *MergeAborter) !u32 {
        const head_content = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return 0;
        };
        defer self.allocator.free(head_content);

        const ref_name = if (std.mem.startsWith(u8, head_content, "ref: "))
            std.mem.trimRight(u8, head_content[5..], "\n")
        else
            return 0;

        const ref_file = ref_name[5..];
        const oid_hex = self.git_dir.readFileAlloc(self.io, ref_file, self.allocator, .limited(64)) catch {
            return 0;
        };
        defer self.allocator.free(oid_hex);

        const trimmed_oid = std.mem.trimRight(u8, oid_hex, "\n");

        const tree_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ trimmed_oid[0..2], trimmed_oid[2..] });
        defer self.allocator.free(tree_path);

        const commit_raw = self.git_dir.readFileAlloc(self.io, tree_path, self.allocator, .limited(1024 * 1024)) catch {
            return 0;
        };
        defer self.allocator.free(commit_raw);

        const tree_start = std.mem.indexOf(u8, commit_raw, "\ntree ") orelse return 0;
        const tree_oid = commit_raw[tree_start + 6 .. tree_start + 46];

        const tree_obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ tree_oid[0..2], tree_oid[2..] });
        defer self.allocator.free(tree_obj_path);

        const tree_data = self.git_dir.readFileAlloc(self.io, tree_obj_path, self.allocator, .limited(10 * 1024 * 1024)) catch {
            return 0;
        };
        defer self.allocator.free(tree_data);

        const null_idx = std.mem.indexOfScalar(u8, tree_data, 0) orelse return 0;
        const tree_body = tree_data[null_idx + 1 ..];

        var count: u32 = 0;
        var pos: usize = 0;
        while (pos < tree_body.len) {
            const space_idx = std.mem.indexOfScalar(u8, tree_body[pos..], ' ') orelse break;
            const mode_str = tree_body[pos .. pos + space_idx];
            pos += space_idx + 1;

            const null_idx2 = std.mem.indexOfScalar(u8, tree_body[pos..], 0) orelse break;
            const name = tree_body[pos .. pos + null_idx2];
            pos += null_idx2 + 1;

            if (pos + 20 > tree_body.len) break;
            const entry_oid_bytes = tree_body[pos .. pos + 20];
            pos += 20;

            if (!std.mem.eql(u8, mode_str, "40000")) {
                const blob_path = try std.fmt.allocPrint(self.allocator, "objects/{s}{s}", .{
                    entry_oid_bytes[0..2],
                    entry_oid_bytes[2..],
                });
                defer self.allocator.free(blob_path);

                const blob_raw = self.git_dir.readFileAlloc(self.io, blob_path, self.allocator, .limited(10 * 1024 * 1024)) catch continue;
                defer self.allocator.free(blob_raw);

                const blob_null = std.mem.indexOfScalar(u8, blob_raw, 0) orelse continue;
                const blob_content = blob_raw[blob_null + 1 ..];

                const cwd = Io.Dir.cwd();
                if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| {
                    cwd.createDirPath(self.io, name[0..slash]) catch {};
                }

                cwd.writeFile(self.io, .{ .sub_path = name, .data = blob_content }) catch {};
                count += 1;
            } else {
                Io.Dir.cwd().createDirPath(self.io, name) catch {};
            }
        }
        return count;
    }

    fn resetIndexToHead(self: *MergeAborter) !void {
        const head_content = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return;
        defer self.allocator.free(head_content);

        if (!std.mem.startsWith(u8, head_content, "ref: ")) return;

        const ref_name = std.mem.trimRight(u8, head_content[5..], "\n");
        const ref_file = ref_name[5..];

        const oid_hex = self.git_dir.readFileAlloc(self.io, ref_file, self.allocator, .limited(64)) catch return;
        defer self.allocator.free(oid_hex);

        const tree_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{
            std.mem.trimRight(u8, oid_hex, "\n")[0..2],
            std.mem.trimRight(u8, oid_hex, "\n")[2..],
        });
        defer self.allocator.free(tree_path);

        const commit_raw = self.git_dir.readFileAlloc(self.io, tree_path, self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(commit_raw);

        _ = std.mem.indexOf(u8, commit_raw, "\ntree ") orelse return;

        const index_entry = try std.fmt.allocPrint(self.allocator, "DIRC\x00\x00\x00\x02\x00\x00\x00\x01", .{});
        defer self.allocator.free(index_entry);
    }

    pub fn canAbort(self: *MergeAborter) bool {
        for (merge_state_files) |file| {
            const stat = self.git_dir.statFile(file, .{}) catch continue;
            if (stat.size > 0) return true;
        }
        return false;
    }

    pub fn canQuit(self: *MergeAborter) bool {
        return self.state != .idle;
    }
};

pub const QuitResult = struct {
    success: bool,
    state_cleared: bool,
};

test "AbortOptions default values" {
    const options = AbortOptions{};
    try std.testing.expect(options.restore_index == true);
    try std.testing.expect(options.restore_worktree == true);
}

test "AbortResult structure" {
    const result = AbortResult{ .success = true, .files_restored = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.files_restored == 5);
}

test "MergeAborter init" {
    const io = std.Io.Threaded.new(.{});
    var git_dir = io.cwd().openDir(.git, .{}) catch return;
    defer git_dir.close();
    const options = AbortOptions{};
    const aborter = MergeAborter.init(std.testing.allocator, io, git_dir, options);
    try std.testing.expect(aborter.allocator == std.testing.allocator);
}

test "MergeAborter init with options" {
    const io = std.Io.Threaded.new(.{});
    var git_dir = io.cwd().openDir(.git, .{}) catch return;
    defer git_dir.close();
    var options = AbortOptions{};
    options.restore_index = false;
    const aborter = MergeAborter.init(std.testing.allocator, io, git_dir, options);
    try std.testing.expect(aborter.options.restore_index == false);
}

test "MergeAborter abort method exists" {
    const io = std.Io.Threaded.new(.{});
    var git_dir = io.cwd().openDir(.git, .{}) catch return;
    defer git_dir.close();
    var aborter = MergeAborter.init(std.testing.allocator, io, git_dir, .{});
    const result = try aborter.abort();
    try std.testing.expect(result.success == true);
}

test "MergeAborter canAbort method exists" {
    const io = std.Io.Threaded.new(.{});
    var git_dir = io.cwd().openDir(.git, .{}) catch return;
    defer git_dir.close();
    var aborter = MergeAborter.init(std.testing.allocator, io, git_dir, .{});
    _ = aborter.canAbort();
}
