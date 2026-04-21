//! DiffResult - Result container for diff operations with file hunks

const std = @import("std");
const myers = @import("myers.zig");

pub const FileHunk = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []const Hunk,
    is_binary: bool,
    is_new: bool,
    is_deleted: bool,
    is_renamed: bool,
    old_mode: usize,
    new_mode: usize,
};

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []const Line,
};

pub const Line = struct {
    content: []const u8,
    line_type: LineType,
    old_line_num: ?usize,
    new_line_num: ?usize,
};

pub const LineType = enum {
    context,
    addition,
    deletion,
    header,
};

pub const DiffResult = struct {
    allocator: std.mem.Allocator,
    file_hunks: std.ArrayList(FileHunk),
    binary_files: std.ArrayList([]const u8),
    stats: DiffStats,

    pub fn init(allocator: std.mem.Allocator) DiffResult {
        return .{
            .allocator = allocator,
            .file_hunks = std.ArrayList(FileHunk).init(allocator),
            .binary_files = std.ArrayList([]const u8).init(allocator),
            .stats = DiffStats{},
        };
    }

    pub fn deinit(self: *DiffResult) void {
        for (self.file_hunks.items) |hunk| {
            self.allocator.free(hunk.old_path);
            self.allocator.free(hunk.new_path);
            for (hunk.hunks) |h| {
                for (h.lines) |line| {
                    self.allocator.free(line.content);
                }
                self.allocator.free(h.lines);
            }
            self.allocator.free(hunk.hunks);
        }
        self.file_hunks.deinit();

        for (self.binary_files.items) |path| {
            self.allocator.free(path);
        }
        self.binary_files.deinit();
    }

    pub fn addFileHunk(self: *DiffResult, hunk: FileHunk) !void {
        try self.file_hunks.append(hunk);
        self.stats.files_changed += 1;
        if (hunk.is_binary) {
            self.stats.binary_files += 1;
        } else {
            for (hunk.hunks) |h| {
                for (h.lines) |line| {
                    switch (line.line_type) {
                        .addition => self.stats.additions += 1,
                        .deletion => self.stats.deletions += 1,
                        else => {},
                    }
                }
            }
        }
    }

    pub fn addBinaryFile(self: *DiffResult, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.binary_files.append(path_copy);
        self.stats.binary_files += 1;
        self.stats.files_changed += 1;
    }

    pub fn hasChanges(self: *DiffResult) bool {
        return self.file_hunks.items.len > 0 or self.binary_files.items.len > 0;
    }

    pub fn fileCount(self: *DiffResult) usize {
        return self.file_hunks.items.len;
    }

    pub fn binaryCount(self: *DiffResult) usize {
        return self.binary_files.items.len;
    }
};

pub const DiffStats = struct {
    files_changed: usize = 0,
    insertions: usize = 0,
    deletions: usize = 0,
    binary_files: usize = 0,

    pub fn additions(self: *DiffStats) usize {
        return self.insertions;
    }

    pub fn getAdditions(self: *const DiffStats) usize {
        return self.insertions;
    }

    pub fn getDeletions(self: *const DiffStats) usize {
        return self.deletions;
    }

    pub fn totalChanges(self: *const DiffStats) usize {
        return self.insertions + self.deletions;
    }
};

pub const WhitespaceError = struct {
    line_number: usize,
    is_old: bool,
    error_type: WhitespaceErrorType,
    line_content: []const u8,
};

pub const WhitespaceErrorType = enum {
    trailing_whitespace,
    space_before_tab,
    blank_line_at_eof,
    indentation_uses_spaces_only,
    indentation_uses_tabs_only,
    line_ends_with_single_cr,
    line_ends_with_cr_and_lf,
};

