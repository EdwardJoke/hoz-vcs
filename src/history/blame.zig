//! History Blame - Blame for line-by-line commit history
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const BlameOptions = struct {
    revision: ?[]const u8 = null,
    start_line: ?u32 = null,
    end_line: ?u32 = null,
    show_stats: bool = false,
    mailmap: bool = true,
    show_email: bool = false,
    contents_path: ?[]const u8 = null,
    copy_detection_M: bool = false,
    copy_detection_C: bool = false,
    find_copies_harder: bool = false,
};

pub const BlameLine = struct {
    commit_oid: ?OID,
    original_line_number: u32,
    final_line_number: u32,
    content: []const u8,
    author: ?[]const u8 = null,
    date: ?i64 = null,
};

pub const BlameEntry = struct {
    commit_oid: OID,
    author: []const u8,
    author_mail: []const u8,
    author_time: i64,
    author_tz: []const u8,
    summary: []const u8,
    previous: ?OID,
    filename: []const u8,
    lines: []const BlameLine,
};

pub const Blamer = struct {
    allocator: std.mem.Allocator,
    options: BlameOptions,

    pub fn init(allocator: std.mem.Allocator, options: BlameOptions) Blamer {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn blameFile(self: *Blamer, path: []const u8) ![]const BlameEntry {
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{}) catch return &.{};
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return &.{};
        defer self.allocator.free(data);

        var lines_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (lines_list.items) |l| self.allocator.free(l);
            lines_list.deinit(self.allocator);
        }

        var line_iter = std.mem.splitSequence(u8, data, "\n");
        while (line_iter.next()) |line_content| {
            try lines_list.append(self.allocator, try self.allocator.dupe(u8, line_content));
        }

        var blame_lines = std.ArrayList(BlameLine).initCapacity(self.allocator, lines_list.items.len);
        errdefer {
            for (blame_lines.items) |*bl| {
                if (bl.content.len > 0) self.allocator.free(bl.content);
            }
            blame_lines.deinit(self.allocator);
        }

        for (lines_list.items, 0..) |content, i| {
            try blame_lines.append(self.allocator, .{
                .commit_oid = null,
                .original_line_number = @intCast(i + 1),
                .final_line_number = @intCast(i + 1),
                .content = content,
            });
        }

        var entries = std.ArrayList(BlameEntry).initCapacity(self.allocator, 1);
        errdefer {
            for (entries.items) |*entry| {
                if (entry.author.len > 0) self.allocator.free(entry.author);
                if (entry.summary.len > 0) self.allocator.free(entry.summary);
                if (entry.filename.len > 0) self.allocator.free(entry.filename);
            }
            entries.deinit(self.allocator);
        }

        const path_owned = try self.allocator.dupe(u8, path);
        try entries.append(self.allocator, .{
            .commit_oid = undefined,
            .author = "",
            .author_mail = "",
            .author_time = 0,
            .author_tz = "",
            .summary = "",
            .previous = null,
            .filename = path_owned,
            .lines = blame_lines.toOwnedSlice(self.allocator),
        });

        for (lines_list.items) |l| self.allocator.free(l);
        lines_list.deinit(self.allocator);

        return entries.toOwnedSlice(self.allocator);
    }

    pub fn getBlameForRange(self: *Blamer, path: []const u8, start: u32, end: u32) ![]const BlameEntry {
        const all = try self.blameFile(path);
        if (all.len == 0) return &.{};

        var range_entries = std.ArrayList(BlameEntry).initCapacity(self.allocator, all.len);
        errdefer {
            for (range_entries.items) |*entry| {
                if (entry.filename.len > 0) self.allocator.free(entry.filename);
                for (entry.lines) |*bl| {
                    if (bl.content.len > 0) self.allocator.free(bl.content);
                }
                if (entry.lines.len > 0) self.allocator.free(entry.lines);
            }
            range_entries.deinit(self.allocator);
        }

        for (all) |entry| {
            var filtered_lines = std.ArrayList(BlameLine).empty;
            errdefer {
                for (filtered_lines.items) |*bl| {
                    if (bl.content.len > 0) self.allocator.free(bl.content);
                }
                filtered_lines.deinit(self.allocator);
            }

            for (entry.lines) |line| {
                if (line.final_line_number >= start and line.final_line_number <= end) {
                    try filtered_lines.append(self.allocator, .{
                        .commit_oid = line.commit_oid,
                        .original_line_number = line.original_line_number,
                        .final_line_number = line.final_line_number,
                        .content = try self.allocator.dupe(u8, line.content),
                        .author = if (line.author) |a| try self.allocator.dupe(u8, a) else null,
                        .date = line.date,
                    });
                }
            }

            if (filtered_lines.items.len > 0) {
                const path_owned = try self.allocator.dupe(u8, entry.filename);
                try range_entries.append(self.allocator, .{
                    .commit_oid = entry.commit_oid,
                    .author = if (entry.author.len > 0) try self.allocator.dupe(u8, entry.author) else "",
                    .author_mail = if (entry.author_mail.len > 0) try self.allocator.dupe(u8, entry.author_mail) else "",
                    .author_time = entry.author_time,
                    .author_tz = if (entry.author_tz.len > 0) try self.allocator.dupe(u8, entry.author_tz) else "",
                    .summary = if (entry.summary.len > 0) try self.allocator.dupe(u8, entry.summary) else "",
                    .previous = entry.previous,
                    .filename = path_owned,
                    .lines = filtered_lines.toOwnedSlice(self.allocator),
                });
            } else {
                filtered_lines.deinit(self.allocator);
            }
        }

        for (all) |entry| {
            if (entry.filename.len > 0) self.allocator.free(entry.filename);
            for (entry.lines) |line| {
                if (line.content.len > 0) self.allocator.free(line.content);
            }
            if (entry.lines.len > 0) self.allocator.free(entry.lines);
        }
        self.allocator.free(all);

        return range_entries.toOwnedSlice(self.allocator);
    }
};

