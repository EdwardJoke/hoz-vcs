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

        var traces = std.ArrayList([2]std.ArrayList(isize)).init(self.allocator);
        defer {
            for (traces.items) |trace| {
                trace[0].deinit();
                trace[1].deinit();
            }
            traces.deinit();
        }

        outer: for (0..@intCast(max + 1)) |_| {
            var trace_pair = [_]std.ArrayList(isize){
                std.ArrayList(isize).init(self.allocator),
                std.ArrayList(isize).init(self.allocator),
            };
            errdefer {
                trace_pair[0].deinit();
                trace_pair[1].deinit();
            };

            for (0..@intCast(max + 1)) |_| {
                try trace_pair[0].append(0);
                try trace_pair[1].append(0);
            }

            for (1..@intCast(max + 1)) |d| {
                for (-d..d + 1) |k| {
                    const trace_idx = if (d % 2 == 1) 1 else 0;
                    const other_idx = if (d % 2 == 1) 0 else 1;

                    var v: isize = undefined;
                    if (k == -d or (k != d and trace_pair[trace_idx].items[@intCast(k - 1 + d)] > trace_pair[trace_idx].items[@intCast(k + d)])) {
                        v = trace_pair[trace_idx].items[@intCast(k - 1 + d)];
                    } else {
                        v = trace_pair[trace_idx].items[@intCast(k + d)] + 1;
                    }

                    while (v > 0 and v < old_len and v - k < new_len and
                        std.mem.eql(u8, old_text[@intCast(v)], new_text[@intCast(v - k)])) : (v += 1) {}

                    trace_pair[other_idx].items[@intCast(k + d)] = v;

                    if (v >= old_len and v - k >= new_len) {
                        try self.backtrack(traces.items, old_text, new_text, old_len, new_len);
                        break :outer;
                    }
                }
            }

            try traces.append(trace_pair);
        }

        return try self.backtrackEdits(traces.items, old_text, new_text);
    }

    fn backtrack(self: *MyersDiff, traces: []const [2]std.ArrayList(isize), old_text: []const []const u8, new_text: []const []const u8, old_len: isize, new_len: isize) !void {
        _ = self;
        _ = traces;
        _ = old_text;
        _ = new_text;
        _ = old_len;
        _ = new_len;
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

            const trace_idx = if (d % 2 == 1) 1 else 0;
            const other_idx = if (d % 2 == 1) 0 else 1;

            if (d > 0 and old_idx > 0 and new_idx > 0 and
                std.mem.eql(u8, old_text[@intCast(old_idx - 1)], new_text[@intCast(new_idx - 1)])) {
                try edits.append(.{ .operation = .equal, .old_line = @intCast(old_idx), .new_line = @intCast(new_idx) });
                old_idx -= 1;
                new_idx -= 1;
            } else if (d > 0 and old_idx > 0 and (new_idx == 0 or
                (d < traces.len and traces[@intCast(d - 1)][other_idx].items.len > @intCast(@max(0, @intCast(old_idx - 1 + @intCast(d) - 1))) and
                traces[@intCast(d - 1)][other_idx].items[@intCast(@max(0, @intCast(old_idx - 1 + @intCast(d) - 1)))] >= old_idx - 1))) {
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
    defer _ = gpa.deinit();

    var diff = MyersDiff.init(gpa.allocator());
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
    const old_text: []const []const u8 = &.{ "hello" };
    const new_text: []const []const u8 = &.{ "world" };

    const edits = try diff.diff(old_text, new_text);
    defer diff.allocator.free(edits);

    try std.testing.expect(edits.len >= 2);
    try std.testing.expectEqual(EditOperation.delete, edits[0].operation);
    try std.testing.expectEqual(EditOperation.insert, edits[edits.len - 1].operation);
}