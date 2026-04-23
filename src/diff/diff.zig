//! Diff Module - Main entry point for diff operations
//!
//! This module provides the unified interface for all diff-related
//! functionality including Myers diff algorithm, unified output,
//! binary detection, rename detection, and patch generation.

pub const DiffOptions = @import("options.zig").DiffOptions;
pub const IgnoreOptions = @import("options.zig").IgnoreOptions;
pub const DiffAlgorithm = @import("options.zig").DiffAlgorithm;

pub const myers = @import("myers.zig");
pub const unified = @import("unified.zig");
pub const result = @import("result.zig");
pub const binary = @import("binary.zig");
pub const rename = @import("rename.zig");
pub const ignore = @import("ignore.zig");
pub const patch = @import("patch.zig");
pub const cache = @import("cache.zig");
pub const parallel = @import("parallel.zig");
pub const large_file = @import("large_file.zig");

pub const DiffEngine = struct {
    allocator: std.mem.Allocator,
    options: DiffOptions,
    ignore_filter: ignore.IgnoreFilter,

    pub fn init(allocator: std.mem.Allocator) DiffEngine {
        return .{
            .allocator = allocator,
            .options = .{},
            .ignore_filter = ignore.IgnoreFilter.init(),
        };
    }

    pub fn deinit(self: *DiffEngine) void {
        _ = self;
    }

    pub fn setOptions(self: *DiffEngine, opts: DiffOptions) void {
        self.options = opts;
        self.applyIgnoreOptions();
    }

    fn applyIgnoreOptions(self: *DiffEngine) void {
        self.ignore_filter.setIgnoreAllSpace(self.options.ignore_whitespace);
        self.ignore_filter.setIgnoreCase(self.options.ignore_case);
        self.ignore_filter.setIgnoreWhitespaceChanges(self.options.ignore_options.ignore_whitespace_changes);
        self.ignore_filter.setIgnoreBlankLines(self.options.ignore_options.ignore_blank_lines);
        self.ignore_filter.setIgnoreSpaceAtEol(self.options.ignore_options.ignore_space_at_eol);
    }

    pub fn diffText(
        self: *DiffEngine,
        old_text: []const u8,
        new_text: []const u8,
    ) !result.DiffResult {
        var diff_result = result.DiffResult.init(self.allocator);
        errdefer diff_result.deinit();

        const old_lines = try self.splitIntoLines(old_text);
        defer self.allocator.free(old_lines);
        const new_lines = try self.splitIntoLines(new_text);
        defer self.allocator.free(new_lines);

        var myers_diff = myers.MyersDiff.init(self.allocator);
        const edits = try myers_diff.diff(old_lines, new_lines);
        defer self.allocator.free(edits);

        if (edits.len == 0) {
            return diff_result;
        }

        const hunk = result.Hunk{
            .old_start = 1,
            .old_count = old_lines.len,
            .new_start = 1,
            .new_count = new_lines.len,
            .lines = try self.convertEditsToLines(edits, old_lines, new_lines),
        };

        const file_hunk = result.FileHunk{
            .old_path = "text",
            .new_path = "text",
            .hunks = &.{hunk},
            .is_binary = false,
            .is_new = false,
            .is_deleted = false,
            .is_renamed = false,
            .old_mode = 0o100644,
            .new_mode = 0o100644,
        };

        try diff_result.addFileHunk(file_hunk);
        return diff_result;
    }

    fn splitIntoLines(self: *DiffEngine, text: []const u8) ![]const []const u8 {
        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer lines.deinit();

        var start: usize = 0;
        for (text, 0..) |byte, i| {
            if (byte == '\n') {
                const line = text[start..i];
                try lines.append(line);
                start = i + 1;
            }
        }

        if (start < text.len) {
            try lines.append(text[start..]);
        }

        return lines.toOwnedSlice();
    }

    fn convertEditsToLines(
        self: *DiffEngine,
        edits: []const myers.Edit,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
    ) ![]const result.Line {
        var lines = std.ArrayList(result.Line).init(self.allocator);
        errdefer lines.deinit();

        for (edits) |edit| {
            const line_type: result.LineType = switch (edit.operation) {
                .equal => .context,
                .insert => .addition,
                .delete => .deletion,
            };

            const content: []const u8 = switch (edit.operation) {
                .equal => if (edit.old_line > 0 and edit.old_line <= old_lines.len)
                    old_lines[edit.old_line - 1]
                else
                    "",
                .delete => if (edit.old_line > 0 and edit.old_line <= old_lines.len)
                    old_lines[edit.old_line - 1]
                else
                    "",
                .insert => if (edit.new_line > 0 and edit.new_line <= new_lines.len)
                    new_lines[edit.new_line - 1]
                else
                    "",
            };

            try lines.append(.{
                .content = content,
                .line_type = line_type,
                .old_line_num = if (edit.old_line > 0) edit.old_line else null,
                .new_line_num = if (edit.new_line > 0) edit.new_line else null,
            });
        }

        return lines.toOwnedSlice();
    }

    pub fn detectBinary(
        self: *DiffEngine,
        content: []const u8,
    ) binary.BinaryResult {
        var detector = binary.BinaryDetection.init(self.allocator);
        return detector.detect(content);
    }
};

const std = @import("std");

test "DiffEngine init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    try std.testing.expect(engine.allocator == gpa.allocator());
}

test "DiffEngine diffText no changes" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    const diff_result = try engine.diffText("hello\nworld\n", "hello\nworld\n");
    defer diff_result.deinit();

    try std.testing.expectEqual(@as(usize, 0), diff_result.stats.insertions);
    try std.testing.expectEqual(@as(usize, 0), diff_result.stats.deletions);
}

test "DiffEngine diffText with changes" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    const diff_result = try engine.diffText("hello\nworld\n", "hello\nzig\nworld\n");
    defer diff_result.deinit();

    try std.testing.expect(diff_result.stats.insertions > 0 or diff_result.stats.deletions > 0);
}

test "DiffEngine detectBinary text" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    const binary_result = engine.detectBinary("hello world");
    try std.testing.expectEqual(false, binary_result.is_binary);
}

test "DiffEngine detectBinary binary" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    const content: [10]u8 = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    const binary_result = engine.detectBinary(&content);
    try std.testing.expectEqual(true, binary_result.is_binary);
}

test "DiffEngine setOptions" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var engine = DiffEngine.init(gpa.allocator());
    defer engine.deinit();

    var opts = DiffOptions{};
    opts.ignore_whitespace = true;
    opts.ignore_case = true;

    engine.setOptions(opts);

    try std.testing.expectEqual(true, engine.options.ignore_whitespace);
    try std.testing.expectEqual(true, engine.options.ignore_case);
}