pub const WhitespaceReport = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(WhitespaceError),

    pub fn init(allocator: std.mem.Allocator) WhitespaceReport {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(WhitespaceError).init(allocator),
        };
    }

    pub fn deinit(self: *WhitespaceReport) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.line_content);
        }
        self.errors.deinit();
    }

    pub fn addError(self: *WhitespaceReport, err: WhitespaceError) !void {
        const line_copy = try self.allocator.dupe(u8, err.line_content);
        errdefer self.allocator.free(line_copy);
        var mutable_err = err;
        mutable_err.line_content = line_copy;
        try self.errors.append(mutable_err);
    }

    pub fn detectWhitespaceErrors(
        self: *WhitespaceReport,
        lines: []const []const u8,
        is_old: bool,
    ) !void {
        for (lines, 0..) |line, idx| {
            const line_num = idx + 1;
            if (self.containsTrailingWhitespace(line)) {
                try self.addError(.{
                    .line_number = line_num,
                    .is_old = is_old,
                    .error_type = .trailing_whitespace,
                    .line_content = line,
                });
            }
            if (self.containsSpaceBeforeTab(line)) {
                try self.addError(.{
                    .line_number = line_num,
                    .is_old = is_old,
                    .error_type = .space_before_tab,
                    .line_content = line,
                });
            }
            if (self.hasBlankLineAtEndOfFile(lines, idx, line)) {
                try self.addError(.{
                    .line_number = line_num,
                    .is_old = is_old,
                    .error_type = .blank_line_at_eof,
                    .line_content = line,
                });
            }
            if (self.containsInvalidCR(line)) {
                try self.addError(.{
                    .line_number = line_num,
                    .is_old = is_old,
                    .error_type = .line_ends_with_single_cr,
                    .line_content = line,
                });
            }
        }
    }

    fn containsTrailingWhitespace(self: *WhitespaceReport, line: []const u8) bool {
        _ = self;
        if (line.len == 0) return false;
        return line[line.len - 1] == ' ' or line[line.len - 1] == '\t';
    }

    fn containsSpaceBeforeTab(self: *WhitespaceReport, line: []const u8) bool {
        _ = self;
        for (0..line.len - 1) |i| {
            if (line[i] == ' ' and line[i + 1] == '\t') {
                return true;
            }
        }
        return false;
    }

    fn hasBlankLineAtEndOfFile(self: *WhitespaceReport, lines: []const []const u8, idx: usize, line: []const u8) bool {
        _ = self;
        if (idx == lines.len - 1) {
            return line.len == 0;
        }
        return false;
    }

    fn containsInvalidCR(self: *WhitespaceReport, line: []const u8) bool {
        _ = self;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            if (line.len == 1 or (line.len > 1 and line[line.len - 2] != '\r')) {
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const WhitespaceReport) usize {
        return self.errors.items.len;
    }

    pub fn formatReport(self: *WhitespaceReport, writer: anytype) !void {
        if (self.errors.items.len == 0) {
            try writer.writeAll("No whitespace errors found.\n");
            return;
        }

        try writer.print("Whitespace errors:\n", .{});
        for (self.errors.items) |err| {
            const side: []const u8 = if (err.is_old) "old" else "new";
            const error_desc = switch (err.error_type) {
                .trailing_whitespace => "trailing whitespace",
                .space_before_tab => "space before tab",
                .blank_line_at_eof => "blank line at end of file",
                .indentation_uses_spaces_only => "indentation uses spaces only",
                .indentation_uses_tabs_only => "indentation uses tabs only",
                .line_ends_with_single_cr => "line ends with CR",
                .line_ends_with_cr_and_lf => "line ends with CRLF",
            };
            try writer.print("  {s}:{d}: {s}\n", .{ side, err.line_number, error_desc });
        }
    }
};

test "DiffResult init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var result = DiffResult.init(gpa.allocator());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.file_hunks.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.binary_files.items.len);
}

test "DiffResult hasChanges" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var result = DiffResult.init(gpa.allocator());
    defer result.deinit();

    try std.testing.expectEqual(false, result.hasChanges());
}

test "DiffStats defaults" {
    const stats = DiffStats{};
    try std.testing.expectEqual(@as(usize, 0), stats.files_changed);
    try std.testing.expectEqual(@as(usize, 0), stats.insertions);
    try std.testing.expectEqual(@as(usize, 0), stats.deletions);
    try std.testing.expectEqual(@as(usize, 0), stats.binary_files);
}

test "DiffStats totalChanges" {
    var stats = DiffStats{ .insertions = 10, .deletions = 5 };
    try std.testing.expectEqual(@as(usize, 15), stats.totalChanges());
}

test "DiffResult addFileHunk" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var result = DiffResult.init(gpa.allocator());
    defer result.deinit();

    const hunk = FileHunk{
        .old_path = "a.txt",
        .new_path = "a.txt",
        .hunks = &.{},
        .is_binary = false,
        .is_new = false,
        .is_deleted = false,
        .is_renamed = false,
        .old_mode = 0o100644,
        .new_mode = 0o100644,
    };

    try result.addFileHunk(hunk);
    try std.testing.expectEqual(@as(usize, 1), result.fileCount());
    try std.testing.expectEqual(true, result.hasChanges());
}

test "FileHunk structure" {
    const hunk = FileHunk{
        .old_path = "old.txt",
        .new_path = "new.txt",
        .hunks = &.{},
        .is_binary = false,
        .is_new = false,
        .is_deleted = false,
        .is_renamed = false,
        .old_mode = 0o100644,
        .new_mode = 0o100644,
    };

    try std.testing.expectEqualStrings("old.txt", hunk.old_path);
    try std.testing.expectEqualStrings("new.txt", hunk.new_path);
    try std.testing.expectEqual(false, hunk.is_binary);
}

test "Line structure" {
    const line = Line{
        .content = "hello world",
        .line_type = .context,
        .old_line_num = 1,
        .new_line_num = 1,
    };

    try std.testing.expectEqualStrings("hello world", line.content);
    try std.testing.expectEqual(LineType.context, line.line_type);
}