//! Tag object - represents an annotated tag
const std = @import("std");
const object_mod = @import("object.zig");
const oid_mod = @import("oid.zig");

/// Tagger identity type (used for both field and create param)
pub const Tagger = struct {
    name: []const u8,
    email: []const u8,
    timestamp: i64,
    timezone: i32,
};

/// Annotated tag object
pub const Tag = struct {
    /// Name of the tag (e.g., "v1.0.0")
    name: []const u8,
    /// OID of the tagged object (commit, tree, blob, or tag)
    target: oid_mod.OID,
    /// Type of the target object (commit, tree, blob, tag)
    target_type: object_mod.Type,
    /// Tagger identity
    tagger: ?Tagger,
    /// Tag message
    message: []const u8,
    /// Optional GPG signature
    gpg_signature: ?[]const u8 = null,

    /// Create a new Tag
    pub fn create(
        name: []const u8,
        target: oid_mod.OID,
        target_type: object_mod.Type,
        tagger: ?Tagger,
        message: []const u8,
    ) Tag {
        return Tag{
            .name = name,
            .target = target,
            .target_type = target_type,
            .tagger = tagger,
            .message = message,
        };
    }

    /// Get the object type for this tag
    pub fn objectType() object_mod.Type {
        return .tag;
    }

    /// Get the target type as a string (e.g., "commit", "tree")
    pub fn targetTypeStr(self: Tag) []const u8 {
        return switch (self.target_type) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    /// Serialize tag to loose object format
    /// Format:
    /// object <target_oid>
    /// type <target_type>
    /// tag <tag_name>
    /// tagger <tagger>
    ///
    /// <message>
    pub fn serialize(self: Tag, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
        defer buffer.deinit(allocator);

        // Write object
        try buffer.appendSlice(allocator, "object ");
        try buffer.appendSlice(allocator, &self.target.toHex());
        try buffer.append(allocator, '\n');

        // Write type
        try buffer.appendSlice(allocator, "type ");
        try buffer.appendSlice(allocator, self.targetTypeStr());
        try buffer.append(allocator, '\n');

        // Write tag name
        try buffer.appendSlice(allocator, "tag ");
        try buffer.appendSlice(allocator, self.name);
        try buffer.append(allocator, '\n');

        // Write tagger if present
        if (self.tagger) |tagger| {
            try buffer.appendSlice(allocator, "tagger ");
            try buffer.appendSlice(allocator, tagger.name);
            try buffer.appendSlice(allocator, " <");
            try buffer.appendSlice(allocator, tagger.email);
            try buffer.appendSlice(allocator, "> ");
            try buffer.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{tagger.timestamp}));
            try buffer.appendSlice(allocator, &timezoneToStr(tagger.timezone));
            try buffer.append(allocator, '\n');
        }

        // GPG signature if present
        if (self.gpg_signature) |sig| {
            try buffer.appendSlice(allocator, "gpgsig ");
            try buffer.appendSlice(allocator, sig);
            try buffer.append(allocator, '\n');
        }

        // Blank line before message
        try buffer.append(allocator, '\n');

        // Write message
        try buffer.appendSlice(allocator, self.message);

        // Wrap with header
        const content = buffer.items;
        const size_str = try std.fmt.allocPrint(allocator, "{}", .{content.len});
        defer allocator.free(size_str);

        const header = try std.fmt.allocPrint(allocator, "tag {s}\x00", .{size_str});
        defer allocator.free(header);

        var result = try allocator.alloc(u8, header.len + content.len);
        @memcpy(result[0..header.len], header);
        @memcpy(result[header.len..], content);

        return result;
    }

    /// Parse tag from loose object data
    pub fn parse(data: []const u8) !Tag {
        const obj = try object_mod.parse(data);
        if (obj.obj_type != .tag) {
            return error.NotATag;
        }

        var target_opt: ?oid_mod.OID = null;
        var target_type_opt: ?object_mod.Type = null;
        var name_opt: []const u8 = "";
        var tagger_opt: ?Tagger = null;
        var gpg_sig_opt: ?[]const u8 = null;
        var message_start: ?usize = null;

        var lines = std.mem.splitSequence(u8, obj.data, "\n");
        while (lines.next()) |line| {
            if (message_start == null and line.len == 0) {
                message_start = lines.index;
                continue;
            }

            if (std.mem.startsWith(u8, line, "object ")) {
                const hex = line[7..];
                target_opt = try oid_mod.OID.fromHex(hex);
            } else if (std.mem.startsWith(u8, line, "type ")) {
                const type_str = line[5..];
                target_type_opt = try typeFromStr(type_str);
            } else if (std.mem.startsWith(u8, line, "tag ")) {
                name_opt = line[4..];
            } else if (std.mem.startsWith(u8, line, "tagger ")) {
                tagger_opt = try parseTagger(line[7..]);
            } else if (std.mem.startsWith(u8, line, "gpgsig ")) {
                gpg_sig_opt = line[7..];
            }
        }

        const target = target_opt orelse return error.MissingObject;
        const target_type = target_type_opt orelse return error.MissingType;

        // Get message (everything after blank line)
        var message: []const u8 = "";
        if (message_start) |_| {
            const first_newline = std.mem.indexOf(u8, obj.data, "\n\n");
            if (first_newline) |nl| {
                message = obj.data[nl + 2 ..];
            }
        }

        return Tag{
            .name = name_opt,
            .target = target,
            .target_type = target_type,
            .tagger = tagger_opt,
            .message = message,
            .gpg_signature = gpg_sig_opt,
        };
    }

    /// Parse type string to Type enum
    fn typeFromStr(str: []const u8) !object_mod.Type {
        if (std.mem.eql(u8, str, "blob")) return .blob;
        if (std.mem.eql(u8, str, "tree")) return .tree;
        if (std.mem.eql(u8, str, "commit")) return .commit;
        if (std.mem.eql(u8, str, "tag")) return .tag;
        return error.UnknownType;
    }

    /// Parse tagger identity from string
    fn parseTagger(str: []const u8) !Tagger {
        const email_start = std.mem.indexOf(u8, str, "<") orelse return error.InvalidTagger;
        var name = str[0..email_start];
        while (name.len > 0 and (name[name.len - 1] == ' ' or name[name.len - 1] == '\t')) {
            name = name[0 .. name.len - 1];
        }

        const email_end = std.mem.indexOf(u8, str, ">") orelse return error.InvalidTagger;
        const email = str[email_start + 1 .. email_end];

        const rest = str[email_end + 1 ..];
        var iter = std.mem.splitSequence(u8, rest, " ");

        var timestamp_str = iter.next();
        while (timestamp_str) |ts| {
            if (ts.len > 0) break;
            timestamp_str = iter.next();
        }
        const ts = timestamp_str orelse return error.InvalidTagger;
        const timestamp = try std.fmt.parseInt(i64, ts, 10);

        var tz_str = iter.next();
        while (tz_str) |tz| {
            if (tz.len > 0) break;
            tz_str = iter.next();
        }
        const tz_final = tz_str orelse return error.InvalidTagger;
        const tz_parsed = try parseTimezone(tz_final);

        return .{
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
};

/// Convert timezone offset to string
fn timezoneToStr(tz: i32) [5]u8 {
    const sign: u8 = if (tz >= 0) '+' else '-';
    const abs_min = @abs(tz);
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

test "tag create" {
    const target = oid_mod.OID.zero();

    const tag = Tag.create("v1.0.0", target, .commit, null, "Release v1.0.0");

    try std.testing.expectEqualSlices(u8, "v1.0.0", tag.name);
    try std.testing.expectEqual(target, tag.target);
    try std.testing.expectEqual(.commit, tag.target_type);
    try std.testing.expectEqualSlices(u8, "Release v1.0.0", tag.message);
}

test "tag target type string" {
    const target = oid_mod.OID.zero();

    const commit_tag = Tag.create("v1.0.0", target, .commit, null, "message");
    try std.testing.expectEqualSlices(u8, "commit", commit_tag.targetTypeStr());

    const tree_tag = Tag.create("v1.0.0", target, .tree, null, "message");
    try std.testing.expectEqualSlices(u8, "tree", tree_tag.targetTypeStr());
}

test "tag serialize and parse roundtrip" {
    const target = oid_mod.OID.fromHex("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef") catch unreachable;
    const tagger = Tagger{
        .name = "Test User",
        .email = "test@example.com",
        .timestamp = 1234567890,
        .timezone = -480, // -0800
    };

    const tag = Tag.create("v1.0.0", target, .commit, tagger, "Test tag message");

    const serialized = try tag.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const parsed = try Tag.parse(serialized);

    try std.testing.expectEqualSlices(u8, "v1.0.0", parsed.name);
    try std.testing.expectEqualSlices(u8, "Test tag message", parsed.message);
    try std.testing.expectEqual(.commit, parsed.target_type);
}

test "tag parse rejects non-tag" {
    const blob_data = "blob 5\x00hello";
    try std.testing.expectError(error.NotATag, Tag.parse(blob_data));
}

test "tag without tagger" {
    const target = oid_mod.OID.zero();
    const tag = Tag.create("v1.0.0", target, .commit, null, "No tagger info");

    try std.testing.expect(tag.tagger == null);

    const serialized = try tag.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const parsed = try Tag.parse(serialized);
    try std.testing.expect(parsed.tagger == null);
}

test "tag timezone parsing" {
    const target = oid_mod.OID.zero();
    const tagger1 = Tagger{
        .name = "A",
        .email = "a@b.c",
        .timestamp = 0,
        .timezone = 0,
    };
    const tag1 = Tag.create("v1", target, .commit, tagger1, "msg");
    try std.testing.expectEqualSlices(u8, "+0000", &timezoneToStr(tag1.tagger.?.timezone));

    const tagger2 = Tagger{
        .name = "A",
        .email = "a@b.c",
        .timestamp = 0,
        .timezone = -330,
    };
    const tag2 = Tag.create("v1", target, .commit, tagger2, "msg");
    try std.testing.expectEqualSlices(u8, "-0530", &timezoneToStr(tag2.tagger.?.timezone));
}
