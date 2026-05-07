//! History Pretty - Pretty print commit formats
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const PrettyFormat = enum {
    short,
    medium,
    full,
    fuller,
    email,
    raw,
};

pub const PrettyOptions = struct {
    format: PrettyFormat = .medium,
    use_mailmap: bool = true,
    show_signature: bool = false,
    abbrev_oid: bool = true,
    abbrev_length: u8 = 7,
    date_style: DateStyle = .short,
    relative_date: bool = false,
};

pub const DateStyle = enum {
    short,
    medium,
    long,
    iso,
    iso_strict,
    local,
    relative,
    raw,
};

const date_mod = @import("date.zig");

pub const PrettyPrinter = struct {
    allocator: std.mem.Allocator,
    options: PrettyOptions,

    pub fn init(allocator: std.mem.Allocator, options: PrettyOptions) PrettyPrinter {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn printShort(self: *PrettyPrinter, writer: anytype, commit_oid: OID, message: []const u8) !void {
        _ = self;
        try writer.print("{s} ", .{commit_oid.abbrev(7)});
        try writeFirstLine(writer, message);
        try writer.writeAll("\n");
    }

    pub fn printMedium(self: *PrettyPrinter, writer: anytype, author: []const u8, date: i64, message: []const u8) !void {
        _ = self;
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var w: std.Io.Writer = .fixed(&buf);
        try date_mod.formatMediumDate(date, &w);
        const date_str = std.Io.Writer.buffered(&w);

        try writer.print("{s}  {s}\n\n", .{ author, date_str });
        try writeIndentedMessage(writer, message, 4);
    }

    pub fn printFull(self: *PrettyPrinter, writer: anytype, author: []const u8, committer: []const u8, date: i64, message: []const u8) !void {
        _ = self;
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var w: std.Io.Writer = .fixed(&buf);
        try date_mod.formatLongDate(date, &w);
        const date_str = std.Io.Writer.buffered(&w);

        try writer.print("Author: {s}\nDate:   {s}\n\n", .{ author, date_str });
        try writeIndentedMessage(writer, message, 4);
        if (committer.len > 0 and !std.mem.eql(u8, committer, author)) {
            try writer.writeAll("\nCommit: ");
            try writer.writeAll(committer);
            try writer.writeAll("\n");
        }
    }

    pub fn printOneline(self: *PrettyPrinter, writer: anytype, commit_oid: OID, message: []const u8) !void {
        _ = self;
        const abbrev_len = self.options.abbrev_length;
        try writer.print("{s} ", .{commit_oid.abbrev(abbrev_len)});
        try writeFirstLine(writer, message);
        try writer.writeAll("\n");
    }
};

fn writeFirstLine(writer: anytype, message: []const u8) !void {
    const nl_idx = std.mem.indexOf(u8, message, "\n") orelse message.len;
    try writer.writeAll(message[0..nl_idx]);
}

fn writeIndentedMessage(writer: anytype, message: []const u8, indent: usize) !void {
    var lines = std.mem.splitSequence(u8, message, "\n");
    while (lines.next()) |line| {
        for (0..indent) |_| try writer.writeByte(' ');
        try writer.writeAll(line);
        try writer.writeAll("\n");
    }
}
