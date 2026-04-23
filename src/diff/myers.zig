//! Diff Engine - Myers diff algorithm implementation
//!
//! This module provides text diffing capabilities using the Myers
//! diff algorithm for efficient computation of the shortest edit script.

const std = @import("std");

pub const EditOperation = enum {
    insert,
    delete,
    equal,
};

pub const Edit = struct {
    operation: EditOperation,
    old_line: usize,
    new_line: usize,
};

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    edits: []const Edit,
};

pub const DiffOptions = struct {
    context_lines: usize = 3,
    ignore_whitespace: bool = false,
    ignore_case: bool = false,
    no_color: bool = false,
    show_unified: bool = true,
    show_stats: bool = false,
    rename_detection: bool = false,
    ignore_options: IgnoreOptions = .{},
};

pub const IgnoreOptions = struct {
    ignore_whitespace_changes: bool = false,
    ignore_blank_lines: bool = false,
    ignore_space_at_eol: bool = false,
};

pub const BinaryDetection = struct {
    is_binary: bool = false,
    suggested_prefix: []const u8 = ".binary",
};

pub const RenameDetection = struct {
    similarity_threshold: f64 = 0.5,
    max_file_size: usize = 100_000,
};

pub const MyersDiff = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MyersDiff {
        return .{ .allocator = allocator };
    }

    pub fn diff(self: *MyersDiff, old_text: []const []const u8, new_text: []const []const u8) ![]const Edit {
        const result = try self.computeEdits(old_text, new_text);
        return result;
    }

    fn computeEdits(self: *MyersDiff, old_text: []const []const u8, new_text: []const []const u8) ![]const Edit {
        const old_len = old_text.len;
        const new_len = new_text.len;

        if (old_len == 0 and new_len == 0) {
            return &.{};
        }

        if (old_len == 0) {
            var edits = std.ArrayList(Edit).init(self.allocator);
            errdefer edits.deinit();
            for (new_text, 0..) |_, i| {
                try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = i + 1 });
            }
            return edits.toOwnedSlice();
        }

        if (new_len == 0) {
            var edits = std.ArrayList(Edit).init(self.allocator);
            errdefer edits.deinit();
            for (old_text, 0..) |_, i| {
                try edits.append(.{ .operation = .delete, .old_line = i + 1, .new_line = 0 });
            }
            return edits.toOwnedSlice();
        }

        return try self.myers(old_text, new_text);
    }

    fn myers(self: *MyersDiff, old_text: []const []const u8, new_text: []const []const u8) ![]const Edit {
        const old_len: isize = @intCast(old_text.len);
        const new_len: isize = @intCast(new_text.len);
        const max: isize = old_len + new_len;

        const trace_size = @as(usize, @intCast(max * 2 + 1));
        var current_trace = try self.allocator.alloc(isize, trace_size);
        defer self.allocator.free(current_trace);
        var previous_trace = try self.allocator.alloc(isize, trace_size);
        defer self.allocator.free(previous_trace);

        @memset(current_trace, 0);
        @memset(previous_trace, 0);

        const offset: isize = max;
        var v_old: isize = 0;
        var v_new: isize = 0;

        outer: for (1..@intCast(max + 1)) |d| {
            for (-d..d + 1) |k| {
                const trace_idx = @as(usize, @intCast(k + offset));

                var v: isize = undefined;
                if (k == -d or (k != d and current_trace[trace_idx - 1] > current_trace[trace_idx])) {
                    v = current_trace[trace_idx - 1];
                } else {
                    v = current_trace[trace_idx] + 1;
                }

                var x = v;
                while (x > 0 and x < old_len and x - k < new_len and
                    std.mem.eql(u8, old_text[@intCast(x - 1)], new_text[@intCast(x - k - 1)])) : (x += 1)
                {}

                if (d % 2 == 1) {
                    previous_trace[trace_idx] = x;
                } else {
                    current_trace[trace_idx] = x;
                }

                if (x >= old_len and x - k >= new_len) {
                    v_old = x;
                    v_new = x - k;
                    break :outer;
                }
            }

            const temp = previous_trace;
            previous_trace = current_trace;
            current_trace = temp;
            if (d % 2 == 0) {
                @memset(current_trace, 0);
            }
        }

        return try self.backtrackEditsOptimized(old_text, new_text, v_old, v_new, max);
    }

    fn backtrackEditsOptimized(
        self: *MyersDiff,
        old_text: []const []const u8,
        new_text: []const []const u8,
        _: isize,
        _: isize,
        max: isize,
    ) ![]const Edit {
        var edits = std.ArrayList(Edit).init(self.allocator);
        errdefer edits.deinit();

        var old_idx = @as(isize, @intCast(old_text.len));
        var new_idx = @as(isize, @intCast(new_text.len));
        var d = max;

        while (d > 0 or old_idx > 0 or new_idx > 0) {
            _ = old_idx - new_idx;

            const is_delete = old_idx > 0 and (new_idx == 0 or d <= max - old_idx);
            const is_insert = new_idx > 0 and (old_idx == 0 or d <= max - new_idx);

            if (is_delete) {
                try edits.append(.{ .operation = .delete, .old_line = @intCast(old_idx), .new_line = 0 });
                old_idx -= 1;
            } else if (is_insert) {
                try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = @intCast(new_idx) });
                new_idx -= 1;
            } else {
                if (old_idx > 0 and new_idx > 0) {
                    try edits.append(.{ .operation = .equal, .old_line = @intCast(old_idx), .new_line = @intCast(new_idx) });
                    old_idx -= 1;
                    new_idx -= 1;
                } else if (old_idx > 0) {
                    try edits.append(.{ .operation = .delete, .old_line = @intCast(old_idx), .new_line = 0 });
                    old_idx -= 1;
                } else if (new_idx > 0) {
                    try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = @intCast(new_idx) });
                    new_idx -= 1;
                } else {
                    break;
                }
            }

            if (d > 0) d -= 1;
        }

        std.mem.reverse(Edit, edits.items);
        return edits.toOwnedSlice();
    }

    fn backtrackEdits(self: *MyersDiff, traces: []const [2]std.ArrayList(isize), old_text: []const []const u8, new_text: []const []const u8) ![]const Edit {
        var edits = std.ArrayList(Edit).init(self.allocator);
        errdefer edits.deinit();

        var old_idx: isize = @intCast(old_text.len);
        var new_idx: isize = @intCast(new_text.len);

        var d: isize = @intCast(traces.len - 1);

        while (d > 0 or old_idx > 0 or new_idx > 0) {
            if (d < 0) {
                d = 0;
            }

            const other_idx = if (d % 2 == 1) 0 else 1;

            if (d > 0 and old_idx > 0 and new_idx > 0 and
                std.mem.eql(u8, old_text[@intCast(old_idx - 1)], new_text[@intCast(new_idx - 1)]))
            {
                try edits.append(.{ .operation = .equal, .old_line = @intCast(old_idx), .new_line = @intCast(new_idx) });
                old_idx -= 1;
                new_idx -= 1;
            } else if (d > 0 and old_idx > 0 and (new_idx == 0 or
                blk: {
                    const idx: isize = old_idx - 1 + @as(isize, @intCast(d)) - 1;
                    const capped: isize = if (idx < 0) 0 else idx;
                    const usize_idx: usize = @intCast(capped);
                    break :blk (d < traces.len and traces[@intCast(d - 1)][other_idx].items.len > usize_idx and
                        traces[@intCast(d - 1)][other_idx].items[usize_idx] >= @as(usize, @intCast(old_idx - 1)));
                }))
            {
                try edits.append(.{ .operation = .delete, .old_line = @intCast(old_idx), .new_line = 0 });
                old_idx -= 1;
                d -= 1;
            } else if (d > 0 and new_idx > 0) {
                try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = @intCast(new_idx) });
                new_idx -= 1;
                d -= 1;
            } else if (old_idx > 0) {
                try edits.append(.{ .operation = .delete, .old_line = @intCast(old_idx), .new_line = 0 });
                old_idx -= 1;
            } else if (new_idx > 0) {
                try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = @intCast(new_idx) });
                new_idx -= 1;
            } else {
                break;
            }
        }

        std.mem.reverse(Edit, edits.items);
        return edits.toOwnedSlice();
    }
};

