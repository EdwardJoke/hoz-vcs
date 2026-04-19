//! DiffOptions - Configuration for diff operations

const std = @import("std");

pub const DiffOptions = struct {
    context_lines: usize = 3,
    ignore_whitespace: bool = false,
    ignore_case: bool = false,
    no_color: bool = false,
    show_unified: bool = true,
    show_stats: bool = false,
    rename_detection: bool = false,
    ignore_options: IgnoreOptions = .{},
    binary_detection: bool = true,
    algorithm: DiffAlgorithm = .myers,
    submodule_config: ?SubmoduleConfig = null,
    color_moved: ColorMovedOption = .no,
    word_diff: WordDiffOption = .{},
};

pub const IgnoreOptions = struct {
    ignore_whitespace_changes: bool = false,
    ignore_blank_lines: bool = false,
    ignore_space_at_eol: bool = false,
    ignore_space_change: bool = false,
};

pub const DiffAlgorithm = enum {
    myers,
    patience,
    histogram,
};

pub const SubmoduleOption = struct {
    name: []const u8,
    path: []const u8,
    url: ?[]const u8 = null,
    branch: ?[]const u8 = null,
};

pub const SubmoduleConfig = struct {
    diff: bool = true,
    log: bool = true,
    short: bool = false,
};

pub const ColorMovedOption = enum {
    no,
    default,
    plain,
    blocks,
    zebra,
    dimmed_zebra,
};

pub const WordDiffOption = struct {
    enabled: bool = false,
    separator: []const u8 = " ",
    internal_ignore_whitespace: bool = false,
};

pub const ColorOption = enum {
    never,
    always,
    auto,
};

pub const OutputPrefix = enum {
    none,
    a,
    b,
};

pub fn initDefault() DiffOptions {
    return .{};
}

pub fn withContext(self: *DiffOptions, lines: usize) *DiffOptions {
    self.context_lines = lines;
    return self;
}

pub fn withIgnoreWhitespace(self: *DiffOptions, ignore: bool) *DiffOptions {
    self.ignore_whitespace = ignore;
    return self;
}

pub fn withIgnoreCase(self: *DiffOptions, ignore: bool) *DiffOptions {
    self.ignore_case = ignore;
    return self;
}

pub fn withNoColor(self: *DiffOptions, no_color: bool) *DiffOptions {
    self.no_color = no_color;
    return self;
}

pub fn withShowUnified(self: *DiffOptions, unified: bool) *DiffOptions {
    self.show_unified = unified;
    return self;
}

pub fn withShowStats(self: *DiffOptions, stats: bool) *DiffOptions {
    self.show_stats = stats;
    return self;
}

pub fn withRenameDetection(self: *DiffOptions, detect: bool) *DiffOptions {
    self.rename_detection = detect;
    return self;
}

pub fn withIgnoreOptions(self: *DiffOptions, opts: IgnoreOptions) *DiffOptions {
    self.ignore_options = opts;
    return self;
}

pub fn withAlgorithm(self: *DiffOptions, algo: DiffAlgorithm) *DiffOptions {
    self.algorithm = algo;
    return self;
}

pub fn withBinaryDetection(self: *DiffOptions, detect: bool) *DiffOptions {
    self.binary_detection = detect;
    return self;
}

test "DiffOptions default values" {
    const opts = DiffOptions{};
    try std.testing.expectEqual(@as(usize, 3), opts.context_lines);
    try std.testing.expectEqual(false, opts.ignore_whitespace);
    try std.testing.expectEqual(false, opts.ignore_case);
    try std.testing.expectEqual(false, opts.no_color);
    try std.testing.expectEqual(true, opts.show_unified);
    try std.testing.expectEqual(false, opts.show_stats);
    try std.testing.expectEqual(false, opts.rename_detection);
}

test "DiffOptions builder pattern" {
    var opts = DiffOptions{};
    try std.testing.expectEqual(@as(usize, 3), opts.context_lines);

    opts.withContext(5);
    try std.testing.expectEqual(@as(usize, 5), opts.context_lines);

    opts.withIgnoreWhitespace(true);
    try std.testing.expectEqual(true, opts.ignore_whitespace);

    opts.withAlgorithm(.patience);
    try std.testing.expectEqual(DiffAlgorithm.patience, opts.algorithm);
}

test "IgnoreOptions default" {
    const opts = IgnoreOptions{};
    try std.testing.expectEqual(false, opts.ignore_whitespace_changes);
    try std.testing.expectEqual(false, opts.ignore_blank_lines);
    try std.testing.expectEqual(false, opts.ignore_space_at_eol);
}

test "DiffAlgorithm enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DiffAlgorithm.myers));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(DiffAlgorithm.patience));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(DiffAlgorithm.histogram));
}
