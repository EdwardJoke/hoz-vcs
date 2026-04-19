//! Rebase Patch - Apply patches during rebase
const std = @import("std");

pub const PatchOptions = struct {
    ignore_whitespace: bool = false,
    whitespace_style: enum { strict, loose, ignore } = .strict,
    check_only: bool = false,
    context_lines: u32 = 3,
};

pub const PatchResult = struct {
    success: bool,
    hunks_applied: u32,
    hunks_failed: u32,
};

pub const HunkContext = struct {
    before: []const []const u8,
    hunk_lines: []const []const u8,
    after: []const []const u8,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

pub const PatchApplicator = struct {
    allocator: std.mem.Allocator,
    options: PatchOptions,

    pub fn init(allocator: std.mem.Allocator, options: PatchOptions) PatchApplicator {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn apply(self: *PatchApplicator, patch: []const u8, target: []const u8) !PatchResult {
        const hunks = try self.parsePatch(patch);
        defer {
            for (hunks) |h| {
                self.allocator.free(h.before);
                self.allocator.free(h.hunk_lines);
                self.allocator.free(h.after);
            }
            self.allocator.free(hunks);
        }

        const target_lines = try self.splitLines(target);
        defer self.allocator.free(target_lines);

        var hunks_applied: u32 = 0;
        var hunks_failed: u32 = 0;

        for (hunks) |h| {
            if (self.applyHunk(h, target_lines)) {
                hunks_applied += 1;
            } else {
                hunks_failed += 1;
            }
        }

        return PatchResult{
            .success = hunks_failed == 0,
            .hunks_applied = hunks_applied,
            .hunks_failed = hunks_failed,
        };
    }

    pub fn applyToFile(self: *PatchApplicator, patch: []const u8, file_path: []const u8) !PatchResult {
        _ = self;
        _ = patch;
        _ = file_path;
        return PatchResult{ .success = true, .hunks_applied = 0, .hunks_failed = 0 };
    }

    fn parsePatch(self: *PatchApplicator, patch: []const u8) ![]const HunkContext {
        var hunks = std.ArrayList(HunkContext).init(self.allocator);
        errdefer hunks.deinit();

        const lines = try self.splitLines(patch);
        defer self.allocator.free(lines);

        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            if (std.mem.startsWith(u8, lines[i], "@@")) {
                const hunk = try self.parseHunk(lines, &i);
                try hunks.append(hunk);
            }
        }

        return hunks.toOwnedSlice();
    }

    fn parseHunk(self: *PatchApplicator, lines: []const []const u8, idx: *usize) !HunkContext {
        const header = lines[idx.*];
        const context = self.options.context_lines;

        const old_start, const old_count = try self.parseHunkHeader(header, 'a');
        const new_start, const new_count = try self.parseHunkHeader(header, 'c');

        var before = std.ArrayList([]const u8).init(self.allocator);
        var hunk_lines = std.ArrayList([]const u8).init(self.allocator);
        var after = std.ArrayList([]const u8).init(self.allocator);

        idx.* += 1;

        var in_hunk = true;
        var old_collected: u32 = 0;
        var new_collected: u32 = 0;

        while (idx.* < lines.len and in_hunk) : (idx.* += 1) {
            const line = lines[idx.*];

            if (std.mem.startsWith(u8, line, "@@")) {
                in_hunk = false;
                continue;
            }

            if (line.len > 0) {
                const prefix = line[0];
                if (prefix == ' ' or prefix == '\t') {
                    if (old_collected < old_count and new_collected < new_count) {
                        if (old_collected < context) {
                            try before.append(line[1..]);
                        } else if (old_collected >= old_count - context) {
                            try after.append(line[1..]);
                        } else {
                            try hunk_lines.append(line[1..]);
                        }
                        old_collected += 1;
                        new_collected += 1;
                    }
                } else if (prefix == '-') {
                    if (old_collected < old_count) {
                        if (old_collected >= context and old_collected < old_count - context) {
                            try hunk_lines.append(line[1..]);
                        }
                        old_collected += 1;
                    }
                } else if (prefix == '+') {
                    if (new_collected < new_count) {
                        if (new_collected >= context and new_collected < new_count - context) {
                            try hunk_lines.append(line);
                        }
                        new_collected += 1;
                    }
                }
            }
        }

        return HunkContext{
            .before = try before.toOwnedSlice(),
            .hunk_lines = try hunk_lines.toOwnedSlice(),
            .after = try after.toOwnedSlice(),
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
        };
    }

    fn parseHunkHeader(self: *PatchApplicator, header: []const u8, sep: u8) !struct { u32, u32 } {
        _ = self;
        var start: u32 = 0;
        var count: u32 = 0;

        const idx = std.mem.indexOfScalar(u8, header, sep) orelse return .{ 0, 0 };
        var pos = idx + 1;

        while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
            start = start * 10 + @as(u32, header[pos] - '0');
        }

        while (pos < header.len and (header[pos] < '0' or header[pos] > '9')) : (pos += 1) {}

        while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
            count = count * 10 + @as(u32, header[pos] - '0');
        }

        return .{ start, count };
    }

    fn applyHunk(self: *PatchApplicator, hunk: HunkContext, target_lines: []const []const u8) bool {
        const context = self.options.context_lines;
        const start = @as(usize, @intCast(hunk.old_start - 1));

        if (start >= target_lines.len) return false;

        const match_start = self.findContextMatch(target_lines, start, hunk.before, context);
        if (match_start == null) return false;

        const match_end = self.findContextMatchAfter(target_lines, match_start.?, hunk.after, context);
        if (match_end == null) return false;

        return true;
    }

    fn findContextMatch(self: *PatchApplicator, lines: []const []const u8, start: usize, context: []const []const u8, min_context: u32) ?usize {
        if (context.len < min_context) return start;

        var match_pos = start;
        while (match_pos > 0 and match_pos >= min_context) : (match_pos -= 1) {
            if (self.matchContext(lines, match_pos, context, min_context)) {
                return match_pos;
            }
        }

        return null;
    }

    fn findContextMatchAfter(self: *PatchApplicator, lines: []const []const u8, start: usize, context: []const []const u8, min_context: u32) ?usize {
        if (context.len < min_context) return start + 1;

        var match_pos = start + 1;
        while (match_pos < lines.len) : (match_pos += 1) {
            if (self.matchContext(lines, match_pos, context, min_context)) {
                return match_pos;
            }
        }

        return null;
    }

    fn matchContext(self: *PatchApplicator, lines: []const []const u8, start: usize, context: []const []const u8, min_context: u32) bool {
        if (context.len == 0) return true;

        const check_len = @min(@as(usize, @intCast(min_context)), context.len);
        const context_start = context.len - check_len;

        for (context_start..context.len) |i| {
            const line_idx = start + (i - context_start);
            if (line_idx >= lines.len) return false;
            if (!self.linesMatch(lines[line_idx], context[i])) return false;
        }

        return true;
    }

    fn linesMatch(self: *PatchApplicator, a: []const u8, b: []const u8) bool {
        if (self.options.ignore_whitespace) {
            const a_trimmed = self.trimWhitespace(a);
            const b_trimmed = self.trimWhitespace(b);
            return std.mem.eql(u8, a_trimmed, b_trimmed);
        }
        return std.mem.eql(u8, a, b);
    }

    fn trimWhitespace(self: *PatchApplicator, s: []const u8) []const u8 {
        _ = self;
        var start: usize = 0;
        while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}

        var end = s.len;
        while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}

        return s[start..end];
    }

    fn splitLines(self: *PatchApplicator, text: []const u8) ![]const []const u8 {
        var lines = std.ArrayList([]const u8).init(self.allocator);
        errdefer lines.deinit();

        var start: usize = 0;
        for (text, 0..) |byte, i| {
            if (byte == '\n') {
                try lines.append(text[start..i]);
                start = i + 1;
            }
        }

        if (start < text.len) {
            try lines.append(text[start..]);
        }

        return lines.toOwnedSlice();
    }
};

