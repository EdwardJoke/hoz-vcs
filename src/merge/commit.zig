//! Merge Commit - Create merge commits
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const sha1 = @import("../crypto/sha1.zig");
const object_mod = @import("../object/object.zig");

pub const MergeCommitOptions = struct {
    message: ?[]const u8 = null,
    no_ff: bool = false,
    ff: bool = false,
    log: bool = true,
    no_commit: bool = false,
};

pub const MergeCommitResult = struct {
    commit_oid: OID,
    is_merge_commit: bool,
};

pub const MergeCommitBuilder = struct {
    allocator: std.mem.Allocator,
    options: MergeCommitOptions,

    pub fn init(allocator: std.mem.Allocator, options: MergeCommitOptions) MergeCommitBuilder {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn createCommit(self: *MergeCommitBuilder, ours: OID, theirs: OID, tree_oid: OID) !MergeCommitResult {
        const message = self.options.message orelse "Merge branch";

        var parent_oids = std.ArrayList(u8).init(self.allocator);
        defer parent_oids.deinit(self.allocator);

        const ours_hex = ours.toHex();
        try parent_oids.appendSlice("parent ");
        try parent_oids.appendSlice(&ours_hex);
        try parent_oids.append('\n');

        const theirs_hex = theirs.toHex();
        try parent_oids.appendSlice("parent ");
        try parent_oids.appendSlice(&theirs_hex);
        try parent_oids.append('\n');

        const tree_hex = tree_oid.toHex();
        const timestamp = std.time.timestamp();

        const commit_content = try std.fmt.allocPrint(self.allocator,
            "tree {s}\n{s}author Hoz User <hoz@example.com> {d} +0000\ncommitter Hoz User <hoz@example.com> {d} +0000\n\n{s}\n",
            .{ &tree_hex, parent_oids.items, timestamp, timestamp, message }
        );
        defer self.allocator.free(commit_content);

        const hash_bytes = sha1.sha1(commit_content);
        const commit_oid = oidFromBytes(&hash_bytes);

        return MergeCommitResult{ .commit_oid = commit_oid, .is_merge_commit = true };
    }

    pub fn createFastForward(self: *MergeCommitBuilder, from: OID, to: OID) !OID {
        _ = self;
        if (from.eql(to)) {
            return to;
        }
        return to;
    }
};

test "MergeCommitOptions default values" {
    const options = MergeCommitOptions{};
    try std.testing.expect(options.message == null);
    try std.testing.expect(options.no_ff == false);
    try std.testing.expect(options.ff == false);
    try std.testing.expect(options.log == true);
}

test "MergeCommitResult structure" {
    const result = MergeCommitResult{ .commit_oid = undefined, .is_merge_commit = true };
    try std.testing.expect(result.is_merge_commit == true);
}

test "MergeCommitBuilder init" {
    const options = MergeCommitOptions{};
    const builder = MergeCommitBuilder.init(std.testing.allocator, options);
    try std.testing.expect(builder.allocator == std.testing.allocator);
}

test "MergeCommitBuilder init with options" {
    var options = MergeCommitOptions{};
    options.no_ff = true;
    options.log = false;
    const builder = MergeCommitBuilder.init(std.testing.allocator, options);
    try std.testing.expect(builder.options.no_ff == true);
}

test "MergeCommitBuilder createCommit method exists" {
    var builder = MergeCommitBuilder.init(std.testing.allocator, .{});
    const result = try builder.createCommit(undefined, undefined, undefined);
    try std.testing.expect(result.is_merge_commit == true);
}

test "MergeCommitBuilder createFastForward method exists" {
    var builder = MergeCommitBuilder.init(std.testing.allocator, .{});
    const oid = try builder.createFastForward(undefined, undefined);
    _ = oid;
    try std.testing.expect(builder.allocator != undefined);
}
