//! Color - ANSI color support for diff output
//!
//! This module provides ANSI color formatting for diff output,
//! including support for color moved detection.

const std = @import("std");

pub const ColorCode = struct {
    code: []const u8,
    prefix: []const u8,
    suffix: []const u8,
};

pub const DiffColor = enum {
    reset,
    bold,
    red,
    green,
    blue,
    yellow,
    magenta,
    cyan,
    white,
    dim,
    italic,
    underline,
};

pub const ColorMovedColor = struct {
    plain: ?[]const u8,
    default_color: ?[]const u8,
    blocks: ?[]const u8,
    zebra: ?[]const u8,
    dimmed_zebra: ?[]const u8,
};

pub const ANSI = struct {
    pub const RESET: []const u8 = "\x1b[0m";
    pub const BOLD: []const u8 = "\x1b[1m";
    pub const DIM: []const u8 = "\x1b[2m";
    pub const ITALIC: []const u8 = "\x1b[3m";
    pub const UNDERLINE: []const u8 = "\x1b[4m";

    pub const FG_BLACK: []const u8 = "\x1b[30m";
    pub const FG_RED: []const u8 = "\x1b[31m";
    pub const FG_GREEN: []const u8 = "\x1b[32m";
    pub const FG_YELLOW: []const u8 = "\x1b[33m";
    pub const FG_BLUE: []const u8 = "\x1b[34m";
    pub const FG_MAGENTA: []const u8 = "\x1b[35m";
    pub const FG_CYAN: []const u8 = "\x1b[36m";
    pub const FG_WHITE: []const u8 = "\x1b[37m";

    pub const BG_BLACK: []const u8 = "\x1b[40m";
    pub const BG_RED: []const u8 = "\x1b[41m";
    pub const BG_GREEN: []const u8 = "\x1b[42m";
    pub const BG_YELLOW: []const u8 = "\x1b[43m";
    pub const BG_BLUE: []const u8 = "\x1b[44m";
    pub const BG_MAGENTA: []const u8 = "\x1b[45m";
    pub const BG_CYAN: []const u8 = "\x1b[46m";
    pub const BG_WHITE: []const u8 = "\x1b[47m";
};

pub fn colorize(text: []const u8, color: DiffColor) []const u8 {
    _ = text;
    _ = color;
    return text;
}

pub fn getColorCode(color: DiffColor) []const u8 {
    return switch (color) {
        .reset => ANSI.RESET,
        .bold => ANSI.BOLD,
        .dim => ANSI.DIM,
        .italic => ANSI.ITALIC,
        .underline => ANSI.UNDERLINE,
        .red => ANSI.FG_RED,
        .green => ANSI.FG_GREEN,
        .yellow => ANSI.FG_YELLOW,
        .blue => ANSI.FG_BLUE,
        .magenta => ANSI.FG_MAGENTA,
        .cyan => ANSI.FG_CYAN,
        .white => ANSI.FG_WHITE,
    };
}

pub fn getResetCode() []const u8 {
    return ANSI.RESET;
}

pub const ColorMovedDetection = struct {
    enabled: bool,
    mode: ColorMovedMode,
    colors: MovedLineColors,
};

pub const ColorMovedMode = enum {
    no,
    default,
    plain,
    blocks,
    zebra,
    dimmed_zebra,
};

pub const MovedLineColors = struct {
    added: []const u8 = ANSI.FG_GREEN,
    deleted: []const u8 = ANSI.FG_RED,
    changed: []const u8 = ANSI.FG_YELLOW,
};

pub fn getMovedLineColor(
    mode: ColorMovedMode,
    line_type: MovedLineType,
) []const u8 {
    switch (mode) {
        .no => return "",
        .default => {
            return switch (line_type) {
                .added => ANSI.FG_CYAN,
                .deleted => ANSI.FG_MAGENTA,
                .unchanged => "",
            };
        },
        .plain => {
            return switch (line_type) {
                .added => ANSI.FG_GREEN,
                .deleted => ANSI.FG_RED,
                .unchanged => "",
            };
        },
        .blocks => {
            return switch (line_type) {
                .added => ANSI.FG_GREEN,
                .deleted => ANSI.FG_RED,
                .unchanged => "",
            };
        },
        .zebra => {
            return switch (line_type) {
                .added => ANSI.FG_GREEN,
                .deleted => ANSI.FG_RED,
                .unchanged => ANSI.DIM,
            };
        },
        .dimmed_zebra => {
            return switch (line_type) {
                .added => ANSI.DIM ++ ANSI.FG_GREEN,
                .deleted => ANSI.DIM ++ ANSI.FG_RED,
                .unchanged => ANSI.DIM,
            };
        },
    }
}

pub const MovedLineType = enum {
    added,
    deleted,
    unchanged,
};

pub fn isMovedLine(line_type: MovedLineType) bool {
    return line_type != .unchanged;
}

test "ANSI color codes defined" {
    try std.testing.expect(ANSI.RESET.len > 0);
    try std.testing.expect(ANSI.FG_RED.len > 0);
    try std.testing.expect(ANSI.FG_GREEN.len > 0);
}

test "getMovedLineColor returns non-empty for moved lines" {
    const color = getMovedLineColor(.zebra, .added);
    try std.testing.expect(color.len > 0);
}

test "getMovedLineColor returns empty for no mode" {
    const color = getMovedLineColor(.no, .added);
    try std.testing.expect(color.len == 0);
}
