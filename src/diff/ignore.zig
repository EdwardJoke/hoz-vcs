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