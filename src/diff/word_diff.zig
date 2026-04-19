//! WordDiff - Word-level diff for showing inline word changes
//!
//! This module provides word-level diff functionality for displaying
//! changes at the word granularity within lines.

const std = @import("std");

pub const WordChange = struct {
    change_type: WordChangeType,
    text: []const u8,
};

pub const WordChangeType = enum {
    equal,
    insert,
    delete,
};

pub const WordDiffOptions = struct {
    separator: []const u8 = " ",
    ignore_whitespace: bool = false,
    word_regex: []const u8 = "\\S+",
};

pub const WordDiffResult = struct {
    changes: []WordChange,
    insertions: u32,
    deletions: u32,
};

pub fn computeWordDiff(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
    options: WordDiffOptions,
) !WordDiffResult {
    var changes = std.ArrayList(WordChange).init(allocator);
    errdefer {
        for (changes.items) |change| {
            allocator.free(change.text);
        }
        changes.deinit();
    }

    var insertions: u32 = 0;
    var deletions: u32 = 0;

    const old_words = splitIntoWords(old_text, options.separator);
    const new_words = splitIntoWords(new_text, options.separator);

    var old_idx: usize = 0;
    var new_idx: usize = 0;

    while (old_idx < old_words.len or new_idx < new_words.len) {
        if (old_idx >= old_words.len) {
            try changes.append(WordChange{
                .change_type = .insert,
                .text = try allocator.dupe(u8, new_words[new_idx]),
            });
            insertions += 1;
            new_idx += 1;
        } else if (new_idx >= new_words.len) {
            try changes.append(WordChange{
                .change_type = .delete,
                .text = try allocator.dupe(u8, old_words[old_idx]),
            });
            deletions += 1;
            old_idx += 1;
        } else if (std.mem.eql(u8, old_words[old_idx], new_words[new_idx])) {
            try changes.append(WordChange{
                .change_type = .equal,
                .text = try allocator.dupe(u8, old_words[old_idx]),
            });
            old_idx += 1;
            new_idx += 1;
        } else {
            try changes.append(WordChange{
                .change_type = .delete,
                .text = try allocator.dupe(u8, old_words[old_idx]),
            });
            deletions += 1;
            old_idx += 1;
        }
    }

    return WordDiffResult{
        .changes = try changes.toOwnedSlice(),
        .insertions = insertions,
        .deletions = deletions,
    };
}

fn splitIntoWords(text: []const u8, separator: []const u8) [][]const u8 {
    var words = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer words.deinit();

    var remaining = text;
    while (remaining.len > 0) {
        const sep_idx = findSeparator(remaining, separator);
        if (sep_idx == 0) {
            words.appendAssumeCapacity("");
            remaining = remaining[separator.len..];
        } else if (sep_idx == null) {
            words.appendAssumeCapacity(remaining);
            break;
        } else {
            words.appendAssumeCapacity(remaining[0..sep_idx.?]);
            remaining = remaining[sep_idx.? + separator.len ..];
        }
    }

    return words.toOwnedSlice() catch &.{};
}

fn findSeparator(text: []const u8, separator: []const u8) ?usize {
    if (separator.len == 0) return null;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i + separator.len <= text.len) {
            if (std.mem.eql(u8, text[i .. i + separator.len], separator)) {
                return i;
            }
        }
    }
    return null;
}

pub fn formatWordDiff(
    allocator: std.mem.Allocator,
    result: WordDiffResult,
    options: WordDiffOptions,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (result.changes) |change| {
        switch (change.change_type) {
            .equal => try buf.writer().print("{s}", .{change.text}),
            .insert => try buf.writer().print("+{s}", .{change.text}),
            .delete => try buf.writer().print("-{s}", .{change.text}),
        }
        if (options.separator.len > 0) {
            try buf.appendSlice(options.separator);
        }
    }

    return buf.toOwnedSlice();
}

pub fn wordDiffStats(result: WordDiffResult) WordDiffStats {
    return WordDiffStats{
        .insertions = result.insertions,
        .deletions = result.deletions,
        .total_changes = result.insertions + result.deletions,
    };
}

pub const WordDiffStats = struct {
    insertions: u32,
    deletions: u32,
    total_changes: u32,
};

test "WordChange type detection" {
    const insert = WordChange{ .change_type = .insert, .text = "hello" };
    try std.testing.expect(insert.change_type == .insert);

    const delete = WordChange{ .change_type = .delete, .text = "world" };
    try std.testing.expect(delete.change_type == .delete);

    const equal = WordChange{ .change_type = .equal, .text = "same" };
    try std.testing.expect(equal.change_type == .equal);
}

test "WordDiffStats calculation" {
    const stats = wordDiffStats(WordDiffResult{
        .changes = &.{},
        .insertions = 5,
        .deletions = 3,
    });
    try std.testing.expect(stats.insertions == 5);
    try std.testing.expect(stats.deletions == 3);
    try std.testing.expect(stats.total_changes == 8);
}
