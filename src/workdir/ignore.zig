//! .gitignore processing for Hoz VCS
//!
//! This module provides .gitignore pattern matching and file filtering
//! to determine which files should be ignored by version control.

const std = @import("std");
const Io = std.Io;

pub const Pattern = struct {
    pattern: []const u8,
    is_negated: bool,
    is_directory_only: bool,
    raw_pattern: []const u8,
};

pub const GitIgnoreError = error{
    PatternInvalid,
    IoError,
};

pub fn parsePattern(line: []const u8) !Pattern {
    if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
        return Pattern{
            .pattern = line,
            .is_negated = false,
            .is_directory_only = false,
            .raw_pattern = line,
        };
    }

    var is_negated = false;
    var pattern = line;

    if (std.mem.startsWith(u8, line, "\\!")) {
        is_negated = true;
        pattern = line[2..];
    } else if (std.mem.startsWith(u8, line, "#")) {
        return Pattern{
            .pattern = line,
            .is_negated = false,
            .is_directory_only = false,
            .raw_pattern = line,
        };
    }

    var is_directory_only = false;
    if (std.mem.endsWith(u8, pattern, "/")) {
        is_directory_only = true;
        pattern = pattern[0 .. pattern.len - 1];
    }

    return .{
        .pattern = pattern,
        .is_negated = is_negated,
        .is_directory_only = is_directory_only,
        .raw_pattern = line,
    };
}

pub fn matchesPattern(pattern: Pattern, path: []const u8, is_dir: bool) bool {
    if (pattern.raw_pattern.len == 0 or std.mem.startsWith(u8, pattern.raw_pattern, "#")) {
        return false;
    }

    if (pattern.is_directory_only and !is_dir) {
        return false;
    }

    return matchesGlob(pattern.pattern, path);
}

fn matchesGlob(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**") != null) {
        return matchesDoubleStar(pattern, path);
    }

    if (std.mem.indexOf(u8, pattern, "*") != null) {
        return matchesWildcard(pattern, path);
    }

    return std.mem.eql(u8, pattern, path) or
        std.mem.endsWith(u8, path, pattern);
}

fn matchesDoubleStar(pattern: []const u8, path: []const u8) bool {
    var pattern_parts = std.mem.splitScalar(u8, pattern, '*');
    const first_part = pattern_parts.first();

    if (first_part.len > 0 and !std.mem.startsWith(u8, path, first_part)) {
        return false;
    }

    return true;
}

fn matchesWildcard(pattern: []const u8, path: []const u8) bool {
    const asterisk_idx = std.mem.indexOf(u8, pattern, "*");
    if (asterisk_idx == null) {
        return std.mem.eql(u8, pattern, path);
    }

    const prefix = pattern[0..asterisk_idx.?];
    const suffix = pattern[asterisk_idx.? + 1 ..];

    if (prefix.len > 0 and !std.mem.startsWith(u8, path, prefix)) {
        return false;
    }

    if (suffix.len > 0 and !std.mem.endsWith(u8, path, suffix)) {
        return false;
    }

    return true;
}

pub fn loadGitIgnore(
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
) ![]Pattern {
    const dir = Io.Dir.cwd();
    const file = dir.openFile(io.*, path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        }
    };
    defer file.close(io.*);

    const stat = try file.stat(io.*);
    const size = @as(usize, @intCast(stat.size));

    const buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    var file_reader = file.reader(io.*, buffer);
    try file_reader.interface.readSliceAll(buffer);

    var patterns = std.ArrayList(Pattern).empty;
    errdefer patterns.deinit(allocator);

    var lines = std.mem.splitScalar(u8, buffer, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len > 0) {
            const pattern = try parsePattern(trimmed);
            try patterns.append(allocator, pattern);
        }
    }

    return try patterns.toOwnedSlice(allocator);
}

pub fn isIgnored(
    patterns: []Pattern,
    path: []const u8,
    is_dir: bool,
) bool {
    var ignored = false;

    for (patterns) |pattern| {
        if (pattern.raw_pattern.len == 0 or std.mem.startsWith(u8, pattern.raw_pattern, "#")) {
            continue;
        }

        if (matchesPattern(pattern, path, is_dir)) {
            ignored = !pattern.is_negated;
        }
    }

    return ignored;
}

