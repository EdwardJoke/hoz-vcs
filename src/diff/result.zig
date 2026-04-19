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