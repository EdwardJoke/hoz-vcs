//! DiffIgnore - Handle --ignore options for diff operations

const std = @import("std");

pub const IgnoreFilter = struct {
    ignore_whitespace_changes: bool = false,
    ignore_blank_lines: bool = false,
    ignore_space_at_eol: bool = false,
    ignore_space_change: bool = false,
    ignore_all_space: bool = false,
    ignore_case: bool = false,

    pub fn init() IgnoreFilter {
        return .{};
    }

    pub fn apply(self: *const IgnoreFilter, old_line: []const u8, new_line: []const u8) bool {
        if (self.ignore_all_space) {
            return self.strippedEqual(old_line, new_line);
        }
        if (self.ignore_whitespace_changes) {
            return self.trimEqual(old_line, new_line);
        }
        if (self.ignore_space_at_eol) {
            return self.trimEolEqual(old_line, new_line);
        }
        if (self.ignore_blank_lines) {
            return self.isBlankLine(old_line) and self.isBlankLine(new_line);
        }
        if (self.ignore_case) {
            return self.caseInsensitiveEqual(old_line, new_line);
        }
        if (self.ignore_space_change) {
            return self.collapseSpaceEqual(old_line, new_line);
        }
        return false;
    }

    fn strippedEqual(self: *const IgnoreFilter, a: []const u8, b: []const u8) bool {
        const stripped_a = self.stripWhitespace(a);
        const stripped_b = self.stripWhitespace(b);
        return std.mem.eql(u8, stripped_a, stripped_b);
    }

    fn trimEqual(self: *const IgnoreFilter, a: []const u8, b: []const u8) bool {
        _ = self;
        const trimmed_a = trimSpaces(a);
        const trimmed_b = trimSpaces(b);
        return std.mem.eql(u8, trimmed_a, trimmed_b);
    }

    fn trimEolEqual(self: *const IgnoreFilter, a: []const u8, b: []const u8) bool {
        _ = self;
        const trimmed_a = trimTrailingSpaces(a);
        const trimmed_b = trimTrailingSpaces(b);
        return std.mem.eql(u8, trimmed_a, trimmed_b);
    }

    fn isBlankLine(self: *const IgnoreFilter, line: []const u8) bool {
        _ = self;
        for (line) |byte| {
            if (byte != ' ' and byte != '\t' and byte != '\n' and byte != '\r') {
                return false;
            }
        }
        return true;
    }

    fn caseInsensitiveEqual(self: *const IgnoreFilter, a: []const u8, b: []const u8) bool {
        _ = self;
        if (a.len != b.len) return false;
        for (a, b) |char_a, char_b| {
            if (std.ascii.toLower(char_a) != std.ascii.toLower(char_b)) {
                return false;
            }
        }
        return true;
    }

    fn collapseSpaceEqual(self: *const IgnoreFilter, a: []const u8, b: []const u8) bool {
        _ = self;
        const max_len = @max(a.len, b.len);
        if (max_len <= 4096) {
            var buf_a: [4096]u8 = undefined;
            var buf_b: [4096]u8 = undefined;
            const collapsed_a = collapseSpacesInto(a, &buf_a);
            const collapsed_b = collapseSpacesInto(b, &buf_b);
            return std.mem.eql(u8, collapsed_a, collapsed_b);
        }
        var heap_buf_a = std.ArrayList(u8).initCapacity(std.heap.page_allocator, a.len) catch return false;
        defer heap_buf_a.deinit();
        var heap_buf_b = std.ArrayList(u8).initCapacity(std.heap.page_allocator, b.len) catch return false;
        defer heap_buf_b.deinit();
        const collapsed_a = collapseSpacesIntoHeap(a, &heap_buf_a);
        const collapsed_b = collapseSpacesIntoHeap(b, &heap_buf_b);
        return std.mem.eql(u8, collapsed_a, collapsed_b);
    }

    fn collapseSpacesInto(str: []const u8, buf: []u8) []u8 {
        var in_space = false;
        var write_idx: usize = 0;
        for (str) |c| {
            if (write_idx >= buf.len) break;
            if (c == ' ' or c == '\t') {
                if (!in_space) {
                    buf[write_idx] = ' ';
                    write_idx += 1;
                    in_space = true;
                }
            } else {
                buf[write_idx] = c;
                write_idx += 1;
                in_space = false;
            }
        }
        return buf[0..write_idx];
    }

    fn collapseSpacesIntoHeap(str: []const u8, list: *std.ArrayList(u8)) []u8 {
        var in_space = false;
        list.items.len = 0;
        for (str) |c| {
            if (c == ' ' or c == '\t') {
                if (!in_space) {
                    list.append(' ') catch break;
                    in_space = true;
                }
            } else {
                list.append(c) catch break;
                in_space = false;
            }
        }
        return list.items;
    }

    fn stripWhitespace(self: *const IgnoreFilter, str: []const u8) []const u8 {
        _ = self;
        var start: usize = 0;
        var end: usize = str.len;

        while (start < end and (str[start] == ' ' or str[start] == '\t')) start += 1;
        while (end > start and (str[end - 1] == ' ' or str[end - 1] == '\t')) end -= 1;

        return str[start..end];
    }

    fn trimSpaces(str: []const u8) []const u8 {
        var start: usize = 0;
        var end: usize = str.len;

        while (start < end and (str[start] == ' ' or str[start] == '\t' or str[start] == '\n' or str[start] == '\r')) start += 1;
        while (end > start and (str[end - 1] == ' ' or str[end - 1] == '\t' or str[end - 1] == '\n' or str[end - 1] == '\r')) end -= 1;

        return str[start..end];
    }

    fn trimTrailingSpaces(str: []const u8) []const u8 {
        var end = str.len;
        while (end > 0 and (str[end - 1] == ' ' or str[end - 1] == '\t')) end -= 1;
        return str[0..end];
    }

    pub fn setIgnoreWhitespaceChanges(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_whitespace_changes = ignore;
    }

    pub fn setIgnoreBlankLines(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_blank_lines = ignore;
    }

    pub fn setIgnoreSpaceAtEol(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_space_at_eol = ignore;
    }

    pub fn setIgnoreSpaceChange(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_space_change = ignore;
    }

    pub fn setIgnoreAllSpace(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_all_space = ignore;
    }

    pub fn setIgnoreCase(self: *IgnoreFilter, ignore: bool) void {
        self.ignore_case = ignore;
    }
};

