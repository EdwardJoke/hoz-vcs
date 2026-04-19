//! Commit object - represents a snapshot of the tree
const std = @import("std");
const object_mod = @import("object.zig");
const oid_mod = @import("oid.zig");

/// Person identity (author or committer)
pub const Identity = struct {
    /// Name (e.g., "John Doe")
    name: []const u8,
    /// Email (e.g., "john@example.com")
    email: []const u8,
    /// Unix timestamp
    timestamp: i64,
    /// Timezone offset in minutes (e.g., -480 for PST)
    timezone: i32,

    /// Format identity for commit serialization
    pub fn format(self: Identity, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{} <{}> {} {}",
            .{
                self.name,
                self.email,
                self.timestamp,
                self.timezoneToStr(),
            },
        );
    }

    /// Convert timezone offset to string (e.g., "+0000", "-0500")
    pub fn timezoneToStr(self: Identity) [5]u8 {
        const sign: u8 = if (self.timezone >= 0) '+' else '-';
        const abs_min = @abs(self.timezone);
        const hours = abs_min / 60;
        const mins = abs_min % 60;
        return .{
            sign,
            @as(u8, @intCast((hours / 10) + '0')),
            @as(u8, @intCast((hours % 10) + '0')),
            @as(u8, @intCast((mins / 10) + '0')),
            @as(u8, @intCast((mins % 10) + '0')),
        };
    }

    /// Parse identity from string (e.g., "John Doe <john@example.com> 1234567890 +0000")
    pub fn parse(str: []const u8) !Identity {
        // Find name (everything before '<')
        const email_start = std.mem.indexOf(u8, str, "<") orelse return error.InvalidIdentity;
        const name = str[0..email_start];

        // Find email (between '<' and '>')
        const email_end = std.mem.indexOf(u8, str, ">") orelse return error.InvalidIdentity;
        const email = str[email_start + 1 .. email_end];

        // Find timestamp and timezone
        const rest = str[email_end + 1 ..];
        var iter = std.mem.split(u8, rest, " ");

        const timestamp_str = iter.next() orelse return error.InvalidIdentity;
        const timestamp = try std.fmt.parseInt(i64, timestamp_str, 10);

        const tz_str = iter.next() orelse return error.InvalidIdentity;
        const tz_parsed = try parseTimezone(tz_str);

        return Identity{
            .name = name,
            .email = email,
            .timestamp = timestamp,
            .timezone = tz_parsed,
        };
    }

    /// Parse timezone string like "+0000" or "-0530"
    fn parseTimezone(tz: []const u8) !i32 {
        if (tz.len != 5) return error.InvalidTimezone;
        const sign: i32 = if (tz[0] == '+') 1 else if (tz[0] == '-') -1 else return error.InvalidTimezone;
        const hours = try std.fmt.parseInt(i32, tz[1..3], 10);
        const mins = try std.fmt.parseInt(i32, tz[3..5], 10);
        return sign * (hours * 60 + mins);
    }

    /// Create a zero identity
    pub fn zero() Identity {
        return .{
            .name = "",
            .email = "",
            .timestamp = 0,
            .timezone = 0,
        };
    }
};