test "MyersDiff init" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer gpa.deinit();

    const diff = MyersDiff.init(gpa.allocator());
    try std.testing.expect(diff.allocator == gpa.allocator());
}

test "MyersDiff empty diff" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
    const old_text: []const []const u8 = &.{};
    const new_text: []const []const u8 = &.{};

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expectEqual(@as(usize, 0), edits.len);
}

test "MyersDiff simple insert" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
    const old_text: []const []const u8 = &.{};
    const new_text: []const []const u8 = &.{"hello"};

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqual(EditOperation.insert, edits[0].operation);
    try std.testing.expectEqual(@as(usize, 0), edits[0].old_line);
    try std.testing.expectEqual(@as(usize, 1), edits[0].new_line);
}

test "MyersDiff simple delete" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
    const old_text: []const []const u8 = &.{"hello"};
    const new_text: []const []const u8 = &.{};

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqual(EditOperation.delete, edits[0].operation);
    try std.testing.expectEqual(@as(usize, 1), edits[0].old_line);
    try std.testing.expectEqual(@as(usize, 0), edits[0].new_line);
}

test "MyersDiff no changes" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
    const old_text: []const []const u8 = &.{ "hello", "world" };
    const new_text: []const []const u8 = &.{ "hello", "world" };

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqual(EditOperation.equal, edits[0].operation);
    try std.testing.expectEqual(EditOperation.equal, edits[1].operation);
}

test "MyersDiff replace" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
    const old_text: []const []const u8 = &.{"hello"};
    const new_text: []const []const u8 = &.{"world"};

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expect(edits.len >= 2);
    try std.testing.expectEqual(EditOperation.delete, edits[0].operation);
    try std.testing.expectEqual(EditOperation.insert, edits[edits.len - 1].operation);
}
