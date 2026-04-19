//! Commit Parent Resolution - Handles parent commit resolution
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const ODB = @import("../object/odb.zig").ODB;

pub const ParentResolver = struct {
    allocator: std.mem.Allocator,
    odb: ?*ODB,

    pub fn init(allocator: std.mem.Allocator, odb: ?*ODB) ParentResolver {
        return .{
            .allocator = allocator,
            .odb = odb,
        };
    }

    pub fn resolveParents(
        self: *ParentResolver,
        head_oid: ?OID,
    ) ![]const OID {
        if (head_oid) |oid| {
            const parents = try self.allocator.alloc(OID, 1);
            parents[0] = oid;
            return parents;
        }
        return &.{};
    }

    pub fn resolveMergeBase(
        self: *ParentResolver,
        oid1: OID,
        oid2: OID,
    ) !?OID {
        _ = self;
        _ = oid1;
        _ = oid2;
        return null;
    }
};

pub fn getInitialCommitParents() []const OID {
    return &.{};
}

test "ParentResolver init" {
    const resolver = ParentResolver.init(std.testing.allocator, null);
    try std.testing.expect(resolver.allocator == std.testing.allocator);
}

test "ParentResolver init with odb" {
    const resolver = ParentResolver.init(std.testing.allocator, null);
    try std.testing.expect(resolver.allocator == std.testing.allocator);
}

test "ParentResolver resolveParents with head" {
    var resolver = ParentResolver.init(std.testing.allocator, null);
    const head_oid = try OID.fromHex("abc123def456789012345678901234567890abcd");
    const parents = try resolver.resolveParents(head_oid);
    defer resolver.allocator.free(parents);

    try std.testing.expect(parents.len == 1);
    try std.testing.expectEqual(head_oid, parents[0]);
}

test "ParentResolver resolveParents without head" {
    var resolver = ParentResolver.init(std.testing.allocator, null);
    const parents = try resolver.resolveParents(null);
    defer resolver.allocator.free(parents);

    try std.testing.expect(parents.len == 0);
}

test "getInitialCommitParents returns empty" {
    const parents = getInitialCommitParents();
    try std.testing.expect(parents.len == 0);
}