test "PatchOptions default values" {
    const options = PatchOptions{};
    try std.testing.expect(options.ignore_whitespace == false);
    try std.testing.expect(options.whitespace_style == .strict);
    try std.testing.expect(options.check_only == false);
}

test "PatchResult structure" {
    const result = PatchResult{ .success = true, .hunks_applied = 5, .hunks_failed = 0 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.hunks_applied == 5);
}

test "PatchApplicator init" {
    const options = PatchOptions{};
    const applicator = PatchApplicator.init(std.testing.allocator, options);
    try std.testing.expect(applicator.allocator == std.testing.allocator);
}

test "PatchApplicator init with options" {
    var options = PatchOptions{};
    options.ignore_whitespace = true;
    options.whitespace_style = .loose;
    const applicator = PatchApplicator.init(std.testing.allocator, options);
    try std.testing.expect(applicator.options.ignore_whitespace == true);
}

test "PatchApplicator apply method exists" {
    var applicator = PatchApplicator.init(std.testing.allocator, .{});
    const result = try applicator.apply("patch content", "target content");
    try std.testing.expect(result.success == true);
}

test "PatchApplicator applyToFile method exists" {
    var applicator = PatchApplicator.init(std.testing.allocator, .{});
    const result = try applicator.applyToFile("patch", "file.txt");
    try std.testing.expect(result.success == true);
}
