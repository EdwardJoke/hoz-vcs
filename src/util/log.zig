//! Logging infrastructure for Hoz VCS
const std = @import("std");

/// ANSI color codes for terminal output
pub const Color = struct {
    reset: []const u8 = "\x1b[0m",
    bold: []const u8 = "\x1b[1m",
    dim: []const u8 = "\x1b[2m",

    // Foreground colors
    black: []const u8 = "\x1b[30m",
    red: []const u8 = "\x1b[31m",
    green: []const u8 = "\x1b[32m",
    yellow: []const u8 = "\x1b[33m",
    blue: []const u8 = "\x1b[34m",
    magenta: []const u8 = "\x1b[35m",
    cyan: []const u8 = "\x1b[36m",
    white: []const u8 = "\x1b[37m",

    // Bright foreground colors
    bright_black: []const u8 = "\x1b[90m",
    bright_red: []const u8 = "\x1b[91m",
    bright_green: []const u8 = "\x1b[92m",
    bright_yellow: []const u8 = "\x1b[93m",
    bright_blue: []const u8 = "\x1b[94m",
    bright_magenta: []const u8 = "\x1b[95m",
    bright_cyan: []const u8 = "\x1b[96m",
    bright_white: []const u8 = "\x1b[97m",
};

/// Enable/disable colored output
var use_color: bool = true;

/// Control colored output
pub fn setColor(enabled: bool) void {
    use_color = enabled;
}

/// Get current color setting
pub fn getColor() bool {
    return use_color;
}

/// Log level severity
pub const Level = enum(u2) {
    debug,
    info,
    warn,
    err,
};

/// Global log level - can be set at runtime
var current_level: Level = .info;

/// Set the global log level
pub fn setLevel(level: Level) void {
    current_level = level;
}

/// Get the current log level
pub fn getLevel() Level {
    return current_level;
}

/// Log a message at the specified level
pub fn log(
    level: Level,
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) {
        return;
    }

    const prefix = switch (level) {
        .debug => "[DBG]",
        .info => "[INF]",
        .warn => "[WRN]",
        .err => "[ERR]",
    };

    std.debug.print("{s} ", .{prefix});
    std.debug.print(format, args);
    std.debug.print("\n", .{});
}

/// Convenience functions for each log level
pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(.warn, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log(.err, format, args);
}

/// Debug-only logging - only compiles in debug builds
pub fn debugOnly(comptime format: []const u8, args: anytype) void {
    if (@import("builtin").mode == .Debug) {
        log(.debug, format, args);
    }
}

/// Assert with logging - logs before panicking in debug mode
pub fn debugAssert(ok: bool, message: []const u8) void {
    if (!ok) {
        log(.err, "Assertion failed: {s}", .{message});
        if (@import("builtin").mode == .Debug) {
            @panic(message);
        }
    }
}

test "log level filtering" {
    // Test that setLevel correctly changes the log level
    try std.testing.expectEqual(Level.info, getLevel());

    setLevel(.warn);
    try std.testing.expectEqual(Level.warn, getLevel());

    // Verify: debug (0) < warn (2), so debug would be filtered
    const debug_int = @intFromEnum(Level.debug);
    const warn_int = @intFromEnum(getLevel());
    try std.testing.expectEqual(true, debug_int < warn_int);

    setLevel(.debug);
    try std.testing.expectEqual(Level.debug, getLevel());
}

test "debug assert" {
    debugAssert(true, "this should pass");
}
