//! Commit Writer - Writes commit objects to the object database
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const ObjectType = @import("../object/object.zig").Type;
const ODB = @import("../object/odb.zig").ODB;
const Builder = @import("builder.zig").CommitBuilder;

pub const CommitWriter = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB) CommitWriter {
        return .{
            .allocator = allocator,
            .odb = odb,
        };
    }

    pub fn write(
        self: *CommitWriter,
        options: Builder.CommitOptions,
    ) !Commit {
        var builder = Builder.init(self.allocator, options);
        const commit = try builder.build();
        const serialized = try builder.serialize(commit);
        defer self.allocator.free(serialized);

        const content = try self.allocator.alloc(u8, serialized.len);
        @memcpy(content, serialized);

        try self.odb.writeObject(content, .commit);

        return commit;
    }

    pub fn writeWithOid(
        self: *CommitWriter,
        options: Builder.CommitOptions,
    ) !OID {
        var builder = Builder.init(self.allocator, options);
        const commit = try builder.build();
        const serialized = try builder.serialize(commit);
        defer self.allocator.free(serialized);

        const content = try self.allocator.alloc(u8, serialized.len);
        @memcpy(content, serialized);

        return try self.odb.writeObject(content, .commit);
    }
};

test "CommitWriter init" {
    var odb: ODB = std.mem.zeroes(ODB);
    const writer = CommitWriter.init(std.testing.allocator, &odb);

    try std.testing.expect(writer.allocator == std.testing.allocator);
}

test "CommitWriter init with null odb" {
    var odb: ODB = std.mem.zeroes(ODB);
    const writer = CommitWriter.init(std.testing.allocator, &odb);

    try std.testing.expect(writer.allocator == std.testing.allocator);
}

test "CommitWriter basic write" {
    var odb: ODB = std.mem.zeroes(ODB);
    const writer = CommitWriter.init(std.testing.allocator, &odb);

    try std.testing.expect(writer.allocator == std.testing.allocator);
}