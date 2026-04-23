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
        if (self.strip_level > 0) {
            old_path = self.stripPath(old_path);
            new_path = self.stripPath(new_path);
        }

        if (self.include_headers) {
            try writer.print("diff --git {s}{s} {s}{s}\n", .{ self.remove_prefix, old_path, self.add_prefix, new_path });
            try writer.print("--- {s}{s}\n", .{ self.remove_prefix, old_path });
            try writer.print("+++ {s}{s}\n", .{ self.add_prefix, new_path });
        }

        var unified_diff = unified.UnifiedDiff.init(self.allocator);
        try unified_diff.formatUnified(writer, old_path, new_path, old_lines, new_lines, edits);
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
        _ = width - path_len - 10;

        try writer.print(" {s}", .{path[0..path_len]});
        var i: usize = path_len;
        while (i < width - 10) : (i += 1) {
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
