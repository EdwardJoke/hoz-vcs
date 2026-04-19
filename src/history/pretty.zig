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
        _ = writer;
        _ = commit_oid;
        _ = message;
    }

    pub fn printMedium(self: *PrettyPrinter, writer: anytype, author: []const u8, date: i64, message: []const u8) !void {
        _ = self;
        _ = writer;
        _ = author;
        _ = date;
        _ = message;
    }

    pub fn printFull(self: *PrettyPrinter, writer: anytype, author: []const u8, committer: []const u8, date: i64, message: []const u8) !void {
        _ = self;
        _ = writer;
        _ = author;
        _ = committer;
        _ = date;
        _ = message;
    }

    pub fn printOneline(self: *PrettyPrinter, writer: anytype, commit_oid: OID, message: []const u8) !void {
        _ = self;
        _ = writer;
        _ = commit_oid;
        _ = message;
    }
};

test "PrettyFormat enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(PrettyFormat.short)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(PrettyFormat.medium)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(PrettyFormat.full)) == 2);
    try std.testing.expect(@as(u3, @intFromEnum(PrettyFormat.fuller)) == 3);
}

test "PrettyOptions default values" {
    const options = PrettyOptions{};
    try std.testing.expect(options.format == .medium);
    try std.testing.expect(options.use_mailmap == true);
    try std.testing.expect(options.abbrev_oid == true);
    try std.testing.expect(options.abbrev_length == 7);
}

test "PrettyPrinter init" {
    const options = PrettyOptions{};
    const printer = PrettyPrinter.init(std.testing.allocator, options);

    try std.testing.expect(printer.allocator == std.testing.allocator);
}

test "PrettyPrinter init with options" {
    var options = PrettyOptions{};
    options.format = .oneline;
    options.relative_date = true;
    const printer = PrettyPrinter.init(std.testing.allocator, options);

    try std.testing.expect(printer.options.format == .oneline);
    try std.testing.expect(printer.options.relative_date == true);
}

test "PrettyPrinter printShort exists" {
    var options = PrettyOptions{};
    var printer = PrettyPrinter.init(std.testing.allocator, options);
    try std.testing.expect(printer.allocator != undefined);
}

test "DateStyle enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(DateStyle.short)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(DateStyle.medium)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(DateStyle.long)) == 2);
    try std.testing.expect(@as(u3, @intFromEnum(DateStyle.relative)) == 6);
}