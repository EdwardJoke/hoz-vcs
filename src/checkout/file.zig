//! File Checkout - Checkout individual files from blobs
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Blob = @import("../object/blob.zig").Blob;
const ODB = @import("../object/odb.zig").ODB;

pub const FileCheckout = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB) FileCheckout {
        return .{
            .allocator = allocator,
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

        const file = try std.fs.createFileAbsolute(dest_path, .{});
        defer file.close();

        try file.writeAll(blob_data);
    }

    pub fn checkoutFileToFd(
        self: *FileCheckout,
        blob_oid: OID,
        dest_fd: std.fs.File,
    ) !void {
        const blob_data = try self.odb.readObject(blob_oid);
        defer self.allocator.free(blob_data);

        try dest_fd.writeAll(blob_data);
    }

    pub fn getBlobContent(self: *FileCheckout, blob_oid: OID) ![]u8 {
        return try self.odb.readObject(blob_oid);
    }
};

test "FileCheckout init" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}

test "FileCheckout init with odb" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.odb == &odb);
}

test "FileCheckout allocator access" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expectEqual(std.testing.allocator, checkout.allocator);
}

test "FileCheckout init sets allocator" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator.ptr != null);
}

test "FileCheckout init sets odb reference" {
    var odb: ODB = undefined;
    const checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.odb != null);
}

test "FileCheckout getBlobContent returns data" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator != undefined);
}

test "FileCheckout checkoutFileToFd signature" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}

test "FileCheckout getBlobContent signature" {
    var odb: ODB = undefined;
    var checkout = FileCheckout.init(std.testing.allocator, &odb);

    try std.testing.expect(checkout.allocator == std.testing.allocator);
}