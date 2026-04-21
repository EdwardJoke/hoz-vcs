//! Graph - ASCII art commit graph visualization
//!
//! This module provides ASCII graph rendering for commit history visualization.

const std = @import("std");

pub const GraphOptions = struct {
    show_branch: bool = true,
    column_spacing: u8 = 2,
    row_spacing: u8 = 0,
    compact: bool = false,
};

pub const GraphColumn = struct {
    branch: []const u8,
    color: ?[]const u8 = null,
    active: bool = false,
};

pub const GraphRow = struct {
    commit_oid: []const u8,
    message: []const u8,
    columns: []GraphColumn,
    parents: []const usize,
    is_merge: bool,
    merge_columns: []const usize,
};

pub const CommitGraph = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(GraphRow),
    options: GraphOptions,
    column_count: usize,

    pub fn init(allocator: std.mem.Allocator, options: GraphOptions) CommitGraph {
        return .{
            .allocator = allocator,
            .rows = std.ArrayList(GraphRow).init(allocator),
            .options = options,
            .column_count = 0,
        };
    }

    pub fn deinit(self: *CommitGraph) void {
        for (self.rows.items) |row| {
            self.allocator.free(row.commit_oid);
            self.allocator.free(row.message);
            for (row.columns) |col| {
                self.allocator.free(col.branch);
            }
            self.allocator.free(row.columns);
            self.allocator.free(row.parents);
            self.allocator.free(row.merge_columns);
        }
        self.rows.deinit();
    }

    pub fn addRow(self: *CommitGraph, row: GraphRow) !void {
        try self.rows.append(row);
        if (row.columns.len > self.column_count) {
            self.column_count = row.columns.len;
        }
    }

    pub fn render(self: *CommitGraph) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        for (self.rows.items) |row| {
            try self.renderRow(&buf, row);
            try buf.append('\n');
        }

        return buf.toOwnedSlice();
    }

    fn renderRow(self: *CommitGraph, buf: *std.ArrayList(u8), row: GraphRow) !void {
        const spacing = self.options.column_spacing;

        if (self.options.show_branch) {
            for (row.columns, 0..) |col, i| {
                if (i > 0) {
                    try self.addSpaces(buf, spacing);
                }

                if (col.active) {
                    try buf.append('*');
                } else {
                    try buf.append('|');
                }

                if (self.options.compact) {
                    try buf.writer().print(" {s}", .{col.branch});
                } else {
                    try buf.writer().print(" {s} |", .{col.branch});
                }
            }

            if (self.options.column_spacing > 0) {
                try self.addSpaces(buf, spacing);
            }

            try buf.append(' ');
        }

        if (row.is_merge) {
            try buf.append('M');
        } else {
            try buf.append('o');
        }
        try buf.append(' ');

        try buf.writer().print("{s} {s}", .{ row.commit_oid, row.message });
    }

    fn addSpaces(self: *CommitGraph, buf: *std.ArrayList(u8), count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try buf.append(' ');
        }
    }
};

pub const ASCII_CHARS = struct {
    pub const VERTICAL: []const u8 = "|";
    pub const HORIZONTAL: []const u8 = "-";
    pub const DOWN: []const u8 = "\\";
    pub const UP: []const u8 = "/";
    pub const MERGE: []const u8 = "M";
    pub const COMMIT: []const u8 = "o";
    pub const STAR: []const u8 = "*";
    pub const SPACE: []const u8 = " ";
    pub const PIPE: []const u8 = "|";
};

pub fn formatGraphLine(
    allocator: std.mem.Allocator,
    columns: []const bool,
    commit_symbol: u8,
    line: []const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (columns) |active| {
        if (active) {
            try buf.append('*');
        } else {
            try buf.append('|');
        }
        try buf.append(ASCII_CHARS.SPACE[0]);
        try buf.append(ASCII_CHARS.SPACE[0]);
    }

    try buf.append(commit_symbol);
    try buf.append(ASCII_CHARS.SPACE[0]);
    try buf.appendSlice(line);

    return buf.toOwnedSlice();
}

pub fn getGraphSymbol(is_merge: bool, is_commit: bool) u8 {
    if (is_commit) {
        return '*';
    } else if (is_merge) {
        return 'M';
    } else {
        return 'o';
    }
}

test "GraphOptions default values" {
    const opts = GraphOptions{};
    try std.testing.expect(opts.show_branch == true);
    try std.testing.expect(opts.column_spacing == 2);
    try std.testing.expect(opts.row_spacing == 0);
    try std.testing.expect(opts.compact == false);
}

test "CommitGraph init and deinit" {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var graph = CommitGraph.init(gpa.allocator(), .{});
    graph.deinit();
    try std.testing.expect(graph.rows.items.len == 0);
}

test "formatGraphLine with active columns" {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const columns = &[_]bool{ true, false, true };
    const line = try formatGraphLine(gpa.allocator(), columns, '*', "abc123 fix bug");
    defer gpa.allocator().free(line);

    try std.testing.expect(line.len > 0);
}
