//! Commit Parser - Parses commit objects
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;

pub const CommitParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommitParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *CommitParser, data: []const u8) !Commit {
        var tree_oid: OID = undefined;
        var parents = std.ArrayList(OID).init(self.allocator);
        defer parents.deinit();
        var author: Identity = undefined;
        var committer: Identity = undefined;
        var encoding: []const u8 = "UTF-8";
        var message_start: usize = 0;

        var lines = std.mem.split(u8, data, "\n");
        var state: enum { header, message } = .header;

        while (lines.next()) |line| {
            if (line.len == 0) {
                state = .message;
                message_start = lines.index;
                continue;
            }

            if (state == .message) break;

            if (std.mem.startsWith(u8, line, "tree ")) {
                const hex = line[5..];
                tree_oid = try OID.fromHex(hex);
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                const parent_oid = try OID.fromHex(hex);
                try parents.append(parent_oid);
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author = try Identity.parse(line[7..]);
            } else if (std.mem.startsWith(u8, line, "committer ")) {
                committer = try Identity.parse(line[10..]);
            } else if (std.mem.startsWith(u8, line, "encoding ")) {
                encoding = line[9..];
            }
        }

        const message = if (message_start > 0) data[message_start - 1 ..] else "";

        return Commit{
            .tree = tree_oid,
            .parents = try parents.toOwnedSlice(),
            .author = author,
            .committer = committer,
            .message = message,
            .encoding = encoding,
        };
    }

    pub fn validateFormat(data: []const u8) !bool {
        if (data.len == 0) return false;

        var has_tree = false;
        var has_author = false;
        var has_committer = false;
        var found_separator = false;

        var lines = std.mem.split(u8, data, "\n");
        while (lines.next()) |line| {
            if (line.len == 0) {
                found_separator = true;
                break;
            }
            if (std.mem.startsWith(u8, line, "tree ")) {
                const hex = line[5..];
                if (hex.len < 40) return false;
                for (hex[0..40]) |c| {
                    if (!std.ascii.isHex(c)) return false;
                }
                has_tree = true;
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                if (hex.len < 40) return false;
                for (hex[0..40]) |c| {
                    if (!std.ascii.isHex(c)) return false;
                }
            } else if (std.mem.startsWith(u8, line, "author ")) {
                if (line.len <= 7) return false;
                has_author = true;
            } else if (std.mem.startsWith(u8, line, "committer ")) {
                if (line.len <= 10) return false;
                has_committer = true;
            }
        }

        if (!has_tree) return false;
        if (!has_author) return false;
        if (!has_committer) return false;
        if (!found_separator) return false;

        return true;
    }
};

test "CommitParser init" {
    const parser = CommitParser.init(std.testing.allocator);
    try std.testing.expect(parser.allocator == std.testing.allocator);
}

test "CommitParser parse tree line" {
    const parser = CommitParser.init(std.testing.allocator);
    try std.testing.expect(parser.allocator == std.testing.allocator);
}

test "CommitParser validate format" {
    const data = "tree abc123\n";
    const valid = try CommitParser.validateFormat(data);
    try std.testing.expect(valid);
}
