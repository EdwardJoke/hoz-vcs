//! File Checkout - Checkout individual files from blobs
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Blob = @import("../object/blob.zig").Blob;
const ODB = @import("../object/odb.zig").ODB;

pub const FileCheckout = struct {
    allocator: std.mem.Allocator,
    io: Io,
    odb: *ODB,

    pub fn init(allocator: std.mem.Allocator, io: Io, odb: *ODB) FileCheckout {
        return .{
            .allocator = allocator,
            .io = io,
            .odb = odb,
        };
    }

    pub fn checkoutFile(
        self: *FileCheckout,
        blob_oid: OID,
        dest_path: []const u8,
    ) !void {
        const blob_data = try self.odb.readObject(blob_oid);
        defer self.allocator.free(blob_data);

        const cwd = Io.Dir.cwd();
        var file = try cwd.createFile(self.io, dest_path, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(blob_data);
    }

    pub fn checkoutFileToFd(
        self: *FileCheckout,
        blob_oid: OID,
        dest_fd: Io.File,
    ) !void {
        const blob_data = try self.odb.readObject(blob_oid);
        defer self.allocator.free(blob_data);

        var writer = dest_fd.writer(self.io, &.{});
        try writer.interface.writeAll(blob_data);
    }

    pub fn getBlobContent(self: *FileCheckout, blob_oid: OID) ![]u8 {
        return try self.odb.readObject(blob_oid);
    }
};

test "FileCheckout init" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}

test "FileCheckout init with odb" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.odb == &odb);
}

test "FileCheckout checkoutFile rejects empty path" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, undefined, &odb);

    const result = checkout.checkoutFile(OID{ .bytes = [_]u8{0} ** 20 }, "");
    try std.testing.expectError(error.FileNotFound, result);
}

test "FileCheckout getBlobContent delegates to odb" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, undefined, &odb);

    try std.testing.expect(checkout.odb == &odb);
    const test_oid = OID{ .bytes = [_]u8{0xAA} ** 20 };
    const result = checkout.getBlobContent(test_oid);
    try std.testing.expectError(error.ObjectNotFound, result);
}
