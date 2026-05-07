//! UnifiedDiff - Generate unified diff output format

const std = @import("std");
const Io = std.Io;
const myers = @import("myers.zig");

pub const UnifiedConfig = struct {
    context_lines: usize = 3,
    old_prefix: []const u8 = "a/",
    new_prefix: []const u8 = "b/",
    no_prefix: bool = false,
    color: bool = true,
};

pub const UnifiedHunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []const []const u8,
};

pub const UnifiedDiff = struct {
    allocator: std.mem.Allocator,
    config: UnifiedConfig,

    pub fn init(allocator: std.mem.Allocator) UnifiedDiff {
        return .{
            .allocator = allocator,
            .config = .{},
        };
    }

    pub fn formatUnified(
        self: *UnifiedDiff,
        writer: *Io.Writer,
        old_path: []const u8,
        new_path: []const u8,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
    ) !void {
        const hunks = try self.groupIntoHunks(old_lines, new_lines, edits);
        defer {
            for (hunks) |hunk| {
                self.allocator.free(hunk.lines);
            }
            self.allocator.free(hunks);
        }

        const prefix = if (self.config.no_prefix) "" else self.config.old_prefix;
        try writer.print("--- {s}{s}\n", .{ prefix, old_path });
        const new_prefix = if (self.config.no_prefix) "" else self.config.new_prefix;
        try writer.print("+++ {s}{s}\n", .{ new_prefix, new_path });

        for (hunks) |hunk| {
            try self.printHunk(writer, hunk, old_lines, new_lines);
        }
    }

    fn groupIntoHunks(
        self: *UnifiedDiff,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
    ) ![]const UnifiedHunk {
        var hunks = std.ArrayList(UnifiedHunk).init(self.allocator);
        errdefer hunks.deinit();

        var i: usize = 0;
        while (i < edits.len) {
            if (edits[i].operation != .equal) {
                const hunk = try self.collectHunk(edits, &i, old_lines, new_lines);
                try hunks.append(hunk);
            } else {
                i += 1;
            }
        }

        return hunks.toOwnedSlice();
    }

    fn collectHunk(
        self: *UnifiedDiff,
        edits: []const myers.Edit,
        start_idx: *usize,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
    ) !UnifiedHunk {
        if (edits.len == 0) return .{
            .old_start = 1,
            .old_count = 0,
            .new_start = 1,
            .new_count = 0,
            .lines = &.{},
        };

        const ctx = self.config.context_lines;

        var hunk_start = start_idx.*;
        var hunk_end = start_idx.*;

        while (hunk_start > 0 and edits[hunk_start - 1].operation == .equal) : (hunk_start -= 1) {
            if (hunk_start == 0) break;
        }

        if (hunk_start > ctx) hunk_start -= ctx;

        hunk_end = start_idx.*;
        while (hunk_end < edits.len and edits[hunk_end].operation != .equal) : (hunk_end += 1) {}
        const saved_end = hunk_end;

        hunk_end = @min(edits.len, hunk_end + ctx);

        var old_count: usize = 0;
        var new_count: usize = 0;

        for (hunk_start..saved_end) |idx| {
            switch (edits[idx].operation) {
                .delete => old_count += 1,
                .insert => new_count += 1,
                .equal => {
                    old_count += 1;
                    new_count += 1;
                },
            }
        }

        const old_start = if (edits[hunk_start].operation == .delete or edits[hunk_start].operation == .equal)
            if (edits[hunk_start].old_line > 0) edits[hunk_start].old_line - 1 else 1
        else if (hunk_start + 1 < edits.len)
            edits[hunk_start + 1].old_line
        else
            old_lines.len + 1;

        const new_start = if (edits[hunk_start].operation == .insert or edits[hunk_start].operation == .equal)
            if (edits[hunk_start].new_line > 0) edits[hunk_start].new_line - 1 else 1
        else if (hunk_start + 1 < edits.len)
            edits[hunk_start + 1].new_line
        else
            new_lines.len + 1;

        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit();
        }

        for (hunk_start..hunk_end) |idx| {
            const edit = edits[idx];
            const line: []const u8 = switch (edit.operation) {
                .equal => if (edit.old_line > 0 and edit.old_line <= old_lines.len) old_lines[edit.old_line - 1] else "",
                .delete => if (edit.old_line > 0 and edit.old_line <= old_lines.len) old_lines[edit.old_line - 1] else "",
                .insert => if (edit.new_line > 0 and edit.new_line <= new_lines.len) new_lines[edit.new_line - 1] else "",
            };
            const prefix: []const u8 = switch (edit.operation) {
                .equal => " ",
                .delete => "-",
                .insert => "+",
            };
            const full_line = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, line });
            try lines.append(full_line);
        }

        start_idx.* = saved_end;

        return .{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .lines = lines.toOwnedSlice(),
        };
    }

    fn printHunk(
        self: *UnifiedDiff,
        writer: *Io.Writer,
        hunk: UnifiedHunk,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
    ) !void {
        _ = old_lines;
        _ = new_lines;

        const cyan = "\x1b[36m";
        const green = "\x1b[32m";
        const red = "\x1b[31m";
        const reset = "\x1b[0m";

        if (self.config.color) {
            try writer.print("{s}{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{
                cyan, "\x1b[1m", hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count, reset,
            });
        } else {
            try writer.print("@@ -{d},{d} +{d},{d} @@\n", .{
                hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count,
            });
        }

        for (hunk.lines) |line| {
            if (line.len == 0) {
                try writer.writeAll("\n");
                continue;
            }
            if (self.config.color) {
                if (std.mem.startsWith(u8, line, "+")) {
                    try writer.print("{s}{s}{s}\n", .{ green, line, reset });
                } else if (std.mem.startsWith(u8, line, "-")) {
                    try writer.print("{s}{s}{s}\n", .{ red, line, reset });
                } else {
                    try writer.print("{s}\n", .{line});
                }
            } else {
                try writer.print("{s}\n", .{line});
            }
        }
    }
};

test "UnifiedDiff init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    const diff = UnifiedDiff.init(gpa.allocator());
    try std.testing.expect(diff.allocator == gpa.allocator());
    try std.testing.expectEqual(@as(usize, 3), diff.config.context_lines);
}

test "UnifiedConfig defaults" {
    const config = UnifiedConfig{};
    try std.testing.expectEqual(@as(usize, 3), config.context_lines);
    try std.testing.expectEqualStrings("a/", config.old_prefix);
    try std.testing.expectEqualStrings("b/", config.new_prefix);
    try std.testing.expectEqual(false, config.no_prefix);
    try std.testing.expectEqual(true, config.color);
}

test "UnifiedHunk structure" {
    const hunk = UnifiedHunk{
        .old_start = 1,
        .old_count = 5,
        .new_start = 1,
        .new_count = 6,
        .lines = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), hunk.old_start);
    try std.testing.expectEqual(@as(usize, 5), hunk.old_count);
    try std.testing.expectEqual(@as(usize, 1), hunk.new_start);
    try std.testing.expectEqual(@as(usize, 6), hunk.new_count);
}
