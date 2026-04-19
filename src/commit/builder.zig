//! Commit Builder - Constructs commit objects from staged changes
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;

/// Options for building a commit
pub const CommitOptions = struct {
    tree_oid: OID,
    author: Identity,
    committer: Identity,
    message: []const u8,
    parents: []const OID = &.{},
    encoding: []const u8 = "UTF-8",
};

/// CommitBuilder constructs and serializes commit objects
pub const CommitBuilder = struct {
    allocator: std.mem.Allocator,
    options: CommitOptions,

    pub fn init(allocator: std.mem.Allocator, options: CommitOptions) CommitBuilder {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn build(self: *CommitBuilder) !Commit {
        return Commit{
            .tree = self.options.tree_oid,
            .parents = self.options.parents,
            .author = self.options.author,
            .committer = self.options.committer,
            .message = self.options.message,
            .encoding = self.options.encoding,
        };
    }

    pub fn serialize(self: *CommitBuilder, commit: Commit) ![]u8 {
        var content = std.ArrayList(u8).init(self.allocator);
        errdefer content.deinit();

        try content.appendSlice("tree ");
        try content.appendSlice(try commit.tree.hexString(self.allocator));
        try content.appendSlice("\n");

        for (commit.parents) |parent| {
            try content.appendSlice("parent ");
            try content.appendSlice(try parent.hexString(self.allocator));
            try content.appendSlice("\n");
        }

        try content.appendSlice("author ");
        try content.appendSlice(try commit.author.format(self.allocator));
        try content.appendSlice("\n");

        try content.appendSlice("committer ");
        try content.appendSlice(try commit.committer.format(self.allocator));
        try content.appendSlice("\n");

        try content.appendSlice("encoding ");
        try content.appendSlice(commit.encoding);
        try content.appendSlice("\n");

        try content.appendSlice("\n");

        try content.appendSlice(commit.message);

        return content.toOwnedSlice();
    }

    pub fn computeOid(self: *CommitBuilder, content: []const u8) !OID {
        return OID.oidFromContent(content);
    }
};

test "CommitBuilder init" {
    const author = Identity{
        .name = "Test Author",
        .email = "test@example.com",
        .timestamp = 1700000000,
        .timezone = -480,
    };

    const tree_oid = OID.zero();
    const options = CommitOptions{
        .tree_oid = tree_oid,
        .author = author,
        .committer = author,
        .message = "Initial commit",
    };

    var builder = CommitBuilder.init(std.testing.allocator, options);
    defer _ = builder;

    try std.testing.expect(builder.options.tree_oid.isZero());
}

test "CommitBuilder build creates valid commit" {
    const author = Identity{
        .name = "Test Author",
        .email = "test@example.com",
        .timestamp = 1700000000,
        .timezone = -480,
    };

    const tree_oid = try OID.fromHex("abc123def456789012345678901234567890abcd");

    var options = CommitOptions{
        .tree_oid = tree_oid,
        .author = author,
        .committer = author,
        .message = "Test commit",
    };

    var builder = CommitBuilder.init(std.testing.allocator, options);
    defer _ = builder;

    const commit = try builder.build();
    try std.testing.expectEqual(tree_oid, commit.tree);
    try std.testing.expectEqualSlices(u8, "Test commit", commit.message);
}

test "CommitBuilder serialize produces valid format" {
    const author = Identity{
        .name = "Test Author",
        .email = "test@example.com",
        .timestamp = 1700000000,
        .timezone = -480,
    };

    const tree_oid = try OID.fromHex("abc123def456789012345678901234567890abcd");

    const options = CommitOptions{
        .tree_oid = tree_oid,
        .author = author,
        .committer = author,
        .message = "Test commit message",
    };

    var builder = CommitBuilder.init(std.testing.allocator, options);
    defer _ = builder;

    const commit = try builder.build();
    const serialized = try builder.serialize(commit);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(std.mem.startsWith(u8, serialized, "tree "));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "author "));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "committer "));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, serialized, "Test commit message"));
}