pub const GitIgnore = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) GitIgnore {
        return .{
            .allocator = allocator,
            .patterns = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit();
    }

    pub fn shouldIgnore(self: *GitIgnore, path: []const u8) bool {
        var ignored = false;
        for (self.patterns.items) |pattern| {
            const is_negation = std.mem.startsWith(u8, pattern, "!");
            if (is_negation) {
                const inner = pattern[1..];
                if (self.matchPatternInner(inner, path)) {
                    ignored = false;
                }
            } else {
                if (self.matchPattern(pattern, path)) {
                    ignored = true;
                }
            }
        }
        return ignored;
    }

    pub fn checkIgnore(self: *GitIgnore, path: []const u8) ?[]const u8 {
        for (self.patterns.items) |pattern| {
            if (self.matchPattern(pattern, path)) {
                return pattern;
            }
        }
        return null;
    }

    pub fn checkIgnoreRecursive(self: *GitIgnore, path: []const u8) ?[]const u8 {
        var current_path: []const u8 = path;
        while (true) {
            if (self.checkIgnore(current_path)) |pattern| {
                return pattern;
            }
            const last_slash = std.mem.lastIndexOfScalar(u8, current_path, '/');
            if (last_slash == null) break;
            current_path = current_path[0..last_slash.?];
        }
        return null;
    }

    pub fn addIgnoreRule(self: *GitIgnore, pattern: []const u8) !void {
        const owned = try self.allocator.dupe(u8, pattern);
        try self.patterns.append(owned);
    }

    pub fn removeIgnoreRule(self: *GitIgnore, pattern: []const u8) bool {
        for (self.patterns.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, pattern)) {
                self.allocator.free(p);
                _ = self.patterns.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn matchPattern(self: *GitIgnore, pattern: []const u8, path: []const u8) bool {
        return self.matchPatternInner(pattern, path);
    }

    fn matchPatternInner(self: *GitIgnore, pattern: []const u8, path: []const u8) bool {
        _ = self;
        if (std.mem.endsWith(u8, pattern, "/")) {
            const dir_pattern = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, path, dir_pattern) or std.mem.eql(u8, path, dir_pattern);
        }

        if (std.mem.startsWith(u8, pattern, "**/")) {
            const suffix = pattern[3..];
            return std.mem.endsWith(u8, path, suffix) or std.mem.indexOf(u8, path, suffix) != null;
        }

        if (std.mem.endsWith(u8, pattern, "/**")) {
            const prefix = pattern[0 .. pattern.len - 3];
            return std.mem.startsWith(u8, path, prefix);
        }

        if (std.mem.startsWith(u8, pattern, "*")) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, path, suffix);
        }

        if (std.mem.endsWith(u8, pattern, "*")) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, path, prefix);
        }

        if (std.mem.indexOf(u8, pattern, "*")) |star_idx| {
            const prefix = pattern[0..star_idx];
            const suffix = pattern[star_idx + 1 ..];
            return std.mem.startsWith(u8, path, prefix) and std.mem.endsWith(u8, path, suffix);
        }

        const basename = if (std.mem.lastIndexOf(u8, path, "/")) |idx| path[idx + 1 ..] else path;
        return std.mem.eql(u8, path, pattern) or std.mem.eql(u8, basename, pattern);
    }
};

