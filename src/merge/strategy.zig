//! Strategy - Merge strategy options
//!
//! This module provides merge strategy options for -X parameter.

const std = @import("std");

pub const StrategyOption = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const MergeStrategy = enum {
    resolve,
    recursive,
    octopus,
    ours,
    subtree,
};

pub const StrategyOptions = struct {
    ignore_space_change: bool = false,
    ignore_whitespace: bool = false,
    patience: bool = false,
    histogram: bool = false,
    no_recursive: bool = false,
    subtree: bool = false,
    ours: bool = false,
    theirs: bool = false,
    renormalize: bool = false,
    no_renormalize: bool = false,
    quiet: bool = false,
    no_stat: bool = false,
    union: bool = false,
};

pub fn parseStrategyOption(option: []const u8) !StrategyOption {
    if (std.mem.startsWith(u8, option, "ignore-space-change")) {
        return StrategyOption{ .name = "ignore-space-change" };
    } else if (std.mem.startsWith(u8, option, "ignore-whitespace")) {
        return StrategyOption{ .name = "ignore-whitespace" };
    } else if (std.mem.startsWith(u8, option, "patience")) {
        return StrategyOption{ .name = "patience" };
    } else if (std.mem.startsWith(u8, option, "histogram")) {
        return StrategyOption{ .name = "histogram" };
    } else if (std.mem.startsWith(u8, option, "ours")) {
        return StrategyOption{ .name = "ours" };
    } else if (std.mem.startsWith(u8, option, "theirs")) {
        return StrategyOption{ .name = "theirs" };
    } else if (std.mem.startsWith(u8, option, "subtree")) {
        return StrategyOption{ .name = "subtree" };
    } else if (std.mem.startsWith(u8, option, "renormalize")) {
        return StrategyOption{ .name = "renormalize" };
    } else if (std.mem.startsWith(u8, option, "no-renormalize")) {
        return StrategyOption{ .name = "no-renormalize" };
    } else if (std.mem.startsWith(u8, option, "quiet")) {
        return StrategyOption{ .name = "quiet" };
    } else if (std.mem.startsWith(u8, option, "no-stat")) {
        return StrategyOption{ .name = "no-stat" };
    } else if (std.mem.startsWith(u8, option, "union")) {
        return StrategyOption{ .name = "union" };
    }
    return error.UnknownOption;
}

pub fn applyStrategyOption(options: *StrategyOptions, option: StrategyOption) void {
    if (std.mem.eql(u8, option.name, "ignore-space-change")) {
        options.ignore_space_change = true;
    } else if (std.mem.eql(u8, option.name, "ignore-whitespace")) {
        options.ignore_whitespace = true;
    } else if (std.mem.eql(u8, option.name, "patience")) {
        options.patience = true;
    } else if (std.mem.eql(u8, option.name, "histogram")) {
        options.histogram = true;
    } else if (std.mem.eql(u8, option.name, "ours")) {
        options.ours = true;
    } else if (std.mem.eql(u8, option.name, "theirs")) {
        options.theirs = true;
    } else if (std.mem.eql(u8, option.name, "subtree")) {
        options.subtree = true;
    } else if (std.mem.eql(u8, option.name, "renormalize")) {
        options.renormalize = true;
    } else if (std.mem.eql(u8, option.name, "no-renormalize")) {
        options.no_renormalize = true;
    } else if (std.mem.eql(u8, option.name, "quiet")) {
        options.quiet = true;
    } else if (std.mem.eql(u8, option.name, "no-stat")) {
        options.no_stat = true;
    } else if (std.mem.eql(u8, option.name, "union")) {
        options.union = true;
    }
}

pub fn parseStrategyOptions(args: []const []const u8) !StrategyOptions {
    var options = StrategyOptions{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-X")) {
            const value = arg[2..];
            if (value.len > 0) {
                const option = try parseStrategyOption(value);
                applyStrategyOption(&options, option);
            }
        }
    }
    return options;
}

test "parseStrategyOption patience" {
    const option = try parseStrategyOption("patience");
    try std.testing.expectEqualStrings("patience", option.name);
}

test "parseStrategyOption ours" {
    const option = try parseStrategyOption("ours");
    try std.testing.expectEqualStrings("ours", option.name);
}

test "applyStrategyOption" {
    var options = StrategyOptions{};
    applyStrategyOption(&options, StrategyOption{ .name = "patience" });
    try std.testing.expect(options.patience == true);
}

test "parseStrategyOptions with multiple options" {
    const args = &[_][]const u8{ "-Xpatience", "-Xours" };
    const options = try parseStrategyOptions(args);
    try std.testing.expect(options.patience == true);
    try std.testing.expect(options.ours == true);
}
