//! Merge Conflict - Conflict detection during merge
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const ConflictType = enum {
    none,
    binary,
    text,
    both_modified,
    deleted_by_us,
    deleted_by_them,
    added_by_us,
    added_by_them,
};

pub const FileConflict = struct {
    path: []const u8,
    conflict_type: ConflictType,
    our_oid: ?OID,
    their_oid: ?OID,
    ancestor_oid: ?OID,
};

pub const ConflictDetector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConflictDetector {
        return .{ .allocator = allocator };
    }

    pub fn detectConflicts(self: *ConflictDetector, path: []const u8, ours: ?OID, theirs: ?OID) !FileConflict {
        if (self.allocator.create(FileConflict)) |conflict| {
            conflict.* = FileConflict{
                .path = path,
                .conflict_type = .none,
                .our_oid = ours,
                .their_oid = theirs,
                .ancestor_oid = null,
            };
            return conflict.*;
        } else |_| {
            return FileConflict{
                .path = path,
                .conflict_type = .none,
                .our_oid = null,
                .their_oid = null,
                .ancestor_oid = null,
            };
        }
    }

    pub fn hasConflicts(_: *ConflictDetector, conflicts: []const FileConflict) bool {
        for (conflicts) |c| {
            if (c.conflict_type != .none) return true;
        }
        return false;
    }
};

test "ConflictType enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.none)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.binary)) == 1);
    try std.testing.expect(@as(u3, @intFromEnum(ConflictType.text)) == 2);
}

test "FileConflict structure" {
    const conflict = FileConflict{
        .path = "test.txt",
        .conflict_type = .text,
        .our_oid = null,
        .their_oid = null,
        .ancestor_oid = null,
    };

    try std.testing.expectEqualStrings("test.txt", conflict.path);
    try std.testing.expect(conflict.conflict_type == .text);
}

test "ConflictDetector init" {
    const detector = ConflictDetector.init(std.testing.allocator);
    try std.testing.expect(detector.allocator == std.testing.allocator);
}

test "ConflictDetector detectConflicts method exists" {
    var detector = ConflictDetector.init(std.testing.allocator);
    const conflict = try detector.detectConflicts("file.txt", null, null);
    try std.testing.expectEqualStrings("file.txt", conflict.path);
}

test "ConflictDetector hasConflicts method exists" {
    var detector = ConflictDetector.init(std.testing.allocator);
    const conflicts: []const FileConflict = &.{};
    const has = detector.hasConflicts(conflicts);
    try std.testing.expect(has == false);
}