test "IgnoreFilter init" {
    const filter = IgnoreFilter.init();
    try std.testing.expectEqual(false, filter.ignore_whitespace_changes);
    try std.testing.expectEqual(false, filter.ignore_blank_lines);
    try std.testing.expectEqual(false, filter.ignore_space_at_eol);
}

test "IgnoreFilter ignore_all_space" {
    var filter = IgnoreFilter.init();
    try std.testing.expectEqual(false, filter.apply("hello   world", "hello world"));
    filter.setIgnoreAllSpace(true);
    try std.testing.expectEqual(true, filter.apply("hello   world", "hello world"));
    try std.testing.expectEqual(false, filter.apply("hello world", "hello  world"));
}

test "IgnoreFilter ignore_blank_lines" {
    var filter = IgnoreFilter.init();
    filter.setIgnoreBlankLines(true);
    try std.testing.expectEqual(true, filter.apply("   ", ""));
    try std.testing.expectEqual(false, filter.apply("content", "content"));
}

test "IgnoreFilter ignore_space_at_eol" {
    var filter = IgnoreFilter.init();
    filter.setIgnoreSpaceAtEol(true);
    try std.testing.expectEqual(true, filter.apply("hello   ", "hello"));
    try std.testing.expectEqual(true, filter.apply("hello\t", "hello"));
    try std.testing.expectEqual(false, filter.apply("hello ", "world"));
}

test "IgnoreFilter case_insensitive" {
    var filter = IgnoreFilter.init();
    filter.setIgnoreCase(true);
    try std.testing.expectEqual(true, filter.apply("HELLO", "hello"));
    try std.testing.expectEqual(true, filter.apply("Hello World", "hello world"));
    try std.testing.expectEqual(false, filter.apply("hello", "world"));
}

test "IgnoreFilter trimTrailingSpaces" {
    const result = IgnoreFilter.trimTrailingSpaces("hello   ");
    try std.testing.expectEqualStrings("hello", result);
}

test "IgnoreFilter isBlankLine" {
    var filter = IgnoreFilter.init();
    try std.testing.expectEqual(true, filter.isBlankLine("   \t  \n"));
    try std.testing.expectEqual(true, filter.isBlankLine(""));
    try std.testing.expectEqual(false, filter.isBlankLine("content"));
}
