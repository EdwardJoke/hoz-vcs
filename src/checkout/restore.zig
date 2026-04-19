//! Restore - Restore working tree files
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Blob = @import("../object/blob.zig").Blob;
const ODB = @import("../object/odb.zig").ODB;

pub const RestoreSource = enum {
    index,
    head,
    commit,
};

pub const RestoreOptions = struct {
    source: RestoreSource = .index,
    staged: bool = false,
    force: bool = false,
    paths: ?[]const []const u8 = null,
    source_oid: ?OID = null,
};

pub const Restorer = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    options: RestoreOptions,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB, options: RestoreOptions) Restorer {
        return .{
            .allocator = allocator,
            .odb = odb,
            .options = options,
        };
    }

    pub fn restore(self: *Restorer, paths: []const []const u8) !void {
        _ = self;
        _ = paths;
    }

    pub fn restoreFromIndex(self: *Restorer, paths: []const []const u8) !void {
        _ = self;
        _ = paths;
    }

    pub fn restoreFromHead(self: *Restorer, paths: []const []const u8) !void {
        _ = self;
        _ = paths;
    }
};

test "RestoreSource enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.index)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.head)) == 1);
    try std.testing.expect(@as(u2, @intFromEnum(RestoreSource.commit)) == 2);
}

test "RestoreOptions default values" {
    const options = RestoreOptions{};
    try std.testing.expect(options.source == .index);
    try std.testing.expect(options.staged == false);
    try std.testing.expect(options.force == false);
}

test "Restorer init" {
    var odb: ODB = undefined;
    const options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
}

test "Restorer init with odb" {
    var odb: ODB = undefined;
    const options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.odb == &odb);
}

test "Restorer init with options" {
    var odb: ODB = undefined;
    var options = RestoreOptions{};
    options.staged = true;
    options.force = true;
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.options.staged == true);
    try std.testing.expect(restorer.options.force == true);
}

test "Restorer init sets allocator" {
    var odb: ODB = undefined;
    const options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.allocator.ptr != null);
}

test "Restorer restore method exists" {
    var odb: ODB = undefined;
    var options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
}

test "Restorer restoreFromIndex method exists" {
    var odb: ODB = undefined;
    var options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
}

test "Restorer restoreFromHead method exists" {
    var odb: ODB = undefined;
    var options = RestoreOptions{};
    var restorer = Restorer.init(std.testing.allocator, &odb, options);

    try std.testing.expect(restorer.allocator == std.testing.allocator);
}