pub fn isIgnoredWithPrecedence(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    path: []const u8,
    is_dir: bool,
) !bool {
    var patterns = std.ArrayList(Pattern).init(alloc);
    defer patterns.deinit();

    var current_dir = try alloc.dupe(u8, dir_path);
    defer alloc.free(current_dir);

    while (true) {
        const gitignore_path = if (current_dir.len == 0)
            try std.fmt.concat(alloc, &.{".gitignore"})
        else
            try std.fmt.concat(alloc, &.{ current_dir, "/.gitignore" });

        if (std.fs.cwd().openFile(gitignore_path, .{})) |file| {
            defer file.close();
            var reader = file.reader();
            var buf: [4096]u8 = undefined;
            while (reader.readUntilDelimiter(&buf, '\n')) |line| {
                const trimmed = std.mem.trim(u8, line, "\r");
                if (trimmed.len > 0) {
                    const pattern = try parsePattern(trimmed);
                    try patterns.append(pattern);
                }
            } else |_| {}
        } else |_| {}

        const last_sep = std.mem.lastIndexOfScalar(u8, current_dir, '/');
        if (last_sep == null) break;
        const parent = current_dir[0..last_sep.?];
        alloc.free(current_dir);
        current_dir = try alloc.dupe(u8, parent);
    }

    const workdir_relative = if (std.mem.startsWith(u8, path, dir_path))
        path[dir_path.len + 1 ..]
    else
        path;

    return isIgnored(patterns.items, workdir_relative, is_dir);
}

test "parsePattern parses regular pattern" {
    const pattern = try parsePattern("*.txt");
    try std.testing.expectEqualStrings("*.txt", pattern.pattern);
    try std.testing.expect(!pattern.is_negated);
    try std.testing.expect(!pattern.is_directory_only);
}

test "parsePattern parses negated pattern" {
    const pattern = try parsePattern("!important.txt");
    try std.testing.expectEqualStrings("important.txt", pattern.pattern);
    try std.testing.expect(pattern.is_negated);
}

test "parsePattern parses directory-only pattern" {
    const pattern = try parsePattern("build/");
    try std.testing.expectEqualStrings("build", pattern.pattern);
    try std.testing.expect(pattern.is_directory_only);
}

test "parsePattern handles empty line" {
    const pattern = try parsePattern("");
    try std.testing.expectEqualStrings("", pattern.pattern);
}

test "parsePattern handles comment" {
    const pattern = try parsePattern("# This is a comment");
    try std.testing.expectEqualStrings("# This is a comment", pattern.pattern);
}

test "matchesPattern matches simple pattern" {
    const pattern = try parsePattern("*.txt");
    try std.testing.expect(matchesPattern(pattern, "file.txt", false));
    try std.testing.expect(!matchesPattern(pattern, "file.md", false));
}

test "matchesPattern respects directory-only flag" {
    const pattern = try parsePattern("build/");
    try std.testing.expect(matchesPattern(pattern, "build", true));
    try std.testing.expect(!matchesPattern(pattern, "build", false));
}

test "matchesGlob handles wildcard" {
    try std.testing.expect(matchesGlob("*.txt", "file.txt"));
    try std.testing.expect(matchesGlob("test*", "test_file"));
    try std.testing.expect(!matchesGlob("*.txt", "file.md"));
}

test "isIgnored returns correct ignored status" {
    const patterns = &.{
        try parsePattern("*.txt"),
        try parsePattern("!important.txt"),
    };

    try std.testing.expect(isIgnored(patterns, "file.txt", false));
    try std.testing.expect(!isIgnored(patterns, "important.txt", false));
    try std.testing.expect(!isIgnored(patterns, "file.md", false));
}

test "isIgnored returns false for empty patterns" {
    const patterns: []Pattern = &.{};
    try std.testing.expect(!isIgnored(patterns, "file.txt", false));
}

test "parsePattern handles escaped negation" {
    const pattern = try parsePattern("\\!important.txt");
    try std.testing.expectEqualStrings("!important.txt", pattern.pattern);
    try std.testing.expect(!pattern.is_negated);
}

test "matchesPattern matches directory" {
    const pattern = try parsePattern("build/");
    try std.testing.expect(matchesPattern(pattern, "build/some/path", true));
}

test "matchesGlob matches wildcard at start" {
    try std.testing.expect(matchesGlob("*.log", "debug.log"));
    try std.testing.expect(!matchesGlob("*.log", "debug.txt"));
}

test "matchesGlob matches wildcard at end" {
    try std.testing.expect(matchesGlob("file.*", "file.txt"));
    try std.testing.expect(!matchesGlob("file.*", "other.txt"));
}

test "matchesGlob handles double star pattern" {
    try std.testing.expect(matchesGlob("**", "any/path/file.txt"));
}

test "isIgnored handles multiple patterns" {
    const patterns = &.{
        try parsePattern("*.o"),
        try parsePattern("*.tmp"),
        try parsePattern("build/"),
    };

    try std.testing.expect(isIgnored(patterns, "file.o", false));
    try std.testing.expect(isIgnored(patterns, "file.tmp", false));
    try std.testing.expect(isIgnored(patterns, "build/output", true));
    try std.testing.expect(!isIgnored(patterns, "file.c", false));
}