/// Commit object
pub const Commit = struct {
    /// Tree OID (required)
    tree: oid_mod.OID,
    /// Parent commits (can be empty for initial commit)
    parents: []const oid_mod.OID,
    /// Author identity
    author: Identity,
    /// Committer identity
    committer: Identity,
    /// Commit message
    message: []const u8,
    /// Optional GPG signature
    gpg_signature: ?[]const u8 = null,

    /// Create a new Commit
    pub fn create(
        tree: oid_mod.OID,
        parents: []const oid_mod.OID,
        author: Identity,
        committer: Identity,
        message: []const u8,
    ) Commit {
        return Commit{
            .tree = tree,
            .parents = parents,
            .author = author,
            .committer = committer,
            .message = message,
        };
    }

    /// Get the object type for this commit
    pub fn objectType() object_mod.Type {
        return .commit;
    }

    /// Serialize commit to loose object format
    /// Format:
    /// tree <tree_oid>
    /// parent <parent_oid>
    /// author <author>
    /// committer <committer>
    ///
    /// <message>
    pub fn serialize(self: Commit, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);

        // Write tree
        try buffer.appendSlice("tree ");
        try buffer.appendSlice(self.tree.toHex());
        try buffer.append('\n');

        // Write parents
        for (self.parents) |parent| {
            try buffer.appendSlice("parent ");
            try buffer.appendSlice(parent.toHex());
            try buffer.append('\n');
        }

        // Write author
        try buffer.appendSlice("author ");
        const author_str = try self.author.format(allocator);
        defer allocator.free(author_str);
        try buffer.appendSlice(author_str);
        try buffer.append('\n');

        // Write committer
        try buffer.appendSlice("committer ");
        const committer_str = try self.committer.format(allocator);
        defer allocator.free(committer_str);
        try buffer.appendSlice(committer_str);
        try buffer.append('\n');

        // GPG signature if present
        if (self.gpg_signature) |sig| {
            try buffer.appendSlice("gpgsig ");
            try buffer.appendSlice(sig);
            try buffer.append('\n');
        }

        // Blank line before message
        try buffer.append('\n');

        // Write message
        try buffer.appendSlice(self.message);

        // Wrap with header
        const content = buffer.items;
        const size_str = try std.fmt.allocPrint(allocator, "{}", .{content.len});
        defer allocator.free(size_str);

        const header = try std.fmt.allocPrint(allocator, "commit {}\x00", .{size_str});
        defer allocator.free(header);

        var result = try allocator.alloc(u8, header.len + content.len);
        @memcpy(result[0..header.len], header);
        @memcpy(result[header.len..], content);

        return result;
    }

    /// Parse commit from loose object data
    pub fn parse(data: []const u8) !Commit {
        const obj = try object_mod.parse(data);
        if (obj.obj_type != .commit) {
            return error.NotACommit;
        }

        var tree_opt: ?oid_mod.OID = null;
        var parents = std.ArrayList(oid_mod.OID).init(std.testing.allocator);
        errdefer parents.deinit();
        var author_opt: ?Identity = null;
        var committer_opt: ?Identity = null;
        var gpg_sig_opt: ?[]const u8 = null;
        var message_start: ?usize = null;

        var lines = std.mem.split(u8, obj.data, "\n");
        while (lines.next()) |line| {
            if (message_start == null and line.len == 0) {
                // Blank line marks start of message
                message_start = lines.index;
                break;
            }

            if (std.mem.startsWith(u8, line, "tree ")) {
                const hex = line[5..];
                tree_opt = oid_mod.OID.fromHex(hex);
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                try parents.append(oid_mod.OID.fromHex(hex));
            } else if (std.mem.startsWith(u8, line, "author ")) {
                const identity_str = line[7..];
                author_opt = try Identity.parse(identity_str);
            } else if (std.mem.startsWith(u8, line, "committer ")) {
                const identity_str = line[10..];
                committer_opt = try Identity.parse(identity_str);
            } else if (std.mem.startsWith(u8, line, "gpgsig ")) {
                gpg_sig_opt = line[7..];
            }
        }

        const tree = tree_opt orelse return error.MissingTree;
        const author = author_opt orelse return error.MissingAuthor;
        const committer = committer_opt orelse return error.MissingCommitter;

        // Get message (everything after blank line)
        var message: []const u8 = "";
        if (message_start) |start| {
            // Re-split to get remaining content
            var msg_iter = std.mem.split(u8, obj.data, "\n");
            var count: usize = 0;
            while (msg_iter.next()) |l| {
                if (count >= start) {
                    if (message.len == 0) {
                        message = l;
                    } else {
                        message = try std.mem.concat(std.testing.allocator, u8, &[2][]u8{ message, "\n", l });
                    }
                }
                count += 1;
            }
        }

        return Commit{
            .tree = tree,
            .parents = try parents.toOwnedSlice(),
            .author = author,
            .committer = committer,
            .message = message,
            .gpg_signature = gpg_sig_opt,
        };
    }
};

test "identity format" {
    const id = Identity{
        .name = "John Doe",
        .email = "john@example.com",
        .timestamp = 1234567890,
        .timezone = -300, // -0500
    };

    const formatted = try id.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualSlices(u8, "John Doe <john@example.com> 1234567890 -0500", formatted);
}

