//! History Date - Date formatting utilities
const std = @import("std");

pub const DateFormat = enum {
    short,
    medium,
    long,
    iso,
    iso_strict,
    local,
    relative,
    raw,
    unix,
    custom,
};

const SECONDS_PER_MINUTE: i64 = 60;
const SECONDS_PER_HOUR: i64 = 3600;
const SECONDS_PER_DAY: i64 = 86400;
const SECONDS_PER_WEEK: i64 = 604800;
const SECONDS_PER_MONTH: i64 = 2592000;
const SECONDS_PER_YEAR: i64 = 31536000;

pub const DateFormatter = struct {
    allocator: std.mem.Allocator,
    format: DateFormat,
    custom_pattern: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, format: DateFormat) DateFormatter {
        return .{
            .allocator = allocator,
            .format = format,
            .custom_pattern = null,
        };
    }

    pub fn initCustom(allocator: std.mem.Allocator, pattern: []const u8) DateFormatter {
        return .{
            .allocator = allocator,
            .format = .custom,
            .custom_pattern = pattern,
        };
    }

    pub fn formatTimestamp(self: *DateFormatter, timestamp: i64, writer: anytype) !void {
        switch (self.format) {
            .short => try formatShortDate(timestamp, writer),
            .medium => try formatMediumDate(timestamp, writer),
            .long => try formatLongDate(timestamp, writer),
            .iso, .iso_strict => try formatIsoDate(timestamp, writer),
            .local, .raw => try formatMediumDate(timestamp, writer),
            .relative => try formatRelativeDate(timestamp, writer),
            .unix => try writer.print("{d}", .{timestamp}),
            .custom => {
                if (self.custom_pattern) |pat| {
                    _ = pat;
                    try formatIsoDate(timestamp, writer);
                } else {
                    try formatShortDate(timestamp, writer);
                }
            },
        }
    }

    pub fn formatRelative(self: *DateFormatter, timestamp: i64, writer: anytype) !void {
        _ = self;
        try formatRelativeDate(timestamp, writer);
    }

    pub fn toUnix(timestamp: i64) i64 {
        return timestamp;
    }

    pub fn fromUnix(unix_time: i64) i64 {
        return unix_time;
    }
};

fn epochToParts(ts: i64) struct { year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8 } {
    var remaining = ts;
    const days: i64 = @divTrunc(remaining, SECONDS_PER_DAY);
    remaining -= days * SECONDS_PER_DAY;
    if (remaining < 0) remaining += SECONDS_PER_DAY;
    const hour: u8 = @intCast(@divTrunc(remaining, SECONDS_PER_HOUR));
    remaining -= @as(i64, hour) * SECONDS_PER_HOUR;
    const minute: u8 = @intCast(@divTrunc(remaining, SECONDS_PER_MINUTE));
    remaining -= @as(i64, minute) * SECONDS_PER_MINUTE;
    const second: u8 = @intCast(if (remaining < 0) 0 else remaining);

    var y: i32 = 1970;
    var d = days;
    while (d >= 365 or (d == 364 and isLeapYear(y))) : (y += 1) {
        const days_in_year: i64 = if (isLeapYear(y)) 366 else 365;
        d -= days_in_year;
    }
    while (d < 0) : (y -= 1) {
        d += if (isLeapYear(y - 1)) 366 else 365;
    }

    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 0;
    var dd = @as(u32, @intCast(d));
    for (month_days) |md, idx| {
        var dim = md;
        if (idx == 1 and isLeapYear(y)) dim += 1;
        if (dd < dim) break;
        dd -= dim;
        m = @intCast(idx + 1);
    }

    return .{
        .year = y,
        .month = m + 1,
        .day = @intCast(dd + 1),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn isLeapYear(year: i32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

pub fn formatShortDate(timestamp: i64, writer: anytype) !void {
    const p = epochToParts(timestamp);
    try writer.print("{d}-{d:0>2}-{d:0>2}", .{ p.year, p.month, p.day });
}

pub fn formatMediumDate(timestamp: i64, writer: anytype) !void {
    const p = epochToParts(timestamp);
    try writer.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ p.year, p.month, p.day, p.hour, p.minute, p.second });
}

pub fn formatLongDate(timestamp: i64, writer: anytype) !void {
    const p = epochToParts(timestamp);
    const dow = dayOfWeek(p.year, p.month, p.day);
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    try writer.print "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        dow_names[dow], mon_names[p.month - 1], p.day, p.hour, p.minute, p.second, p.year
    };
}

