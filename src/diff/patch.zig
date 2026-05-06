//! PatchFormat - Generate patch format for diff output

const std = @import("std");
const Io = std.Io;
const myers = @import("myers.zig");
const unified = @import("unified.zig");

pub const PatchFormat = struct {
    allocator: std.mem.Allocator,
    strip_level: usize = 0,
    include_headers: bool = true,
    include_context: bool = true,
    add_prefix: []const u8 = "a/",
    remove_prefix: []const u8 = "b/",

    pub fn init(allocator: std.mem.Allocator) PatchFormat {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PatchFormat) void {
        _ = self;
    }

    pub fn generatePatch(
        self: *PatchFormat,
        writer: *Io.Writer,
        old_path: []const u8,
        new_path: []const u8,
        old_lines: []const []const u8,
        new_lines: []const []const u8,
        edits: []const myers.Edit,
    ) !void {
        var display_old = old_path;
        var display_new = new_path;

        if (self.strip_level > 0) {
            display_old = self.stripPath(old_path);
            display_new = self.stripPath(new_path);
        }

        if (self.include_headers) {
            try writer.print("diff --git {s}{s} {s}{s}\n", .{ self.remove_prefix, display_old, self.add_prefix, display_new });
            try writer.print("--- {s}{s}\n", .{ self.remove_prefix, display_old });
            try writer.print("+++ {s}{s}\n", .{ self.add_prefix, display_new });
        }

        var unified_diff = unified.UnifiedDiff.init(self.allocator);
        try unified_diff.formatUnified(writer, display_old, display_new, old_lines, new_lines, edits);
    }

    fn stripPath(self: *const PatchFormat, path: []const u8) []const u8 {
        var count = self.strip_level;
        var start: usize = 0;

        while (count > 0 and start < path.len) {
            if (path[start] == '/') {
                count -= 1;
            }
            start += 1;
        }

        while (start < path.len and path[start] == '/') start += 1;

        if (start >= path.len) return path;
        return path[start..];
    }

    pub fn generatePatchHeader(
        self: *PatchFormat,
        writer: *Io.Writer,
        old_path: []const u8,
        new_path: []const u8,
        old_mode: usize,
        new_mode: usize,
        is_new: bool,
        is_deleted: bool,
        is_renamed: bool,
    ) !void {
        try writer.print("diff --git {s}{s} {s}{s}\n", .{ self.remove_prefix, old_path, self.add_prefix, new_path });

        if (is_new) {
            try writer.print("new file mode {o}\n", .{new_mode});
        } else if (is_deleted) {
            try writer.print("deleted file mode {o}\n", .{old_mode});
        } else if (old_mode != new_mode) {
            try writer.print("old mode {o}\n", .{old_mode});
            try writer.print("new mode {o}\n", .{new_mode});
        }

        if (is_renamed) {
            try writer.print("rename from {s}\n", .{old_path});
            try writer.print("rename to {s}\n", .{new_path});
        }

        if (is_new or is_renamed) {
            try writer.print("--- /dev/null\n");
        } else {
            try writer.print("--- {s}{s}\n", .{ self.remove_prefix, old_path });
        }

        if (is_deleted or is_renamed) {
            try writer.print("+++ /dev/null\n");
        } else {
            try writer.print("+++ {s}{s}\n", .{ self.add_prefix, new_path });
        }
    }

    pub fn generateStatLine(
        self: *PatchFormat,
        writer: *Io.Writer,
        path: []const u8,
        insertions: usize,
        deletions: usize,
    ) !void {
        _ = self;
        const width: usize = 60;
        const path_len = @min(path.len, 40);
        const padding = if (width > path_len + 10) width - path_len - 10 else 0;

        try writer.print(" {s}", .{path[0..path_len]});
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try writer.print(" ", .{});
        }

        if (insertions > 0) {
            try writer.print("\x1b[32m", .{});
            var j: usize = 0;
            while (j < @min(insertions, 20)) : (j += 1) {
                try writer.print("+", .{});
            }
            try writer.print("\x1b[0m", .{});
        }

        if (deletions > 0) {
            try writer.print("\x1b[31m", .{});
            var j: usize = 0;
            while (j < @min(deletions, 20)) : (j += 1) {
                try writer.print("-", .{});
            }
            try writer.print("\x1b[0m", .{});
        }

        try writer.print("\n", .{});
    }

    pub const ApplyResult = struct {
        success: bool,
        content: []const u8,
        hunks_applied: u32,
        hunks_failed: u32,
    };

    pub fn apply(
        self: *PatchFormat,
        patch_content: []const u8,
        target_content: []const u8,
    ) !ApplyResult {
        const hunks = try self.parseHunks(patch_content);
        defer {
            for (hunks) |h| {
                self.allocator.free(h.lines);
            }
            self.allocator.free(hunks);
        }

        const target_lines = try self.splitLines(target_content);
        defer self.allocator.free(target_lines);

        var result_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer result_lines.deinit(self.allocator);

        var hunks_applied: u32 = 0;
        var hunks_failed: u32 = 0;
        var current_line: usize = 0;

        for (hunks) |hunk| {
            const match_pos = self.findHunkStart(target_lines, current_line, hunk.old_start);
            if (match_pos) |pos| {
                while (current_line < pos) : (current_line += 1) {
                    try result_lines.append(self.allocator, target_lines[current_line]);
                }
                const applied = try self.applyHunk(&result_lines, target_lines, &current_line, hunk);
                if (applied) {
                    hunks_applied += 1;
                } else {
                    hunks_failed += 1;
                }
            } else {
                hunks_failed += 1;
            }
        }

        while (current_line < target_lines.len) : (current_line += 1) {
            try result_lines.append(self.allocator, target_lines[current_line]);
        }

        var result_buf = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        for (result_lines.items) |line| {
            try result_buf.appendSlice(self.allocator, line);
            try result_buf.append(self.allocator, '\n');
        }

        return ApplyResult{
            .success = hunks_failed == 0,
            .content = try result_buf.toOwnedSlice(self.allocator),
            .hunks_applied = hunks_applied,
            .hunks_failed = hunks_failed,
        };
    }

    const Hunk = struct {
        old_start: u32,
        old_count: u32,
        new_start: u32,
        new_count: u32,
        lines: []const HunkLine,
    };

    const HunkLine = struct {
        const Kind = enum { context, add, remove };
        kind: Kind,
        content: []const u8,
    };

    fn parseHunks(self: *PatchFormat, patch: []const u8) ![]const Hunk {
        var hunks = std.ArrayListUnmanaged(Hunk).empty;
        errdefer hunks.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, patch, '\n');
        var current_lines = try std.ArrayList(HunkLine).initCapacity(self.allocator, 0);
        defer current_lines.deinit(self.allocator);

        var current_header: ?Hunk = null;

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "@@")) {
                if (current_header) |*hdr| {
                    hdr.lines = try current_lines.toOwnedSlice(self.allocator);
                    try hunks.append(self.allocator, hdr.*);
                }
                current_header = try self.parseHunkHeader(line);
                current_lines.clearAndFree(self.allocator);
            } else if (current_header != null) {
                if (line.len == 0) {
                    try current_lines.append(self.allocator, .{ .kind = .context, .content = "" });
                } else if (line[0] == ' ' or line[0] == '-' or line[0] == '+') {
                    const kind: HunkLine.Kind = switch (line[0]) {
                        ' ' => .context,
                        '-' => .remove,
                        '+' => .add,
                        else => .context,
                    };
                    try current_lines.append(self.allocator, .{
                        .kind = kind,
                        .content = if (line.len > 1) line[1..] else "",
                    });
                } else if (std.mem.startsWith(u8, line, "\\ ") or std.mem.startsWith(u8, line, "\\")) {
                    try current_lines.append(self.allocator, .{ .kind = .context, .content = line });
                }
            }
        }

        if (current_header) |*hdr| {
            hdr.lines = try current_lines.toOwnedSlice(self.allocator);
            try hunks.append(self.allocator, hdr.*);
        }

        return hunks.toOwnedSlice(self.allocator);
    }

    fn parseHunkHeader(_: *PatchFormat, header: []const u8) !Hunk {
        var old_start: u32 = 0;
        var old_count: u32 = 1;
        var new_start: u32 = 0;
        var new_count: u32 = 1;

        const minus_idx = std.mem.indexOfScalar(u8, header, '-') orelse return Hunk{
            .old_start = 0,
            .old_count = 0,
            .new_start = 0,
            .new_count = 0,
            .lines = &.{},
        };
        const plus_idx = std.mem.indexOfScalar(u8, header, '+') orelse return Hunk{
            .old_start = 0,
            .old_count = 0,
            .new_start = 0,
            .new_count = 0,
            .lines = &.{},
        };

        var pos = minus_idx + 1;
        while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
            old_start = old_start * 10 + @as(u32, header[pos] - '0');
        }
        if (pos < header.len and header[pos] == ',') {
            pos += 1;
            old_count = 0;
            while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
                old_count = old_count * 10 + @as(u32, header[pos] - '0');
            }
        }

        pos = plus_idx + 1;
        while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
            new_start = new_start * 10 + @as(u32, header[pos] - '0');
        }
        if (pos < header.len and header[pos] == ',') {
            pos += 1;
            new_count = 0;
            while (pos < header.len and header[pos] >= '0' and header[pos] <= '9') : (pos += 1) {
                new_count = new_count * 10 + @as(u32, header[pos] - '0');
            }
        }

        return Hunk{
            .old_start = old_start,
            .old_count = old_count,
            .new_start = new_start,
            .new_count = new_count,
            .lines = &.{},
        };
    }

    fn findHunkStart(self: *PatchFormat, lines: []const []const u8, start: usize, target_line: u32) ?usize {
        _ = self;
        const target = @as(usize, @intCast(target_line)) -| 1;
        if (target >= lines.len) {
            if (start < lines.len) return start;
            return null;
        }
        return target;
    }

    fn applyHunk(
        self: *PatchFormat,
        result: *std.ArrayList([]const u8),
        target: []const []const u8,
        current: *usize,
        hunk: Hunk,
    ) !bool {
        var context_idx: usize = 0;
        const context_lines = try self.collectContextLines(hunk);
        defer self.allocator.free(context_lines);

        for (hunk.lines) |hunk_line| {
            switch (hunk_line.kind) {
                .context => {
                    if (current.* >= target.len) return false;
                    if (context_idx < context_lines.len and
                        !std.mem.eql(u8, target[current.*], context_lines[context_idx]))
                    {
                        return false;
                    }
                    try result.append(self.allocator, target[current.*]);
                    current.* += 1;
                    context_idx += 1;
                },
                .remove => {
                    if (current.* >= target.len) return false;
                    current.* += 1;
                },
                .add => {
                    try result.append(self.allocator, hunk_line.content);
                },
            }
        }

        return true;
    }

    fn collectContextLines(self: *PatchFormat, hunk: Hunk) ![]const []const u8 {
        var count: usize = 0;
        for (hunk.lines) |line| {
            if (line.kind == .context) count += 1;
        }
        var list = std.ArrayList([]const u8).initCapacity(self.allocator, count) catch return error.OutOfMemory;
        for (hunk.lines) |line| {
            if (line.kind == .context) {
                try list.append(self.allocator, line.content);
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn splitLines(self: *PatchFormat, text: []const u8) ![]const []const u8 {
        var lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer lines.deinit(self.allocator);

        var start: usize = 0;
        for (text, 0..) |byte, i| {
            if (byte == '\n') {
                try lines.append(self.allocator, text[start..i]);
                start = i + 1;
            }
        }

        if (start < text.len) {
            try lines.append(self.allocator, text[start..]);
        }

        return lines.toOwnedSlice(self.allocator);
    }
};

test "PatchFormat init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    const patch = PatchFormat.init(gpa.allocator());
    try std.testing.expectEqual(@as(usize, 0), patch.strip_level);
    try std.testing.expectEqual(true, patch.include_headers);
}

test "PatchFormat strip_path" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var patch = PatchFormat.init(gpa.allocator());
    patch.strip_level = 1;

    const stripped = patch.stripPath("a/b/c.txt");
    try std.testing.expectEqualStrings("b/c.txt", stripped);
}

test "PatchFormat strip_path_deep" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var patch = PatchFormat.init(gpa.allocator());
    patch.strip_level = 2;

    const stripped = patch.stripPath("a/b/c/d.txt");
    try std.testing.expectEqualStrings("d.txt", stripped);
}

test "PatchFormat strip_path_single" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    var patch = PatchFormat.init(gpa.allocator());
    patch.strip_level = 3;

    const stripped = patch.stripPath("a.txt");
    try std.testing.expectEqualStrings("a.txt", stripped);
}

test "PatchFormat prefixes" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    const patch = PatchFormat.init(gpa.allocator());
    try std.testing.expectEqualStrings("a/", patch.remove_prefix);
    try std.testing.expectEqualStrings("b/", patch.add_prefix);
}
