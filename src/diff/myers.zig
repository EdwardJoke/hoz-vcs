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
        const max_d: isize = old_len + new_len;

        if (max_d == 0) return &.{};

        const trace_size = @as(usize, @intCast(max_d * 2 + 1));
        var current_trace = try self.allocator.alloc(isize, trace_size);
        defer self.allocator.free(current_trace);
        var previous_trace = try self.allocator.alloc(isize, trace_size);
        defer self.allocator.free(previous_trace);

        @memset(current_trace, 0);
        @memset(previous_trace, 0);

        var trace_history = std.ArrayList([]isize).init(self.allocator);
        defer {
            for (trace_history.items) |row| self.allocator.free(row);
            trace_history.deinit();
        }

        const offset: isize = max_d;
        var v_old: isize = 0;
        var v_new: isize = 0;

        outer: for (1..@intCast(max_d + 1)) |d| {
            for (-@as(isize, @intCast(d))..@as(isize, @intCast(d)) + 1) |k| {
                const trace_idx = @as(usize, @intCast(k + offset));

                var v: isize = undefined;
                if (k == -@as(isize, @intCast(d)) or (k != @as(isize, @intCast(d)) and current_trace[trace_idx - 1] > current_trace[trace_idx])) {
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

            const snapshot = try self.allocator.dupe(isize, if (d % 2 == 1) previous_trace else current_trace);
            try trace_history.append(snapshot);

            const temp = previous_trace;
            previous_trace = current_trace;
            current_trace = temp;
            if (d % 2 == 0) {
                @memset(current_trace, 0);
            }
        }

        return try self.backtrackEdits(old_text, new_text, v_old, v_new, max_d, offset, trace_history.items);
    }

    fn backtrackEdits(
        self: *MyersDiff,
        old_text: []const []const u8,
        new_text: []const []const u8,
        v_old: isize,
        v_new: isize,
        max_d: isize,
        offset: isize,
        trace_history: []const []isize,
    ) ![]const Edit {
        var edits = std.ArrayList(Edit).init(self.allocator);
        errdefer edits.deinit();

        var x: isize = v_old;
        var y: isize = v_new;

        var d: usize = @intCast(max_d);
        while (d > 0) : (d -= 1) {
            const k = x - y;

            const trace_row = if (d > 0 and d <= trace_history.len)
                trace_history[d - 1]
            else
                null;

            var prev_k: isize = undefined;
            if (k == -@as(isize, @intCast(d)) or (k != @as(isize, @intCast(d)) and trace_row != null and
                trace_row[@intCast((k - 1) + offset)] > trace_row[@intCast(k + offset)]))
            {
                prev_k = k + 1;
            } else {
                prev_k = k - 1;
            }

            const have_trace = trace_row != null;
            const prev_x: isize = if (have_trace)
                trace_row[@intCast(prev_k + offset)]
            else blk: {
                var px = if (prev_k > k) x else x - 1;
                const py = px - prev_k;
                while (px > 0 and py > 0 and
                    std.mem.eql(u8, old_text[@intCast(px - 1)], new_text[@intCast(py - 1)]))
                {
                    px -= 1;
                }
                break :blk px;
            };

            while (x > prev_x and y > prev_x - prev_k) {
                x -= 1;
                y -= 1;
                try edits.append(.{
                    .operation = .equal,
                    .old_line = @intCast(x + 1),
                    .new_line = @intCast(y + 1),
                });
            }

            if (x > prev_x) {
                x -= 1;
                try edits.append(.{
                    .operation = .delete,
                    .old_line = @intCast(x + 1),
                    .new_line = 0,
                });
            } else if (y > prev_x - prev_k) {
                y -= 1;
                try edits.append(.{
                    .operation = .insert,
                    .old_line = 0,
                    .new_line = @intCast(y + 1),
                });
            }
        }

        while (x > 0 and y > 0) {
            x -= 1;
            y -= 1;
            try edits.append(.{
                .operation = .equal,
                .old_line = @intCast(x + 1),
                .new_line = @intCast(y + 1),
            });
        }

        while (x > 0) : (x -= 1) {
            try edits.append(.{ .operation = .delete, .old_line = @intCast(x), .new_line = 0 });
        }
        while (y > 0) : (y -= 1) {
            try edits.append(.{ .operation = .insert, .old_line = 0, .new_line = @intCast(y) });
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
