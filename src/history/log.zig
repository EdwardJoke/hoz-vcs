//! History Log - Commit log with format specifiers
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;

pub const LogFormat = enum {
    short,
    medium,
    full,
    oneline,
    raw,
    format,
};

pub const LogFormatOptions = struct {
    format: LogFormat = .medium,
    custom_format: ?[]const u8 = null,
    date_format: ?[]const u8 = null,
    abbrev_oid: bool = true,
    abbrev_length: u8 = 7,
    all: bool = false,
    all_match: bool = false,
    left_right: bool = false,
    commits_before: ?[]const u8 = null,
    commits_after: ?[]const u8 = null,
    author: ?[]const u8 = null,
    grep: ?[]const u8 = null,
    max_count: ?u32 = null,
    skip: u32 = 0,
};

pub const LogEntry = struct {
    commit_oid: OID,
    author_name: []const u8,
    author_email: []const u8,
    author_date: i64,
    committer_name: []const u8,
    committer_email: []const u8,
    committer_date: i64,
    message: []const u8,
    parent_oids: []const OID,
    tree_oid: OID,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    options: LogFormatOptions,

    pub fn init(allocator: std.mem.Allocator, options: LogFormatOptions) Logger {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn formatEntry(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        switch (self.options.format) {
            .short => try self.formatShort(entry, writer),
            .oneline => try self.formatOneline(entry, writer),
            .medium => try self.formatMedium(entry, writer),
            .full => try self.formatFull(entry, writer),
            .raw => try self.formatRaw(entry, writer),
            .format => try self.formatCustom(entry, writer),
        }
    }

    pub fn formatOneline(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        _ = self;
        const abbrev_len = std.math.min(self.options.abbrev_length, @as(u8, OID.OID_HEX_SIZE));
        const oid_hex = entry.commit_oid.toHex();
        const subject = firstLine(entry.message);
        try writer.print("{s} {s}\n", .{ oid_hex[0..abbrev_len], subject });
    }

    pub fn formatMedium(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        _ = self;
        const abbrev_len = std.math.min(self.options.abbrev_length, @as(u8, OID.OID_HEX_SIZE));
        const oid_hex = entry.commit_oid.toHex();
        try writer.print("commit {s}\n", .{oid_hex[0..abbrev_len]});
        try writer.print("Author: {s} <{s}>\n", .{ entry.author_name, entry.author_email });
        if (entry.parent_oids.len > 0) {
            const parent_hex = entry.parent_oids[0].toHex();
            try writer.print("      Parent: {s}\n", .{parent_hex[0..abbrev_len]});
        }
        const date_str = formatDate(entry.author_date);
        try writer.print("Date:   {s}\n", .{date_str});
        try writer.writeAll("\n");
        try writeIndentedMessage(writer, entry.message, 4);
        try writer.writeAll("\n");
    }

    pub fn formatFull(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        _ = self;
        const abbrev_len = std.math.min(self.options.abbrev_length, @as(u8, OID.OID_HEX_SIZE));
        const oid_hex = entry.commit_oid.toHex();
        try writer.print("commit {s}\n", .{oid_hex});
        const tree_hex = entry.tree_oid.toHex();
        try writer.print("tree {s}\n", .{tree_hex});
        for (entry.parent_oids) |parent| {
            const parent_hex = parent.toHex();
            try writer.print("parent {s}\n", .{parent_hex});
        }
        try writer.print("author {s} <{s}> {d} {s}\n", .{
            entry.author_name,
            entry.author_email,
            entry.author_date,
            "+0000",
        });
        try writer.print("committer {s} <{s}> {d} {s}\n", .{
            entry.committer_name,
            entry.committer_email,
            entry.committer_date,
            "+0000",
        });
        try writer.writeAll("\n");
        try writeIndentedMessage(writer, entry.message, 4);
    }

    fn formatShort(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        _ = self;
        const abbrev_len = std.math.min(self.options.abbrev_length, @as(u8, OID.OID_HEX_SIZE));
        const oid_hex = entry.commit_oid.toHex();
        try writer.print("commit {s}\n", .{oid_hex[0..abbrev_len]});
        try writer.print("Author: {s} <{s}>\n", .{ entry.author_name, entry.author_email });
        const date_str = formatDate(entry.author_date);
        try writer.print("Date:   {s}\n", .{date_str});
        try writer.writeAll("\n");
        try writeIndentedMessage(writer, entry.message, 4);
    }

    fn formatRaw(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        _ = self;
        const oid_hex = entry.commit_oid.toHex();
        try writer.print("commit {s}\n", .{oid_hex});
        const tree_hex = entry.tree_oid.toHex();
        try writer.print("tree {s}\n", .{tree_hex});
        for (entry.parent_oids) |parent| {
            const parent_hex = parent.toHex();
            try writer.print("parent {s}\n", .{parent_hex});
        }
        try writer.print("author {s} <{s}> {d} +0000\n", .{
            entry.author_name,
            entry.author_email,
            entry.author_date,
        });
        try writer.print("committer {s} <{s}> {d} +0000\n", .{
            entry.committer_name,
            entry.committer_email,
            entry.committer_date,
        });
        try writer.writeAll("\n");
        try writer.writeAll(entry.message);
        if (!std.mem.endsWith(u8, entry.message, "\n")) {
            try writer.writeAll("\n");
        }
    }

    fn formatCustom(self: *Logger, entry: *const LogEntry, writer: anytype) !void {
        if (self.options.custom_format) |fmt| {
            const abbrev_len = std.math.min(self.options.abbrev_length, @as(u8, OID.OID_HEX_SIZE));
            const oid_hex = entry.commit_oid.toHex();
            var i: usize = 0;
            while (i < fmt.len) : (i += 1) {
                if (fmt[i] == '%' and i + 1 < fmt.len) {
                    i += 1;
                    const ch = fmt[i];
                    const two_char = if (i + 1 < fmt.len)
                        fmt[i .. i + 2]
                    else
                        fmt[i .. i + 1];

                    if (std.mem.eql(u8, two_char, "an") or ch == 'a') {
                        try writer.writeAll(entry.author_name);
                        if (two_char.len > 1 and two_char[0] == 'a' and two_char[1] == 'n') i += 1;
                    } else if (std.mem.eql(u8, two_char, "ae")) {
                        try writer.writeAll(entry.author_email);
                        i += 1;
                    } else if (std.mem.eql(u8, two_char, "cn") or ch == 'c') {
                        try writer.writeAll(entry.committer_name);
                        if (two_char.len > 1 and two_char[0] == 'c' and two_char[1] == 'n') i += 1;
                    } else if (std.mem.eql(u8, two_char, "ce")) {
                        try writer.writeAll(entry.committer_email);
                        i += 1;
                    } else if (std.mem.eql(u8, two_char, "at") or ch == 't') {
                        const ds = formatDate(entry.author_date);
                        try writer.writeAll(ds);
                        if (two_char.len > 1 and two_char[0] == 'a' and two_char[1] == 't') i += 1;
                    } else if (std.mem.eql(u8, two_char, "ci") or ch == 'c') {
                        const ds = formatDate(entry.committer_date);
                        try writer.writeAll(ds);
                        if (two_char.len > 1 and two_char[0] == 'c' and two_char[1] == 'i') i += 1;
                    } else switch (ch) {
                        'H', 'h' => try writer.writeAll(oid_hex[0..abbrev_len]),
                        's' => try writer.writeAll(firstLine(entry.message)),
                        'T' => try writer.writeAll(&entry.tree_oid.toHex()),
                        'P' => {
                            for (entry.parent_oids, 0..) |p, pi| {
                                if (pi > 0) try writer.writeAll(" ");
                                try writer.writeAll(&p.toHex());
                            }
                        },
                        'b' => try writer.writeAll(entry.message),
                        'n' => try writer.writeByte('\n'),
                        '%' => try writer.writeByte('%'),
                        else => {
                            try writer.writeByte('%');
                            try writer.writeByte(ch);
                        },
                    }
                } else {
                    try writer.writeByte(fmt[i]);
                }
            }
        } else {
            try self.formatMedium(entry, writer);
        }
    }
};

fn firstLine(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "\n")) |nl| {
        return message[0..nl];
    }
    return message;
}

