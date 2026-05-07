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
        if (head_oid == null) {
            return &.{};
        }

        const oid = head_oid.?;

        if (self.odb) |odb| {
            if (odb.getObject(oid)) |obj| {
                defer obj.deinit();
                if (obj.data.len > 0) {
                    var parent_list = std.ArrayList(OID).init(self.allocator);
                    errdefer parent_list.deinit(self.allocator);

                    var header_iter = std.mem.splitScalar(u8, obj.data, '\n');
                    while (header_iter.next()) |line| {
                        if (std.mem.startsWith(u8, line, "parent ")) {
                            const parent_hex = line[7..47];
                            if (OID.fromHex(parent_hex)) |parent_oid| {
                                try parent_list.append(self.allocator, parent_oid);
                            }
                        } else if (line.len == 0) break;
                        if (std.mem.startsWith(u8, line, "tree ")) break;
                    }

                    if (parent_list.items.len > 0) {
                        return parent_list.toOwnedSlice(self.allocator);
                    }
                }
            }
        }

        return &.{};
    }

    pub fn resolveMergeBase(
        self: *ParentResolver,
        oid1: OID,
        oid2: OID,
    ) !?OID {
        if (self.odb == null) {
            return error.NoObjectDatabase;
        }

        var ancestors1 = std.AutoArrayHashMap(OID, void).init(self.allocator);
        defer ancestors1.deinit();

        var queue = std.ArrayList(OID).init(self.allocator);
        defer queue.deinit();
        try queue.append(oid1);

        while (queue.pop()) |current| {
            if (ancestors1.contains(current)) {
                continue;
            }
            try ancestors1.put(current, {});

            if (current.eql(oid2)) {
                return oid2;
            }

            if (self.odb) |odb| {
                if (odb.getObject(current)) |obj| {
                    if (obj.data.len > 0) {
                        var header_iter = std.mem.splitScalar(u8, obj.data, '\n');
                        while (header_iter.next()) |line| {
                            if (std.mem.startsWith(u8, line, "parent ")) {
                                const parent_hex = line[7..47];
                                if (OID.fromHex(parent_hex)) |parent_oid| {
                                    try queue.append(parent_oid);
                                }
                            } else if (line.len == 0) break;
                        }
                    }
                }
            }
        }

        queue.clearRetainingCapacity();
        try queue.append(oid2);

        while (queue.pop()) |current| {
            if (ancestors1.contains(current)) {
                return current;
            }
            try ancestors1.put(current, {});

            if (self.odb) |odb| {
                if (odb.getObject(current)) |obj| {
                    if (obj.data.len > 0) {
                        var header_iter2 = std.mem.splitScalar(u8, obj.data, '\n');
                        while (header_iter2.next()) |line| {
                            if (std.mem.startsWith(u8, line, "parent ")) {
                                const parent_hex = line[7..47];
                                if (OID.fromHex(parent_hex)) |parent_oid| {
                                    try queue.append(parent_oid);
                                }
                            } else if (line.len == 0) break;
                        }
                    }
                }
            }
        }

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

test "ParentResolver resolveParents with head but no odb returns empty" {
    var resolver = ParentResolver.init(std.testing.allocator, null);
    const head_oid = try OID.fromHex("abc123def456789012345678901234567890abcd");
    const parents = try resolver.resolveParents(head_oid);
    defer resolver.allocator.free(parents);

    try std.testing.expect(parents.len == 0);
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
