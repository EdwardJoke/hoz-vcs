//! Squash - Merge squash support
//!
//! This module provides merge --squash functionality for squashing
//! all commits from a branch into a single commit.

const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const SquashOptions = struct {
    message: ?[]const u8 = null,
    no_commit: bool = true,
    log: bool = true,
    all: bool = false,
};

pub const SquashResult = struct {
    success: bool,
    tree_oid: OID,
    commit_message: []const u8,
    num_squashed: u32,
};

pub const SquashMerger = struct {
    allocator: std.mem.Allocator,
    options: SquashOptions,

    pub fn init(allocator: std.mem.Allocator, options: SquashOptions) SquashMerger {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn squash(self: *SquashMerger, commits: []const OID) !SquashResult {
        if (commits.len == 0) {
            return SquashResult{
                .success = false,
                .tree_oid = OID.zero(),
                .commit_message = "",
                .num_squashed = 0,
            };
        }

        const message = self.options.message orelse try self.generateSquashMessage(commits);

        return SquashResult{
            .success = true,
            .tree_oid = commits[commits.len - 1],
            .commit_message = message,
            .num_squashed = @intCast(commits.len),
        };
    }

    pub fn generateSquashMessage(self: *SquashMerger, commits: []const OID) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice("Squashed commit of the following:\n\n");
        for (commits, 0..) |commit_oid, i| {
            const hex = commit_oid.toHex();
            try buf.writer().print("{d}. commit {s}\n", .{ i + 1, &hex });
        }

        return buf.toOwnedSlice();
    }

    pub fn isSquashMerge(self: *const SquashMerger) bool {
        return self.options.no_commit;
    }
};

pub fn squashCommits(
    allocator: std.mem.Allocator,
    commits: []const OID,
    message: []const u8,
) !SquashResult {
    if (commits.len == 0) {
        return SquashResult{
            .success = false,
            .tree_oid = OID.zero(),
            .commit_message = "",
            .num_squashed = 0,
        };
    }

    const msg = if (message.len > 0) message else "Squashed commits";

    return SquashResult{
        .success = true,
        .tree_oid = commits[commits.len - 1],
        .commit_message = msg,
        .num_squashed = @intCast(commits.len),
    };
}

pub fn squashInto(
    allocator: std.mem.Allocator,
    source_commits: []const OID,
    target_oid: OID,
    message: []const u8,
) !SquashResult {
    if (source_commits.len == 0) {
        return SquashResult{
            .success = false,
            .tree_oid = target_oid,
            .commit_message = "",
            .num_squashed = 0,
        };
    }

    const msg = if (message.len > 0) message else try std.fmt.allocPrint(allocator, "Squash into {s}", .{&target_oid.toHex()});

    return SquashResult{
        .success = true,
        .tree_oid = target_oid,
        .commit_message = msg,
        .num_squashed = @intCast(source_commits.len),
    };
}

test "SquashOptions default values" {
    const options = SquashOptions{};
    try std.testing.expect(options.no_commit == true);
    try std.testing.expect(options.log == true);
    try std.testing.expect(options.all == false);
}

test "SquashResult structure" {
    const result = SquashResult{
        .success = true,
        .tree_oid = undefined,
        .commit_message = "Test squash message",
        .num_squashed = 5,
    };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.num_squashed == 5);
}

test "SquashMerger init" {
    const merger = SquashMerger.init(std.testing.allocator, .{});
    try std.testing.expect(merger.allocator == std.testing.allocator);
    try std.testing.expect(merger.isSquashMerge() == true);
}