fn dayOfWeek(year: i32, month: u8, day: u8) usize {
    const y: i32 = if (month < 3) year - 1 else year;
    const m: i32 = if (month < 3) @as(i32, month) + 12 else @as(i32, month);
    const k: i32 = @as(i32, day);
    const q: i32 = @divTrunc(13 * (m + 1), 5);
    const j: i32 = @divTrunc(y, 100);
    const rem_y = y - j * 100;
    const h = (k + q + rem_y + @divTrunc(rem_y, 4) + @divTrunc(j, 4) - 2 * j) % 7;
    return @intCast(if (h < 0) h + 7 else h);
}

pub fn formatIsoDate(timestamp: i64, writer: anytype) !void {
    const p = epochToParts(timestamp);
    try writer.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ p.year, p.month, p.day, p.hour, p.minute, p.second });
}

pub fn formatRelativeDate(timestamp: i64, writer: anytype) !void {
    const now: i64 = @intCast(std.time.timestamp());
    const diff = now - timestamp;
    if (diff < 0) {
        try writer.writeAll("just now");
        return;
    }
    if (diff < SECONDS_PER_MINUTE) {
        try writer.print("{d} seconds ago", .{diff});
    } else if (diff < SECONDS_PER_HOUR) {
        try writer.print("{d} minutes ago", .{@divTrunc(diff, SECONDS_PER_MINUTE)});
    } else if (diff < SECONDS_PER_DAY) {
        try writer.print("{d} hours ago", .{@divTrunc(diff, SECONDS_PER_HOUR)});
    } else if (diff < SECONDS_PER_WEEK) {
        try writer.print("{d} days ago", .{@divTrunc(diff, SECONDS_PER_DAY)});
    } else if (diff < SECONDS_PER_MONTH) {
        try writer.print("{d} weeks ago", .{@divTrunc(diff, SECONDS_PER_WEEK)});
    } else if (diff < SECONDS_PER_YEAR) {
        try writer.print("{d} months ago", .{@divTrunc(diff, SECONDS_PER_MONTH)});
    } else {
        try writer.print("{d} years ago", .{@divTrunc(diff, SECONDS_PER_YEAR)});
    }
}

pub fn parseDate(date_str: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, date_str, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDateFormat;

    if (std.mem.eql(u8, trimmed, "now")) return std.time.timestamp();

    const ts = std.fmt.parseInt(i64, trimmed, 10) catch null;
    if (ts) |t| return t;

    if (trimmed.len >= 10 and trimmed[4] == '-' and trimmed[7] == '-') {
        const year = std.fmt.parseInt(i32, trimmed[0..4], 10) catch return error.InvalidDateFormat;
        const month = std.fmt.parseInt(u8, trimmed[5..7], 10) catch return error.InvalidDateFormat;
        const day = std.fmt.parseInt(u8, trimmed[8..10], 10) catch return error.InvalidDateFormat;
        var result: i64 = 0;
        var y: i32 = 1970;
        while (y < year) : (y += 1) {
            result += if (isLeapYear(y)) @as(i64, 366 * SECONDS_PER_DAY) else @as(i64, 365 * SECONDS_PER_DAY);
        }
        var m: u8 = 1;
        while (m < month) : (m += 1) {
            const md: u8 = switch (m) {
                1, 3, 5, 7, 8, 10, 12 => 31,
                4, 6, 9, 11 => 30,
                2 => if (isLeapYear(year)) 29 else 28,
                else => 30,
            };
            result += @as(i64, md) * SECONDS_PER_DAY;
        }
        result += @as(i64, day - 1) * SECONDS_PER_DAY;
        return result;
    }

    return error.InvalidDateFormat;
}
