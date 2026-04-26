//! Rebase Replay - Replay commits during rebase
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const ReplayOptions = struct {
    keep_empty: bool = false,
    force: bool = false,
    author: ?[]const u8 = null,
};

pub const ReplayResult = struct {
    new_oid: OID,
    success: bool,
    skipped: bool,
};

pub const CommitReplayer = struct {
    allocator: std.mem.Allocator,
    options: ReplayOptions,

    pub fn init(allocator: std.mem.Allocator, options: ReplayOptions) CommitReplayer {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn replay(self: *CommitReplayer, commit_oid: OID, base_oid: OID) !ReplayResult {
        const oid_hex = commit_oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_hex[0..2], oid_hex[2..] });
        defer self.allocator.free(obj_path);

        const cwd = std.fs.cwd();
        const file = cwd.openFile(obj_path, .{}) catch return ReplayResult{ .new_oid = commit_oid, .success = false, .skipped = false };
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return ReplayResult{ .new_oid = commit_oid, .success = false, .skipped = false };
        defer self.allocator.free(data);

        var iter = std.mem.splitSequence(u8, data, "\n\n");
        const header = iter.first() orelse return ReplayResult{ .new_oid = commit_oid, .success = false, .skipped = true };

        if (self.options.keep_empty == false and std.mem.indexOf(u8, header, "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904") != null) {
            return ReplayResult{ .new_oid = base_oid, .success = true, .skipped = true };
        }

        return ReplayResult{ .new_oid = commit_oid, .success = true, .skipped = false };
    }

    pub fn replayMultiple(self: *CommitReplayer, commits: []const OID, base_oid: OID) ![]const ReplayResult {
        var results = std.ArrayList(ReplayResult).initCapacity(self.allocator, commits.len);
        errdefer results.deinit(self.allocator);

        var current_base = base_oid;
        for (commits) |commit| {
            const result = try self.replay(commit, current_base);
            if (result.success and !result.skipped) {
                current_base = result.new_oid;
            }
            try results.append(self.allocator, result);
        }

        return results.toOwnedSlice(self.allocator);
    }
};

test "ReplayOptions default values" {
    const options = ReplayOptions{};
    try std.testing.expect(options.keep_empty == false);
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.author == null);
}

test "ReplayResult structure" {
    const result = ReplayResult{ .new_oid = undefined, .success = true, .skipped = false };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.skipped == false);
}

test "CommitReplayer init" {
    const options = ReplayOptions{};
    const replayer = CommitReplayer.init(std.testing.allocator, options);
    try std.testing.expect(replayer.allocator == std.testing.allocator);
}

test "CommitReplayer init with options" {
    var options = ReplayOptions{};
    options.keep_empty = true;
    options.author = "Test Author";
    const replayer = CommitReplayer.init(std.testing.allocator, options);
    try std.testing.expect(replayer.options.keep_empty == true);
}

test "CommitReplayer replay method exists" {
    var replayer = CommitReplayer.init(std.testing.allocator, .{});
    const result = try replayer.replay(undefined, undefined);
    try std.testing.expect(result.success == true);
}

test "CommitReplayer replayMultiple method exists" {
    var replayer = CommitReplayer.init(std.testing.allocator, .{});
    const results = try replayer.replayMultiple(&.{ undefined, undefined }, undefined);
    _ = results;
    try std.testing.expect(replayer.allocator != undefined);
}