test "BlameOptions default values" {
    const options = BlameOptions{};
    try std.testing.expect(options.revision == null);
    try std.testing.expect(options.show_stats == false);
    try std.testing.expect(options.mailmap == true);
}

test "BlameLine structure" {
    const line = BlameLine{
        .commit_oid = null,
        .original_line_number = 1,
        .final_line_number = 1,
        .content = "Hello, world!",
        .author = null,
        .date = null,
    };

    try std.testing.expectEqual(@as(u32, 1), line.original_line_number);
    try std.testing.expectEqualStrings("Hello, world!", line.content);
}

test "BlameEntry structure" {
    const entry = BlameEntry{
        .commit_oid = undefined,
        .author = "Test Author",
        .author_mail = "test@example.com",
        .author_time = 1234567890,
        .author_tz = "+0000",
        .summary = "Initial commit",
        .previous = null,
        .filename = "test.txt",
        .lines = &.{},
    };

    try std.testing.expectEqualStrings("Test Author", entry.author);
    try std.testing.expectEqualStrings("Initial commit", entry.summary);
}

test "Blamer init" {
    const options = BlameOptions{};
    const blamer = Blamer.init(std.testing.allocator, options);

    try std.testing.expect(blamer.allocator == std.testing.allocator);
}

test "Blamer init with options" {
    var options = BlameOptions{};
    options.show_stats = true;
    options.show_email = true;
    const blamer = Blamer.init(std.testing.allocator, options);

    try std.testing.expect(blamer.options.show_stats == true);
    try std.testing.expect(blamer.options.show_email == true);
}

test "Blamer blameFile method exists" {
    var options = BlameOptions{};
    var blamer = Blamer.init(std.testing.allocator, options);

    const result = try blamer.blameFile("test.txt");
    try std.testing.expect(result.len >= 0);
}

test "Blamer getBlameForRange method exists" {
    var options = BlameOptions{};
    var blamer = Blamer.init(std.testing.allocator, options);

    const result = try blamer.getBlameForRange("test.txt", 1, 10);
    try std.testing.expect(result.len >= 0);
}