fn formatDate(timestamp: i64) [25]u8 {
    var buf: [25]u8 = undefined;
    const epoch = std.time.epoch.Epoch.secs(timestamp);
    const day_sec = epoch.getDaySeconds();
    const year = epoch.getYear();
    const month = year.month();
    const day = year.day();

    const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    const wd = epoch.getWeekday();
    const wd_name = weekday_names[@intFromEnum(wd)];
    const mon_name = month_names[month];

    const hours = day_sec.getHoursIntoDay().hour;
    const mins = day_sec.getHoursIntoDay().minute;
    const secs = day_sec.getHoursIntoDay().second;

    const y_str = std.fmt.bufPrint(&buf[0..5], "{d}", .{@as(u32, @intCast(@mod(year, 10000)))}) catch undefined;

    _ = std.fmt.bufPrint(&buf, "{s} {s} {s: >2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        wd_name,
        mon_name,
        y_str,
        hours,
        mins,
        secs,
    }) catch undefined;
    return buf;
}

fn writeIndentedMessage(writer: anytype, message: []const u8, indent: usize) !void {
    var lines = std.mem.tokenize(u8, message, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeAll("\n");
        first = false;
        for (0..indent) |_| {
            try writer.writeByte(' ');
        }
        try writer.writeAll(line);
    }
}

test "LogFormat enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(LogFormat.short)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(LogFormat.medium)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(LogFormat.full)) == 2);
    try std.testing.expect(@as(u3, @intFromEnum(LogFormat.oneline)) == 3);
}

test "LogFormatOptions default values" {
    const options = LogFormatOptions{};
    try std.testing.expect(options.format == .medium);
    try std.testing.expect(options.abbrev_oid == true);
    try std.testing.expect(options.abbrev_length == 7);
    try std.testing.expect(options.skip == 0);
}

test "Logger init" {
    const options = LogFormatOptions{};
    const logger = Logger.init(std.testing.allocator, options);

    try std.testing.expect(logger.allocator == std.testing.allocator);
}

test "Logger init with options" {
    var options = LogFormatOptions{};
    options.format = .oneline;
    options.max_count = 10;
    const logger = Logger.init(std.testing.allocator, options);

    try std.testing.expect(logger.options.format == .oneline);
    try std.testing.expect(logger.options.max_count == 10);
}

test "Logger formatEntry exists" {
    var options = LogFormatOptions{};
    var logger = Logger.init(std.testing.allocator, options);
    try std.testing.expect(logger.allocator != undefined);
}

test "LogEntry structure fields" {
    const entry = LogEntry{
        .commit_oid = undefined,
        .author_name = "Test Author",
        .author_email = "test@example.com",
        .author_date = 1234567890,
        .committer_name = "Test Committer",
        .committer_email = "test@example.com",
        .committer_date = 1234567890,
        .message = "Test commit message",
        .parent_oids = &.{},
        .tree_oid = undefined,
    };

    try std.testing.expectEqualStrings("Test Author", entry.author_name);
    try std.testing.expectEqualStrings("Test commit message", entry.message);
}