test "identity parse" {
    const str = "John Doe <john@example.com> 1234567890 +0000";
    const id = try Identity.parse(str);

    try std.testing.expectEqualSlices(u8, "John Doe", id.name);
    try std.testing.expectEqualSlices(u8, "john@example.com", id.email);
    try std.testing.expectEqual(@as(i64, 1234567890), id.timestamp);
    try std.testing.expectEqual(@as(i32, 0), id.timezone);
}

test "commit create" {
    const tree_oid = oid_mod.OID.zero();
    const parent_oid = oid_mod.OID.zero();
    const parents = &[_]oid_mod.OID{parent_oid};

    const author = Identity{
        .name = "John Doe",
        .email = "john@example.com",
        .timestamp = 1234567890,
        .timezone = 0,
    };

    const commit = Commit.create(tree_oid, parents, author, author, "Initial commit");

    try std.testing.expectEqual(tree_oid, commit.tree);
    try std.testing.expectEqual(1, commit.parents.len);
    try std.testing.expectEqualSlices(u8, "Initial commit", commit.message);
}

test "identity timezone to string" {
    const id_pos = Identity{ .name = "Test", .email = "t@t.com", .timestamp = 0, .timezone = 330 };
    try std.testing.expectEqualSlices(u8, "+0530", &id_pos.timezoneToStr());

    const id_neg = Identity{ .name = "Test", .email = "t@t.com", .timestamp = 0, .timezone = -480 };
    try std.testing.expectEqualSlices(u8, "-0800", &id_neg.timezoneToStr());

    const id_zero = Identity{ .name = "Test", .email = "t@t.com", .timestamp = 0, .timezone = 0 };
    try std.testing.expectEqualSlices(u8, "+0000", &id_zero.timezoneToStr());
}

test "identity parse invalid" {
    try std.testing.expectError(error.InvalidIdentity, Identity.parse("no email"));
    try std.testing.expectError(error.InvalidIdentity, Identity.parse("Name <email>"));
    try std.testing.expectError(error.InvalidTimezone, Identity.parse("Name <e@e.com> 12345"));
}

test "commit serialize and parse roundtrip" {
    const tree_hex = "0000000000000000000000000000000000000000";
    const tree_oid = oid_mod.OID.fromHex(tree_hex);

    const parent_hex = "1111111111111111111111111111111111111111";
    const parents = &[_]oid_mod.OID{oid_mod.OID.fromHex(parent_hex)};

    const author = Identity{
        .name = "Alice",
        .email = "alice@example.com",
        .timestamp = 1700000000,
        .timezone = -300,
    };

    const commit = Commit.create(tree_oid, parents, author, author, "Add feature\n\nDetailed description");

    const serialized = try commit.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const parsed = try Commit.parse(serialized);
    try std.testing.expectEqual(tree_oid, parsed.tree);
    try std.testing.expectEqual(1, parsed.parents.len);
    try std.testing.expectEqualSlices(u8, "Alice", parsed.author.name);
    try std.testing.expectEqualSlices(u8, "alice@example.com", parsed.author.email);
    try std.testing.expectEqualSlices(u8, "Add feature\n\nDetailed description", parsed.message);
}

test "commit multi-parent" {
    const tree_oid = oid_mod.OID.zero();
    const parent1 = oid_mod.OID.fromHex("1111111111111111111111111111111111111111");
    const parent2 = oid_mod.OID.fromHex("2222222222222222222222222222222222222222");
    const parents = &[_]oid_mod.OID{ parent1, parent2 };

    const author = Identity.zero();
    const commit = Commit.create(tree_oid, parents, author, author, "Merge branch");

    try std.testing.expectEqual(2, commit.parents.len);
    try std.testing.expectEqual(object_mod.Type.commit, commit.objectType());
}

test "commit initial (no parents)" {
    const tree_oid = oid_mod.OID.zero();
    const parents: []const oid_mod.OID = &.{};

    const author = Identity.zero();
    const commit = Commit.create(tree_oid, parents, author, author, "Initial commit");

    try std.testing.expectEqual(0, commit.parents.len);
}

test "commit parse rejects non-commit" {
    const blob_data = "blob 5\x00hello";
    try std.testing.expectError(error.NotACommit, Commit.parse(blob_data));
}
